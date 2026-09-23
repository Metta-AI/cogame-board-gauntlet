# Training on Board Gauntlet

Board Gauntlet makes decisions inside the game server from a player-supplied
prompt. The player socket does not accept moves. Its supported training path
is to learn from the same system and user prompts the server sends to its
language model. It does not expose numeric steps for Metta RL or PufferLib.

The exporter runs complete games through the production Nim simulator. The
`tactician` baseline supplies labels, the `hustler` baseline supplies an
opponent, and seeded random opening plies vary the positions. Opening moves
are not training targets. Consecutive seeds rotate through Connect Four,
Breakthrough, Hex, and Quoridor. Whole games go to one split by seed.

After syncing `nimby.lock` as described in the [README](../README.md), run:

```sh
nim c --path:src --out:out/export-posttrain tools/export_posttrain.nim
out/export-posttrain /tmp/board-gauntlet-dataset 100
```

The output contains `train.jsonl`, `validation.jsonl`, and `manifest.json`.
Each row matches the Metta post-training `Example` schema: the exact game
prompt and a JSON move the simulator accepted. The manifest records the
source revision, game seeds, final scores, teacher seat, and example counts.
At least 20 consecutive episodes give both splits every board.
The prompts use `PLAYER_PROMPT="Play to win. Copy one legal move exactly."`.

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/board-gauntlet-dataset \
  --output /tmp/board-gauntlet-posttrain-run \
  --model MODEL_OR_PATH --max-steps 1000 --max-length 2048
```

Check `train_overlength` and `validation_overlength` in the optimizer
manifest for the selected tokenizer. This dataset imitates the scripted
teacher; it does not measure model win rate. The server currently calls its
configured Anthropic or Bedrock provider, so fielding a trained model needs
that provider to serve it.
