## Actual native client, parser normalization, and authoritative apply probe.
import std/[json, options, os]
import bitworld/decision_trajectory
import gauntlet/[prompts, llm, sim, training]

putEnv("COWORLD_LLM_ENDPOINT", paramStr(1))
putEnv("COWORLD_LLM_MODEL", "checkpoint/native-fixture")
putEnv("COWORLD_LLM_TEMPERATURE", "0")
var config = defaultGameConfig()
config.game = gConnectFour
config.size = 7
config.sampled = true
config.players = @[PlayerConfig(name: "a"), PlayerConfig(name: "b")]
config.tokens = @["a", "b"]
var game = initSim(config)
let before = game
let selection = PromptSelection(variant: pvMixed, seed: 4)
let decision = newLlmClient(config).decide(game, "Exact private operator prompt", "", selection)
doAssert decision.nativeAttempts.len == 2
doAssert not decision.nativeAttempts[0].accepted
if paramStr(2) == "retry":
  doAssert not decision.fellBack
  doAssert decision.nativeAttempts[1].accepted
  doAssert decision.move == "a"
else:
  doAssert decision.fellBack
  doAssert not decision.nativeAttempts[1].accepted
for attempt in decision.nativeAttempts:
  doAssert attempt.platformCallId.isSome
  doAssert attempt.rawResponse.kind == JObject
  doAssert attempt.request["temperature"].getFloat() == 0
  doAssert attempt.latencyMs.isSome
  doAssert attempt.inputTokens.get() == 3
  doAssert attempt.outputTokens.get() == 2
game.applyMove(decision.move, decision.say, decision.notes, decision.scripted, decision.fellBack)
let trajectory = newDecisionTrajectory("probe", "probe", "board-gauntlet", "fixture", "fixture-source")
trajectory.recordAppliedDecision(before, decision, decision,
  "Exact private operator prompt", "native-fixture", game.done, selection)
trajectory.finish(esTruncated, game.resultsJson(), %*{})
echo trajectory.eventsJsonl()

if paramCount() >= 3:
  let output = paramStr(3)
  let complete = newDecisionTrajectory("probe", "gauntlet-" & $config.seed,
    "board-gauntlet", "fixture", "fixture-source")
  complete.recordAppliedDecision(before, decision, decision,
    "Exact private operator prompt", "native-fixture", game.done, selection)
  while not game.done:
    let previous = game
    let next = Decision(move: tacticianMove(game), scripted: true)
    game.applyMove(next.move, next.say, next.notes, next.scripted, next.fellBack)
    complete.recordAppliedDecision(previous, next, next,
      "Exact private operator prompt", "scripted-tactician", game.done, selection)
  complete.finish(esCompleted, game.resultsJson(), %*{})
  writeFile(output / "trajectory.jsonl", complete.eventsJsonl())
  var events = newJArray()
  for event in game.events: events.add(event.publicEventJson())
  let resolved = game.config
  writeFile(output / "replay.json", $(%*{
    "protocol": "gauntlet.replay.v1",
    "names": game.names,
    "policyNames": ["fixture-0", "fixture-1"],
    "config": {"game": $resolved.game, "rotated": resolved.rotated,
      "size": resolved.size, "walls": resolved.walls, "first": resolved.first,
      "seed": resolved.seed, "maxPlies": resolved.maxPlies, "sampled": true},
    "events": events, "results": game.resultsJson()}))
