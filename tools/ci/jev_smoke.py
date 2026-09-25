"""Run Jev beside a scripted seat in all four boards' production image."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


class SystemOne(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        assert self.path == "/v1/systemone"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert "reply with only the JSON object" not in body["state"]
        observation = json.loads(body["state"].split("\nYour observation:\n", 1)[1])
        choices = body["questions"]["decision"]["criteria"]
        assert list(choices) == observation["legalMoves"]
        self.calls.append((dict(self.headers), body["model"], observation))
        payload = json.dumps({
            "model": body["model"],
            "answers": {"decision": {
                "type": "choice", "confidence": 1.0,
                "probabilities": {move: float(move == observation["legalMoves"][0])
                                  for move in choices},
            }},
            "usage": {"input_tokens": 100, "output_tokens": 1},
        }).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def docker(*args):
    return subprocess.run(
        ["docker", *args], check=True, capture_output=True, text=True, timeout=120
    ).stdout.strip()


def episode(image, server, game, size, jev_slot):
    prefix = f"gauntlet-jev-{os.getpid()}-{game}"
    network = f"{prefix}-net"
    containers = [f"{prefix}-game", f"{prefix}-p0", f"{prefix}-p1"]
    with tempfile.TemporaryDirectory(prefix=f"{prefix}-") as directory:
        work = Path(directory)
        os.chmod(work, 0o777)
        (work / "config.json").write_text(json.dumps({
            "game": game, "size": size, "seed": 23, "maxPlies": 4,
            "num_agents": 2, "tokens": ["token-0", "token-1"],
            "players": [{"name": "Jev"}, {"name": "Tactician"}],
            "first": 0, "turnDelayMs": 0,
            "llmTimeoutSeconds": 5, "episodeTimeoutSeconds": 120,
            "player_connect_timeout_seconds": 5,
        }))
        docker("network", "create", network)
        passed = False
        try:
            docker(
                "run", "-d", "--name", containers[0], "--network", network,
                "--network-alias", "gauntlet-game", "-e", "COGAME_HOST=0.0.0.0",
                "-e", "COGAME_PORT=8080",
                "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
                "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
                "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
                "-v", f"{work}:/coworld:rw", image, "/bin/board-gauntlet",
            )
            time.sleep(1)
            for slot in range(2):
                args = [
                    "run", "-d", "--name", containers[slot + 1],
                    "--network", network,
                    "--add-host", "host.docker.internal:host-gateway",
                    "-e", f"COWORLD_PLAYER_WS_URL=ws://gauntlet-game:8080/"
                    f"player?slot={slot}&token=token-{slot}",
                ]
                if slot == jev_slot:
                    args += [
                        "-e", "PLAYER_JEV=1", "-e",
                        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME="
                        f"http://host.docker.internal:{server.server_port}",
                    ]
                else:
                    args += ["-e", "PLAYER_SCRIPTED=tactician"]
                docker(*args, image, "/bin/board-gauntlet-player")
            assert docker("wait", containers[0]) == "0"
            for container in containers[1:]:
                assert docker("wait", container) == "0"
            results = json.loads((work / "results.json").read_text())
            replay = json.loads((work / "replay.json").read_text())
            moves = [event for event in replay["events"] if event["kind"] == "move"]
            calls = [call for call in SystemOne.calls
                     if call[2]["game"] == game and call[2]["slot"] == jev_slot]
            assert results["game"] == game
            assert results["plies"] == len(moves) == 4
            assert results["fallbacks"][jev_slot] == 0
            assert results["illegalReplies"][jev_slot] == 0
            assert len(calls) == 2
            assert len([move for move in moves if move["seat"] == jev_slot]) == 2
            for move in moves:
                assert not move["fellBack"]
                assert move["scripted"] == (move["seat"] != jev_slot)
            for (headers, model, observation), move in zip(
                calls, [move for move in moves if move["seat"] == jev_slot]
            ):
                assert headers["x-coworld-player-slot"] == str(jev_slot)
                assert "authorization" not in headers
                assert model == "typesafe/jev-1.13"
                assert observation["slot"] == jev_slot
                assert observation["toMove"]
                assert observation["legalMoves"]
                assert move["move"] == observation["legalMoves"][0]
                assert "seed" not in observation
                assert "policyNames" not in observation
                assert "notes" not in observation["opponent"]
            print(f"{game}: seat {jev_slot}, 2 accepted Jev moves, 2 scripted moves")
            passed = True
        finally:
            if not passed:
                for container in containers:
                    logs = subprocess.run(
                        ["docker", "logs", container], capture_output=True, text=True
                    )
                    print(logs.stdout, logs.stderr, file=sys.stderr)
            for container in containers:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
            subprocess.run(["docker", "network", "rm", network], capture_output=True)


if __name__ == "__main__":
    model = http.server.HTTPServer(("0.0.0.0", 0), SystemOne)
    worker = threading.Thread(target=model.serve_forever, daemon=True)
    worker.start()
    try:
        for game, size, slot in [
            ("connect-four", 5, 0), ("breakthrough", 6, 1),
            ("hex", 4, 0), ("quoridor", 5, 1),
        ]:
            episode(sys.argv[1], model, game, size, slot)
    finally:
        model.shutdown()
        worker.join()
