## Board Gauntlet sim: the one dispatch point over the four game modules.
##
## Pure rules — no IO, no networking, no LLM. The server, the tests and the
## wasm replay viewer all drive this same module, which is what makes a
## replay re-derivable from its recorded events alone.
##
## `games/*.nim` own the rules of one board each and export the same five
## procs; everything else — events, `settle`, scores, results, the viewer
## state and `replayMatch` — lives here.

import std/[json, math, random, strutils], types
from games/connect_four import nil
from games/breakthrough import nil
from games/hex import nil
from games/quoridor import nil

export types

const
  ## Eval-bar denominators, per game. The bar is THIS module's `standing`
  ## heuristic, never an engine evaluation, and the viewer's caption says so.
  EvalScale* = [40.0, 400.0, 200.0, 200.0]

proc gameIndex*(game: Game): int =
  case game
  of gConnectFour: 0
  of gBreakthrough: 1
  of gHex: 2
  of gQuoridor: 3
  of gRotate: raise newException(GauntletError,
    "the rotation must be resolved before play")

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the board: every seat plays under an
  ## anonymous cog alias, drawn deterministically from the seed so replays
  ## and the live game agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc initSim*(config: GameConfig): Sim =
  if config.players.len != 2:
    raise newException(GauntletError, "board-gauntlet seats exactly 2 players")
  if config.game == gRotate:
    raise newException(GauntletError,
      "sampleEpisode must resolve the rotation before initSim")
  if not sizeLegal(config.game, config.size):
    raise newException(GauntletError,
      "size " & $config.size & " is not legal for " & $config.game)
  if config.first < 0 or config.first > 1:
    raise newException(GauntletError, "first must be 0 or 1")
  if config.maxPlies < 4:
    raise newException(GauntletError, "maxPlies must be at least 4")
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  result.says = newSeq[string](2)
  result.notes = newSeq[string](2)
  result.pawns = [-1, -1]
  result.winner = -1
  result.lastCapture = -1
  result.mover = config.first
  case config.game
  of gConnectFour: connect_four.startBoard(result)
  of gBreakthrough: breakthrough.startBoard(result)
  of gHex: hex.startBoard(result)
  of gQuoridor: quoridor.startBoard(result)
  of gRotate: discard
  result.events.add(GameEvent(kind: evStart, round: -1, seat: -1))

# ---- Rule dispatch ----------------------------------------------------------

proc legalMoves*(sim: Sim): seq[string] =
  ## Every legal move for `sim.mover`, as canonical strings in canonical
  ## order. The prompt, the retry hint, the validator and both baselines all
  ## call this one proc, so the printed set and the accepted set cannot drift.
  case sim.config.game
  of gConnectFour: result = connect_four.legalMoves(sim)
  of gBreakthrough: result = breakthrough.legalMoves(sim)
  of gHex: result = hex.legalMoves(sim)
  of gQuoridor: result = quoridor.legalMoves(sim)
  of gRotate: raise newException(GauntletError, "unresolved rotation")

proc isLegalMove*(sim: Sim, move: string): bool =
  ## Membership in `legalMoves(sim)`, decided without building the whole
  ## set — the same predicate, cheaper.
  case sim.config.game
  of gConnectFour: connect_four.isLegalMove(sim, move)
  of gBreakthrough: breakthrough.isLegalMove(sim, move)
  of gHex: hex.isLegalMove(sim, move)
  of gQuoridor: quoridor.isLegalMove(sim, move)
  of gRotate: false

proc hasAnyLegalMove*(sim: Sim): bool =
  case sim.config.game
  of gConnectFour: connect_four.hasAnyLegalMove(sim)
  of gBreakthrough: breakthrough.hasAnyLegalMove(sim)
  of gHex: hex.hasAnyLegalMove(sim)
  of gQuoridor: quoridor.hasAnyLegalMove(sim)
  of gRotate: false

proc immediateWinMoves*(sim: Sim): seq[string] =
  ## Every move that ends the game with `sim.mover` as the winner.
  case sim.config.game
  of gConnectFour: result = connect_four.immediateWinMoves(sim)
  of gBreakthrough: result = breakthrough.immediateWinMoves(sim)
  of gHex: result = hex.immediateWinMoves(sim)
  of gQuoridor: result = quoridor.immediateWinMoves(sim)
  of gRotate: result = @[]

proc hasImmediateWin*(sim: Sim): bool =
  case sim.config.game
  of gConnectFour: connect_four.hasImmediateWin(sim)
  of gBreakthrough: breakthrough.hasImmediateWin(sim)
  of gHex: hex.hasImmediateWin(sim)
  of gQuoridor: quoridor.hasImmediateWin(sim)
  of gRotate: false

proc terminalFor*(sim: Sim, seat: int):
    tuple[won: bool, how: string, path: seq[int]] =
  case sim.config.game
  of gConnectFour: result = connect_four.terminal(sim, seat)
  of gBreakthrough: result = breakthrough.terminal(sim, seat)
  of gHex: result = hex.terminal(sim, seat)
  of gQuoridor: result = quoridor.terminal(sim, seat)
  of gRotate: result = (false, "", @[])

proc standing*(sim: Sim, seat: int): int =
  ## Higher is better for `seat`, on the true board, defined for all four
  ## games. It drives the eval bar, adjudicates `ply-cap` and `wall-clock`,
  ## and is what the `tactician` baseline maximises.
  case sim.config.game
  of gConnectFour: connect_four.standing(sim, seat)
  of gBreakthrough: breakthrough.standing(sim, seat)
  of gHex: hex.standing(sim, seat)
  of gQuoridor: quoridor.standing(sim, seat)
  of gRotate: 0

proc distToWin*(sim: Sim, seat: int): int =
  ## Hex: how many further stones the seat needs to link its two edges.
  hex.distToWin(sim, seat)

proc pathLen*(sim: Sim, seat: int): int =
  ## Quoridor: pawn-step distance from the seat's pawn to its goal rank.
  quoridor.pathLen(sim, seat)

proc hexNeighbourCells*(sim: Sim, cell: int): seq[int] =
  ## Hex: the rhombus neighbourhood of a cell.
  hex.neighbourCells(sim, cell)

proc hexRouteCells*(sim: Sim, seat: int): seq[int] =
  ## Hex: the empty cells on ONE of the seat's shortest 0-1 routes.
  hex.shortestRouteCells(sim, seat)

proc evalBar*(sim: Sim): float =
  let raw = (sim.standing(0) - sim.standing(1)).float /
    EvalScale[gameIndex(sim.config.game)]
  clamp(raw, -1.0, 1.0)

proc readout*(sim: Sim, seat: int): string =
  ## The one-line per-seat tension string the scorebug draws.
  case sim.config.game
  of gConnectFour:
    "THREATS " & $connect_four.openThrees(sim, seat)
  of gBreakthrough:
    "PIECES " & $breakthrough.pieces(sim, seat) & " \u00B7 ROW " &
      $(breakthrough.mostAdvanced(sim, seat) + 1)
  of gHex:
    let distance = sim.distToWin(seat)
    if distance >= hex.Unreachable: "CUT OFF"
    else: "TO CONNECT " & $distance
  of gQuoridor:
    "PATH " & $sim.pathLen(seat) & " \u00B7 WALLS " & $sim.wallsLeft[seat]
  of gRotate: ""

proc normalizeMove*(sim: Sim, raw: string): string =
  ## The tolerant reader. Returns "" when the string does not name a move
  ## of THIS game — a legal-looking move of a different game included.
  let capped = cleanText(raw, MaxMoveLen)
  var cleaned = newStringOfCap(capped.len)
  for ch in capped.toLowerAscii():
    if ch in {'a' .. 'z', '0' .. '9'}:
      cleaned.add(ch)
  case sim.config.game
  of gConnectFour: connect_four.normalizeMove(sim, cleaned, capped)
  of gBreakthrough: breakthrough.normalizeMove(sim, cleaned, capped)
  of gHex: hex.normalizeMove(sim, cleaned)
  of gQuoridor: quoridor.normalizeMove(sim, cleaned)
  of gRotate: ""

# ---- Scoring and settling ---------------------------------------------------

proc score*(sim: Sim, seat: int): float =
  ## +1 won, 0 drawn, -1 lost. The array always sums to zero.
  if not sim.done or sim.winner < 0: 0.0
  elif sim.winner == seat: 1.0
  else: -1.0

proc outcome*(sim: Sim, seat: int): float =
  (sim.score(seat) + 1.0) / 2.0

proc settle*(sim: var Sim, reason, ending: string, record = true) =
  ## The single proc that ends the game. It is called on RECORD and on
  ## PLAYBACK, so a wall-clock stop — which is not derivable from the moves
  ## — re-derives identically in the wasm viewer.
  if sim.done:
    return
  case ending
  of "board-full":
    sim.winner = -1
  of "ply-cap", "wall-clock":
    let a = sim.standing(0)
    let b = sim.standing(1)
    sim.winner = if a > b: 0 elif b > a: 1 else: -1
  of "no-moves":
    sim.winner = 1 - sim.mover
  else:
    discard   ## the win check already named the winner
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  if record:
    var event = GameEvent(kind: evEnd, round: sim.plies, seat: -1,
      reason: reason, ending: ending)
    event.scores = @[sim.score(0), sim.score(1)]
    event.standing = @[sim.standing(0), sim.standing(1)]
    sim.events.add(event)

proc endEarly*(sim: var Sim) =
  ## The play deadline stopped the episode between plies. The position is
  ## fully scored by `standing`, so this is a real result, not a discard.
  sim.settle("deadline", "wall-clock")

# ---- Play -------------------------------------------------------------------

proc applyRules(sim: var Sim, move: string) =
  case sim.config.game
  of gConnectFour: connect_four.applyMove(sim, move)
  of gBreakthrough: breakthrough.applyMove(sim, move)
  of gHex: hex.applyMove(sim, move)
  of gQuoridor: quoridor.applyMove(sim, move)
  of gRotate: raise newException(GauntletError, "unresolved rotation")

proc advance(sim: var Sim, move, say, notes: string,
    scripted, fellBack, quiet: bool) =
  ## Resolution-order steps 6-11, atomically. `quiet` is the baselines'
  ## probe path: the rules run, no event is recorded.
  if sim.done:
    raise newException(GauntletError, "the episode is over")
  let mover = sim.mover
  let ply = sim.plies
  sim.applyRules(move)
  sim.lastMove = move
  sim.scripted[mover] = scripted
  sim.fellBack[mover] = fellBack
  if fellBack:
    inc sim.fallbacks[mover]
  if not quiet:
    sim.says[mover] = say
    if notes.len > 0:
      sim.notes[mover] = notes
    sim.events.add(GameEvent(
      kind: evMove, round: ply, seat: mover, move: move,
      mkind: sim.lastKind,
      capture: (if sim.lastCapture >= 0: sim.cellName(sim.lastCapture)
                else: ""),
      say: say, notes: notes, scripted: scripted, fellBack: fellBack))
  let verdict = sim.terminalFor(mover)
  if verdict.won:
    sim.winner = mover
    sim.winPath = verdict.path
    if not quiet:
      var win = GameEvent(kind: evWin, round: ply, seat: mover,
        how: verdict.how)
      for cell in verdict.path:
        win.path.add(sim.cellName(cell))
      sim.events.add(win)
    inc sim.plies
    sim.ply = sim.plies
    sim.settle("complete", verdict.how, not quiet)
    return
  if sim.config.game == gConnectFour and connect_four.boardFull(sim):
    inc sim.plies
    sim.ply = sim.plies
    sim.settle("complete", "board-full", not quiet)
    return
  inc sim.plies
  sim.ply = sim.plies
  sim.mover = (sim.config.first + sim.plies) mod 2
  if not sim.hasAnyLegalMove():
    ## The seat to move is starved: it loses, and the other seat wins.
    let victor = 1 - sim.mover
    sim.winner = victor
    if not quiet:
      sim.events.add(GameEvent(kind: evWin, round: ply, seat: victor,
        how: "no-moves"))
    sim.settle("complete", "no-moves", not quiet)
    return
  if sim.plies >= sim.config.maxPlies:
    sim.settle("complete", "ply-cap", not quiet)

proc applyMove*(sim: var Sim, move, say, notes: string,
    scripted = false, fellBack = false) =
  ## Raises `GauntletError` naming the seat and the move when `move` is not
  ## in `legalMoves(sim)`; the server probes with this on a copy before it
  ## commits anything.
  if sim.done:
    raise newException(GauntletError, "the episode is over")
  if not sim.isLegalMove(move):
    raise newException(GauntletError,
      "seat " & $sim.mover & ": '" & cleanText(move, MaxMoveLen) &
      "' is not a legal " & $sim.config.game & " move")
  sim.advance(move, say, notes, scripted, fellBack, quiet = false)

proc probeBase*(sim: Sim): Sim =
  ## A stripped copy for the baselines' lookahead: same board, same walls,
  ## no event log and no config sequences, so a probe costs three small
  ## allocations instead of copying the whole episode.
  var config = sim.config
  config.tokens = @[]
  config.players = @[PlayerConfig(name: ""), PlayerConfig(name: "")]
  Sim(config: config, names: @["", ""], board: sim.board,
      hWalls: sim.hWalls, vWalls: sim.vWalls, pawns: sim.pawns,
      wallsLeft: sim.wallsLeft, wallsUsed: sim.wallsUsed,
      captures: sim.captures, says: @["", ""], notes: @["", ""],
      mover: sim.mover, ply: sim.ply, plies: sim.plies,
      winner: sim.winner, lastCapture: -1, done: sim.done)

proc probeMove*(base: Sim, move: string): Sim =
  ## `base` must come from `probeBase`; `move` must already be legal.
  result = base
  result.advance(move, "", "", true, false, quiet = true)

proc resetProbe*(probe: var Sim, base: Sim) =
  ## Rewinds a probe to `base` in place. Element-wise so the sequences keep
  ## their storage: a baseline that scans 130 candidate moves a ply would
  ## otherwise spend most of its time in the allocator.
  for index in 0 ..< probe.board.len:
    probe.board[index] = base.board[index]
  for index in 0 ..< probe.hWalls.len:
    probe.hWalls[index] = base.hWalls[index]
  for index in 0 ..< probe.vWalls.len:
    probe.vWalls[index] = base.vWalls[index]
  probe.pawns = base.pawns
  probe.wallsLeft = base.wallsLeft
  probe.wallsUsed = base.wallsUsed
  probe.captures = base.captures
  probe.fallbacks = base.fallbacks
  probe.mover = base.mover
  probe.ply = base.ply
  probe.plies = base.plies
  probe.winner = base.winner
  probe.done = base.done
  probe.lastCapture = -1
  probe.lastKind = mkStep
  probe.winPath.setLen(0)
  probe.lastMove.setLen(0)
  probe.reason.setLen(0)
  probe.ending.setLen(0)

proc applyProbe*(probe: var Sim, move: string) =
  ## Applies an already-legal move to a rewound probe.
  probe.advance(move, "", "", true, false, quiet = true)

# ---- Results and viewer state -----------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var outcomes = newJArray()
  var standings = newJArray()
  var captures = newJArray()
  var wallsUsed = newJArray()
  var illegal = newJArray()
  var fallbacks = newJArray()
  for seat in 0 .. 1:
    ## Results are platform-facing: the league attributes by POLICY name,
    ## not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    outcomes.add(%sim.outcome(seat))
    standings.add(%sim.standing(seat))
    captures.add(%sim.captures[seat])
    wallsUsed.add(%sim.wallsUsed[seat])
    illegal.add(%sim.illegalReplies[seat])
    fallbacks.add(%sim.fallbacks[seat])
  %*{
    "names": names,
    "scores": scores,
    "outcome": outcomes,
    "game": $sim.config.game,
    "rotated": sim.config.rotated,
    "size": sim.config.size,
    "walls": sim.config.walls,
    "first": sim.config.first,
    "seed": sim.config.seed,
    "winner": sim.winner,
    "plies": sim.plies,
    "maxPlies": sim.config.maxPlies,
    "standing": standings,
    "captures": captures,
    "wallsUsed": wallsUsed,
    "illegalReplies": illegal,
    "fallbacks": fallbacks,
    "ending": sim.ending,
    "reason": sim.reason
  }

proc boardStateJson*(sim: Sim): JsonNode =
  var board = newJArray()
  for cell in sim.board:
    board.add(%($cell))
  var hWalls = newJArray()
  for wall in sim.hWalls:
    hWalls.add(%wall)
  var vWalls = newJArray()
  for wall in sim.vWalls:
    vWalls.add(%wall)
  var seats = newJArray()
  for seat in 0 .. 1:
    seats.add(%*{
      "name": sim.names[seat],
      "policy": (if seat < sim.config.players.len:
                   sim.config.players[seat].name else: ""),
      "standing": sim.standing(seat),
      "captures": sim.captures[seat],
      "wallsUsed": sim.wallsUsed[seat],
      "wallsLeft": sim.wallsLeft[seat],
      "score": sim.score(seat),
      "say": sim.says[seat],
      "notes": sim.notes[seat],
      "scripted": sim.scripted[seat],
      "fellBack": sim.fellBack[seat],
      "readout": sim.readout(seat)
    })
  var winPath = newJArray()
  for cell in sim.winPath:
    winPath.add(%sim.cellName(cell))
  %*{
    "board_game": $sim.config.game,
    "rotated": sim.config.rotated,
    "size": sim.config.size,
    "walls": sim.config.walls,
    "board": board,
    "hWalls": hWalls,
    "vWalls": vWalls,
    "pawns": [sim.pawns[0], sim.pawns[1]],
    "wallsLeft": [sim.wallsLeft[0], sim.wallsLeft[1]],
    "seats": seats,
    "mover": sim.mover,
    "ply": sim.ply,
    "maxPlies": sim.config.maxPlies,
    "plies": sim.plies,
    "legalCount": (if sim.done: 0 else: sim.legalMoves().len),
    "lastMove": {
      "seat": (if sim.plies > 0 and sim.lastMove.len > 0:
                 (sim.config.first + sim.plies - 1) mod 2 else: -1),
      "move": sim.lastMove,
      "mkind": $sim.lastKind,
      "capture": (if sim.lastCapture >= 0: sim.cellName(sim.lastCapture)
                  else: "")
    },
    "eval": sim.evalBar(),
    "winner": sim.winner,
    "winPath": winPath,
    "phase": (if sim.done: "done" else: "moving"),
    "gameDone": sim.done,
    "reason": sim.reason,
    "ending": sim.ending
  }

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  case event.kind
  of evStart:
    discard
  of evMove:
    result["seat"] = %event.seat
    result["move"] = %event.move
    result["mkind"] = %($event.mkind)
    result["capture"] = %event.capture
    result["say"] = %event.say
    result["notes"] = %event.notes
    result["scripted"] = %event.scripted
    result["fellBack"] = %event.fellBack
  of evWin:
    result["seat"] = %event.seat
    result["how"] = %event.how
    var path = newJArray()
    for cell in event.path:
      path.add(%cell)
    result["path"] = path
  of evEnd:
    result["reason"] = %event.reason
    result["ending"] = %event.ending
    var scores = newJArray()
    for value in event.scores:
      scores.add(%value)
    result["scores"] = scores
    var standings = newJArray()
    for value in event.standing:
      standings.add(%value)
    result["standing"] = standings

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    move: node{"move"}.getStr(""),
    capture: node{"capture"}.getStr(""),
    say: node{"say"}.getStr(""),
    notes: node{"notes"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    fellBack: node{"fellBack"}.getBool(false),
    how: node{"how"}.getStr(""),
    reason: node{"reason"}.getStr(""),
    ending: node{"ending"}.getStr("")
  )
  let kindNode = node{"mkind"}
  if kindNode != nil and kindNode.kind == JString:
    result.mkind = parseEnum[MoveKind](kindNode.getStr())
  if node.hasKey("path"):
    for cell in node["path"]:
      result.path.add(cell.getStr())
  if node.hasKey("scores"):
    for value in node["scores"]:
      result.scores.add(value.getFloat())
  if node.hasKey("standing"):
    for value in node["standing"]:
      result.standing.add(value.getInt())

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives one state per event prefix by replaying `move` events
  ## through the rules and applying `end`'s reason/ending through the same
  ## `settle` the recording used. The recorded `mkind` and `capture` on a
  ## move, and `seat` / `how` / `path` on a win, are re-derived and CHECKED,
  ## so a replay that disagrees with the rules raises instead of drawing a
  ## lie.
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log's first event
  ## is that same start.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evMove:
      let mark = sim.events.len
      sim.applyMove(event.move, event.say, event.notes, event.scripted,
        event.fellBack)
      let derived = sim.events[mark]
      if derived.mkind != event.mkind:
        raise newException(GauntletError,
          "ply " & $event.round & ": recorded mkind " & $event.mkind &
          " but the rules give " & $derived.mkind)
      if derived.capture != event.capture:
        raise newException(GauntletError,
          "ply " & $event.round & ": recorded capture '" & event.capture &
          "' but the rules give '" & derived.capture & "'")
    of evWin:
      var derived: GameEvent
      var found = false
      for logged in sim.events:
        if logged.kind == evWin:
          derived = logged
          found = true
      if not found:
        raise newException(GauntletError,
          "ply " & $event.round & ": a win was recorded that the rules do " &
          "not derive")
      if derived.seat != event.seat or derived.how != event.how or
          derived.path != event.path:
        raise newException(GauntletError,
          "ply " & $event.round & ": the recorded win (seat " & $event.seat &
          ", " & event.how & ") does not match the re-derived one (seat " &
          $derived.seat & ", " & derived.how & ")")
    of evEnd:
      if not sim.done:
        ## A wall-clock stop is not derivable from the moves.
        sim.settle(event.reason, event.ending)
      elif sim.reason != event.reason or sim.ending != event.ending:
        raise newException(GauntletError,
          "recorded end " & event.reason & "/" & event.ending &
          " but the rules give " & sim.reason & "/" & sim.ending)
    result.add(sim)
