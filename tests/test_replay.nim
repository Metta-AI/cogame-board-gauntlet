## Record -> re-derive, and the bytes.
##
## `replayMatch` drives the SAME rules the server ran, from the recorded
## events alone, and applies the recorded `end` through the SAME `settle`
## proc -- which is what makes a wall-clock stop, not derivable from the
## moves, re-derive identically in the wasm viewer (particle-worlds
## 13c66d7, 2026-08-26).

import std/[json, random, strutils, unicode, unittest]
import gauntlet/sim
import gauntlet/llm

proc variantConfig(game: Game, size = 0, walls = -1, maxPlies = 0,
    seed = 0): GameConfig =
  result = defaultGameConfig()
  result.game = game
  result.size = if size > 0: size else: defaultSize(game)
  result.walls = if walls >= 0: walls
                 elif game == gQuoridor: 10
                 else: 0
  result.maxPlies =
    if maxPlies > 0: maxPlies
    elif game == gConnectFour: 42
    elif game == gHex: 49
    else: 80
  result.seed = seed
  result.turnDelayMs = 0
  for index in 0 .. 1:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)
  result = sampleEpisode(result)

proc liveFrames(sim: Sim): seq[JsonNode] =
  ## The frames a recording server would broadcast: one per event.
  discard sim
  @[]

proc recordFrames(config: GameConfig,
    step: proc (sim: var Sim): bool {.closure.}): (Sim, seq[JsonNode]) =
  ## Drives an episode, capturing `boardStateJson` once per event the sim
  ## appends -- the same one-frame-per-event timeline `replayMatch` yields.
  var sim = initSim(config)
  ## Frame 0 is the state before any event; `replayMatch` then yields one
  ## more per recorded event, including the `start` the sim logs at init.
  var frames = @[sim.boardStateJson()]
  var seen = 0
  while seen < sim.events.len:
    frames.add(sim.boardStateJson())
    inc seen
  while not sim.done:
    if not step(sim):
      break
    while seen < sim.events.len:
      frames.add(sim.boardStateJson())
      inc seen
  while seen < sim.events.len:
    frames.add(sim.boardStateJson())
    inc seen
  (sim, frames)

proc randomStep(seed: int): proc (sim: var Sim): bool {.closure.} =
  var rng = initRand(int64(seed) * 991 + 3)
  result = proc (sim: var Sim): bool =
    let legal = sim.legalMoves()
    sim.applyMove(legal[rng.rand(legal.high)], "", "", true, false)
    true

proc tacticianStep(sim: var Sim): bool =
  sim.applyMove(tacticianMove(sim), "", "", true, false)
  true

proc racerStep(sim: var Sim): bool =
  ## The hustler races its own progress and never defends, which is what
  ## takes a Quoridor episode to `goal-row` rather than to the ply cap.
  sim.applyMove(hustlerMove(sim), "", "", true, false)
  true

proc replayPayloadJson(sim: Sim): JsonNode =
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policyNames = newJArray()
  for player in sim.config.players:
    policyNames.add(%player.name)
  var events = newJArray()
  for event in sim.events:
    events.add(event.eventToJson())
  %*{
    "protocol": "gauntlet.replay.v1",
    "names": names,
    "policyNames": policyNames,
    "config": {
      "game": $sim.config.game,
      "rotated": sim.config.rotated,
      "size": sim.config.size,
      "walls": sim.config.walls,
      "first": sim.config.first,
      "seed": sim.config.seed,
      "maxPlies": sim.config.maxPlies,
      "sampled": true
    },
    "events": events,
    "results": sim.resultsJson()
  }

proc eventsOf(sim: Sim): seq[GameEvent] =
  ## Round-tripped through JSON, so the test exercises the bytes the
  ## viewer actually reads rather than the in-memory objects.
  for event in sim.events:
    result.add(eventFromJson(event.eventToJson()))

proc checkReDerives(sim: Sim, frames: seq[JsonNode]) =
  ## Raises rather than `check`ing, so a mismatch fails the enclosing test
  ## and names ONE differing key instead of dumping two whole board states
  ## into the CI log.
  let replayed = replayMatch(sim.config, sim.eventsOf())
  doAssert replayed.len == frames.len,
    "replayMatch yielded " & $replayed.len & " frames, the recording had " &
    $frames.len
  for index in 0 ..< replayed.len:
    let derived = replayed[index].boardStateJson()
    if derived == frames[index]:
      continue
    for key, value in frames[index]:
      if derived{key} != value:
        raise newException(AssertionDefect,
          "frame " & $index & " differs at '" & key & "': live " & $value &
          " vs replay " & $derived{key})
    raise newException(AssertionDefect, "frame " & $index & " differs")
  doAssert replayed[^1].resultsJson() == sim.resultsJson()
  doAssert replayed[^1].reason == sim.reason
  doAssert replayed[^1].ending == sim.ending
  doAssert replayed[^1].winner == sim.winner

# ---- 18. Every reason/ending pair re-derives -------------------------------

suite "re-derivation":
  test "line, board-full, home-rank, connection, goal-row and ply-cap":
    var covered: seq[string]

    ## line: seeded random Connect Four.
    block:
      let (sim, frames) = recordFrames(variantConfig(gConnectFour, seed = 3),
        randomStep(3))
      check sim.ending == "line"
      checkReDerives(sim, frames)
      covered.add(sim.ending)

    ## board-full: play only moves that do not end the game.
    block:
      var found = false
      for seed in 0 ..< 400:
        var rng = initRand(int64(seed) * 37 + 5)
        let step = proc (sim: var Sim): bool =
          var options: seq[string]
          let base = sim.probeBase()
          for move in sim.legalMoves():
            let probe = base.probeMove(move)
            if not probe.done or probe.ending == "board-full":
              options.add(move)
          if options.len == 0:
            return false
          sim.applyMove(options[rng.rand(options.high)], "", "", true, false)
          true
        let (sim, frames) = recordFrames(
          variantConfig(gConnectFour, seed = seed), step)
        if sim.done and sim.ending == "board-full":
          checkReDerives(sim, frames)
          covered.add(sim.ending)
          found = true
          break
      check found

    ## home-rank: the tactician plays Breakthrough out.
    block:
      let (sim, frames) = recordFrames(
        variantConfig(gBreakthrough, seed = 23), tacticianStep)
      check sim.ending == "home-rank"
      checkReDerives(sim, frames)
      covered.add(sim.ending)

    ## no-pieces: a capture-greedy driver on a 4x4 board that never breaks
    ## through takes the last enemy piece instead.
    block:
      var found = false
      for seed in 0 ..< 200:
        var rng = initRand(int64(seed) * 13 + 1)
        let step = proc (sim: var Sim): bool =
          let base = sim.probeBase()
          var captures, quiet: seq[string]
          for move in sim.legalMoves():
            let probe = base.probeMove(move)
            if probe.done and probe.ending == "home-rank":
              continue
            let target = move.split('-')[1]
            if sim.board[sim.cellIndex(target)] != ocEmpty:
              captures.add(move)
            else:
              quiet.add(move)
          var pool = if captures.len > 0: captures
                     elif quiet.len > 0: quiet
                     else: sim.legalMoves()
          sim.applyMove(pool[rng.rand(pool.high)], "", "", true, false)
          true
        let (sim, frames) = recordFrames(
          variantConfig(gBreakthrough, size = 4, seed = seed), step)
        if sim.ending == "no-pieces":
          checkReDerives(sim, frames)
          covered.add(sim.ending)
          found = true
          break
      check found

    ## connection: seeded random Hex.
    block:
      let (sim, frames) = recordFrames(variantConfig(gHex, seed = 11),
        randomStep(11))
      check sim.ending == "connection"
      checkReDerives(sim, frames)
      covered.add(sim.ending)

    ## goal-row: the tactician races its Quoridor pawn home.
    block:
      let (sim, frames) = recordFrames(
        variantConfig(gQuoridor, seed = 5), racerStep)
      check sim.ending == "goal-row"
      checkReDerives(sim, frames)
      covered.add(sim.ending)

    ## ply-cap: a Quoridor episode with a cap it cannot beat.
    block:
      let (sim, frames) = recordFrames(
        variantConfig(gQuoridor, maxPlies = 6, seed = 9), tacticianStep)
      check sim.ending == "ply-cap"
      check sim.reason == "complete"
      checkReDerives(sim, frames)
      covered.add(sim.ending)

    check covered == @["line", "board-full", "home-rank", "no-pieces",
      "connection", "goal-row", "ply-cap"]

  test "a wall-clock stop re-derives, because settle is the same proc":
    ## Not derivable from the moves at all: the viewer only knows it
    ## happened because the `end` event says so, and the SAME settle applies
    ## it on both paths.
    for game in [gConnectFour, gBreakthrough, gHex, gQuoridor]:
      var rng = initRand(int64(ord(game)) * 17 + 4)
      var sim = initSim(variantConfig(game, seed = 42))
      var frames = @[sim.boardStateJson()]
      var seen = 0
      while seen < sim.events.len:
        frames.add(sim.boardStateJson())
        inc seen
      var ply = 0
      while not sim.done:
        if ply >= 8:
          sim.endEarly()
        else:
          let legal = sim.legalMoves()
          sim.applyMove(legal[rng.rand(legal.high)], "", "", true, false)
        while seen < sim.events.len:
          frames.add(sim.boardStateJson())
          inc seen
        inc ply
      check sim.reason == "deadline"
      check sim.ending == "wall-clock"
      checkReDerives(sim, frames)

  test "no-moves settles the starved seat identically on both paths":
    ## `complete/no-moves` is UNREACHABLE from the standard Breakthrough
    ## opening -- a piece on rank 2 always has a rank-1 square to step to or
    ## capture on, and a piece that reached rank 1 has already won -- so it
    ## is covered from a hand-built position instead of from a recorded
    ## episode. What matters is that the one `settle` proc decides it, and
    ## decides it the same way twice.
    var sim = initSim(variantConfig(gBreakthrough, size = 6))
    for cell in 0 ..< cellCount(sim.config):
      sim.board[cell] = ocEmpty
    sim.board[cellIndex(sim.config, "a1")] = ocSeat0
    sim.board[cellIndex(sim.config, "c4")] = ocSeat0
    sim.board[cellIndex(sim.config, "a2")] = ocSeat1
    sim.board[cellIndex(sim.config, "b1")] = ocSeat1
    var twin = sim
    sim.applyMove("c4-c5", "", "", true, false)
    check sim.reason == "complete"
    check sim.ending == "no-moves"
    check sim.winner == 0
    twin.applyMove("c4-c5", "", "", true, false)
    check twin.boardStateJson() == sim.boardStateJson()
    check twin.resultsJson() == sim.resultsJson()
    ## settle is idempotent: a second call cannot change a settled episode.
    twin.settle("deadline", "wall-clock")
    check twin.boardStateJson() == sim.boardStateJson()

# ---- 19. A recording that disagrees with the rules RAISES -------------------

suite "re-derivation guards":
  test "replayMatch raises on a doctored mkind, capture, seat, how or path":
    let (sim, _) = recordFrames(variantConfig(gBreakthrough, seed = 23),
      tacticianStep)
    let clean = sim.eventsOf()
    check replayMatch(sim.config, clean).len == clean.len + 1

    proc doctored(edit: proc (events: var seq[GameEvent])): seq[GameEvent] =
      result = sim.eventsOf()
      edit(result)

    ## mkind
    expect GauntletError:
      discard replayMatch(sim.config, doctored(proc (e: var seq[GameEvent]) =
        for index in 0 ..< e.len:
          if e[index].kind == evMove:
            e[index].mkind = mkWall
            break))
    ## capture
    expect GauntletError:
      discard replayMatch(sim.config, doctored(proc (e: var seq[GameEvent]) =
        for index in 0 ..< e.len:
          if e[index].kind == evMove:
            e[index].capture = "a1"
            break))
    ## win.seat
    expect GauntletError:
      discard replayMatch(sim.config, doctored(proc (e: var seq[GameEvent]) =
        for index in 0 ..< e.len:
          if e[index].kind == evWin:
            e[index].seat = 1 - e[index].seat
            break))
    ## win.how
    expect GauntletError:
      discard replayMatch(sim.config, doctored(proc (e: var seq[GameEvent]) =
        for index in 0 ..< e.len:
          if e[index].kind == evWin:
            e[index].how = "no-pieces"
            break))
    ## win.path
    expect GauntletError:
      discard replayMatch(sim.config, doctored(proc (e: var seq[GameEvent]) =
        for index in 0 ..< e.len:
          if e[index].kind == evWin:
            e[index].path = @["a1", "b2"]
            break))
    ## an illegal recorded move
    expect GauntletError:
      discard replayMatch(sim.config, doctored(proc (e: var seq[GameEvent]) =
        for index in 0 ..< e.len:
          if e[index].kind == evMove:
            e[index].move = "f1-f2"
            break))

# ---- 20. Strict UTF-8, cut on rune boundaries ------------------------------

suite "strict utf-8":
  test "full-cap multi-byte say and notes survive a strict JSON round trip":
    ## Every recorded string is cut on a RUNE boundary with the cut marked.
    ## A byte-boundary cut is exactly how a replay renders in a browser but
    ## fails a strict parser.
    var say = ""
    for _ in 0 ..< MaxSayLen + 20:
      say.add("\u65E5")
    say.add("\u2728")
    var notes = ""
    for _ in 0 ..< MaxNotesLen + 40:
      notes.add("\u65E5")
    notes.add("\u2728")
    let cutSay = cleanText(say, MaxSayLen)
    let cutNotes = cleanText(notes, MaxNotesLen)
    check cutSay.runeLen == MaxSayLen
    check cutNotes.runeLen == MaxNotesLen
    check cutSay.endsWith("\u2026")
    check cutNotes.endsWith("\u2026")
    check validateUtf8(cutSay) == -1
    check validateUtf8(cutNotes) == -1
    ## Exactly at the cap: nothing is cut and nothing is marked.
    var exact = ""
    for _ in 0 ..< MaxSayLen:
      exact.add("\u65E5")
    check cleanText(exact, MaxSayLen) == exact

    var sim = initSim(variantConfig(gConnectFour, seed = 4))
    var rng = initRand(4)
    while not sim.done:
      let legal = sim.legalMoves()
      sim.applyMove(legal[rng.rand(legal.high)], cutSay, cutNotes, false,
        false)
    let bytes = $sim.replayPayloadJson()
    check validateUtf8(bytes) == -1
    let parsed = parseJson(bytes)
    check parsed["events"].len == sim.events.len
    for event in parsed["events"]:
      if event["kind"].getStr() == "move":
        check event["say"].getStr().runeLen == MaxSayLen
        check event["notes"].getStr().runeLen == MaxNotesLen
        check validateUtf8(event["say"].getStr()) == -1
    ## And the bytes re-derive.
    var events: seq[GameEvent]
    for node in parsed["events"]:
      events.add(eventFromJson(node))
    let replayed = replayMatch(sim.config, events)
    check replayed[^1].boardStateJson() == sim.boardStateJson()

  test "a move string over the cap is cut on a rune boundary too":
    var sim = initSim(variantConfig(gHex, seed = 6))
    var long = "c4"
    for _ in 0 ..< 30:
      long.add("\u65E5")
    ## normalizeMove caps the raw string first; the result is still a legal
    ## cell name and never a truncated multi-byte sequence.
    let move = sim.normalizeMove(long)
    check move == "c4"
    check validateUtf8(cleanText(long, MaxMoveLen)) == -1
    check cleanText(long, MaxMoveLen).runeLen == MaxMoveLen

# ---- 21. The replay bytes are self-sufficient ------------------------------

suite "replay bytes":
  test "the payload carries everything the viewer needs":
    for game in [gConnectFour, gBreakthrough, gHex, gQuoridor]:
      let (sim, _) = recordFrames(variantConfig(game, seed = 7),
        tacticianStep)
      let payload = sim.replayPayloadJson()
      check payload["protocol"].getStr() == "gauntlet.replay.v1"
      for key in ["protocol", "names", "policyNames", "config", "events",
          "results"]:
        check payload.hasKey(key)
      for key in ["game", "rotated", "size", "walls", "first", "seed",
          "maxPlies", "sampled"]:
        check payload["config"].hasKey(key)
      check payload["config"]["game"].getStr() != "rotate"
      check payload["names"].len == 2
      check payload["policyNames"].len == 2
      check payload["events"].len == sim.events.len
      check payload["results"]["reason"].getStr() in ["complete", "deadline"]
      ## Moves and cells are ALGEBRAIC strings in the bytes, never indices.
      for event in payload["events"]:
        if event["kind"].getStr() == "move":
          check event["move"].getStr().len > 0
          check event["move"].getStr()[0] in 'a' .. 'z'
        if event["kind"].getStr() == "win":
          for cell in event["path"]:
            check cell.getStr()[0] in 'a' .. 'z'

  test "a rotated episode records the RESOLVED game, never `rotate`":
    for seed in 1 .. 8:
      var config = defaultGameConfig()
      config.game = gRotate
      config.size = 7
      config.walls = 10
      config.maxPlies = 80
      config.seed = seed
      config.players = @[PlayerConfig(name: "A"), PlayerConfig(name: "B")]
      config.tokens = @["t0", "t1"]
      let (sim, _) = recordFrames(sampleEpisode(config), tacticianStep)
      let payload = sim.replayPayloadJson()
      check payload["config"]["rotated"].getBool()
      check payload["config"]["game"].getStr() != "rotate"
      check payload["results"]["game"].getStr() ==
        payload["config"]["game"].getStr()
      check payload["results"]["rotated"].getBool()
      discard liveFrames(sim)
