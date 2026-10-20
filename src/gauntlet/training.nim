## Authoritative private language decisions; spectator replay stays separate.
import std/[json, options]
import bitworld/decision_trajectory
import llm, observation, sim, prompts

proc decisionAction*(decision: Decision): JsonNode =
  %*{"move": decision.move, "say": decision.say, "notes": decision.notes}

proc recordAppliedDecision*(trajectory: DecisionTrajectory, before: Sim,
    proposed, applied: Decision, operatorPrompt, policy: string, terminal: bool, selection: PromptSelection) =
  let seat = before.mover
  let actualAction = applied.decisionAction()
  var attempts = proposed.nativeAttempts
  var selected = none(string)
  if not applied.fellBack and attempts.len == 0:
    let origin = if applied.scripted: aoTeacher else: aoUnknown
    var evidence = newDecisionAttempt("ply-" & $before.plies & "-applied", policy, origin)
    evidence.prompt = %*[{"role": "system", "content": before.systemPrompt(seat, selection)},
      {"role": "user", "content": before.userPrompt(seat, operatorPrompt)}]
    evidence.response = %($actualAction)
    evidence.parsedAction = actualAction
    evidence.accepted = true
    attempts.add(evidence)
  for index in 0 ..< attempts.len:
    if applied.fellBack and attempts[index].accepted:
      attempts[index].accepted = false
      attempts[index].rejectionReason = some("Authoritative engine rejected the proposed move")
    elif attempts[index].accepted:
      selected = some(attempts[index].attemptId)
  let view = before.playerObservation(seat)
  view["prompt_template"] = selection.promptMetadata(before.systemPrompt(seat, selection),
    before.userPrompt(seat, operatorPrompt))
  var promptAttempts = newJArray()
  for attempt in attempts:
    promptAttempts.add(%*{"attempt_id": attempt.attemptId,
      "prompt_template": selection.promptMetadata(attempt.prompt[0]["content"].getStr(),
        attempt.prompt[1]["content"].getStr())})
  view["prompt_attempts"] = promptAttempts
  trajectory.recordDecision("gauntlet-" & $before.plies, $seat,
    view, attempts, selected, actualAction,
    if applied.fellBack: asFallback else: asAccepted, terminal = terminal,
    fallbackOrigin = if applied.fellBack: some("scripted-tactician") else: none(string))
