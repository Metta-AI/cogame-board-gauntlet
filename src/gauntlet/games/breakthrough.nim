## Breakthrough (6 x 6 by default), rules only.
##
## Seat 0 is red with two full home ranks at the bottom, seat 1 is blue
## with two at the top. Pieces step one rank forward, straight onto an
## empty cell or diagonally onto an empty cell or an enemy piece (which is
## removed). Reaching the far home rank wins; so does taking the last
## enemy piece; a seat with no legal move loses.

import std/strutils, ../types

proc forwardOf*(seat: int): int =
  if seat == 0: 1 else: -1

proc homeRankOf*(sim: Sim, seat: int): int =
  ## The rank a seat's piece must reach to break through.
  if seat == 0: boardRows(sim) - 1 else: 0

proc startBoard*(sim: var Sim) =
  let cols = boardCols(sim.config)
  let rows = boardRows(sim.config)
  sim.board = newSeq[Occupant](cols * rows)
  for col in 0 ..< cols:
    sim.board[0 * cols + col] = ocSeat0
    sim.board[1 * cols + col] = ocSeat0
    sim.board[(rows - 2) * cols + col] = ocSeat1
    sim.board[(rows - 1) * cols + col] = ocSeat1

proc moveName*(sim: Sim, fromCell, toCell: int): string =
  sim.cellName(fromCell) & "-" & sim.cellName(toCell)

template stepLegal*(sim: Sim, seat, fromRow, fromCol, dCol: int): bool =
  ## `dCol` is 0 for a straight step, -1 / +1 for a diagonal one. A
  ## template because the move scans call it for every piece on the board,
  ## once per candidate move, and a debug build inlines nothing.
  block:
    let toRow = fromRow + forwardOf(seat)
    let toCol = fromCol + dCol
    if toRow < 0 or toRow >= boardRows(sim) or
        toCol < 0 or toCol >= boardCols(sim):
      false
    else:
      let target = sim.board[toRow * boardCols(sim) + toCol]
      if dCol == 0: target == ocEmpty
      else: target != seatOccupant(seat)

iterator moveOffsets*(): int =
  ## Canonical destination order for one piece: straight, then the file to
  ## the left, then the file to the right.
  yield 0
  yield -1
  yield 1

proc legalMoves*(sim: Sim): seq[string] =
  let cols = boardCols(sim)
  let rows = boardRows(sim)
  let me = seatOccupant(sim.mover)
  for row in 0 ..< rows:
    for col in 0 ..< cols:
      if sim.occ(row, col) != me:
        continue
      for dCol in moveOffsets():
        if sim.stepLegal(sim.mover, row, col, dCol):
          result.add(sim.moveName(row * cols + col,
            (row + forwardOf(sim.mover)) * cols + col + dCol))

proc parseMove*(sim: Sim, move: string): tuple[fromCell, toCell: int] =
  ## Raises when the string does not name two cells of this board.
  let parts = move.split('-')
  if parts.len != 2:
    raise newException(GauntletError, "not a breakthrough move: " & move)
  (sim.cellIndex(parts[0]), sim.cellIndex(parts[1]))

proc isLegalMove*(sim: Sim, move: string): bool =
  var fromCell, toCell: int
  try:
    (fromCell, toCell) = sim.parseMove(move)
  except CatchableError:
    return false
  if sim.board[fromCell] != seatOccupant(sim.mover):
    return false
  let fromRow = sim.rowOf(fromCell)
  let fromCol = sim.colOf(fromCell)
  let dCol = sim.colOf(toCell) - fromCol
  if sim.rowOf(toCell) != fromRow + forwardOf(sim.mover):
    return false
  if dCol < -1 or dCol > 1:
    return false
  sim.stepLegal(sim.mover, fromRow, fromCol, dCol)

proc applyMove*(sim: var Sim, move: string) =
  let (fromCell, toCell) = sim.parseMove(move)
  let captured = sim.board[toCell] != ocEmpty
  if captured:
    inc sim.captures[sim.mover]
    sim.lastCapture = toCell
    sim.lastKind = mkCapture
  else:
    sim.lastCapture = -1
    sim.lastKind = mkStep
  sim.board[toCell] = seatOccupant(sim.mover)
  sim.board[fromCell] = ocEmpty

proc pieces*(sim: Sim, seat: int): int =
  let me = seatOccupant(seat)
  for cell in sim.board:
    if cell == me:
      inc result

proc advanceOf*(sim: Sim, seat, row: int): int =
  if seat == 0: row else: boardRows(sim) - 1 - row

proc mostAdvanced*(sim: Sim, seat: int): int =
  ## The furthest rank (0-based advance) any of the seat's pieces has
  ## reached; -1 when the seat has no pieces left.
  result = -1
  let me = seatOccupant(seat)
  for row in 0 ..< boardRows(sim):
    for col in 0 ..< boardCols(sim):
      if sim.occ(row, col) == me:
        let advance = sim.advanceOf(seat, row)
        if advance > result:
          result = advance

proc terminal*(sim: Sim, seat: int):
    tuple[won: bool, how: string, path: seq[int]] =
  let cols = boardCols(sim)
  let me = seatOccupant(seat)
  let home = sim.homeRankOf(seat)
  for col in 0 ..< cols:
    if sim.occ(home, col) == me:
      return (true, "home-rank", @[home * cols + col])
  if sim.pieces(1 - seat) == 0:
    return (true, "no-pieces", @[])
  (false, "", @[])

proc hasAnyLegalMove*(sim: Sim): bool =
  let me = seatOccupant(sim.mover)
  for row in 0 ..< boardRows(sim):
    for col in 0 ..< boardCols(sim):
      if sim.occ(row, col) != me:
        continue
      for dCol in moveOffsets():
        if sim.stepLegal(sim.mover, row, col, dCol):
          return true
  false

proc standing*(sim: Sim, seat: int): int =
  var total = 0
  var best = 0
  var count = 0
  let me = seatOccupant(seat)
  for row in 0 ..< boardRows(sim):
    for col in 0 ..< boardCols(sim):
      if sim.occ(row, col) != me:
        continue
      inc count
      let advance = sim.advanceOf(seat, row)
      total += advance
      if advance > best:
        best = advance
  100 * count + 10 * total + 40 * best

proc immediateWinMoves*(sim: Sim): seq[string] =
  ## A move wins now when it lands on the opponent's home rank or removes
  ## the opponent's last piece. Both are decidable without applying it.
  let cols = boardCols(sim)
  let mover = sim.mover
  let goal = sim.homeRankOf(mover)
  let theirPieces = sim.pieces(1 - mover)
  let me = seatOccupant(mover)
  for row in 0 ..< boardRows(sim):
    for col in 0 ..< cols:
      if sim.occ(row, col) != me:
        continue
      for dCol in moveOffsets():
        if not sim.stepLegal(mover, row, col, dCol):
          continue
        let toRow = row + forwardOf(mover)
        let toCol = col + dCol
        let takes = dCol != 0 and sim.occ(toRow, toCol) != ocEmpty
        if toRow == goal or (takes and theirPieces == 1):
          result.add(sim.moveName(row * cols + col, toRow * cols + toCol))

proc hasImmediateWin*(sim: Sim): bool =
  sim.immediateWinMoves().len > 0

proc normalizeMove*(sim: Sim, cleaned, raw: string): string =
  ## `<file><rank><file><rank>`, so "b2-c3", "b2c3", "b2 x c3" and "B2-C3"
  ## all mean the same move. `cleaned` is the alphanumeric-only string;
  ## `raw` is the original, whose alphanumeric RUNS are read first so a
  ## separator letter ("b2 x c3") does not run the two cells together.
  let cols = boardCols(sim)
  let rows = boardRows(sim)
  var runs: seq[string]
  var current = ""
  for ch in raw.toLowerAscii():
    if ch in {'a' .. 'z', '0' .. '9'}:
      current.add(ch)
    elif current.len > 0:
      runs.add(current)
      current = ""
  if current.len > 0:
    runs.add(current)
  var cells: seq[string]
  for run in runs:
    if run.len != 2:
      continue
    let col = ord(run[0]) - ord('a')
    let row = ord(run[1]) - ord('1')
    if col >= 0 and col < cols and row >= 0 and row < rows:
      cells.add(fileLetter(col) & $(row + 1))
  if cells.len == 2:
    return cells[0] & "-" & cells[1]
  if cleaned.len != 4:
    return ""
  proc cell(fileCh, rankCh: char): string =
    let col = ord(fileCh) - ord('a')
    let row = ord(rankCh) - ord('1')
    if col < 0 or col >= cols or row < 0 or row >= rows:
      return ""
    fileLetter(col) & $(row + 1)
  let a = cell(cleaned[0], cleaned[1])
  let b = cell(cleaned[2], cleaned[3])
  if a.len == 0 or b.len == 0:
    return ""
  a & "-" & b
