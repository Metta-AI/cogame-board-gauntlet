"""Qualify native request/response, retry, fallback, privacy, and replay joins."""
import json
import re
import sys
from pathlib import Path

binary, output, revision, sdk = sys.argv[1:]
sys.path.insert(0, str(Path(sdk) / "tools"))
from native_fixture import qualify

def action(user):
    return {"move": re.search(r"YOUR LEGAL MOVES[^\n]*exactly: ([^ ]+)", user)[1]}

qualify(binary, {'seed': 17, 'sampled': True, 'turnDelayMs': 0, 'player_connect_timeout_seconds': 3, 'episodeTimeoutSeconds': 120, 'maxOutputTokens': 900, 'llmTimeoutSeconds': 5, 'tokens': ['0', '1'], 'players': [{'name': 'fixture-0'}, {'name': 'fixture-1'}], 'game': 'connect-four', 'size': 5, 'maxPlies': 4, 'plySpacingSeconds': 1}, action, output, revision)
