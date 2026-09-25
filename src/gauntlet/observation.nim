## The public position and one seat's private state for external policies.

import std/json
import llm, sim

proc playerObservation*(sim: Sim, slot: int): JsonNode =
  var board = newJArray()
  for cell in sim.board:
    board.add(%($cell))
  var hWalls = newJArray()
  var vWalls = newJArray()
  for wall in sim.hWalls:
    hWalls.add(%wall)
  for wall in sim.vWalls:
    vWalls.add(%wall)
  var pawns = newJArray()
  if sim.config.game == gQuoridor:
    for cell in sim.pawns:
      pawns.add(%sim.cellName(cell))
  var legal: seq[string]
  if not sim.done and sim.mover == slot:
    legal = sim.legalMoves()
  %*{
    "protocol": "gauntlet.player.v2",
    "slot": slot,
    "name": sim.names[slot],
    "colour": (if slot == 0: "RED" else: "BLUE"),
    "game": $sim.config.game,
    "size": sim.config.size,
    "rotated": sim.config.rotated,
    "ply": sim.ply,
    "maxPlies": sim.config.maxPlies,
    "toMove": not sim.done and sim.mover == slot,
    "board": board,
    "boardText": sim.boardText(),
    "hWalls": hWalls,
    "vWalls": vWalls,
    "pawns": pawns,
    "history": sim.historyText(),
    "rules": rulesText(sim.config.game, sim.config.size),
    "goal": sim.goalText(slot),
    "positionSummary": sim.positionSummary(slot),
    "legalMoves": legal,
    "you": {
      "score": sim.score(slot),
      "standing": sim.standing(slot),
      "captures": sim.captures[slot],
      "wallsLeft": sim.wallsLeft[slot],
      "notes": sim.notes[slot]
    },
    "opponent": {
      "score": sim.score(1 - slot),
      "standing": sim.standing(1 - slot),
      "captures": sim.captures[1 - slot],
      "wallsLeft": sim.wallsLeft[1 - slot]
    },
    "done": sim.done,
    "reason": sim.reason,
    "ending": sim.ending
  }
