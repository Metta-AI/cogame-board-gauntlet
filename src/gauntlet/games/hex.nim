## Hex (7 x 7 rhombus by default), rules only.
##
## Seat 0 (red) links the left file to the right file; seat 1 (blue) links
## the bottom rank to the top rank. Stones are placed on empty cells, they
## never move and are never removed, and a full board always contains
## exactly one winning connection, so Hex has no draws.

import ../types

const
  ## The standard rhombus neighbourhood, as (dRow, dCol) pairs:
  ## west, east, south, north, north-west and south-east of the rhombus.
  HexNeighbours* = [(0, -1), (0, 1), (-1, 0), (1, 0), (-1, 1), (1, -1)]
  ## `distToWin` sentinel for "the opponent has cut every route".
  Unreachable* = 99

proc startBoard*(sim: var Sim) =
  sim.board = newSeq[Occupant](cellCount(sim.config))

iterator neighbours*(sim: Sim, cell: int): int =
  ## The rows/cols bounds are hoisted rather than taken from `onBoard`: this
  ## is the inner loop of both path searches, a debug build inlines
  ## nothing, and the baselines run the searches once per candidate move.
  let cols = boardCols(sim)
  let rows = boardRows(sim)
  let row = cell div cols
  let col = cell mod cols
  for (dRow, dCol) in HexNeighbours:
    let r = row + dRow
    let c = col + dCol
    if r >= 0 and r < rows and c >= 0 and c < cols:
      yield r * cols + c

proc legalMoves*(sim: Sim): seq[string] =
  for cell in 0 ..< sim.board.len:
    if sim.board[cell] == ocEmpty:
      result.add(sim.cellName(cell))

proc isLegalMove*(sim: Sim, move: string): bool =
  try:
    sim.board[sim.cellIndex(move)] == ocEmpty
  except CatchableError:
    false

proc applyMove*(sim: var Sim, move: string) =
  sim.board[sim.cellIndex(move)] = seatOccupant(sim.mover)
  sim.lastKind = mkPlace
  sim.lastCapture = -1

proc isSource*(sim: Sim, seat, cell: int): bool =
  if seat == 0: sim.colOf(cell) == 0 else: sim.rowOf(cell) == 0

proc isTarget*(sim: Sim, seat, cell: int): bool =
  if seat == 0: sim.colOf(cell) == boardCols(sim) - 1
  else: sim.rowOf(cell) == boardRows(sim) - 1

proc connection*(sim: Sim, seat: int): seq[int] =
  ## The chain of the seat's own stones linking its two edges, or an empty
  ## sequence when there is none. BFS with parent tracking so the win
  ## event can name the cells.
  let me = seatOccupant(seat)
  let total = sim.board.len
  var parent: array[MaxCells, int32]
  var queue: array[MaxCells, int32]
  for cell in 0 ..< total:
    parent[cell] = -2'i32                  ## -2 = unvisited
  var head = 0
  var tail = 0
  for cell in 0 ..< total:
    if sim.board[cell] == me and sim.isSource(seat, cell):
      parent[cell] = -1'i32
      queue[tail] = int32(cell)
      inc tail
  while head < tail:
    let cell = int(queue[head])
    inc head
    if sim.isTarget(seat, cell):
      var walk = cell
      while walk >= 0:
        result.add(walk)
        walk = int(parent[walk])
      return
    for next in sim.neighbours(cell):
      if sim.board[next] == me and parent[next] == -2'i32:
        parent[next] = int32(cell)
        queue[tail] = int32(next)
        inc tail
  @[]

proc terminal*(sim: Sim, seat: int):
    tuple[won: bool, how: string, path: seq[int]] =
  let path = sim.connection(seat)
  if path.len > 0:
    (true, "connection", path)
  else:
    (false, "", @[])

proc hasAnyLegalMove*(sim: Sim): bool =
  for cell in sim.board:
    if cell == ocEmpty:
      return true
  false

proc distToWin*(sim: Sim, seat: int): int =
  ## 0-1 BFS from the seat's source edge to its target edge: a cell it owns
  ## costs 0, an empty cell costs 1, an opponent cell is impassable. The
  ## answer is the number of further stones the seat needs, so 0 means the
  ## connection already exists.
  let me = seatOccupant(seat)
  let them = seatOccupant(1 - seat)
  let total = sim.board.len
  var dist: array[MaxCells, int32]
  ## A deque over a ring buffer: 0-cost edges push front, 1-cost push back.
  var deque: array[2 * MaxCells + 2, int32]
  for cell in 0 ..< total:
    dist[cell] = int32(Unreachable)
  var head = MaxCells
  var tail = MaxCells
  for cell in 0 ..< total:
    if sim.board[cell] == them or not sim.isSource(seat, cell):
      continue
    let cost = if sim.board[cell] == me: 0'i32 else: 1'i32
    if cost < dist[cell]:
      dist[cell] = cost
      if cost == 0:
        dec head
        deque[head] = int32(cell)
      else:
        deque[tail] = int32(cell)
        inc tail
  while head < tail:
    let cell = int(deque[head])
    inc head
    let base = dist[cell]
    if sim.isTarget(seat, cell):
      return int(base)
    for next in sim.neighbours(cell):
      if sim.board[next] == them:
        continue
      let step = if sim.board[next] == me: 0'i32 else: 1'i32
      if base + step < dist[next]:
        dist[next] = base + step
        if step == 0'i32:
          dec head
          deque[head] = int32(next)
        else:
          deque[tail] = int32(next)
          inc tail
  Unreachable

proc standing*(sim: Sim, seat: int): int =
  1000 - 10 * sim.distToWin(seat)

proc immediateWinMoves*(sim: Sim): seq[string] =
  ## A stone wins now only when the seat is one cell short; checking that
  ## first keeps this to a single BFS in the overwhelming majority of
  ## positions.
  if sim.distToWin(sim.mover) != 1:
    return @[]
  var probe = sim
  for cell in 0 ..< sim.board.len:
    if sim.board[cell] != ocEmpty:
      continue
    probe.board[cell] = seatOccupant(sim.mover)
    if probe.distToWin(sim.mover) == 0:
      result.add(sim.cellName(cell))
    probe.board[cell] = ocEmpty

proc hasImmediateWin*(sim: Sim): bool =
  sim.distToWin(sim.mover) == 1

proc normalizeMove*(sim: Sim, cleaned: string): string =
  ## `<file><rank>`, single-digit rank, on this board.
  if cleaned.len != 2:
    return ""
  let col = ord(cleaned[0]) - ord('a')
  let row = ord(cleaned[1]) - ord('1')
  if col < 0 or col >= boardCols(sim) or row < 0 or row >= boardRows(sim):
    return ""
  fileLetter(col) & $(row + 1)

proc shortestRouteCells*(sim: Sim, seat: int): seq[int] =
  ## The EMPTY cells on ONE shortest 0-1 route between the seat's edges —
  ## the cells it would still have to fill to connect. Ties resolve toward
  ## the seat's own straight corridor because the search relaxes cells in
  ## row-major order, so the route does not wander between plies.
  let me = seatOccupant(seat)
  let them = seatOccupant(1 - seat)
  let total = sim.board.len
  var dist: array[MaxCells, int32]
  var parent: array[MaxCells, int32]
  var deque: array[2 * MaxCells + 2, int32]
  for cell in 0 ..< total:
    dist[cell] = int32(Unreachable)
    parent[cell] = -1'i32
  var head = MaxCells
  var tail = MaxCells
  for cell in 0 ..< total:
    if sim.board[cell] == them or not sim.isSource(seat, cell):
      continue
    let cost = if sim.board[cell] == me: 0'i32 else: 1'i32
    if cost < dist[cell]:
      dist[cell] = cost
      if cost == 0'i32:
        dec head
        deque[head] = int32(cell)
      else:
        deque[tail] = int32(cell)
        inc tail
  while head < tail:
    let cell = int(deque[head])
    inc head
    let base = dist[cell]
    if sim.isTarget(seat, cell):
      var walk = cell
      while walk >= 0:
        if sim.board[walk] == ocEmpty:
          result.add(walk)
        walk = int(parent[walk])
      return
    for next in sim.neighbours(cell):
      if sim.board[next] == them:
        continue
      let step = if sim.board[next] == me: 0'i32 else: 1'i32
      if base + step < dist[next]:
        dist[next] = base + step
        parent[next] = int32(cell)
        if step == 0'i32:
          dec head
          deque[head] = int32(next)
        else:
          deque[tail] = int32(next)
          inc tail
  @[]

proc neighbourCells*(sim: Sim, cell: int): seq[int] =
  ## The `neighbours` iterator as a sequence, for callers outside this
  ## module (the tests assert the rhombus neighbourhood by name).
  for next in sim.neighbours(cell):
    result.add(next)
