# Board Gauntlet training

The five certified variants share one native simulator. The existing
`tools/export_posttrain.nim` exports complete games with hosted prompts and
reply parsing for Metta post-training:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim /tmp/board-gauntlet-data 20 0
```

This dataset rotates through Connect Four, Breakthrough, Hex, and Quoridor.
Train it with Metta's post-training CLI and a model of your choice.

For numeric reinforcement learning, compile the persistent bridge:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/board-gauntlet-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/board-gauntlet-train-bridge
```

Pass the bridge, manifest, and variant to Metta's
`recipes.external.coworld.train` for native PufferLib or
`recipes.external.coworld_metta_rl.train` for Metta RL. The variants are
`gauntlet`, `connect-four`, `breakthrough-6`, `hex-7`, and `quoridor-9`.
The bridge gives the policy 256 action slots. Each legal slot names the exact
native move and has six numeric geometry features in the observation. The
remaining slots are masked. It also encodes the complete board, walls, pawns,
resources, mover, and ply. The simulator supplies legal moves, scripted
opponents, and signed terminal scores. The hosted text channel remains in
the post-training exporter.
