## Packaging invariants, parsed straight out of the manifest template.
##
## Everything asserted here is something the platform (or the ladder)
## rejects at upload time or silently mis-schedules, and none of it is
## visible to the sim tests.

import std/[json, sequtils, sets, strutils, unittest]
import gauntlet/sim

const
  Seats = 2
  Slug = "board-gauntlet"
  ImagePlaceholder = "{{BOARD_GAUNTLET_IMAGE}}"

let manifest = parseFile("coworld_manifest_template.json")

proc arrayProperties(schema: JsonNode): seq[(string, JsonNode)] =
  ## Every property of a JSON Schema whose type is `array`.
  if not schema.hasKey("properties"):
    return
  for name, property in schema["properties"]:
    if property{"type"}.getStr() == "array":
      result.add((name, property))

# ---- 22. num_agents, everywhere and nowhere else ---------------------------

suite "num_agents":
  test "it is 2 in all five variants and in the certification fixture":
    check manifest["variants"].len == 5
    var ids: seq[string]
    for variant in manifest["variants"]:
      ids.add(variant["id"].getStr())
      ## CoworldVariant is additionalProperties:false and the platform
      ## reads only game_config.num_agents, so a variant-level num_agents
      ## is rejected at upload (cogame-goofspiel-oshi-zumo 0.1.0).
      check not variant.hasKey("num_agents")
      check variant.hasKey("description")
      check variant["description"].getStr().len > 0
      let config = variant["game_config"]
      check config.hasKey("num_agents")
      check config["num_agents"].kind == JInt
      check config["num_agents"].getInt() == Seats
      check config["players"].len == Seats
    check ids == @["gauntlet", "connect-four", "breakthrough-6", "hex-7",
      "quoridor-9"]
    let fixture = manifest["certification"]["game_config"]
    check fixture["num_agents"].getInt() == Seats
    check fixture["players"].len == Seats
    check manifest["certification"]["players"].len == Seats

# ---- 23. tokens, and array bounds ------------------------------------------

suite "schemas":
  test "no game_config carries tokens, but config_schema still requires it":
    var configs = @[manifest["certification"]["game_config"]]
    for variant in manifest["variants"]:
      configs.add(variant["game_config"])
    for config in configs:
      ## matriculate rejects runner-managed tokens in a fixture
      ## (cogame-knights-archers, 2026-08-26).
      check not config.hasKey("tokens")
    let schema = manifest["game"]["config_schema"]
    check "tokens" in schema["required"].getElems().mapIt(it.getStr())
    check "players" in schema["required"].getElems().mapIt(it.getStr())
    check schema["additionalProperties"].getBool() == false

  test "every array property declares minItems and maxItems":
    for name, schema in [("config_schema", manifest["game"]["config_schema"]),
        ("results_schema", manifest["game"]["results_schema"])].items:
      for (property, node) in arrayProperties(schema):
        checkpoint(name & "." & property)
        check node.hasKey("minItems")
        check node.hasKey("maxItems")
        check node["minItems"].getInt() == Seats
        check node["maxItems"].getInt() == Seats
      check schema["additionalProperties"].getBool() == false

  test "results_schema matches what the sim actually writes":
    let schema = manifest["game"]["results_schema"]
    var config = defaultGameConfig()
    config.game = gBreakthrough
    config.size = 6
    config.walls = 0
    config.maxPlies = 80
    config.seed = 23
    config.players = @[PlayerConfig(name: "Sprocket"),
      PlayerConfig(name: "Gizmo")]
    config.tokens = @["t0", "t1"]
    var sim = initSim(sampleEpisode(config))
    sim.endEarly()
    let results = sim.resultsJson()
    var required: HashSet[string]
    for name in schema["required"]:
      required.incl(name.getStr())
    var produced: HashSet[string]
    for key, _ in results:
      produced.incl(key)
    check required == produced
    check results["reason"].getStr() in
      schema["properties"]["reason"]["enum"].getElems().mapIt(it.getStr())
    check results["ending"].getStr() in
      schema["properties"]["ending"]["enum"].getElems().mapIt(it.getStr())
    check "rotate" notin
      schema["properties"]["game"]["enum"].getElems().mapIt(it.getStr())

# ---- 24. The upload contract ------------------------------------------------

suite "upload contract":
  test "protocols and docs are {type,value} objects, not bare strings":
    ## A bare string here is a platform-side validation error the repo CI
    ## does not catch (cogame-garble 0.1.0, 2026-08-24).
    let protocols = manifest["game"]["protocols"]
    for key in ["player", "global"]:
      check protocols.hasKey(key)
      check protocols[key].kind == JObject
      check protocols[key]["type"].getStr() == "text"
      check protocols[key]["value"].getStr().len > 200
    let docs = manifest["game"]["docs"]
    check docs["readme"]["type"].getStr() == "text"
    check docs["readme"]["value"].getStr().len > 200
    check docs["pages"].len >= 1
    for page in docs["pages"]:
      check page.hasKey("id")
      check page.hasKey("title")
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200
    ## The rules page carries all four games and the honest eval-bar note.
    let rules = docs["pages"][0]["content"]["value"].getStr()
    for game in ["connect-four", "breakthrough", "hex", "quoridor"]:
      check game in rules
    check "HEURISTIC" in rules or "heuristic" in rules
    check "RotationOrder" in rules

  test "the game block carries exactly what the upload contract wants":
    let game = manifest["game"]
    check game["name"].getStr() == Slug
    check game["description"].getStr().len > 200
    check not game.hasKey("tags")
    check not game.hasKey("display_name")
    check not game.hasKey("version")
    check not manifest.hasKey("version")
    check manifest["tags"].len >= 3
    check manifest["episode_timeout_minutes"].getInt() == 20
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"
    check game["owner"].getStr() == "daveey@gmail.com"
    check game["runnable"]["type"].getStr() == "game"
    check game["runnable"]["image"].getStr() == ImagePlaceholder
    check game["runnable"]["run"].getElems().mapIt(it.getStr()) ==
      @["/bin/" & Slug]
    ## Without this the secret never resolves and every hosted episode
    ## silently plays scripted (hive, 2026-08-23). The namespace is
    ## game.name.
    let uri = game["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr()
    check uri == "secret://coworld/" & Slug & "/anthropic_api_key"
    check uri.split('/')[3] == game["name"].getStr()

  test "every bundled player is complete and asks for a whole cpu":
    ## The bundled minimum for `cpu` is "1"; 500m is rejected at upload
    ## (cogame-pistonball 0.1.1, 2026-08-26).
    check manifest["player"].len == 2
    for player in manifest["player"]:
      for key in ["id", "type", "name", "description", "image", "run",
          "source_url", "resources"]:
        check player.hasKey(key)
      check player["type"].getStr() == "player"
      check player["image"].getStr() == ImagePlaceholder
      check player["run"].getElems().mapIt(it.getStr()) ==
        @["/bin/" & Slug & "-player"]
      check player["resources"]["limits"]["cpu"].getStr() == "1"
      check player["resources"]["requests"]["cpu"].getStr() == "100m"
      check player["resources"]["requests"]["memory"].getStr() == "64Mi"
    ## One prompt player, one scripted player, both from the same image.
    check not manifest["player"][0].hasKey("env")
    check manifest["player"][1]["env"]["PLAYER_SCRIPTED"].getStr() ==
      "tactician"

# ---- 25. The certification fixture seats every declared player -------------

suite "certification":
  test "every fixture player_id is declared, and every declared id plays":
    var declared: HashSet[string]
    for player in manifest["player"]:
      declared.incl(player["id"].getStr())
    var seated: HashSet[string]
    for slot in manifest["certification"]["players"]:
      let id = slot["player_id"].getStr()
      check id in declared
      seated.incl(id)
    ## A fixture that seats only one declared runnable fails cert
    ## `players_missing` (raid 0.1.2 -> 0.1.3, 2026-08-23).
    check seated == declared

  test "the fixture is the breakthrough-6 variant, pinned and quiet":
    let fixture = manifest["certification"]["game_config"]
    check fixture["game"].getStr() == "breakthrough"
    check fixture["size"].getInt() == 6
    check fixture["seed"].getInt() == 23
    check fixture["turnDelayMs"].getInt() == 0
    check fixture["maxPlies"].getInt() == 80

# ---- The policy set the release workflow uploads ---------------------------

suite "policies":
  test "two prompt champions and two scripted fillers, one image":
    let policies = parseFile("tools/ci/policies.json")
    check policies.len == 4
    var prompts, scripted: seq[string]
    for policy in policies:
      check policy["run"].getStr() == "/bin/" & Slug & "-player"
      check policy["name"].getStr().startsWith(Slug & "-")
      let env = policy["env"]
      if env.hasKey("PLAYER_PROMPT"):
        prompts.add(policy["name"].getStr())
        check env["PLAYER_PROMPT"].getStr().len > 400
        ## Player-side Bedrock is not used: every decision is server-side.
        check not env.hasKey("USE_BEDROCK")
      else:
        scripted.add(policy["name"].getStr())
        check env["PLAYER_SCRIPTED"].getStr() in ["tactician", "hustler"]
    ## A scripted policy seated as a champion is a failure state.
    check prompts.len == 2
    check scripted.len == 2
    check policies[0]["env"]["PLAYER_PROMPT"] !=
      policies[1]["env"]["PLAYER_PROMPT"]
    ## Champion #2 is uploaded while daveey-1 is the active player.
    check not policies[0].hasKey("player")
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check not policies[2].hasKey("player")
    check not policies[3].hasKey("player")
