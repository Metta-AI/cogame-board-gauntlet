# Private language training

The ordinary hosted game owns language requests, prompt construction, reply
normalization, and action application. Training uses that exact path.
The native Messages endpoint is `COWORLD_LLM_ENDPOINT`; set
`COWORLD_LLM_MODEL` to a registered `checkpoint/<artifact-sha256>` identity.
`COWORLD_LLM_TEMPERATURE` explicitly selects temperature from 0 through 1;
when absent, the provider default remains unchanged. Saved players and the
verified learner gateway must use the same sampling policy and token budgets.
A player cannot choose its own checkpoint URL or serving identity.

To capture private hosted evidence, supply `COGAME_SAVE_TRAJECTORY_URI`,
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`.
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
Directories are private and episode files are created exclusively with mode 0600. Existing outputs are never overwritten. The manifest records exact
source revision, seed, outcome, target policy, and selected decision IDs.
Opponent decisions and all attempts remain available as evidence; they are
not implicitly teacher labels.

From the shared Metta checkout, validate and combine the episode files:

```sh
uv run --package coworld python - <<'PYTHON'
import os
from pathlib import Path
from coworld.decision_trajectory import CompleteEpisode

source = Path("/tmp/board-gauntlet-private-corpus")
destination = source / "complete-episodes.jsonl"
paths = sorted(source.glob("train/*.jsonl")) + sorted(source.glob("validation/*.jsonl"))
assert len(paths) == 20
with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
    for path in paths:
        episode = CompleteEpisode.model_validate_json(path.read_text())
        output.write(episode.model_dump_json() + "\n")
PYTHON
```

The shared `metta_training.posttrain.hosted.export_hosted` importer requires
external review bound to the combined corpus SHA256 and exact source revision.
Select `scripted-tactician` explicitly; unreviewed teachers are rejected.
Combining files preserves evidence and does not approve labels. The importer
assigns whole seed families to splits, including matched wording variants.
This corpus supplies candidate imitation data. It does not establish checkpoint
game strength or reinforcement learning readiness.
Reinforcement learning also requires real sampled token IDs and draw-time
behavior log probabilities from the owned serving engine. Greedy responses
and teacher labels do not supply those probabilities.

Consecutive seeds rotate Connect Four, Breakthrough, Hex, and Quoridor.
The tactician seat alternates by seed; the hustler is the opponent. Seeded
random opening plies remain in the episode and are excluded from targets.
At least 20 episodes cover every board in both whole-episode splits.
The numeric bridge is a separate research interface, not this hosted path.

## Matched wording collection

Build the bridge and use `board-gauntlet-train-bridge MANIFEST VARIANT --language`
for text collection. Reset accepts `promptVariant` and `promptSeed`; training
permits five wordings, including canonical. Held-out selections require an explicit
`split: validation` on the reset and are rejected by training exports.
The numeric interface preserves its canonical messages and action catalog.

The source exporter accepts `OUTPUT EPISODES FIRST_SEED PROMPT_VARIANT PROMPT_SEED`.
Mixed exports advance the prompt seed separately within each source split and record each selection.
This prevents every-fifth-seed validation from removing a wording from the source training directory.
The shared importer assigns its own whole-family splits; check wording coverage in its final training rows too.
Collect separate private directories with identical scenario seeds for each
wording. Episode identities include requested selection, resolved wording, and prompt seed.
Canonical and mixed exports remain distinct even when they resolve to the same wording.
Scenario-family identities
and train/validation assignment depend only on the scenario seed. Keep the
original teacher, opponent, and random-opening labels and selected decision IDs.
Prompt diversity does not turn opponent moves or random openings into targets.

Private observations carry `prompt_template` for the configured context and
`prompt_attempts` for exact recorded attempt messages, including retries. Native
attempt records retain their original request, response, origin, and receipt
fields. Empty fallback attempts are not model-generation evidence.

For evaluation, freeze policies and compare canonical with the two held-out
wordings using matched scenario seeds, seats, opponents, and ordinary budgets.
Report scores, invalid actions, fallback, and incomplete episodes. Scripted
parity establishes mechanical invariance, not improved learning or reduced collapse.

Run the retained full-game wording checks after building the bridge:

```sh
python3 tools/test_prompt_variants.py /tmp/board-gauntlet-train-bridge
```

The 32 complete games cover all four board variants, seven direct wordings,
and one mixed selection. They check exact message hashes, private notes, legal
moves, actions and outcomes. The existing native retry/fallback fixture now uses
mixed wording, including exact request-to-attempt checks. The duplicate socket
and native wording panels have been removed.


## Source-owned native verification

`tools/export_native_posttrain.py` joins a private applied-decision journal to
the recorded native replay. Run it from the clean revision that produced the
capture; every decision and terminal record must name that revision.

```sh
python3 tools/export_native_posttrain.py --replay /private/replay.json \
  --trajectory /private/trajectory.jsonl --game-log /private/game.log \
  --episode-id EPISODE_ID
```

The verifier reconstructs observations, selected rule wording, exact model
requests including retries, applied actions and final scores. Operator prompts
remain private capture metadata. The report hashes its inputs; a game-log hash
is provenance, not an independent provider receipt or a model-quality claim.
The tool does not approve teacher data or import it into a training campaign.

Historical captures retain their original reader and source checkout, including
`021af601feb17875c87544ff28784d613b1e0c29`. Do not rewrite their source identity or
run them through the current producer. New captures use the current canonical
producer and SDK decision format; no second capture writer is introduced.
