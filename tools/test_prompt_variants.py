"""Play complete board games through the public text and numeric protocols."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

BINARY = str(Path(sys.argv[1]).resolve())
MANIFEST = str(Path(__file__).resolve().parents[1] / "coworld_manifest_template.json")
VARIANTS = [
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
]
CASES = [
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
            ("mixed", 4),
        ]:
            observation = request(
                process,
                {
                    "kind": "reset",
                    "players": 2,
                    "seed": seed,
                    "promptVariant": choice,
                    "promptSeed": prompt_seed,
                    "split": "validation",
                },
            )
            transcript, systems = [], {}
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
                ) == ("board-gauntlet-rules-v2", selected, choice, prompt_seed)
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
            outcome = transcript, observation
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
            assert len({systems[seat] for systems in direct}) == 7
        process.stdin.close()
        assert process.wait(timeout=5) == 0
    print(board, seed, "8 complete text games PASS", flush=True)

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

print(json.dumps({"complete_text_games": completed}))
