## Quoridor (9 x 9, 10 walls a side by default), rules only.
##
## Seat 0's pawn starts on the centre file of rank 1 and must reach the top
## rank; seat 1 starts on the centre file of the top rank and must reach
## rank 1. A move is either a pawn destination or a wall placement
## `<anchor><h|v>`; a wall is legal only while both pawns still have some
## route to their own goal rank, so no pawn is ever starved.

import ../types

const
  ## North, east, south, west — the canonical direction order for pawn
  ## moves and for the perpendicular pair of a blocked jump.
  Dirs* = [(1, 0), (0, 1), (-1, 0), (0, -1)]
  Perpendicular* = [[1, 3], [0, 2], [1, 3], [0, 2]]
  ## `pathLen` sentinel for a pawn with no route (never reachable in play).
  NoRoute* = 99

## These five are TEMPLATES, not procs: they are the innermost operations of
## every path search, the baselines call the searches a couple of hundred
## times a ply, and a debug build does not inline a proc. Expanding them at
## compile time is what keeps the debug test sweeps inside CI's budget.
template anchorSide*(sim: Sim): int = boardCols(sim) - 1

template anchorIndex*(sim: Sim, row, col: int): int =
  row * anchorSide(sim) + col

template anchorOnBoard*(sim: Sim, row, col: int): bool =
  row >= 0 and row < anchorSide(sim) and col >= 0 and col < anchorSide(sim)

proc goalRowOf*(sim: Sim, seat: int): int =
  if seat == 0: boardRows(sim) - 1 else: 0

proc startBoard*(sim: var Sim) =
  let cols = boardCols(sim.config)
  let rows = boardRows(sim.config)
  let anchors = (cols - 1) * (cols - 1)
  sim.board = newSeq[Occupant](cols * rows)
  sim.hWalls = newSeq[bool](anchors)
  sim.vWalls = newSeq[bool](anchors)
  sim.pawns[0] = 0 * cols + cols div 2
  sim.pawns[1] = (rows - 1) * cols + cols div 2
  sim.board[sim.pawns[0]] = ocSeat0
  sim.board[sim.pawns[1]] = ocSeat1
  sim.wallsLeft = [sim.config.walls, sim.config.walls]

template blockedVertical*(sim: Sim, row, col: int): bool =
  ## Is the step (row, col) <-> (row + 1, col) blocked by a horizontal wall?
  (sim.anchorOnBoard(row, col) and sim.hWalls[sim.anchorIndex(row, col)]) or
    (sim.anchorOnBoard(row, col - 1) and
      sim.hWalls[sim.anchorIndex(row, col - 1)])

template blockedHorizontal*(sim: Sim, row, col: int): bool =
  ## Is the step (row, col) <-> (row, col + 1) blocked by a vertical wall?
  (sim.anchorOnBoard(row, col) and sim.vWalls[sim.anchorIndex(row, col)]) or
    (sim.anchorOnBoard(row - 1, col) and
      sim.vWalls[sim.anchorIndex(row - 1, col)])

template stepBlocked*(sim: Sim, row, col, dir: int): bool =
  (case dir
   of 0: sim.blockedVertical(row, col)
   of 1: sim.blockedHorizontal(row, col)
   of 2: sim.blockedVertical(row - 1, col)
   else: sim.blockedHorizontal(row, col - 1))

proc pawnBfs(sim: Sim, startCell, goalRow: int,
    dist: var array[MaxCells, int32],
    parent: var array[MaxCells, int32]): int =
  ## Shortest pawn-step route from `startCell` to any cell of `goalRow`
  ## over the wall-blocked graph, ignoring the opponent pawn (a jump never
  ## makes a route longer). Returns the goal cell reached, or -1.
  let cols = boardCols(sim)
  let total = sim.board.len
  var queue: array[MaxCells, int32]
  for cell in 0 ..< total:
    dist[cell] = -1'i32
    parent[cell] = -1'i32
  var head = 0
  var tail = 0
  dist[startCell] = 0'i32
  queue[tail] = int32(startCell)
  inc tail
  while head < tail:
    let cell = int(queue[head])
    inc head
    if cell div cols == goalRow:
      return cell
    let row = cell div cols
    let col = cell mod cols
    for dir in 0 .. 3:
      let r = row + Dirs[dir][0]
      let c = col + Dirs[dir][1]
      if not sim.onBoard(r, c):
        continue
      if sim.stepBlocked(row, col, dir):
        continue
      let next = r * cols + c
      if dist[next] >= 0'i32:
        continue
      dist[next] = dist[cell] + 1'i32
      parent[next] = int32(cell)
      queue[tail] = int32(next)
      inc tail
  -1

proc pathLen*(sim: Sim, seat: int): int =
  ## Pawn-step distance from the seat's pawn to its goal rank. This is the
  ## hottest proc in the repo (the baselines call it twice per candidate
  ## move), so it runs its own breadth-first search with no parent array
  ## and an early exit on the first goal cell reached.
  let cols = boardCols(sim)
  let rows = boardRows(sim)
  let total = sim.board.len
  let goalRow = sim.goalRowOf(seat)
  var dist: array[MaxCells, int32]
  var queue: array[MaxCells, int32]
  for cell in 0 ..< total:
    dist[cell] = -1'i32
  var head = 0
  var tail = 0
  let start = sim.pawns[seat]
  dist[start] = 0'i32
  queue[tail] = int32(start)
  inc tail
  while head < tail:
    let cell = int(queue[head])
    inc head
    let row = cell div cols
    if row == goalRow:
      return int(dist[cell])
    let col = cell mod cols
    let base = dist[cell] + 1'i32
    for dir in 0 .. 3:
      let r = row + Dirs[dir][0]
      let c = col + Dirs[dir][1]
      if r < 0 or r >= rows or c < 0 or c >= cols:
        continue
      let next = r * cols + c
      if dist[next] >= 0'i32:
        continue
      if sim.stepBlocked(row, col, dir):
        continue
      dist[next] = base
      queue[tail] = int32(next)
      inc tail
  NoRoute

proc hasRoute*(sim: Sim, seat: int): bool =
  var dist, parent: array[MaxCells, int32]
  sim.pawnBfs(sim.pawns[seat], sim.goalRowOf(seat), dist, parent) >= 0

type
  ## One undirected step of a stored shortest route, in the same
  ## coordinates a wall blocks: `vertical` steps are (row, col) <-> (row+1,
  ## col), horizontal ones are (row, col) <-> (row, col+1).
  RouteEdge* = tuple[vertical: bool, row, col: int]

proc routeEdges*(sim: Sim, seat: int): seq[RouteEdge] =
  ## The steps of ONE shortest route to the seat's goal rank. A candidate
  ## wall that blocks none of these cannot have cut the seat off, which
  ## turns the great majority of wall-legality checks into a handful of
  ## comparisons instead of a fresh breadth-first search.
  let cols = boardCols(sim)
  var dist, parent: array[MaxCells, int32]
  var walk = sim.pawnBfs(sim.pawns[seat], sim.goalRowOf(seat), dist, parent)
  if walk < 0:
    return @[]
  while parent[walk] >= 0'i32:
    let prev = int(parent[walk])
    let aRow = prev div cols
    let aCol = prev mod cols
    let bRow = walk div cols
    let bCol = walk mod cols
    if aCol == bCol:
      result.add((true, min(aRow, bRow), aCol))
    else:
      result.add((false, aRow, min(aCol, bCol)))
    walk = prev

proc wallEdges*(row, col: int, horizontal: bool): array[2, RouteEdge] =
  ## The two steps a wall on this anchor blocks.
  if horizontal:
    [(true, row, col), (true, row, col + 1)]
  else:
    [(false, row, col), (false, row + 1, col)]

proc wallBlocksRoute(route: seq[RouteEdge], row, col: int,
    horizontal: bool): bool =
  let edges = wallEdges(row, col, horizontal)
  for edge in route:
    if edge == edges[0] or edge == edges[1]:
      return true
  false

proc wallSlotFree*(sim: Sim, row, col: int, horizontal: bool): bool =
  ## Everything about a wall placement except the path invariant: the mover
  ## has walls left, the anchor carries no wall of either orientation, and
  ## neither of the two steps it blocks is already blocked.
  if sim.wallsLeft[sim.mover] <= 0:
    return false
  if not sim.anchorOnBoard(row, col):
    return false
  let index = sim.anchorIndex(row, col)
  if sim.hWalls[index] or sim.vWalls[index]:
    return false
  if horizontal:
    if sim.blockedVertical(row, col) or sim.blockedVertical(row, col + 1):
      return false
  else:
    if sim.blockedHorizontal(row, col) or
        sim.blockedHorizontal(row + 1, col):
      return false
  true

proc stepBlockedWith(sim: Sim, row, col, dir: int,
    exRow, exCol: int, exHorizontal: bool): bool =
  ## `stepBlocked` with one extra, not-yet-placed wall in the way, so a
  ## candidate placement can be tested without copying the whole Sim.
  if sim.stepBlocked(row, col, dir):
    return true
  let step: RouteEdge =
    case dir
    of 0: (true, row, col)
    of 1: (false, row, col)
    of 2: (true, row - 1, col)
    else: (false, row, col - 1)
  let edges = wallEdges(exRow, exCol, exHorizontal)
  step == edges[0] or step == edges[1]

proc hasRouteWith(sim: Sim, seat, exRow, exCol: int,
    exHorizontal: bool): bool =
  let cols = boardCols(sim)
  let rows = boardRows(sim)
  let total = sim.board.len
  let goalRow = sim.goalRowOf(seat)
  var seen: array[MaxCells, bool]
  var queue: array[MaxCells, int32]
  for cell in 0 ..< total:
    seen[cell] = false
  var head = 0
  var tail = 0
  seen[sim.pawns[seat]] = true
  queue[tail] = int32(sim.pawns[seat])
  inc tail
  while head < tail:
    let cell = int(queue[head])
    inc head
    let row = cell div cols
    if row == goalRow:
      return true
    let col = cell mod cols
    for dir in 0 .. 3:
      let r = row + Dirs[dir][0]
      let c = col + Dirs[dir][1]
      if r < 0 or r >= rows or c < 0 or c >= cols:
        continue
      if seen[r * cols + c]:
        continue
      if sim.stepBlockedWith(row, col, dir, exRow, exCol, exHorizontal):
        continue
      seen[r * cols + c] = true
      queue[tail] = int32(r * cols + c)
      inc tail
  false

proc wallKeepsRoutes*(sim: Sim, row, col: int, horizontal: bool,
    routes: array[2, seq[RouteEdge]]): bool =
  ## The path invariant. A candidate wall that blocks no step of either
  ## stored shortest route cannot have cut anyone off, which is what keeps
  ## a full legal-move scan to a couple of searches instead of 256.
  var touched = false
  for seat in 0 .. 1:
    if wallBlocksRoute(routes[seat], row, col, horizontal):
      touched = true
  if not touched:
    return true
  sim.hasRouteWith(0, row, col, horizontal) and
    sim.hasRouteWith(1, row, col, horizontal)

proc wallName*(sim: Sim, row, col: int, horizontal: bool): string =
  fileLetter(col) & $(row + 1) & (if horizontal: "h" else: "v")

proc pawnMoves*(sim: Sim): seq[tuple[cell: int, kind: MoveKind]] =
  ## Plain steps in north/east/south/west order, then the jump and
  ## diagonal targets in the same order.
  let cols = boardCols(sim)
  let me = sim.pawns[sim.mover]
  let them = sim.pawns[1 - sim.mover]
  let row = me div cols
  let col = me mod cols
  for dir in 0 .. 3:
    let r = row + Dirs[dir][0]
    let c = col + Dirs[dir][1]
    if not sim.onBoard(r, c) or sim.stepBlocked(row, col, dir):
      continue
    if r * cols + c != them:
      result.add((r * cols + c, mkStep))
  for dir in 0 .. 3:
    let r = row + Dirs[dir][0]
    let c = col + Dirs[dir][1]
    if not sim.onBoard(r, c) or sim.stepBlocked(row, col, dir):
      continue
    if r * cols + c != them:
      continue
    let jr = r + Dirs[dir][0]
    let jc = c + Dirs[dir][1]
    if sim.onBoard(jr, jc) and not sim.stepBlocked(r, c, dir):
      result.add((jr * cols + jc, mkJump))
      continue
    ## The straight jump is unavailable, and only then may the mover step
    ## to either cell diagonally adjacent to the opponent pawn.
    for side in Perpendicular[dir]:
      let pr = r + Dirs[side][0]
      let pc = c + Dirs[side][1]
      if sim.onBoard(pr, pc) and not sim.stepBlocked(r, c, side):
        result.add((pr * cols + pc, mkJump))

proc legalMoves*(sim: Sim): seq[string] =
  for (cell, _) in sim.pawnMoves():
    result.add(sim.cellName(cell))
  if sim.wallsLeft[sim.mover] <= 0:
    return
  let routes = [sim.routeEdges(0), sim.routeEdges(1)]
  for row in 0 ..< anchorSide(sim):
    for col in 0 ..< anchorSide(sim):
      for horizontal in [true, false]:
        if sim.wallSlotFree(row, col, horizontal) and
            sim.wallKeepsRoutes(row, col, horizontal, routes):
          result.add(sim.wallName(row, col, horizontal))

proc isWallMove*(move: string): bool =
  move.len >= 3 and (move[^1] == 'h' or move[^1] == 'v')

proc parseWall*(sim: Sim, move: string): tuple[row, col: int,
    horizontal: bool] =
  let horizontal = move[^1] == 'h'
  let body = move[0 ..< move.high]
  let col = ord(body[0]) - ord('a')
  var rank = 0
  for index in 1 ..< body.len:
    if body[index] notin '0' .. '9':
      raise newException(GauntletError, "not a wall: " & move)
    rank = rank * 10 + (ord(body[index]) - ord('0'))
  if not sim.anchorOnBoard(rank - 1, col):
    raise newException(GauntletError, "wall anchor off the board: " & move)
  (rank - 1, col, horizontal)

proc isLegalMove*(sim: Sim, move: string): bool =
  if isWallMove(move):
    var row, col: int
    var horizontal: bool
    try:
      (row, col, horizontal) = sim.parseWall(move)
    except CatchableError:
      return false
    if not sim.wallSlotFree(row, col, horizontal):
      return false
    let routes = [sim.routeEdges(0), sim.routeEdges(1)]
    return sim.wallKeepsRoutes(row, col, horizontal, routes)
  var cell = -1
  try:
    cell = sim.cellIndex(move)
  except CatchableError:
    return false
  for (target, _) in sim.pawnMoves():
    if target == cell:
      return true
  false

proc applyMove*(sim: var Sim, move: string) =
  sim.lastCapture = -1
  if isWallMove(move):
    let (row, col, horizontal) = sim.parseWall(move)
    let index = sim.anchorIndex(row, col)
    if horizontal: sim.hWalls[index] = true else: sim.vWalls[index] = true
    dec sim.wallsLeft[sim.mover]
    inc sim.wallsUsed[sim.mover]
    sim.lastKind = mkWall
    return
  let cell = sim.cellIndex(move)
  var kind = mkStep
  for (target, moveKind) in sim.pawnMoves():
    if target == cell:
      kind = moveKind
      break
  sim.board[sim.pawns[sim.mover]] = ocEmpty
  sim.pawns[sim.mover] = cell
  sim.board[cell] = seatOccupant(sim.mover)
  sim.lastKind = kind

proc terminal*(sim: Sim, seat: int):
    tuple[won: bool, how: string, path: seq[int]] =
  if sim.rowOf(sim.pawns[seat]) == sim.goalRowOf(seat):
    (true, "goal-row", @[sim.pawns[seat]])
  else:
    (false, "", @[])

proc hasAnyLegalMove*(sim: Sim): bool =
  sim.pawnMoves().len > 0

proc standing*(sim: Sim, seat: int): int =
  1000 - 10 * sim.pathLen(seat) + 2 * sim.wallsLeft[seat]

proc immediateWinMoves*(sim: Sim): seq[string] =
  ## Only a pawn move can win; a wall never does.
  let goal = sim.goalRowOf(sim.mover)
  for (cell, _) in sim.pawnMoves():
    if sim.rowOf(cell) == goal:
      result.add(sim.cellName(cell))

proc hasImmediateWin*(sim: Sim): bool =
  sim.immediateWinMoves().len > 0

proc normalizeMove*(sim: Sim, cleaned: string): string =
  ## `<file><rank>` is a pawn move; `<file><rank>h|v` is a wall.
  if cleaned.len == 2:
    let col = ord(cleaned[0]) - ord('a')
    let row = ord(cleaned[1]) - ord('1')
    if col < 0 or col >= boardCols(sim) or row < 0 or row >= boardRows(sim):
      return ""
    return fileLetter(col) & $(row + 1)
  if cleaned.len == 3 and (cleaned[2] == 'h' or cleaned[2] == 'v'):
    let col = ord(cleaned[0]) - ord('a')
    let row = ord(cleaned[1]) - ord('1')
    if not sim.anchorOnBoard(row, col):
      return ""
    return fileLetter(col) & $(row + 1) & cleaned[2]
  ""
