## Shared types and pure geometry for Board Gauntlet.
##
## Everything here is IO-free and allocation-light so the per-game rule
## modules (`gauntlet/games/*.nim`), the dispatching sim, the server, the
## tests and the wasm replay viewer all agree on one board representation.
##
## Cells are ALGEBRAIC on the outside and (row, col) on the inside: files
## `a`, `b`, `c`, ... left to right; ranks `1`, `2`, ... bottom to top, so
## `a1` is (row 0, col 0). `cellName` and `cellIndex` are the only two
## places the two representations meet; nothing spectator-facing ever
## shows an internal index.

import std/[json, strutils, unicode]

const
  ## The widest board any shipped game uses (Quoridor 9x9, Hex up to 11).
  ## Fixed so the BFS helpers can work on stack arrays.
  MaxSide* = 11
  MaxCells* = MaxSide * MaxSide
  ## Reply-schema caps, all measured in RUNES and cut on rune boundaries.
  MaxMoveLen* = 12
  MaxSayLen* = 80
  MaxNotesLen* = 400
  MaxPromptLen* = 4000
  MaxErrorLen* = 200
  ## Anonymous cog aliases, from cogame-babel's pool.
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  GauntletError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  Game* = enum
    gRotate       = "rotate"          ## config only; resolved by sampleEpisode
    gConnectFour  = "connect-four"
    gBreakthrough = "breakthrough"
    gHex          = "hex"
    gQuoridor     = "quoridor"

  GameConfig* = object
    tokens*: seq[string]                ## connection tokens, injected by the runner
    players*: seq[PlayerConfig]         ## policy display names, by slot
    game*: Game
    rotated*: bool                      ## true when the rotation resolved `game`
    size*: int                          ## per-game side; connect-four is size x (size-1)
    walls*: int                         ## quoridor walls per seat
    first*: int                         ## the seat that moves on ply 0
    maxPlies*: int
    seed*: int
    episodeTimeoutSeconds*: int
    plySpacingSeconds*: int             ## 0 => derive 4
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*, llmTimeoutSeconds*: int
    sampled*: bool                      ## true once the rotation/caps were applied

  Occupant* = enum
    ocEmpty = "empty", ocSeat0 = "seat0", ocSeat1 = "seat1"

  MoveKind* = enum
    mkDrop = "drop", mkPlace = "place", mkStep = "step",
    mkJump = "jump", mkCapture = "capture", mkWall = "wall"

  EventKind* = enum
    evStart = "start"
    evMove  = "move"
    evWin   = "win"
    evEnd   = "end"

  GameEvent* = object
    kind*: EventKind
    round*: int             ## the PLY index (0-based); start: -1
    seat*: int              ## move / win: the acting seat; -1 otherwise
    move*: string           ## move: the canonical move string
    mkind*: MoveKind        ## move: how the move resolved
    capture*: string        ## move: the emptied cell, or ""
    say*: string            ## move: spectator line, already truncated
    notes*: string          ## move: the seat's private notes, already truncated
    scripted*: bool         ## move: decided by a scripted baseline
    fellBack*: bool         ## move: the LLM decision failed and fell back
    how*: string            ## win: line|connection|home-rank|no-pieces|no-moves|goal-row
    path*: seq[string]      ## win: the winning cells, algebraic
    reason*: string         ## end: complete|deadline
    ending*: string         ## end: the finer ending
    scores*: seq[float]     ## end
    standing*: seq[int]     ## end

  Sim* = object
    config*: GameConfig
    names*: seq[string]             ## anonymous cog aliases
    board*: seq[Occupant]           ## cols*rows, row-major from rank 1
    hWalls*, vWalls*: seq[bool]     ## quoridor: (size-1)^2 anchors per orientation
    pawns*: array[2, int]           ## quoridor: cell index per seat
    wallsLeft*: array[2, int]
    wallsUsed*, captures*: array[2, int]
    fallbacks*, illegalReplies*: array[2, int]
    says*, notes*: seq[string]      ## latest, per seat
    scripted*, fellBack*: array[2, bool]
    mover*: int
    ply*, plies*: int
    winner*: int                    ## -1 = none yet / draw
    winPath*: seq[int]
    lastMove*: string
    lastKind*: MoveKind
    lastCapture*: int               ## cell index or -1
    done*: bool
    reason*, ending*: string
    events*: seq[GameEvent]

const
  RotationOrder* = [gConnectFour, gBreakthrough, gHex, gQuoridor]

# ---- Text hygiene -----------------------------------------------------------

proc cleanText*(text: string, cap: int): string =
  ## Trims, collapses newlines to spaces, and cuts over-cap text on a RUNE
  ## boundary with the cut marked. A byte-boundary cut is exactly how a
  ## replay renders in a browser but fails a strict JSON parser.
  result = text.strip()
  if result.len > 0:
    result = result.replace("\r\n", " ").replace('\n', ' ').replace('\t', ' ')
    result = result.strip()
  if result.runeLen <= cap:
    return
  result = result.runeSubStr(0, cap - 1) & "\u2026"

# ---- Geometry ---------------------------------------------------------------

proc boardCols*(config: GameConfig): int =
  config.size

proc boardRows*(config: GameConfig): int =
  ## Connect Four is `size` files by `size - 1` ranks; every other game is
  ## a square of `size`.
  if config.game == gConnectFour: config.size - 1 else: config.size

proc cellCount*(config: GameConfig): int =
  boardCols(config) * boardRows(config)

proc boardCols*(sim: Sim): int = boardCols(sim.config)
proc boardRows*(sim: Sim): int = boardRows(sim.config)
proc cellCount*(sim: Sim): int = cellCount(sim.config)

proc rowOf*(config: GameConfig, cell: int): int = cell div boardCols(config)
proc colOf*(config: GameConfig, cell: int): int = cell mod boardCols(config)
proc rowOf*(sim: Sim, cell: int): int = rowOf(sim.config, cell)
proc colOf*(sim: Sim, cell: int): int = colOf(sim.config, cell)

proc fileLetter*(col: int): string =
  $chr(ord('a') + col)

proc cellName*(config: GameConfig, cell: int): string =
  if cell < 0 or cell >= cellCount(config):
    raise newException(GauntletError, "cell out of range: " & $cell)
  fileLetter(colOf(config, cell)) & $(rowOf(config, cell) + 1)

proc cellName*(sim: Sim, cell: int): string = cellName(sim.config, cell)

proc cellIndex*(config: GameConfig, name: string): int =
  ## The inverse of `cellName`. Raises on anything that is not a cell of
  ## this board.
  let text = name.strip().toLowerAscii()
  if text.len < 2:
    raise newException(GauntletError, "not a cell name: " & name)
  let col = ord(text[0]) - ord('a')
  var rank = 0
  for index in 1 ..< text.len:
    if text[index] notin '0' .. '9':
      raise newException(GauntletError, "not a cell name: " & name)
    rank = rank * 10 + (ord(text[index]) - ord('0'))
  let row = rank - 1
  if col < 0 or col >= boardCols(config) or row < 0 or row >= boardRows(config):
    raise newException(GauntletError, "cell off the board: " & name)
  row * boardCols(config) + col

proc cellIndex*(sim: Sim, name: string): int = cellIndex(sim.config, name)

proc occ*(sim: Sim, cell: int): Occupant = sim.board[cell]
proc occ*(sim: Sim, row, col: int): Occupant = sim.board[row * boardCols(sim) + col]

proc seatOccupant*(seat: int): Occupant =
  if seat == 0: ocSeat0 else: ocSeat1

proc onBoard*(sim: Sim, row, col: int): bool =
  row >= 0 and row < boardRows(sim) and col >= 0 and col < boardCols(sim)

# ---- Config -----------------------------------------------------------------

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    game: gRotate,
    size: 7,
    walls: 10,
    first: 0,
    maxPlies: 80,
    seed: 0,
    episodeTimeoutSeconds: 1200,
    plySpacingSeconds: 0,
    turnDelayMs: 250,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 30
  )

proc parseGame*(text: string): Game =
  for game in Game:
    if $game == text:
      return game
  raise newException(GauntletError, "unknown game: " & text)

proc sizeRange*(game: Game): (int, int) =
  ## The per-game legal side lengths. `rotate` spans the union because the
  ## rotation has not resolved yet.
  case game
  of gConnectFour: (5, 9)
  of gBreakthrough: (4, 8)
  of gHex: (4, 11)
  of gQuoridor: (5, 11)
  of gRotate: (4, 11)

proc defaultSize*(game: Game): int =
  case game
  of gConnectFour: 7
  of gBreakthrough: 6
  of gHex: 7
  of gQuoridor: 9
  of gRotate: 7

proc sizeLegal*(game: Game, size: int): bool =
  let (lo, hi) = sizeRange(game)
  if size < lo or size > hi:
    return false
  case game
  of gBreakthrough: size mod 2 == 0     ## two full home ranks a side
  of gQuoridor: size mod 2 == 1         ## an odd side centres each pawn
  else: true

proc plyCap*(game: Game, size: int): int =
  ## The most plies the board itself can absorb.
  case game
  of gConnectFour: size * (size - 1)
  of gHex: size * size
  else: 200

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(GauntletError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("game"):
    config.game = parseGame(node["game"].getStr())
  if node.hasKey("rotated"):
    config.rotated = node["rotated"].getBool()
  if node.hasKey("size"):
    config.size = node["size"].getInt()
  if node.hasKey("walls"):
    config.walls = node["walls"].getInt()
  if node.hasKey("first"):
    config.first = node["first"].getInt()
  if node.hasKey("maxPlies"):
    config.maxPlies = node["maxPlies"].getInt()
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("plySpacingSeconds"):
    config.plySpacingSeconds = node["plySpacingSeconds"].getInt()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.players.len != 2:
    raise newException(GauntletError,
      "board-gauntlet seats exactly 2 players, got " & $config.players.len)
  if config.first < 0 or config.first > 1:
    raise newException(GauntletError, "first must be 0 or 1")
  if config.maxPlies < 4 or config.maxPlies > 200:
    raise newException(GauntletError, "maxPlies must be 4..200")
  if config.walls < 0 or config.walls > 20:
    raise newException(GauntletError, "walls must be 0..20")
  let (lo, hi) = sizeRange(config.game)
  if config.size < lo or config.size > hi:
    raise newException(GauntletError,
      "size for " & $config.game & " must be " & $lo & ".." & $hi &
      ", got " & $config.size)
  if config.game != gRotate and not sizeLegal(config.game, config.size):
    raise newException(GauntletError,
      "size " & $config.size & " is not legal for " & $config.game)

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Resolves the rotation and fits the episode to the board. Idempotent:
  ## a config that already carries `sampled` (a replay being re-read) is
  ## untouched, so a replay re-derives the episode it recorded.
  result = config
  if result.sampled:
    return
  if result.game == gRotate:
    result.game = RotationOrder[((result.seed mod 4) + 4) mod 4]
    result.rotated = true
    ## The rotation's board defaults: the `gauntlet` variant's size and
    ## walls are only sensible for some of the four, so snap the ones that
    ## are not legal for the game that was actually drawn.
    if not sizeLegal(result.game, result.size):
      result.size = defaultSize(result.game)
  elif not sizeLegal(result.game, result.size):
    result.size = defaultSize(result.game)
  if result.game != gQuoridor:
    result.walls = 0
  result.maxPlies =
    max(min(result.maxPlies, plyCap(result.game, result.size)), 4)
  result.turnDelayMs =
    min(result.turnDelayMs, 120_000 div max(result.maxPlies, 1))
  result.sampled = true
