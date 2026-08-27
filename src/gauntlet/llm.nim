## Claude-backed decision making for Board Gauntlet, plus the two scripted
## baselines every fallback lands on.
##
## A policy here is just a prompt: the game server composes the acting
## seat's observation — the whole position, the whole move history and the
## whole legal-move set, because this family is perfect information — adds
## that seat's operator prompt, and asks Claude for one move.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## `tactician` baseline immediately (no retries, no network waits) so
## offline certification still completes - this fallback is load-bearing.

import
  std/[json, os, strutils],
  bitworld/runtime,
  curly,
  sim
from games/connect_four import nil
from games/breakthrough import nil
from games/hex import nil
from games/quoridor import nil

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## The Bedrock sidecar caps 30 requests a minute per episode and a ply
  ## issues at most two (the call plus one retry), so two LLM-driven plies
  ## may not start closer together than this.
  DerivedPlySpacingSeconds* = 4

type
  Decision* = object
    move*: string
    say*: string
    notes*: string
    scripted*: bool   ## decided by a baseline rather than by the model
    fellBack*: bool   ## an LLM decision was attempted and failed
    illegal*: bool    ## the reply parsed but did not name a legal move

  Baseline* = enum
    blTactician = "tactician"
    blHustler = "hustler"

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool

proc parseBaseline*(text: string): Baseline =
  ## `1`, `true` and `yes` are accepted synonyms for `tactician`.
  case text.strip().toLowerAscii()
  of "hustler": blHustler
  else: blTactician

proc isScriptedName*(text: string): bool =
  text.strip().toLowerAscii() in
    ["tactician", "hustler", "1", "true", "yes"]

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "board-gauntlet llm: failed to fetch ANTHROPIC_API_KEY_URI: ",
      error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id. `us.anthropic.claude-sonnet-4-6` is deliberately NOT
  ## in this list: it times out on every sidecar call (raid, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "board-gauntlet llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "board-gauntlet llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "board-gauntlet llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "board-gauntlet llm: no LLM credentials; every seat plays the ",
      "tactician baseline"

# ---- The scripted baselines -------------------------------------------------
#
# Both are deterministic given the sim state, always produce a move that is
# in `legalMoves(sim)`, and never produce `say` or `notes`. Both are
# game-agnostic shells over three procs — `legalMoves`, a move applied to a
# copy, and `standing` — plus the per-game tie-breaks below.

proc tacticianMove*(sim: Sim): string =
  ## 1. Win now. 2. Otherwise prefer moves that do not hand the opponent an
  ## immediate win. 3. Among those, maximise `standing(self) -
  ## standing(opponent)`. 4. Ties go to the lowest canonical index.
  let moves = sim.legalMoves()
  if moves.len == 0:
    raise newException(GauntletError, "no legal move to choose from")
  let wins = sim.immediateWinMoves()
  if wins.len > 0:
    for move in moves:
      if move in wins:
        return move
  let me = sim.mover
  let base = sim.probeBase()
  var probe = base
  var bestSafe = low(int)
  var bestSafeMove = ""
  var bestAny = low(int)
  var bestAnyMove = moves[0]
  for move in moves:
    probe.resetProbe(base)
    probe.applyProbe(move)
    let value = probe.standing(me) - probe.standing(1 - me)
    let safe = probe.done or not probe.hasImmediateWin()
    if value > bestAny:
      bestAny = value
      bestAnyMove = move
    if safe and value > bestSafe:
      bestSafe = value
      bestSafeMove = move
  if bestSafeMove.len > 0: bestSafeMove else: bestAnyMove

proc hustlerCandidates(sim: Sim, moves: seq[string]): seq[string] =
  ## The hustler's per-game pre-filter. It never defends: it maximises its
  ## own progress and ignores the opponent's.
  case sim.config.game
  of gConnectFour:
    ## The three central files, whenever at least one of them is legal.
    let order = connect_four.columnOrder(boardCols(sim))
    var central: seq[string]
    for index in 0 ..< min(3, order.len):
      central.add(fileLetter(order[index]))
    for move in moves:
      if move in central:
        result.add(move)
  of gBreakthrough:
    ## The most advanced own piece (ties: lowest cell index); a capture by
    ## that piece always beats a non-capture.
    let me = sim.mover
    var bestAdvance = -1
    var bestCell = -1
    for cell in 0 ..< sim.board.len:
      if sim.board[cell] != seatOccupant(me):
        continue
      let advance = breakthrough.advanceOf(sim, me, sim.rowOf(cell))
      if advance > bestAdvance:
        bestAdvance = advance
        bestCell = cell
    if bestCell < 0:
      return
    let head = sim.cellName(bestCell) & "-"
    var captures: seq[string]
    for move in moves:
      if not move.startsWith(head):
        continue
      result.add(move)
      if sim.board[sim.cellIndex(move[head.len .. ^1])] != ocEmpty:
        captures.add(move)
    if captures.len > 0:
      result = captures
  of gHex:
    ## The empty cells on its own shortest route, so it builds a chain and
    ## never wanders.
    var route: seq[string]
    for cell in hex.shortestRouteCells(sim, sim.mover):
      route.add(sim.cellName(cell))
    for move in moves:
      if move in route:
        result.add(move)
  of gQuoridor:
    ## No wall at all while it is not behind; once behind, the wall that
    ## adds the most steps to the opponent's route.
    let me = sim.mover
    var pawnMoves: seq[string]
    for (cell, _) in quoridor.pawnMoves(sim):
      pawnMoves.add(sim.cellName(cell))
    if sim.pathLen(me) <= sim.pathLen(1 - me):
      return pawnMoves
    let base = sim.probeBase()
    var probe = base
    var best = sim.pathLen(1 - me)
    var bestWall = ""
    for move in moves:
      if not quoridor.isWallMove(move):
        continue
      probe.resetProbe(base)
      probe.applyProbe(move)
      let after = probe.pathLen(1 - me)
      if after > best:
        best = after
        bestWall = move
    if bestWall.len > 0:
      return @[bestWall]
    return pawnMoves
  of gRotate:
    discard

proc hustlerMove*(sim: Sim): string =
  ## 1. Win now. 2. Otherwise maximise `standing(self)` alone, tie-broken by
  ## the HIGHEST canonical index, over the per-game pre-filter above.
  let moves = sim.legalMoves()
  if moves.len == 0:
    raise newException(GauntletError, "no legal move to choose from")
  let wins = sim.immediateWinMoves()
  if wins.len > 0:
    for move in moves:
      if move in wins:
        return move
  var candidates = hustlerCandidates(sim, moves)
  if candidates.len == 0:
    candidates = moves
  let me = sim.mover
  let base = sim.probeBase()
  var probe = base
  var best = low(int)
  var bestMove = candidates[0]
  for move in candidates:
    probe.resetProbe(base)
    probe.applyProbe(move)
    let value = probe.standing(me)
    if value >= best:
      best = value
      bestMove = move
  bestMove

proc scriptedMove*(sim: Sim, baseline: Baseline): string =
  case baseline
  of blTactician: tacticianMove(sim)
  of blHustler: hustlerMove(sim)

# ---- Observation building ---------------------------------------------------

proc colourOf*(seat: int): string =
  if seat == 0: "RED" else: "BLUE"

proc pieceChar(sim: Sim, cell: int): char =
  case sim.board[cell]
  of ocEmpty: '.'
  of ocSeat0: 'R'
  of ocSeat1: 'B'

proc fileFooter(cols: int, indent: string): string =
  result = indent
  for col in 0 ..< cols:
    result.add(fileLetter(col))
    result.add(' ')
  result = result.strip(leading = false)

proc boardText*(sim: Sim): string =
  ## The board as a labelled ASCII diagram, ranks descending, files
  ## lettered along the bottom. Quoridor additionally draws the wall
  ## segments that sit between cells.
  let cols = boardCols(sim)
  let rows = boardRows(sim)
  var lines: seq[string]
  for row in countdown(rows - 1, 0):
    var line = align($(row + 1), 2) & " "
    if sim.config.game == gHex:
      line.add(spaces(row))
    for col in 0 ..< cols:
      line.add(sim.pieceChar(row * cols + col))
      if col < cols - 1:
        if sim.config.game == gQuoridor and
            quoridor.blockedHorizontal(sim, row, col):
          line.add('|')
        else:
          line.add(' ')
    lines.add(line)
    if sim.config.game == gQuoridor and row > 0:
      var sep = "   "
      for col in 0 ..< cols:
        sep.add(if quoridor.blockedVertical(sim, row - 1, col): '-' else: ' ')
        if col < cols - 1:
          sep.add(' ')
      if sep.strip().len > 0:
        lines.add(sep)
  lines.add(fileFooter(cols, "   "))
  lines.join("\n")

proc historyText*(sim: Sim): string =
  var parts: seq[string]
  var index = 1
  for event in sim.events:
    if event.kind != evMove:
      continue
    parts.add($index & ". " & event.move)
    inc index
  if parts.len == 0:
    return "(no moves yet)"
  parts.join(" ")

proc goalText*(sim: Sim, seat: int): string =
  case sim.config.game
  of gConnectFour:
    "drop discs so that four of your own end up in a row - horizontally, " &
      "vertically or on either diagonal."
  of gBreakthrough:
    "march a piece to rank " & $(breakthrough.homeRankOf(sim, seat) + 1) &
      " (the opponent's home rank), or capture every enemy piece."
  of gHex:
    if seat == 0:
      "link the left file (a) to the right file (" &
        fileLetter(boardCols(sim) - 1) &
        ") with an unbroken chain of your own stones."
    else:
      "link the bottom rank (1) to the top rank (" & $boardRows(sim) &
        ") with an unbroken chain of your own stones."
  of gQuoridor:
    "get your pawn to rank " & $(quoridor.goalRowOf(sim, seat) + 1) & "."
  of gRotate: ""

proc positionSummary*(sim: Sim, seat: int): string =
  ## Nothing here is secret: both seats get both numbers.
  let them = 1 - seat
  result.add("Your standing heuristic is " & $sim.standing(seat) &
    "; your opponent's is " & $sim.standing(them) & ".\n")
  case sim.config.game
  of gConnectFour:
    result.add("You have " & $connect_four.openThrees(sim, seat) &
      " open threes; they have " & $connect_four.openThrees(sim, them) & ".")
  of gBreakthrough:
    result.add("You have " & $breakthrough.pieces(sim, seat) &
      " pieces, most advanced " &
      $(breakthrough.mostAdvanced(sim, seat) + 1) &
      " ranks from your home rank; they have " &
      $breakthrough.pieces(sim, them) & ", most advanced " &
      $(breakthrough.mostAdvanced(sim, them) + 1) & ".")
  of gHex:
    result.add("You are " & $sim.distToWin(seat) &
      " stones from connecting; your opponent is " &
      $sim.distToWin(them) & ".")
  of gQuoridor:
    result.add("Your path is " & $sim.pathLen(seat) & " steps, theirs is " &
      $sim.pathLen(them) & ". Walls left: you " & $sim.wallsLeft[seat] &
      ", opponent " & $sim.wallsLeft[them] & ".")
  of gRotate: discard

proc rulesText*(game: Game, size: int): string =
  ## The rules of one game, stated in full. The same text goes into the
  ## manifest's rules page.
  case game
  of gConnectFour:
    "CONNECT FOUR on " & $size & " files by " & $(size - 1) & " ranks.\n" &
    "- A move is a single file letter, a to " & fileLetter(size - 1) & ".\n" &
    "- It is legal only while that file still has an empty cell.\n" &
    "- Your disc drops to the LOWEST empty cell of that file.\n" &
    "- You win the moment four of your own discs sit in a row " &
      "horizontally, vertically or on either diagonal.\n" &
    "- If the board fills with no line, the game is a draw.\n"
  of gBreakthrough:
    "BREAKTHROUGH on " & $size & " x " & $size & ".\n" &
    "- RED fills ranks 1 and 2 and advances toward rank " & $size &
      "; BLUE fills ranks " & $(size - 1) & " and " & $size &
      " and advances toward rank 1.\n" &
    "- A move is <from>-<to>, e.g. b2-c3. `to` is one rank FORWARD of " &
      "`from`, on the same file or one file to either side.\n" &
    "- A straight-forward move is legal only onto an EMPTY cell: there " &
      "is no straight capture.\n" &
    "- A diagonal-forward move is legal onto an empty cell or onto an " &
      "enemy piece, which is removed.\n" &
    "- You win the moment one of your pieces lands on the opponent's " &
      "home rank, or when you take their last piece.\n" &
    "- A seat with no legal move loses. There are no draws by rule.\n"
  of gHex:
    "HEX on a " & $size & " x " & $size & " rhombus.\n" &
    "- Cell (file, rank) touches its west, east, south and north " &
      "neighbours plus north-west and south-east: c4 touches b4, d4, c3, " &
      "c5, b5 and d3.\n" &
    "- A move is a cell name; it is legal while that cell is empty. " &
      "Stones never move and are never removed.\n" &
    "- RED links the left file (a) to the right file (" &
      fileLetter(size - 1) & "); BLUE links rank 1 to rank " & $size & ".\n" &
    "- You win the moment your own stones form an unbroken chain between " &
      "your two edges. Hex has no draws.\n"
  of gQuoridor:
    "QUORIDOR on " & $size & " x " & $size & ".\n" &
    "- RED's pawn starts on the centre file of rank 1 and must reach " &
      "rank " & $size & "; BLUE starts on rank " & $size &
      " and must reach rank 1.\n" &
    "- A move is either a pawn destination (a cell name) or a wall, " &
      "<anchor><h|v>, anchor a1 to " & fileLetter(size - 2) & $(size - 1) &
      ".\n" &
    "- A horizontal wall xNh blocks the two vertical steps at (x,N) and " &
      "(x+1,N); a vertical wall xNv blocks the two horizontal steps at " &
      "(x,N) and (x,N+1).\n" &
    "- A wall is legal only while you have walls left, the anchor is " &
      "empty, neither step it blocks is already blocked, and BOTH pawns " &
      "still have some route to their own goal rank.\n" &
    "- A pawn steps to an orthogonally adjacent cell when no wall is in " &
      "the way. If the opponent pawn is next to you, you may jump " &
      "straight over it; only when that jump is off the board or " &
      "wall-blocked may you take one of the two cells diagonally beside " &
      "them instead.\n" &
    "- You win the moment your pawn reaches your goal rank.\n"
  of gRotate: ""

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.names[seat]
  result.add("You are " & me & ", a cog playing " &
    ($sim.config.game).toUpperAscii() & " against one other cog on the " &
    "Board Gauntlet. You play " & colourOf(seat) & ".\n\n")
  result.add("This is a PERFECT-INFORMATION, zero-sum, two-player board " &
    "game. You are shown the entire position, the entire move history and " &
    "the entire legal-move set every ply. Nothing about the board is " &
    "hidden from you and nothing about it is hidden from your opponent; " &
    "the only thing you cannot see is what they are thinking.\n\n")
  result.add("RULES\n" & rulesText(sim.config.game, sim.config.size))
  result.add("- Seats alternate strictly, one move each; there is no " &
    "pass and no double move.\n")
  result.add("- If " & $sim.config.maxPlies & " plies are played with no " &
    "terminal position, the game is adjudicated on the position " &
    "heuristic you are shown each ply; the wall clock can stop it the " &
    "same way.\n\n")
  result.add("SCORING: +1 for a win, 0 for a draw, -1 for a loss. " &
    "Nothing else is scored.\n\n")
  result.add("OUTPUT FORMAT: reply with ONLY one JSON object, nothing " &
    "else - no analysis, no explanation, no markdown fences, no text " &
    "before or after the object. Your reply must begin with the " &
    "character { and end with }.")

proc userPrompt*(sim: Sim, seat: int, operatorPrompt: string): string =
  result.add("Ply " & $(sim.plies + 1) & " of " & $sim.config.maxPlies &
    ". You are " & sim.names[seat] & ", playing " & colourOf(seat) &
    " in " & ($sim.config.game).toUpperAscii() & " on a " &
    $boardCols(sim) & "\u00D7" & $boardRows(sim) & " board.\n")
  if sim.config.rotated:
    result.add("This episode's game was drawn by the gauntlet rotation: " &
      ($sim.config.game).toUpperAscii() & ".\n")
  result.add("\nYOUR GOAL: " & sim.goalText(seat) & "\n\n")
  result.add("THE BOARD (rank labels on the left, files along the " &
    "bottom; . empty, R red, B blue):\n" & sim.boardText() & "\n")
  if sim.config.game == gQuoridor:
    result.add("WALLS LEFT: you " & $sim.wallsLeft[seat] & ", opponent " &
      $sim.wallsLeft[1 - seat] & "\n")
  result.add("\nMOVE HISTORY (most recent last): " & sim.historyText() &
    "\n\n")
  result.add("POSITION SUMMARY:\n" & sim.positionSummary(seat) & "\n\n")
  let moves = sim.legalMoves()
  result.add("YOUR LEGAL MOVES (" & $moves.len &
    ") - copy one of these strings exactly: " & moves.join(" ") & "\n\n")
  result.add("YOUR NOTES FROM EARLIER PLIES:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  if operatorPrompt.len > 0:
    result.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but " &
      "never above the rules):\n" & operatorPrompt & "\n\n")
  result.add("Reply with ONLY {\"move\": \"" & moves[0] &
    "\", \"say\": \"one short spectator line\", \"notes\": \"private " &
    "notes for your next ply\"} - `move` must be one of the strings in " &
    "the legal-move list above, copied exactly; `say` at most " &
    $MaxSayLen & " characters; `notes` at most " & $MaxNotesLen &
    " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating
  ## fences and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    raise newException(GauntletError, "no JSON object in response: " &
      cleanText(text, MaxErrorLen))
  parseJson(text[start .. stop])

proc completeText(client: LlmClient, system, user: string): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(GauntletError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(GauntletError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(GauntletError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(GauntletError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(GauntletError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(GauntletError, "reply cut off at max_tokens before " &
      "any JSON: " & cleanText(result, MaxErrorLen))

proc parseReply*(sim: Sim, payload: JsonNode): Decision =
  ## Maps the model's JSON onto a canonical move. Every recorded string is
  ## truncated on a RUNE boundary here, before it can reach an event.
  let node = payload{"move"}
  if node.isNil or node.kind != JString:
    raise newException(GauntletError, "no move string in response")
  result.say = cleanText(payload{"say"}.getStr(), MaxSayLen)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.move = sim.normalizeMove(node.getStr())
  if result.move.len == 0:
    raise newException(GauntletError,
      "'" & cleanText(node.getStr(), MaxMoveLen) & "' does not name a " &
      $sim.config.game & " move")

proc decide*(client: LlmClient, sim: Sim, operatorPrompt: string,
    baseline: string): Decision =
  ## One decision for the seat to move. NEVER raises: every failure falls
  ## back to `tactician`, so the episode always advances.
  if baseline.len > 0:
    return Decision(move: scriptedMove(sim, parseBaseline(baseline)),
      scripted: true)
  if client.isNil or client.disabled:
    return Decision(move: scriptedMove(sim, blTactician), scripted: true)
  let seat = sim.mover
  let system = systemPrompt(sim, seat)
  var illegal = false
  for attempt in 0 .. 1:
    var user = sim.userPrompt(seat, operatorPrompt)
    if attempt > 0:
      user.add("\n\nYour previous reply was invalid. Respond with ONLY " &
        "the requested JSON object; `move` must be exactly one of the " &
        "strings in this list: " & sim.legalMoves().join(" "))
    try:
      var decision = sim.parseReply(
        extractJsonObject(client.completeText(system, user)))
      ## Reject an illegal move HERE so the retry carries the printed set,
      ## computed by the same predicate the validator applies.
      var probe = sim
      probe.applyMove(decision.move, "", "", false, false)
      return decision
    except CatchableError as error:
      if "is not a legal" in error.msg or "does not name a" in error.msg:
        illegal = true
      echo "board-gauntlet llm: seat ", seat, " attempt ", attempt,
        " failed: ", cleanText(error.msg, MaxErrorLen)
      if client.disabled:
        break
  echo "board-gauntlet llm: seat ", seat, " falling back to the tactician ",
    "baseline"
  Decision(move: scriptedMove(sim, blTactician), scripted: false,
    fellBack: true, illegal: illegal)
