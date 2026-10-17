"""Full native-player games exercise actual failed requests and consumed fallbacks."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

from test_prompt_socket_games import metadata

GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
SOURCE = sys.argv[4]
ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())

for variant in manifest["variants"][1:]:
    baseline = None
    for choice in ("canonical", "plain", "heldout-briefing"):
        output = OUTPUT / f"{variant['id']}-{choice}"
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
        config = variant["game_config"] | {
            "tokens": ["0", "1"],
            "seed": 17,
            "promptVariant": choice,
            "promptSeed": 0,
            # Only the local closed endpoint's request-spacing floor changes.
            # All board sizes, ply caps, wall-clock budgets, and scoring remain ordinary.
            "plySpacingSeconds": 1,
        }
        (output / "config.json").write_text(json.dumps(config))
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        with socket.socket() as closed_endpoint:
            closed_endpoint.bind(("127.0.0.1", 0))
            environment = dict(os.environ)
            for key in (
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_API_KEY_URI",
                "AWS_BEARER_TOKEN_BEDROCK",
                "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            ):
                environment.pop(key, None)
            environment.update(
                COGAME_HOST="127.0.0.1",
                COGAME_PORT=str(port),
                COGAME_CONFIG_URI=(output / "config.json").as_uri(),
                COGAME_RESULTS_URI=(output / "results.json").as_uri(),
                COGAME_SAVE_REPLAY_URI=(output / "replay.json").as_uri(),
                COGAME_SAVE_TRAJECTORY_URI=(output / "trajectory.jsonl").as_uri(),
                COWORLD_SOURCE_REVISION=SOURCE,
                COWORLD_EPISODE_ID=str(uuid.uuid4()),
                COWORLD_GAME_VERSION="source-prompt-validation",
                COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_endpoint.getsockname()[1]}",
                COWORLD_LLM_MODEL="closed-endpoint-validation",
            )
            processes, logs = [], []
            try:
                log = (output / "game.log").open("w")
                logs.append(log)
                game = subprocess.Popen(
                    [str(GAME)], cwd=ROOT, env=environment, stdout=log, stderr=log
                )
                processes.append(game)
                ready_deadline = time.monotonic() + 30
                while True:
                    with socket.socket() as probe:
                        ready = probe.connect_ex(("127.0.0.1", port)) == 0
                    if ready:
                        break
                    assert game.poll() is None and time.monotonic() < ready_deadline
                    time.sleep(0.02)
                for seat in range(2):
                    player_env = environment | {
                        "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}",
                        "PLAYER_SCRIPTED": "",
                        "PLAYER_PROMPT": f"PRIVATE-OPERATOR-{seat}: maximize your score.",
                    }
                    log = (output / f"player-{seat}.log").open("w")
                    logs.append(log)
                    processes.append(
                        subprocess.Popen(
                            [str(PLAYER)],
                            cwd=ROOT,
                            env=player_env,
                            stdout=log,
                            stderr=log,
                        )
                    )
                deadline = time.monotonic() + 180
                for process in processes:
                    assert (
                        process.wait(timeout=max(1, deadline - time.monotonic())) == 0
                    )
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
                for log in logs:
                    log.close()
        events = [
            json.loads(line)
            for line in (output / "trajectory.jsonl").read_text().splitlines()
        ]
        assert events[-1]["status"] == "completed"
        assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
        transcript = []
        for event in events[:-1]:
            seat = int(event["seat"])
            view = event["observation"]
            configured = view.pop("prompt_template")
            prompt_attempts = view.pop("prompt_attempts")
            attempts = event["attempts"]
            assert len(attempts) == 2
            assert (
                event["action_status"] == "fallback"
                and event["selected_attempt_id"] is None
            )
            assert configured == metadata(attempts[0]["prompt"], choice, 0)
            assert prompt_attempts == [
                {
                    "attempt_id": a["attempt_id"],
                    "prompt_template": metadata(a["prompt"], choice, 0),
                }
                for a in attempts
            ]
            users = []
            for index, attempt in enumerate(attempts):
                assert attempt["origin"] == "model" and not attempt["accepted"]
                assert (
                    attempt["raw_response"] is None
                    and attempt["platform_call_id"] is None
                )
                messages = attempt["prompt"]
                assert [m["role"] for m in messages] == ["system", "user"]
                system, user = (m["content"] for m in messages)
                assert f"PRIVATE-OPERATOR-{seat}" in user
                assert f"PRIVATE-OPERATOR-{1 - seat}" not in user
                assert ("Your previous reply was invalid" in user) == (index == 1)
                assert view["rules"] in system
                assert attempt["request"]["system"] == system
                assert attempt["request"]["messages"] == [
                    {"role": "user", "content": user}
                ]
                users.append(user)
            transcript.append((view, users, event["executed_action"]))
        replay_text = (output / "replay.json").read_text()
        assert (
            "PRIVATE-OPERATOR" not in replay_text
            and "prompt_template" not in replay_text
        )
        replay = json.loads(replay_text)
        results = json.loads((output / "results.json").read_text())
        assert results["plies"] == len(events) - 1 and results["reason"] == "complete"
        result = transcript, replay, results
        if baseline is None:
            baseline = result
        assert result == baseline
        print(variant["id"], choice, len(transcript), "native plies PASS", flush=True)
