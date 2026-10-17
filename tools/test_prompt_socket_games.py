"""Complete external-player games through the shipped server and private writer."""

import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import uuid

import websockets

VARIANTS = ["canonical", "plain", "numbered", "questions", "reordered"]


def metadata(messages, choice, seed):
    return {
        "bank": "board-gauntlet-rules-v1",
        "variant": VARIANTS[seed] if choice == "mixed" else choice,
        "selection": choice,
        "seed": seed,
        "system_sha256": hashlib.sha256(messages[0]["content"].encode()).hexdigest(),
        "user_sha256": hashlib.sha256(messages[1]["content"].encode()).hexdigest(),
    }


async def play(binary, folder, config, revision, choice, seed):
    folder.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = config | {
        "tokens": ["0", "1"],
        "seed": 17,
        "promptVariant": choice,
        "promptSeed": seed,
    }
    (folder / "config.json").write_text(json.dumps(config))
    environment = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
    ):
        environment.pop(key, None)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(folder / "config.json").as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
        COWORLD_SOURCE_REVISION=revision,
        COWORLD_EPISODE_ID=str(uuid.uuid4()),
        COWORLD_GAME_VERSION="source-prompt-validation",
    )
    received = {}
    with (folder / "game.log").open("w") as log:
        process = await asyncio.create_subprocess_exec(
            binary, env=environment, stdout=log, stderr=log
        )
        tasks = []
        try:
            async with asyncio.timeout(30):
                while True:
                    assert process.returncode is None
                    with socket.socket() as probe:
                        if probe.connect_ex(("127.0.0.1", port)) == 0:
                            break
                    await asyncio.sleep(0.02)

            async def player(seat):
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}"
                ) as connection:
                    async for raw in connection:
                        frame = json.loads(raw)
                        if frame["type"] == "welcome":
                            await connection.send(
                                json.dumps({"type": "register", "control": "external"})
                            )
                        elif frame["type"] == "observation":
                            messages = frame["messages"]
                            assert [m["role"] for m in messages] == ["system", "user"]
                            assert frame["prompt_template"] == metadata(
                                messages, choice, seed
                            )
                            view = frame["observation"]
                            assert view["slot"] == seat and view["toMove"]
                            assert "notes" not in view["opponent"]
                            assert view["rules"] in messages[0]["content"]
                            received[frame["id"]] = frame
                            await connection.send(
                                json.dumps(
                                    {
                                        "type": "action",
                                        "id": frame["id"],
                                        "move": view["legalMoves"][0],
                                    }
                                )
                            )
                        elif frame["type"] == "final":
                            assert frame["reason"] == "complete"
                            return

            tasks = [asyncio.create_task(player(seat)) for seat in range(2)]
            async with asyncio.timeout(180):
                await asyncio.gather(*tasks)
                while "artifacts written;" not in (folder / "game.log").read_text():
                    assert process.returncode is None
                    await asyncio.sleep(0.02)
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if process.returncode is None:
                process.terminate()
            await asyncio.wait_for(process.wait(), 5)

    events = [
        json.loads(line)
        for line in (folder / "trajectory.jsonl").read_text().splitlines()
    ]
    assert events[-1]["status"] == "completed"
    assert len(received) == len(events) - 1
    assert (folder / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
    transcript = []
    for index, event in enumerate(events[:-1], 1):
        frame = received[index]
        view = event["observation"]
        assert view.pop("prompt_template") == frame["prompt_template"]
        attempts = view.pop("prompt_attempts")
        assert view == frame["observation"]
        assert len(event["attempts"]) == 1
        attempt = event["attempts"][0]
        assert attempt["origin"] == "unknown" and attempt["accepted"]
        assert attempt["prompt"] == frame["messages"]
        assert attempts == [
            {
                "attempt_id": attempt["attempt_id"],
                "prompt_template": frame["prompt_template"],
            }
        ]
        assert event["action_status"] == "accepted"
        transcript.append((view, frame["messages"][1], event["executed_action"]))
    replay = json.loads((folder / "replay.json").read_text())
    assert "prompt_template" not in json.dumps(replay)
    results = json.loads((folder / "results.json").read_text())
    assert results["plies"] == len(received) and results["reason"] == "complete"
    print(
        config["game"], choice, seed, len(received), "complete plies PASS", flush=True
    )
    return transcript, replay, results


async def main():
    binary, output, revision = sys.argv[1:]
    output = Path(output).resolve()
    output.mkdir(mode=0o700)
    manifest = json.loads(Path("coworld_manifest_template.json").read_text())
    choices = [(v, 0) for v in VARIANTS + ["heldout-briefing", "heldout-reference"]]
    choices += [("mixed", seed) for seed in range(5)]
    for variant in manifest["variants"][1:]:
        baseline = None
        for choice, seed in choices:
            result = await play(
                binary,
                output / f"{variant['id']}-{choice}-{seed}",
                variant["game_config"],
                revision,
                choice,
                seed,
            )
            if baseline is None:
                baseline = result
            assert result == baseline


if __name__ == "__main__":
    asyncio.run(main())
