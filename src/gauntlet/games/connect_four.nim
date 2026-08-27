## Connect Four (7 files x 6 ranks by default), rules only.
##
## Seat 0 plays red discs, seat 1 blue. A move is a file letter; the disc
## falls to the lowest empty cell of that file. Four of your own discs in
## a row, in any of the four directions, wins on the spot; a full board
## with no line is a draw.

import std/strutils, ../types

const
  ## Window weights by the mover's disc count in a four-cell window that
  ## holds no opponent disc.
  WindowWeight = [0, 1, 4, 16, 10_000]

proc startBoard*(sim: var Sim) =
  sim.board = newSeq[Occupant](cellCount(sim.config))

proc columnOrder*(cols: int): seq[int] =
  ## Canonical file order: distance from the centre file, left before
  ## right. On a 7-wide board that is d, c, e, b, f, a, g.
  let centre = (cols - 1) div 2
  result.add(centre)
  var offset = 1
  while result.len < cols:
    if centre - offset >= 0:
      result.add(centre - offset)
    if centre + offset < cols:
      result.add(centre + offset)
    inc offset

proc dropRow*(sim: Sim, col: int): int =
  ## The lowest empty rank of `col`, or -1 when the file is full.
  for row in 0 ..< boardRows(sim):
    if sim.occ(row, col) == ocEmpty:
      return row
  -1

proc legalMoves*(sim: Sim): seq[string] =
  for col in columnOrder(boardCols(sim)):
    if sim.dropRow(col) >= 0:
      result.add(fileLetter(col))

proc isLegalMove*(sim: Sim, move: string): bool =
  if move.len != 1:
    return false
  let col = ord(move[0]) - ord('a')
  col >= 0 and col < boardCols(sim) and sim.dropRow(col) >= 0

proc applyMove*(sim: var Sim, move: string) =
  let col = ord(move[0]) - ord('a')
  let row = sim.dropRow(col)
  sim.board[row * boardCols(sim) + col] = seatOccupant(sim.mover)
  sim.lastKind = mkDrop
  sim.lastCapture = -1

iterator windows*(cols, rows: int): array[4, int] =
  ## Every four-cell line on the board: horizontal, vertical, and both
  ## diagonals. On a 7x6 board there are exactly 69 of them.
  for row in 0 ..< rows:
    for col in 0 .. cols - 4:
      yield [row * cols + col, row * cols + col + 1,
             row * cols + col + 2, row * cols + col + 3]
  for col in 0 ..< cols:
    for row in 0 .. rows - 4:
      yield [row * cols + col, (row + 1) * cols + col,
             (row + 2) * cols + col, (row + 3) * cols + col]
  for row in 0 .. rows - 4:
    for col in 0 .. cols - 4:
      yield [row * cols + col, (row + 1) * cols + col + 1,
             (row + 2) * cols + col + 2, (row + 3) * cols + col + 3]
  for row in 0 .. rows - 4:
    for col in 3 ..< cols:
      yield [row * cols + col, (row + 1) * cols + col - 1,
             (row + 2) * cols + col - 2, (row + 3) * cols + col - 3]

proc lineIn(board: seq[Occupant], cols, rows: int, me: Occupant): seq[int] =
  for window in windows(cols, rows):
    var owned = 0
    for cell in window:
      if board[cell] == me:
        inc owned
    if owned == 4:
      return @window
  @[]

proc terminal*(sim: Sim, seat: int):
    tuple[won: bool, how: string, path: seq[int]] =
  let path = lineIn(sim.board, boardCols(sim), boardRows(sim),
    seatOccupant(seat))
  if path.len == 4:
    (true, "line", path)
  else:
    (false, "", @[])

proc boardFull*(sim: Sim): bool =
  for cell in sim.board:
    if cell == ocEmpty:
      return false
  true

proc hasAnyLegalMove*(sim: Sim): bool =
  not sim.boardFull()

proc standing*(sim: Sim, seat: int): int =
  ## Sum the window weight of every four-cell window that holds no
  ## opponent disc; a window with both colours in it is dead and scores 0.
  let me = seatOccupant(seat)
  let them = seatOccupant(1 - seat)
  for window in windows(boardCols(sim), boardRows(sim)):
    var owned = 0
    var blocked = false
    for cell in window:
      if sim.board[cell] == them:
        blocked = true
        break
      elif sim.board[cell] == me:
        inc owned
    if not blocked:
      result += WindowWeight[owned]

proc openThrees*(sim: Sim, seat: int): int =
  ## Windows holding exactly three of the seat's discs and no opponent
  ## disc — the scorebug readout.
  let me = seatOccupant(seat)
  let them = seatOccupant(1 - seat)
  for window in windows(boardCols(sim), boardRows(sim)):
    var owned = 0
    var blocked = false
    for cell in window:
      if sim.board[cell] == them:
        blocked = true
        break
      elif sim.board[cell] == me:
        inc owned
    if not blocked and owned == 3:
      inc result

proc immediateWinMoves*(sim: Sim): seq[string] =
  ## Every drop that completes a line for the seat to move, in canonical
  ## order. Cheap: one board copy, seven probes.
  let cols = boardCols(sim)
  let rows = boardRows(sim)
  let me = seatOccupant(sim.mover)
  var board = sim.board
  for col in columnOrder(cols):
    let row = sim.dropRow(col)
    if row < 0:
      continue
    board[row * cols + col] = me
    if lineIn(board, cols, rows, me).len == 4:
      result.add(fileLetter(col))
    board[row * cols + col] = ocEmpty

proc hasImmediateWin*(sim: Sim): bool =
  sim.immediateWinMoves().len > 0

proc normalizeMove*(sim: Sim, cleaned, raw: string): string =
  ## `cleaned` is the lower-cased alphanumeric-only string; `raw` is the
  ## original, used to find a standalone one-character token so that
  ## "column d - centre" reads as `d` rather than as the `c` of "column".
  let cols = boardCols(sim)
  proc asFile(text: string): string =
    if text.len != 1:
      return ""
    let ch = text[0]
    if ch >= 'a' and ord(ch) - ord('a') < cols:
      return $ch
    if ch >= '1' and ord(ch) - ord('1') < cols:
      return fileLetter(ord(ch) - ord('1'))
    ""
  ## Every byte outside a-z0-9 becomes a space, so multi-byte punctuation
  ## (an em dash) separates tokens instead of joining them.
  var flat = newStringOfCap(raw.len)
  for ch in raw.toLowerAscii():
    if ch in {'a' .. 'z', '0' .. '9'}: flat.add(ch)
    else: flat.add(' ')
  for part in flat.splitWhitespace():
    let candidate = asFile(part)
    if candidate.len > 0:
      return candidate
  if cleaned.len == 0:
    return ""
  asFile($cleaned[0])
