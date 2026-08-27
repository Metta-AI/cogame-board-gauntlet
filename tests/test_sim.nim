## The rules. Everything here runs in ci.yml, in both debug and release:
## debug catches range and overflow bugs, release catches codegen bugs.

import std/[json, random, sets, unittest]
import gauntlet/sim
import gauntlet/llm

const AllGames = [gConnectFour, gBreakthrough, gHex, gQuoridor]

proc variantConfig*(game: Game, size = 0, walls = -1, maxPlies = 0,
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

proc playOut(config: GameConfig, first, second: Baseline, opening = 0,
    seed = 0): Sim =
  ## The baselines are deterministic and carry no RNG, so 300 seeds of
  ## pure self-play would be 300 copies of one episode. A seeded random
  ## OPENING of `opening` plies puts the baselines in 300 genuinely
  ## different positions and then lets them play it out.
  var rng = initRand(int64(seed) * 1009 + 7)
  result = initSim(config)
  var ply = 0
  while not result.done:
    var move: string
    if ply < opening:
      let moves = result.legalMoves()
      move = moves[rng.rand(moves.high)]
    else:
      move = scriptedMove(result, if result.mover == 0: first else: second)
    result.applyMove(move, "", "", true, false)
    inc ply

proc playRandom(config: GameConfig, seed: int): Sim =
  var rng = initRand(int64(seed) * 977 + 13)
  result = initSim(config)
  while not result.done:
    let moves = result.legalMoves()
    check moves.len > 0
    result.applyMove(moves[rng.rand(moves.high)], "", "", true, false)

# ---- 1. Coordinates ---------------------------------------------------------

suite "coordinates":
  test "cellIndex(cellName(i)) == i on every shipped board":
    for game in AllGames:
      let config = variantConfig(game)
      for cell in 0 ..< cellCount(config):
        check cellIndex(config, cellName(config, cell)) == cell

  test "a1 is (row 0, col 0) and g7 is (row 6, col 6) on a 7x7":
    let config = variantConfig(gHex, size = 7)
    check cellIndex(config, "a1") == 0
    check rowOf(config, cellIndex(config, "a1")) == 0
    check colOf(config, cellIndex(config, "a1")) == 0
    check rowOf(config, cellIndex(config, "g7")) == 6
    check colOf(config, cellIndex(config, "g7")) == 6
    check cellName(config, 0) == "a1"
    check cellName(config, 48) == "g7"

  test "an off-board name raises":
    let config = variantConfig(gHex, size = 7)
    expect GauntletError: discard cellIndex(config, "h1")
    expect GauntletError: discard cellIndex(config, "a8")
    expect GauntletError: discard cellIndex(config, "zz")
    expect GauntletError: discard cellIndex(config, "a")

# ---- 2. The rotation --------------------------------------------------------

suite "rotation":
  test "seed mod 4 maps onto the fixed rotation order, for 400 seeds":
    for seed in 0 ..< 400:
      var config = defaultGameConfig()
      config.players = @[PlayerConfig(name: "A"), PlayerConfig(name: "B")]
      config.seed = seed
      let resolved = sampleEpisode(config)
      check resolved.rotated
      check resolved.game == RotationOrder[seed mod 4]
      check $resolved.game != "rotate"

  test "sampleEpisode is idempotent":
    for seed in 0 ..< 40:
      var config = defaultGameConfig()
      config.players = @[PlayerConfig(name: "A"), PlayerConfig(name: "B")]
      config.seed = seed
      let once = sampleEpisode(config)
      let twice = sampleEpisode(once)
      check once == twice

  test "every rotation outcome of the gauntlet variant builds a legal Sim":
    for seed in 0 ..< 40:
      var config = defaultGameConfig()
      config.game = gRotate
      config.size = 7
      config.walls = 10
      config.maxPlies = 80
      config.seed = seed
      config.players = @[PlayerConfig(name: "A"), PlayerConfig(name: "B")]
      config.tokens = @["t0", "t1"]
      let resolved = sampleEpisode(config)
      check sizeLegal(resolved.game, resolved.size)
      let sim = initSim(resolved)
      check sim.legalMoves().len > 0
      check sim.config.maxPlies <= plyCap(resolved.game, resolved.size)

  test "an unpinned seed cannot silently mean seed 0":
    ## The server draws one before initSim; the rotation would otherwise
    ## always pick connect-four.
    var config = defaultGameConfig()
    check config.seed == 0
    check sampleEpisode(config).game == gConnectFour
    for drawn in [1, 7, 118829, 999_999_999]:
      var pinned = defaultGameConfig()
      pinned.seed = drawn
      let resolved = sampleEpisode(pinned)
      check resolved.seed == drawn
      check resolved.game == RotationOrder[drawn mod 4]

# ---- 3. Connect Four --------------------------------------------------------

suite "connect-four":
  test "a drop lands on the lowest empty cell of its file":
    var sim = initSim(variantConfig(gConnectFour))
    sim.applyMove("d", "", "", true, false)
    check sim.board[cellIndex(sim.config, "d1")] == ocSeat0
    sim.applyMove("d", "", "", true, false)
    check sim.board[cellIndex(sim.config, "d2")] == ocSeat1
    check sim.board[cellIndex(sim.config, "d3")] == ocEmpty

  test "a full file leaves legalMoves":
    var sim = initSim(variantConfig(gConnectFour))
    for _ in 0 ..< 6:
      sim.applyMove("a", "", "", true, false)
    check "a" notin sim.legalMoves()
    check not sim.isLegalMove("a")
    expect GauntletError: sim.applyMove("a", "", "", true, false)

  test "all four line directions are detected, with a four-cell win path":
    ## Classify the win path of every `line` ending over seeded random
    ## play: horizontal, vertical and both diagonals must all turn up, and
    ## every path must be four cells of the winner's own colour.
    var seen: HashSet[string]
    for seed in 0 ..< 400:
      let sim = playRandom(variantConfig(gConnectFour, seed = seed), seed)
      if sim.ending != "line":
        continue
      check sim.reason == "complete"
      check sim.winner >= 0
      check sim.winPath.len == 4
      var win: GameEvent
      for event in sim.events:
        if event.kind == evWin: win = event
      check win.how == "line"
      check win.seat == sim.winner
      check win.path.len == 4
      var cells: seq[int]
      for name in win.path:
        let cell = cellIndex(sim.config, name)
        check sim.board[cell] == seatOccupant(sim.winner)
        cells.add(cell)
      let cols = boardCols(sim.config)
      let dRow = rowOf(sim.config, cells[1]) - rowOf(sim.config, cells[0])
      let dCol = colOf(sim.config, cells[1]) - colOf(sim.config, cells[0])
      discard cols
      if dRow == 0: seen.incl("horizontal")
      elif dCol == 0: seen.incl("vertical")
      elif dRow == dCol: seen.incl("rising")
      else: seen.incl("falling")
    check seen == toHashSet(["horizontal", "vertical", "rising", "falling"])

  test "a full board with no line is a draw":
    ## Play, over seeded orderings, only moves that do not end the game --
    ## the board fills and nobody has four in a row.
    var found = false
    for seed in 0 ..< 400:
      var rng = initRand(int64(seed) * 37 + 5)
      var sim = initSim(variantConfig(gConnectFour, seed = seed))
      var stuck = false
      while not sim.done:
        var options: seq[string]
        let base = sim.probeBase()
        for move in sim.legalMoves():
          let probe = base.probeMove(move)
          if not probe.done or probe.ending == "board-full":
            options.add(move)
        if options.len == 0:
          stuck = true
          break
        sim.applyMove(options[rng.rand(options.high)], "", "", true, false)
      if stuck or not sim.done or sim.ending != "board-full":
        continue
      found = true
      check sim.reason == "complete"
      check sim.winner == -1
      check sim.score(0) == 0.0
      check sim.score(1) == 0.0
      check sim.plies == 42
      break
    check found

  test "standing counts exactly 69 windows on a 7x6 board":
    var sim = initSim(variantConfig(gConnectFour))
    ## An empty board: every window has zero of the mover's discs, so it
    ## scores w[0] = 0. Give seat 0 one disc and every window through that
    ## cell scores w[1] = 1, which counts the windows containing it.
    check sim.standing(0) == 0
    ## Sum over all cells of (windows through that cell) = 4 * 69 = 276.
    var total = 0
    for cell in 0 ..< cellCount(sim.config):
      var probe = initSim(variantConfig(gConnectFour))
      probe.board[cell] = ocSeat0
      total += probe.standing(0)
    check total == 4 * 69

  test "a window holding both colours contributes 0":
    var sim = initSim(variantConfig(gConnectFour))
    sim.board[cellIndex(sim.config, "a1")] = ocSeat0
    sim.board[cellIndex(sim.config, "b1")] = ocSeat1
    ## The three windows through a1 that also contain b1 are dead for both.
    var mine = initSim(variantConfig(gConnectFour))
    mine.board[cellIndex(mine.config, "a1")] = ocSeat0
    check sim.standing(0) < mine.standing(0)

# ---- 4. Breakthrough --------------------------------------------------------

suite "breakthrough":
  test "straight forward onto an occupied cell is illegal":
    var sim = initSim(variantConfig(gBreakthrough))
    check not sim.isLegalMove("a1-a2")
    expect GauntletError: sim.applyMove("a1-a2", "", "", true, false)

  test "a diagonal onto an enemy captures and removes it":
    var sim = initSim(variantConfig(gBreakthrough, size = 6))
    ## Hand-built: a lone red on c3 and a lone blue on d4.
    for cell in 0 ..< cellCount(sim.config):
      sim.board[cell] = ocEmpty
    sim.board[cellIndex(sim.config, "c3")] = ocSeat0
    sim.board[cellIndex(sim.config, "d4")] = ocSeat1
    sim.board[cellIndex(sim.config, "a1")] = ocSeat1
    check sim.isLegalMove("c3-d4")
    sim.applyMove("c3-d4", "", "", true, false)
    check sim.board[cellIndex(sim.config, "d4")] == ocSeat0
    check sim.board[cellIndex(sim.config, "c3")] == ocEmpty
    check sim.captures[0] == 1
    check sim.lastKind == mkCapture
    var move: GameEvent
    for event in sim.events:
      if event.kind == evMove: move = event
    check move.capture == "d4"
    check move.mkind == mkCapture

  test "a diagonal onto your own piece and any backwards move are illegal":
    var sim = initSim(variantConfig(gBreakthrough))
    check sim.isLegalMove("a2-b3")       ## diagonal onto empty: legal
    check not sim.isLegalMove("a1-b2")   ## diagonal onto own piece
    check not sim.isLegalMove("a2-b2")   ## sideways
    check not sim.isLegalMove("b2-b1")   ## backwards
    check not sim.isLegalMove("b2-a1")   ## backwards diagonal
    check not sim.isLegalMove("a2-a3-")  ## not a move string at all

  test "reaching the far home rank ends home-rank":
    var sim = initSim(variantConfig(gBreakthrough, size = 6))
    for cell in 0 ..< cellCount(sim.config):
      sim.board[cell] = ocEmpty
    sim.board[cellIndex(sim.config, "c5")] = ocSeat0
    sim.board[cellIndex(sim.config, "a1")] = ocSeat1
    sim.applyMove("c5-c6", "", "", true, false)
    check sim.done
    check sim.ending == "home-rank"
    check sim.reason == "complete"
    check sim.winner == 0
    check sim.score(0) == 1.0
    check sim.score(1) == -1.0

  test "taking the last piece ends no-pieces":
    var sim = initSim(variantConfig(gBreakthrough, size = 6))
    for cell in 0 ..< cellCount(sim.config):
      sim.board[cell] = ocEmpty
    sim.board[cellIndex(sim.config, "c3")] = ocSeat0
    sim.board[cellIndex(sim.config, "d4")] = ocSeat1
    sim.applyMove("c3-d4", "", "", true, false)
    check sim.done
    check sim.ending == "no-pieces"
    check sim.winner == 0

  test "a blocked army ends no-moves and the STARVED seat loses":
    ## Hand-built: blue's whole army is a2 and b1. a2 cannot step straight
    ## (a1 holds a red piece) and cannot take b1 (its own piece); b1 has no
    ## rank below it. Red plays a quiet move and blue is starved.
    var sim = initSim(variantConfig(gBreakthrough, size = 6))
    for cell in 0 ..< cellCount(sim.config):
      sim.board[cell] = ocEmpty
    sim.board[cellIndex(sim.config, "a1")] = ocSeat0
    sim.board[cellIndex(sim.config, "c4")] = ocSeat0
    sim.board[cellIndex(sim.config, "a2")] = ocSeat1
    sim.board[cellIndex(sim.config, "b1")] = ocSeat1
    check sim.mover == 0
    sim.applyMove("c4-c5", "", "", true, false)
    check sim.done
    check sim.ending == "no-moves"
    check sim.reason == "complete"
    check sim.winner == 0
    check sim.score(1) == -1.0
    var win: GameEvent
    for event in sim.events:
      if event.kind == evWin: win = event
    check win.how == "no-moves"
    check win.seat == 0

# ---- 5. Hex -----------------------------------------------------------------

suite "hex":
  test "c4 has exactly six neighbours and a1 exactly two":
    let config = variantConfig(gHex, size = 7)
    var sim = initSim(config)
    proc names(cell: int): HashSet[string] =
      for next in hexNeighbourCells(sim, cell):
        result.incl(sim.cellName(next))
    check names(cellIndex(config, "c4")) ==
      toHashSet(["b4", "d4", "c3", "c5", "b5", "d3"])
    check names(cellIndex(config, "a1")) == toHashSet(["b1", "a2"])

  test "adjacency is symmetric for every pair":
    var sim = initSim(variantConfig(gHex, size = 7))
    for cell in 0 ..< cellCount(sim.config):
      for next in hexNeighbourCells(sim, cell):
        var back = false
        for other in hexNeighbourCells(sim, next):
          if other == cell: back = true
        check back

  test "a full board always has EXACTLY one winning connection":
    for seed in 0 ..< 300:
      var rng = initRand(int64(seed) * 31 + 5)
      var sim = initSim(variantConfig(gHex, size = 7, seed = seed))
      var cells = newSeq[int](cellCount(sim.config))
      for index in 0 ..< cells.len:
        cells[index] = index
      rng.shuffle(cells)
      for index, cell in cells:
        sim.board[cell] = if index mod 2 == 0: ocSeat0 else: ocSeat1
      let red = sim.terminalFor(0).won
      let blue = sim.terminalFor(1).won
      check red != blue

  test "distToWin is 0 once connected and 99 when every route is cut":
    var sim = initSim(variantConfig(gHex, size = 7))
    for col in 0 ..< 7:
      sim.board[3 * 7 + col] = ocSeat0
    check sim.distToWin(0) == 0
    check sim.terminalFor(0).won
    var cut = initSim(variantConfig(gHex, size = 7))
    for row in 0 ..< 7:
      cut.board[row * 7 + 3] = ocSeat1
    check cut.distToWin(0) == 99
    check cut.standing(0) == 10

# ---- 6. Quoridor ------------------------------------------------------------

suite "quoridor":
  test "an occupied anchor, a re-blocked step and a cut-off pawn are illegal":
    var sim = initSim(variantConfig(gQuoridor, size = 9, walls = 10))
    check sim.isLegalMove("e3h")
    sim.applyMove("e3h", "", "", true, false)
    check sim.wallsUsed[0] == 1
    check sim.wallsLeft[0] == 9
    ## Same anchor, either orientation.
    check not sim.isLegalMove("e3h")
    check not sim.isLegalMove("e3v")
    ## A horizontal wall one file to the left re-blocks a step e3h took.
    check not sim.isLegalMove("d3h")
    ## A wall that leaves a pawn with no path at all.
    var boxed = initSim(variantConfig(gQuoridor, size = 9, walls = 10))
    for move in ["d1v", "e1h", "f1h"]:
      if boxed.isLegalMove(move):
        boxed.applyMove(move, "", "", true, false)
        boxed.applyMove(boxed.legalMoves()[0], "", "", true, false)
    ## Whatever was played, the invariant still holds for both pawns.
    check boxed.pathLen(0) < 99
    check boxed.pathLen(1) < 99

  test "over 200 seeded episodes every position keeps a path for both pawns":
    for seed in 0 ..< 200:
      var rng = initRand(int64(seed) * 61 + 7)
      var sim = initSim(variantConfig(gQuoridor, size = 9, walls = 10,
        maxPlies = 30, seed = seed))
      while not sim.done:
        let moves = sim.legalMoves()
        check moves.len > 0
        sim.applyMove(moves[rng.rand(moves.high)], "", "", true, false)
        check sim.pathLen(0) < 99
        check sim.pathLen(1) < 99

  test "the straight jump is offered, and the diagonals only when it is not":
    var sim = initSim(variantConfig(gQuoridor, size = 9, walls = 10))
    ## Face the pawns off in the middle of the board.
    sim.board[sim.pawns[0]] = ocEmpty
    sim.board[sim.pawns[1]] = ocEmpty
    sim.pawns[0] = cellIndex(sim.config, "e4")
    sim.pawns[1] = cellIndex(sim.config, "e5")
    sim.board[sim.pawns[0]] = ocSeat0
    sim.board[sim.pawns[1]] = ocSeat1
    var moves = sim.legalMoves()
    check "e6" in moves      ## the straight jump over e5
    check "d5" notin moves   ## no diagonal while the jump is available
    check "f5" notin moves
    ## Now block the far side of the jump with a wall behind blue.
    var blocked = sim
    blocked.applyMove("e5h", "", "", true, false)
    ## e5h blocks (e,5)-(e,6) and (f,5)-(f,6): the straight jump is gone.
    blocked.mover = 0
    var jumpMoves = blocked.legalMoves()
    check "e6" notin jumpMoves
    check "d5" in jumpMoves
    check "f5" in jumpMoves

  test "a pawn always has at least one legal move, and goal-row ends it":
    var sim = initSim(variantConfig(gQuoridor, size = 9, walls = 10))
    check sim.hasAnyLegalMove()
    sim.board[sim.pawns[0]] = ocEmpty
    sim.board[sim.pawns[1]] = ocEmpty
    sim.pawns[0] = cellIndex(sim.config, "e8")
    sim.pawns[1] = cellIndex(sim.config, "a1")
    sim.board[sim.pawns[0]] = ocSeat0
    sim.board[sim.pawns[1]] = ocSeat1
    check sim.hasAnyLegalMove()
    sim.applyMove("e9", "", "", true, false)
    check sim.done
    check sim.ending == "goal-row"
    check sim.winner == 0

# ---- 7. Turn order ----------------------------------------------------------

suite "turn order":
  test "the mover alternates strictly, in every game":
    for game in AllGames:
      for seed in 0 ..< 10:
        var sim = initSim(variantConfig(game, seed = seed))
        var rng = initRand(int64(seed) * 17 + 1)
        var expected = sim.config.first
        var ply = 0
        while not sim.done:
          check sim.mover == expected
          check sim.mover == (sim.config.first + ply) mod 2
          let moves = sim.legalMoves()
          sim.applyMove(moves[rng.rand(moves.high)], "", "", true, false)
          expected = 1 - expected
          inc ply

# ---- 8. Legality ------------------------------------------------------------

suite "legality":
  test "applyMove raises for every move outside legalMoves":
    for game in AllGames:
      for seed in 0 ..< 75:
        var rng = initRand(int64(seed) * 13 + 3)
        var sim = initSim(variantConfig(game, maxPlies = 12, seed = seed))
        while not sim.done:
          let legal = sim.legalMoves().toHashSet()
          ## Probe a handful of well-formed strings of this game and check
          ## that exactly the ones in `legal` are accepted.
          var probes: seq[string]
          for cell in 0 ..< min(cellCount(sim.config), 12):
            probes.add(sim.cellName(cell))
          probes.add("a")
          probes.add("a1-b2")
          probes.add("a1h")
          for probe in probes:
            if probe in legal:
              continue
            var copy = sim
            expect GauntletError:
              copy.applyMove(probe, "", "", true, false)
          sim.applyMove(sim.legalMoves()[rng.rand(sim.legalMoves().high)],
            "", "", true, false)

  test "normalizeMove accepts the tolerated spellings and nothing else":
    var four = initSim(variantConfig(gConnectFour))
    for raw in ["d", "D", " d ", "4", "column d \u2014 centre"]:
      check four.normalizeMove(raw) == "d"
    check four.normalizeMove("h") == ""
    check four.normalizeMove("b2-c3") == "b"    ## first standalone token
    var hexSim = initSim(variantConfig(gHex, size = 7))
    check hexSim.normalizeMove("c4") == "c4"
    check hexSim.normalizeMove("C4") == "c4"
    check hexSim.normalizeMove("h4") == ""
    check hexSim.normalizeMove("c8") == ""
    check hexSim.normalizeMove("b2-c3") == ""   ## a different game's move
    check hexSim.normalizeMove("e3h") == ""
    var bt = initSim(variantConfig(gBreakthrough, size = 6))
    for raw in ["b2-c3", "b2c3", "b2 x c3", "B2-C3"]:
      check bt.normalizeMove(raw) == "b2-c3"
    check bt.normalizeMove("c4") == ""
    check bt.normalizeMove("g2-h3") == ""
    var quo = initSim(variantConfig(gQuoridor, size = 9))
    check quo.normalizeMove("e2") == "e2"
    check quo.normalizeMove("e3h") == "e3h"
    check quo.normalizeMove("E3 H") == "e3h"
    check quo.normalizeMove("i9") == "i9"
    check quo.normalizeMove("i9h") == ""        ## anchors stop at h8
    check quo.normalizeMove("b2-c3") == ""

# ---- 9. Termination bound ---------------------------------------------------

suite "termination":
  test "every episode ends inside maxPlies with a legal reason/ending pair":
    const Reasons = ["complete", "deadline"]
    const Endings = ["line", "board-full", "home-rank", "no-pieces",
      "no-moves", "connection", "goal-row", "ply-cap", "wall-clock"]
    for game in AllGames:
      for baseline in [blTactician, blHustler]:
        for seed in 0 ..< 300:
          let sim = playOut(variantConfig(game, seed = seed), baseline,
            baseline, opening = seed mod 6, seed = seed)
          check sim.done
          check sim.plies <= sim.config.maxPlies
          check sim.reason in Reasons
          check sim.ending in Endings

# ---- 10. Scoring ------------------------------------------------------------

suite "scoring":
  test "scores sum to exactly zero over 300 seeded episodes":
    for game in AllGames:
      for seed in 0 ..< 75:
        for pairing in 0 ..< 4:
          let first = if pairing < 2: blTactician else: blHustler
          let second = if pairing mod 2 == 0: blTactician else: blHustler
          let sim = playOut(variantConfig(game, seed = seed), first,
            second, opening = seed mod 5, seed = seed)
          check sim.score(0) + sim.score(1) == 0.0
          if sim.winner >= 0:
            check sim.score(sim.winner) == 1.0
            check sim.score(1 - sim.winner) == -1.0
            check sim.outcome(sim.winner) == 1.0
          else:
            check sim.score(0) == 0.0
            check sim.outcome(0) == 0.5

  test "a draw happens only on board-full, ply-cap or wall-clock":
    for game in AllGames:
      for seed in 0 ..< 60:
        let sim = playRandom(variantConfig(game, seed = seed), seed)
        if sim.winner < 0:
          check sim.ending in ["board-full", "ply-cap", "wall-clock"]
          check sim.standing(0) == sim.standing(1) or
            sim.ending == "board-full"

  test "the ending table names the winner":
    ## no-moves gives it to the seat NOT to move; every other terminal
    ## ending gives it to the seat that moved.
    for game in AllGames:
      for seed in 0 ..< 40:
        let sim = playOut(variantConfig(game, seed = seed), blTactician,
          blHustler, opening = seed mod 7, seed = seed)
        case sim.ending
        of "line", "connection", "home-rank", "no-pieces", "goal-row":
          check sim.winner >= 0
          var win: GameEvent
          for event in sim.events:
            if event.kind == evWin: win = event
          check win.seat == sim.winner
          check win.how == sim.ending
        of "no-moves":
          check sim.winner == 1 - sim.mover
        of "ply-cap", "wall-clock":
          if sim.standing(0) > sim.standing(1): check sim.winner == 0
          elif sim.standing(1) > sim.standing(0): check sim.winner == 1
          else: check sim.winner == -1
        else:
          check sim.ending == "board-full"

# ---- 11. standing and the eval bar -----------------------------------------

suite "standing":
  test "standing is finite for both seats in every reachable position":
    for game in AllGames:
      for seed in 0 ..< 30:
        var rng = initRand(int64(seed) * 7 + 11)
        var sim = initSim(variantConfig(game, seed = seed))
        while not sim.done:
          for seat in 0 .. 1:
            let value = sim.standing(seat)
            check value > low(int) div 2
            check value < high(int) div 2
          check sim.evalBar() >= -1.0
          check sim.evalBar() <= 1.0
          let moves = sim.legalMoves()
          sim.applyMove(moves[rng.rand(moves.high)], "", "", true, false)
        check sim.evalBar() >= -1.0
        check sim.evalBar() <= 1.0

  test "a hex stone on the seat's own shortest route never lengthens it":
    for seed in 0 ..< 60:
      var rng = initRand(int64(seed) * 23 + 9)
      var sim = initSim(variantConfig(gHex, size = 7, seed = seed))
      while not sim.done:
        let seat = sim.mover
        let before = sim.distToWin(seat)
        let route = hexRouteCells(sim, seat)
        if route.len > 0:
          let probe = sim.probeBase().probeMove(sim.cellName(route[0]))
          check probe.distToWin(seat) <= before
        let moves = sim.legalMoves()
        sim.applyMove(moves[rng.rand(moves.high)], "", "", true, false)

# ---- 12. Every shipped game_config builds a Sim ----------------------------

suite "shipped configs":
  test "every variant's and the cert fixture's game_config builds a Sim":
    let manifest = parseFile("coworld_manifest_template.json")
    var fixtures: seq[JsonNode]
    for variant in manifest["variants"]:
      fixtures.add(variant["game_config"])
    fixtures.add(manifest["certification"]["game_config"])
    check fixtures.len == 6
    for fixture in fixtures:
      ## The runner injects tokens; the fixture must not carry them.
      check not fixture.hasKey("tokens")
      var config = defaultGameConfig()
      var node = copy(fixture)
      node.delete("num_agents")
      node["tokens"] = %*["token-0", "token-1"]
      config.update($node)
      for seed in [0, 1, 2, 3, 23, 118829]:
        var seeded = config
        if seeded.seed == 0:
          seeded.seed = seed
        let resolved = sampleEpisode(seeded)
        let sim = initSim(resolved)
        check sim.legalMoves().len > 0
        check sim.names.len == 2
        check sim.names[0] != sim.names[1]
