# Private language training

The ordinary hosted game owns language requests, prompt construction, reply
normalization, and action application. Training uses that exact path.
The native Messages endpoint is `COWORLD_LLM_ENDPOINT`; set
`COWORLD_LLM_MODEL` to a registered `checkpoint/<artifact-sha256>` identity.
`COWORLD_LLM_TEMPERATURE` explicitly selects temperature from 0 through 1;
when absent, the provider default remains unchanged. Saved players and the
verified learner gateway must use the same sampling policy and token budgets.
A player cannot choose its own checkpoint URL or serving identity.

To capture private hosted evidence, supply `COboard-gauntlet_SAVE_TRAJECTORY_URI`,
`COWORLD_EPISODE_ID`, `COWORLD_board-gauntlet_VERSION`, and `COWORLD_SOURCE_REVISION`.
The game records every native attempt, retry, platform call ID, and actual
executed action. Missing credentials or invalid replies produce consumed
fallbacks, which are excluded from model learning targets. Terminal outcomes
and all seats remain in the private episode. Public replay contains no new
training prompts or native responses. Private corpora are excluded from image
build contexts and must never be published as replay artifacts.

After syncing `nimby.lock`, commit the qualified source and run:

```sh
nim c --path:src --out:/tmp/export-posttrain tools/export_posttrain.nim
/tmp/export-posttrain /tmp/board-gauntlet-private-corpus 20
python3 tests/test_training_corpus.py /tmp/board-gauntlet-private-corpus
```

The definitive format is `coworld-private-complete-episodes-v1`: one complete
episode per file under `train/` or `validation/`, plus `manifest.json`.
Directories are private and episode files are created exclusively with mode
0600. Existing outputs are never overwritten. The manifest records exact
source revision, seed, outcome, target policy, and selected decision IDs.
Opponent decisions and all attempts remain available as evidence; they are
not implicitly teacher labels.

From the shared Metta checkout, import complete episodes with an explicit
policy selection using `metta-posttrain export-hosted SOURCE OUTPUT
--policy scripted-tactician`. Use `coworld training qualify EVENTS --transport local
--policy scripted-tactician` to qualify raw hosted event streams before training.
This corpus supports supervised fine-tuning of the named teacher. It does
not establish checkpoint game strength or reinforcement learning readiness.
Reinforcement learning also requires real sampled token IDs and draw-time
behavior log probabilities from the owned serving engine. Greedy responses
and teacher labels do not supply those probabilities.

Consecutive seeds rotate Connect Four, Breakthrough, Hex, and Quoridor.
The tactician seat alternates by seed; the hustler is the opponent. Seeded
random opening plies remain in the episode and are excluded from targets.
At least 20 episodes cover every board in both whole-episode splits.
The numeric bridge is a separate research interface, not this hosted path.
