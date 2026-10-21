## Verify native captures against the source-owned seeded replay engine.
import std/[json, os, strutils]
import gauntlet/[sim, llm, server, observation, prompts]

let args = commandLineParams()
if args.len != 4: quit("usage: verify_native REPLAY TRAJECTORY EPISODE_ID SOURCE_REVISION", 1)
let replay = parseFile(args[0])
var captures: seq[JsonNode]
for line in readFile(args[1]).strip().splitLines(): captures.add(parseJson(line))
let summary = captures[^1]
doAssert summary["event_type"].getStr() == "episode"
doAssert summary["episode_id"].getStr() == args[2]
doAssert summary["source_revision"].getStr() == args[3]
let outcome = copy(summary["outcome"])
doAssert outcome == replay["results"]
let config = configFromReplay(replay)
doAssert summary["seed_family"].getStr() == "gauntlet-" & $config.seed
var events: seq[GameEvent]
for event in replay["events"]: events.add(eventFromJson(event))
let frames = replayMatch(config, events)
let fullSchedule = frames[^1].done and frames[^1].reason == "complete"
doAssert frames[^1].resultsJson()["scores"] == replay["results"]["scores"]
doAssert (summary["status"].getStr() == "completed") == fullSchedule
var index = 0
for eventIndex, event in events:
  if event.kind == evMove:
    let seat = event.seat
    let capture = captures[index]
    doAssert capture["event_type"].getStr() == "decision"
    doAssert capture["episode_id"].getStr() == args[2]
    doAssert capture["source_revision"].getStr() == args[3]
    doAssert capture["decision_index"].getInt() == index
    doAssert capture["decision_id"].getStr() == "gauntlet-" & $frames[eventIndex].plies
    doAssert capture["seat"].getStr() == $seat
    let action = %*{"move": event.move, "say": event.say, "notes": event.notes}
    doAssert capture["executed_action"] == action
    let observation = copy(capture["observation"])
    let operatorPrompt = observation["operator_prompt"].getStr()
    let metadata = observation["prompt_template"]
    doAssert metadata["selection"] == captures[0]["observation"]["prompt_template"]["selection"]
    doAssert metadata["seed"] == captures[0]["observation"]["prompt_template"]["seed"]
    let selection = promptSelection(%*{"promptVariant": metadata["selection"], "promptSeed": metadata["seed"]})
    observation.delete("operator_prompt")
    observation.delete("prompt_template")
    observation.delete("prompt_attempts")
    doAssert observation == frames[eventIndex].playerObservation(seat)
    let system = systemPrompt(frames[eventIndex], seat, selection)
    let user = userPrompt(frames[eventIndex], seat, operatorPrompt)
    doAssert metadata == selection.promptMetadata(system, user)
    var expectedMetadata = newJArray()
    var selectedFound = false
    for attemptIndex, attempt in capture["attempts"].getElems():
      expectedMetadata.add(%*{"attempt_id": attempt["attempt_id"],
        "prompt_template": selection.promptMetadata(attempt["prompt"][0]["content"].getStr(),
          attempt["prompt"][1]["content"].getStr())})
      if attempt["attempt_id"] == capture["selected_attempt_id"]:
        doAssert attempt["accepted"].getBool()
        selectedFound = true
      if attempt["origin"].getStr() == "model":
        doAssert attempt["prompt"][0]["content"].getStr() == system
        var expectedUser = user
        if attemptIndex > 0:
          expectedUser.add("\n\nYour previous reply was invalid. Respond with ONLY " &
            "the requested JSON object; `move` must be exactly one of the " &
            "strings in this list: " & frames[eventIndex].legalMoves().join(" "))
        doAssert attempt["prompt"][1]["content"].getStr() == expectedUser
        doAssert attempt["request"]["system"].getStr() == system
        doAssert attempt["request"]["messages"][0]["content"] == attempt["prompt"][1]["content"]
      if attempt["attempt_id"] == capture["selected_attempt_id"] and attempt["origin"].getStr() in ["model", "teacher"]:
        let parsed = parseReply(frames[eventIndex], extractJsonObject(attempt["response"].getStr()))
        let normalized = %*{"move": parsed.move, "say": parsed.say, "notes": parsed.notes}
        doAssert normalized == action
    doAssert capture["observation"]["prompt_attempts"] == expectedMetadata
    doAssert selectedFound == (capture["action_status"].getStr() == "accepted")
    inc index
doAssert index == captures.len - 1
echo $(%*{"seed": config.seed, "scores": replay["results"]["scores"],
  "full_schedule": fullSchedule, "decisions": index, "policy_names": replay["policyNames"]})
