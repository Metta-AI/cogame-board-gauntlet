## Export complete scripted games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED]

import std/[json, os, osproc, random, strutils]
import gauntlet/[sim, llm]

const OperatorPrompt = "Play to win. Copy one legal move exactly."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 3:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len == 3: parseInt(args[2]) else: 0
  if episodes < 20:
    quit("at least 20 episodes cover each board in both splits", 1)
  if firstSeed < 0:
    quit("first seed must be nonnegative", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.seed = seed
    let tacticianSeat = seed mod 2
    config.players = @[
      PlayerConfig(name: if tacticianSeat == 0: "tactician" else: "hustler"),
      PlayerConfig(name: if tacticianSeat == 1: "tactician" else: "hustler")
    ]
    config.tokens = @["training-seat-0", "training-seat-1"]
    config = sampleEpisode(config)
    var sim = initSim(config)
    let openingPlies = seed mod 6
    var rng = initRand(int64(seed) * 1009 + 7)
    var count = 0
    while not sim.done:
      let mover = sim.mover
      let baseline = if mover == tacticianSeat: blTactician else: blHustler
      var move: string
      if sim.plies < openingPlies:
        let legal = sim.legalMoves()
        move = legal[rng.rand(legal.high)]
      else:
        move = scriptedMove(sim, baseline)
        if mover == tacticianSeat:
          let row = %*{
            "episode_id": "board-gauntlet-" & $seed,
            "seed": "board-gauntlet-" & $seed,
            "decision_id": sim.plies,
            "prompt": [
              {"role": "system", "content": sim.systemPrompt(mover)},
              {"role": "user", "content": sim.userPrompt(mover, OperatorPrompt)}
            ],
            "completion": [{"role": "assistant", "content": $(%*{
              "move": move, "say": "", "notes": ""
            })}],
            "game": "board-gauntlet",
            "action_schema_revision": "gauntlet-move-v1"
          }
          if seed mod 5 == 0:
            validationRows.add($row)
          else:
            trainRows.add($row)
          inc count
      sim.applyMove(move, "", "", true, false)
    let results = sim.resultsJson()
    doAssert results["reason"].getStr() == "complete"
    runs.add(%*{
      "seed": seed,
      "game": $sim.config.game,
      "tactician_seat": tacticianSeat,
      "opening_plies": openingPlies,
      "examples": count,
      "results": results
    })
  if trainRows.len == 0 or validationRows.len == 0:
    quit("both splits need labelled decisions", 1)
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  let manifest = %*{
    "schema_version": 1,
    "game": "board-gauntlet",
    "source_revision": sourceRevision,
    "teacher": "tactician",
    "opponent": "hustler",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }
  writeFile(output / "manifest.json", pretty(manifest) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
