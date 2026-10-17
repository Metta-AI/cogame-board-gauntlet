"""Play complete board games through the public text and numeric protocols."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

BINARY = str(Path(sys.argv[1]).resolve())
MANIFEST = str(Path(__file__).resolve().parents[1] / "coworld_manifest_template.json")
VARIANTS = ["canonical", "plain", "numbered", "questions", "reordered"]
CASES = [("gauntlet", f"rotation-{index}") for index in range(4)] + [
    (board, f"test-{board}")
    for board in ("connect-four", "breakthrough-6", "hex-7", "quoridor-9")
]


def request(process, command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


completed = 0
for board, seed in CASES:
    canonical = None
    direct = []
    with subprocess.Popen(
        [BINARY, MANIFEST, board, "--language"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        for choice, prompt_seed in [
            *((v, 0) for v in VARIANTS),
            *(("mixed", i) for i in range(5)),
        ]:
            observation = request(
                process,
                {
                    "kind": "reset",
                    "players": 2,
                    "seed": seed,
                    "promptVariant": choice,
                    "promptSeed": prompt_seed,
                },
            )
            transcript, systems, rules = [], {}, {}
            while observation["kind"] == "decision":
                seat = observation["seat"]
                view = observation["semantic_view"]
                metadata = view.pop("prompt_template")
                selected = VARIANTS[prompt_seed] if choice == "mixed" else choice
                assert (
                    metadata["bank"],
                    metadata["variant"],
                    metadata["selection"],
                    metadata["seed"],
                ) == ("board-gauntlet-rules-v1", selected, choice, prompt_seed)
                system, user = observation["messages"]
                assert system["role"] == "system" and user["role"] == "user"
                for message in observation["messages"]:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                if seat in systems:
                    assert systems[seat] == system["content"]
                systems[seat] = system["content"]
                rules[seat] = system["content"].split("RULES\n", 1)[1]
                assert "prompt_template" not in user["content"]
                assert f"PRIVATE-{1 - seat}" not in user["content"]
                if len(transcript) >= 2:
                    assert f"PRIVATE-{seat}" in user["content"]
                action = json.loads(request(process, {"kind": "teacher"})["response"])
                assert action["move"] in view["legal_moves"]
                action["notes"] = f"PRIVATE-{seat}"
                result = request(
                    process,
                    {
                        "kind": "step",
                        "decision_id": observation["decision_id"],
                        "response": json.dumps(action),
                    },
                )
                assert result["kind"] == "accepted" and result["action"] == action
                transcript.append((view, user, action))
                observation = result["observation"]
                assert len(transcript) <= view["max_plies"]
            assert observation["kind"] == "terminal" and len(transcript) >= 4
            assert sum(observation["scores"].values()) == 0
            assert set(systems) == {0, 1}
            outcome = transcript, rules, observation
            if choice == "canonical":
                canonical = outcome
            else:
                assert outcome == canonical, (
                    "Wording changed rules, private views, legal moves, actions, or scores"
                )
            if choice == "mixed":
                assert systems == direct[prompt_seed]
            else:
                direct.append(systems)
            completed += 1
        for seat in (0, 1):
            assert len({systems[seat] for systems in direct}) == 5
        process.stdin.close()
        assert process.wait(timeout=5) == 0
    print(board, seed, "10 complete text games PASS", flush=True)

for invalid in (
    {"promptVariant": "heldout-briefing"},
    {"promptVariant": "heldout-reference"},
    {"promptVariant": "mixed"},
    {"promptVariant": "unknown"},
    {"promptVariant": 1},
    {"promptVariant": "mixed", "promptSeed": -1},
    {"promptVariant": "mixed", "promptSeed": True},
    {"promptVariant": "mixed", "promptSeed": 1.5},
):
    result = subprocess.run(
        [BINARY, MANIFEST, "gauntlet", "--language"],
        text=True,
        capture_output=True,
        timeout=10,
        input=json.dumps({"kind": "reset", "seed": "17", "players": 2} | invalid)
        + "\n",
    )
    assert result.returncode != 0 and not result.stdout

comparisons = 0
if len(sys.argv) == 3:
    for board, seed in CASES:
        processes = [
            subprocess.Popen(
                [str(Path(program).resolve()), MANIFEST, board],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            for program in (sys.argv[2], BINARY)
        ]
        try:
            observations = [
                request(p, {"kind": "reset", "seed": seed, "players": 2})
                for p in processes
            ]
            while observations[0]["kind"] == "decision":
                assert observations[0] == observations[1]
                encodings = [request(p, {"kind": "encode"}) for p in processes]
                assert (
                    encodings[0] == encodings[1] and len(encodings[0]["actions"]) == 256
                )
                actions = [
                    request(p, {"kind": "teacher"})["response"] for p in processes
                ]
                assert actions[0] == actions[1]
                results = [
                    request(
                        p,
                        {
                            "kind": "step",
                            "decision_id": obs["decision_id"],
                            "response": action,
                        },
                    )
                    for p, obs, action in zip(
                        processes, observations, actions, strict=True
                    )
                ]
                assert results[0] == results[1]
                observations = [r["observation"] for r in results]
            assert observations[0] == observations[1]
            comparisons += 1
        finally:
            for process in processes:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
print(
    json.dumps(
        {"complete_text_games": completed, "original_numeric_comparisons": comparisons}
    )
)
