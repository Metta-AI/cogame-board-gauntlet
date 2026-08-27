## Board Gauntlet game server: implements the Coworld game contract.
##
## Endpoints, in registration order (all before any catch-all, because the
## certifier probes /healthz and both client routes BEFORE the player pods
## start and neither client route may open the player socket):
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - the game block
##   GET /client/chrome_common.js    - the inherited chrome
##   GET /client/chrome.css
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - gauntlet.player.v1 (live mode only)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Play is strictly alternating: exactly one seat decides per ply and the
## next observation cannot be built until this move is applied, so LLM
## calls go out one at a time by construction. A simultaneous-decision
## variant would have to issue them as one parallel batch instead.

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  ReplayProtocol = "gauntlet.replay.v1"
  PlayerProtocol = "gauntlet.player.v1"
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts - the part
  ## that must never be the thing that runs out of time.
  PlayBudgetFraction* = 0.6
  ## The certifier pings /global AFTER the player pods start, so keep
  ## answering for a moment once the artifacts have landed.
  ShutdownGraceSeconds = 20

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    baselines: seq[string]      ## "" = LLM seat, else the baseline's name
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous cog aliases; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.boardStateJson()
  result["type"] = %"state"
  result["game"] = %"board-gauntlet"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Redacted to the seat's own tallies. It carries no board and no move
  ## list because DECISIONS ARE SERVER-SIDE, so this loses the policy
  ## nothing; it also means no wire exists on which two seats could
  ## coordinate.
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "game": $gs.config.game,
    "ply": gs.sim.ply,
    "maxPlies": gs.config.maxPlies,
    "seat": {
      "score": gs.sim.score(slot),
      "standing": gs.sim.standing(slot),
      "captures": gs.sim.captures[slot],
      "wallsLeft": gs.sim.wallsLeft[slot],
      "fallbacks": gs.sim.fallbacks[slot]
    },
    "toMove": (not gs.sim.done and gs.sim.mover == slot),
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason,
    "ending": gs.sim.ending
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole snapshot; players get
  ## the redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayConfigJson(config: GameConfig): JsonNode =
  %*{
    "game": $config.game,
    "rotated": config.rotated,
    "size": config.size,
    "walls": config.walls,
    "first": config.first,
    "seed": config.seed,
    "maxPlies": config.maxPlies,
    "sampled": true
  }

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": ReplayProtocol,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": replayConfigJson(gs.config),
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.boardStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection. Results carry POLICY
    ## names for the platform; the final frame hands the seats their
    ## anonymous aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "outcome": results["outcome"],
      "names": aliasNames,
      "game": results["game"],
      "plies": results["plies"],
      "reason": results["reason"],
      "ending": results["ending"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "board-gauntlet: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## Keep /healthz and /global answering while the certifier catches up.
  echo "board-gauntlet: artifacts written; ", ShutdownGraceSeconds,
    "s shutdown grace"
  sleep(ShutdownGraceSeconds * 1000)
  echo "board-gauntlet: episode complete, shutting down"
  quit(0)

proc moveText(sim: Sim, seat: int, move: string): string =
  sim.names[seat] & " plays " & move

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "board-gauntlet: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing, and
    ## the hosted dispatcher hands that timeout only to its own worker
    ## sidecar, NOT to the game container, so when the env is silent assume
    ## the configured default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    let plySpacing =
      if config.plySpacingSeconds > 0: config.plySpacingSeconds
      else: DerivedPlySpacingSeconds
    ## The pathological case is latency, not length: one ply can cost the
    ## spacing floor, then the call plus one retry, then apply/broadcast,
    ## then the turn delay -- and every one of those runs AFTER the guard,
    ## so all four are in the worst case it refuses to open a ply against.
    ## Refuse to OPEN a ply that could outrun the budget rather than
    ## stopping mid-ply.
    let worstPlySeconds = float(2 * config.llmTimeoutSeconds + 2) +
      plySpacing.float + config.turnDelayMs.float / 1000.0
    if playDeadline > 0.0:
      echo "board-gauntlet: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int,
        "s, worst ply ", worstPlySeconds.int, "s"
    var lastLlmStart = 0.0

    while true:
      var simCopy: Sim
      var seatPrompt: string
      var seatBaseline: string
      var mover = -1
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and
            epochTime() + worstPlySeconds > playDeadline:
          echo "board-gauntlet: play deadline reached after ",
            state.sim.plies, "/", config.maxPlies,
            " plies; settling on the position"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        mover = state.sim.mover
        simCopy = state.sim
        seatPrompt = state.prompts[mover]
        seatBaseline = state.baselines[mover]

      let usesLlm = seatBaseline.len == 0 and not client.disabled
      if usesLlm and lastLlmStart > 0.0:
        ## The Bedrock sidecar caps requests per minute per episode; gate
        ## LLM plies only, so the all-scripted path is unaffected.
        let wait = plySpacing.float - (epochTime() - lastLlmStart)
        if wait > 0.0:
          sleep(int(wait * 1000))
      if usesLlm:
        lastLlmStart = epochTime()

      ## The slow part (Claude) runs outside the lock on a snapshot; only
      ## this thread mutates the sim, so the snapshot cannot go stale.
      let decision = client.decide(simCopy, seatPrompt, seatBaseline)

      withLock stateLock:
        if decision.illegal:
          inc state.sim.illegalReplies[mover]
        try:
          state.sim.applyMove(decision.move, decision.say, decision.notes,
            decision.scripted, decision.fellBack)
        except GauntletError as error:
          echo "board-gauntlet: move rejected (",
            cleanText(error.msg, MaxErrorLen),
            "); falling back to the tactician baseline"
          let fallback = tacticianMove(state.sim)
          state.sim.applyMove(fallback, "", "", false, true)
        echo "board-gauntlet: ply ", state.sim.plies, "/", config.maxPlies,
          " ", moveText(state.sim, mover, state.sim.lastMove), " at ",
          (epochTime() - gameStart).int, "s"
        state.broadcastLocked()

      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc scriptHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name,
        "application/javascript; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "board-gauntlet: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": PlayerProtocol,
        "slot": slot,
        "name": state.sim.names[slot],
        "seats": 2,
        "game": $state.config.game,
        "rotated": state.config.rotated,
        "size": state.config.size,
        "walls": state.config.walls,
        "first": state.config.first,
        "maxPlies": state.config.maxPlies
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          let prompt = cleanText(payload{"prompt"}.getStr(), MaxPromptLen)
          var baseline = ""
          let scriptedNode = payload{"scripted"}
          if scriptedNode != nil:
            case scriptedNode.kind
            of JBool:
              baseline = if scriptedNode.getBool(): "tactician" else: ""
            of JString:
              if isScriptedName(scriptedNode.getStr()):
                baseline = $parseBaseline(scriptedNode.getStr())
            else:
              discard
          withLock stateLock:
            state.prompts[slot] = prompt
            state.baselines[slot] = baseline
          echo "board-gauntlet: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if baseline.len > 0: ", scripted " & baseline else: ""), ")"
      except CatchableError as error:
        echo "board-gauntlet: ignoring bad player frame: ",
          cleanText(error.msg, MaxErrorLen)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay_broadcast.html"))
  result.get("/client/renderer.js", scriptHandler("renderer.js"))
  result.get("/client/chrome_common.js", scriptHandler("chrome_common.js"))
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  let node = payload["config"]
  result.game = parseGame(node{"game"}.getStr("connect-four"))
  result.rotated = node{"rotated"}.getBool(false)
  result.size = node{"size"}.getInt(7)
  result.walls = node{"walls"}.getInt(0)
  result.first = node{"first"}.getInt(0)
  result.seed = node{"seed"}.getInt(0)
  result.maxPlies = node{"maxPlies"}.getInt(80)
  ## The replay carries the episode's resolved game and caps; never re-fit
  ## them. The aliases are re-derived from the seed.
  result.sampled = true
  let policyNames = payload{"policyNames"}
  if policyNames != nil and policyNames.kind == JArray and
      policyNames.len == payload["names"].len:
    for name in policyNames:
      result.players.add(PlayerConfig(name: name.getStr()))
  else:
    for name in payload["names"]:
      result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  let enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr(ReplayProtocol),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "board-gauntlet: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(GauntletError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.baselines = newSeq[string](config.players.len)

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "board-gauntlet: serving on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
