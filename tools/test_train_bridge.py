"""Play each certified board through Metta's numeric decision protocol."""

import json
import sys
from pathlib import Path

from metta_training.decision_environment import DecisionEncoding
from metta_training.game import Terminal
from metta_training.session import GameBridge


BRIDGE = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"

cases = [("gauntlet", f"rotation-{index}") for index in range(4)]
cases += [
    (variant, f"test-{variant}")
    for variant in ("connect-four", "breakthrough-6", "hex-7", "quoridor-9")
]
rotated_games = set()
for variant, seed in cases:
    with GameBridge([str(BRIDGE), str(MANIFEST), variant]) as bridge:
        observation = bridge.reset(seed, 2)
        dimensions = None
        decisions = 0
        while not isinstance(observation, Terminal):
            view = observation.semantic_view
            if variant == "gauntlet":
                rotated_games.add(view["game"])
            assert view["legal_moves"]
            encoding = DecisionEncoding.model_validate_json(
                bridge.request({"kind": "encode"})
            )
            assert len(encoding.actions) == 256
            dimensions = dimensions or len(encoding.values)
            assert len(encoding.values) == dimensions
            assert [action["move"] for action in encoding.actions if action] == view[
                "legal_moves"
            ]
            action = json.loads(bridge.teacher())
            assert encoding.action_for(encoding.indices_for(action)) == action
            observation = bridge.step(
                observation.decision_id, json.dumps(action)
            ).observation
            decisions += 1
        assert decisions >= 4
        assert abs(sum(observation.scores.values())) < 1e-6
        print(variant, decisions, dimensions, observation.scores)
assert rotated_games == {"connect-four", "breakthrough", "hex", "quoridor"}
