## Persistent JSONL bridge for Metta RL and native PufferLib training.
## nim c -d:release --path:src -o:board-gauntlet-train-bridge tools/train_bridge.nim

import std/[json, os, strutils]
import gauntlet/[sim, llm]

const OperatorPrompt = "Play to win. Copy one legal move exactly."
const ActionSlots = 256
const WallSlots = (MaxSide - 1) * (MaxSide - 1)

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(game: Sim, id: int): JsonNode =
  var board = newJArray()
  for occupant in game.board:
    board.add(%($occupant))
  var hWalls = newJArray()
  var vWalls = newJArray()
  for wall in game.hWalls:
    hWalls.add(%wall)
  for wall in game.vWalls:
    vWalls.add(%wall)
  let legal = game.legalMoves()
  %*{
    "kind": "decision", "game": "board-gauntlet", "decision_id": id,
    "seat": game.mover, "engine_seat": game.mover, "turn": game.plies,
    "semantic_view": {
      "game": $game.config.game, "size": game.config.size,
      "board": board, "horizontal_walls": hWalls,
      "vertical_walls": vWalls, "pawns": game.pawns,
      "walls_left": game.wallsLeft, "mover": game.mover,
      "plies": game.plies, "max_plies": game.config.maxPlies,
      "last_move": game.lastMove, "legal_moves": legal
    },
    "inbox": [],
    "messages": [
      {"role": "system", "content": game.systemPrompt(game.mover)},
      {"role": "user", "content": game.userPrompt(game.mover, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["move"],
      "properties": {"move": {"type": "string", "enum": legal}}},
    "typed_question": newJNull()
  }

proc moveFeatures(game: Sim, move: string): array[6, int] =
  ## A legal move's geometry accompanies its changing catalog index.
  let parts = move.split('-')
  if parts.len == 2:
    let fromCell = game.cellIndex(parts[0])
    let toCell = game.cellIndex(parts[1])
    return [1, game.rowOf(fromCell), game.colOf(fromCell),
      game.rowOf(toCell), game.colOf(toCell), 0]
  if move.len == 1:
    return [2, 0, 0, 0, ord(move[0]) - ord('a'), 0]
  if move[^1] in {'h', 'v'}:
    let anchor = game.cellIndex(move[0 .. ^2])
    return [3, 0, 0, game.rowOf(anchor), game.colOf(anchor),
      if move[^1] == 'h': 1 else: 2]
  let cell = game.cellIndex(move)
  [4, 0, 0, game.rowOf(cell), game.colOf(cell), 0]

proc encoding(game: Sim, id: int): JsonNode =
  var values = newJArray()
  for kind in [gConnectFour, gBreakthrough, gHex, gQuoridor]:
    values.add(%(if game.config.game == kind: 1 else: 0))
  values.add(%game.mover)
  values.add(%game.config.size)
  values.add(%game.plies)
  values.add(%game.config.maxPlies)
  for seat in 0 .. 1:
    values.add(%game.pawns[seat])
    values.add(%game.wallsLeft[seat])
    values.add(%game.captures[seat])
  for index in 0 ..< MaxCells:
    let occupant = if index < game.board.len: game.board[index] else: ocEmpty
    values.add(%(if occupant == ocSeat0: 1 elif occupant == ocSeat1: -1 else: 0))
  for index in 0 ..< WallSlots:
    values.add(%(if index < game.hWalls.len and game.hWalls[index]: 1 else: 0))
    values.add(%(if index < game.vWalls.len and game.vWalls[index]: 1 else: 0))
  let legal = game.legalMoves()
  doAssert legal.len > 0 and legal.len <= ActionSlots
  var actions = newJArray()
  for index in 0 ..< ActionSlots:
    if index < legal.len:
      actions.add(%*{"move": legal[index]})
      for value in game.moveFeatures(legal[index]):
        values.add(%value)
    else:
      actions.add(newJNull())
      for field in 0 ..< 6:
        values.add(%0)
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: board-gauntlet-train-bridge MANIFEST [variant]", 1)
  let variant = if args.len == 2: args[1] else: "gauntlet"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 2
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      runtimeConfig["turnDelayMs"] = %0
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      game = initSim(config)
      id = 0
      response = game.decision(id)
    of "encode":
      doAssert not game.done
      response = game.encoding(id)
    of "teacher":
      doAssert not game.done
      let baseline = if game.mover == game.config.seed mod 2:
        blTactician else: blHustler
      response = %*{"response": $(%*{"move": scriptedMove(game, baseline)})}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let move = action["move"].getStr()
      game.applyMove(move, "", "", true, false)
      inc id
      var observation: JsonNode
      if game.done:
        observation = %*{"kind": "terminal", "scores": {
          "0": game.score(0), "1": game.score(1)}}
      else:
        observation = game.decision(id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
