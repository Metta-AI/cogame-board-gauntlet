## Actual native client, parser normalization, and authoritative apply probe.
import std/[json, options, os]
import bitworld/decision_trajectory
import gauntlet/[llm, sim, training]

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
let decision = newLlmClient(config).decide(game, "Exact private operator prompt", "")
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
  "Exact private operator prompt", "native-fixture", game.done)
trajectory.finish(esTruncated, game.resultsJson(), %*{})
echo trajectory.eventsJsonl()
