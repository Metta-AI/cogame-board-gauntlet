#!/usr/bin/env python3
"""Generate the Board Gauntlet seat-cog sheet with nano-banana.

One render, two cogs on a flat chroma backdrop: the RED seat holding a
Connect Four disc and a Hex stone, the BLUE seat holding a Breakthrough
pawn and a Quoridor wall plank. One sheet per character family keeps the
style consistent across roles; `split_cog_sheet.py` keys, splits and pads
the result into data/soldier_<colour>_front.png.

    GEMINI_API_KEY=... python3 scripts/art/generate_cog_sheet.py

The key is only ever the `x-goog-api-key` header. It is never printed,
never written to a file and never a URL parameter.
"""
import base64
import json
import os
import urllib.request

MODEL = "gemini-2.5-flash-image"
ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    f"{MODEL}:generateContent"
)
REFERENCE = "scripts/art/source/cog_reference.png"
OUT = "scripts/art/source/cog_seats_sheet.png"

PROMPT = """Using this robot character ("cog") as the exact character design
reference, draw TWO of these cogs side by side in one row, evenly spaced, the
same size, full body, front-facing, in the same clean cartoon rendering.
Background: perfectly flat, solid, uniform pure bright green (#00FF00), no
shadows, no gradients, no floor - it will be chroma-keyed out.
LEFT - RED SEAT: warm red (#E0523A) plating and panels, holding up a large
round red game disc in one hand and a red hexagonal game stone in the other.
RIGHT - BLUE SEAT: cool blue (#3F7CC4) plating and panels, holding up a tall
blue board-game pawn in one hand and a short lacquered wooden wall plank in
the other. Both cogs keep the wheeled base, riveted shoulders and glowing
screen face of the reference. No text, no labels, no board, no table."""


def main() -> None:
    parts = []
    if os.path.exists(REFERENCE):
        with open(REFERENCE, "rb") as handle:
            parts.append({
                "inline_data": {
                    "mime_type": "image/png",
                    "data": base64.b64encode(handle.read()).decode(),
                }
            })
    parts.append({"text": PROMPT})
    body = {
        "contents": [{"parts": parts}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={
            "x-goog-api-key": os.environ["GEMINI_API_KEY"],
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    part = next(
        p for p in payload["candidates"][0]["content"]["parts"]
        if "inlineData" in p
    )
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as handle:
        handle.write(base64.b64decode(part["inlineData"]["data"]))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
