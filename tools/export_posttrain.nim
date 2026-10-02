## Export authoritative private complete episodes, with full control provenance.
import std/[json, os, osproc, random, strutils]
import bitworld/decision_trajectory
import gauntlet/[sim, llm, training]

const OperatorPrompt = "Play to win. Copy one legal move exactly."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 3:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len == 3: parseInt(args[2]) else: 0
  doAssert episodes >= 20 and firstSeed >= 0
  doAssert not dirExists(output) and not fileExists(output)
  doAssert execProcess("git status --porcelain").strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.seed = seed
    let tacticianSeat = seed mod 2
    config.players = @[PlayerConfig(name: "teacher0"), PlayerConfig(name: "teacher1")]
    config.tokens = @["training-seat-0", "training-seat-1"]
    config = sampleEpisode(config)
    var sim = initSim(config)
    let openingPlies = seed mod 6
    var rng = initRand(int64(seed) * 1009 + 7)
    let episodeId = "board-gauntlet-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, episodeId,
      "board-gauntlet", "source-" & sourceRevision, sourceRevision)
    var selectedDecisionIds: seq[string]
    while not sim.done:
      let before = sim
      let baseline = if sim.mover == tacticianSeat: blTactician else: blHustler
      var decision: Decision
      var policy: string
      if sim.plies < openingPlies:
        let legal = sim.legalMoves()
        decision.move = legal[rng.rand(legal.high)]
        policy = "seeded-random-opening"
      else:
        decision.move = scriptedMove(sim, baseline)
        decision.scripted = true
        policy = "scripted-" & $baseline
        if sim.mover == tacticianSeat:
          selectedDecisionIds.add("gauntlet-" & $sim.plies)
      # Validate the exact ordinary client payload before applying it.
      let parsed = sim.parseReply(decision.decisionAction())
      doAssert parsed.move == decision.move
      sim.applyMove(parsed.move, parsed.say, parsed.notes, decision.scripted, false)
      trajectory.recordAppliedDecision(before, decision, decision,
        OperatorPrompt, policy, sim.done)
    let results = sim.resultsJson()
    doAssert results["reason"].getStr() == "complete"
    var participants = newJObject()
    for seat in 0 ..< results["scores"].len:
      participants[$seat] = %*{"score": results["scores"][seat]}
    trajectory.finish(esCompleted, results, participants)
    let split = if seed mod 5 == 0: "validation" else: "train"
    trajectory.writeCompleteEpisode(output / split / (episodeId & ".jsonl"))
    runs.add(%*{"seed": seed, "split": split, "game": $sim.config.game,
      "teacher_seat": tacticianSeat, "opening_plies": openingPlies,
      "decisions": sim.plies, "selected_decision_ids": selectedDecisionIds, "results": results})
  writeFile(output / "manifest.json", pretty(%*{"schema_version": "1",
    "format": "coworld-private-complete-episodes-v1", "game": "board-gauntlet",
    "source_revision": sourceRevision, "teacher_policy": "scripted-tactician",
    "opponent_policy": "scripted-hustler", "operator_prompt": OperatorPrompt,
    "runs": runs}) & "\n")
  echo "complete episodes=", episodes
