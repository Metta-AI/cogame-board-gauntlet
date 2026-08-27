#!/usr/bin/env python3
"""Key, split and pad the nano-banana seat-cog sheet into seat sprites.

Gemini does not return alpha, and the "pure green" it is asked for comes
back as *some* green with a tinted edge, so the backdrop colour is taken as
the MEDIAN of the image border (corners sometimes carry a smudge) and the
key is a flood fill from the border, which leaves any green *inside* a cog
alone. The row is then split on empty columns and each part padded to a
square.

    python3 scripts/art/split_cog_sheet.py

Writes data/soldier_red_front.png and data/soldier_blue_front.png -- the two
seat avatars the scorebug plates draw. It does NOT own data/arena_floor.png
(copied from cogame-babel), data/board_grain.png or data/wall_plank.png
(authored by scripts/art/make_board_textures.py).
"""
import os
from collections import deque

from PIL import Image

SHEET = "scripts/art/source/cog_seats_sheet.png"
ROLES = ["soldier_red_front", "soldier_blue_front"]
OUT_DIR = "data"
SIZE = 192
TOLERANCE = 62


def border_median(image):
    width, height = image.size
    pixels = image.load()
    samples = []
    for x in range(width):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, height - 1][:3])
    for y in range(height):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[width - 1, y][:3])
    channels = []
    for index in range(3):
        values = sorted(sample[index] for sample in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)


def near(a, b, tolerance=TOLERANCE):
    return sum((a[i] - b[i]) ** 2 for i in range(3)) <= tolerance * tolerance


def key_out(image):
    """Flood-fill the backdrop from every border pixel that matches it."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    backdrop = border_median(image)
    seen = bytearray(width * height)
    queue = deque()
    for x in range(width):
        queue.append((x, 0))
        queue.append((x, height - 1))
    for y in range(height):
        queue.append((0, y))
        queue.append((width - 1, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        if seen[y * width + x]:
            continue
        seen[y * width + x] = 1
        if not near(pixels[x, y][:3], backdrop):
            continue
        pixels[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    # Second pass: the flood fill cannot reach backdrop trapped between the
    # wheels and the arms, and the render's anti-aliased edges leave a green
    # fringe. Both are strongly green-dominant, and NOTHING in these two
    # cogs is (red plating, blue plating, cyan face, wooden plank), so a
    # dominance test is safe here and is stated as such.
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            if g > r * 1.25 and g > b * 1.25 and g > 70:
                pixels[x, y] = (0, 0, 0, 0)
            elif g > (r + b) * 0.62 and g > 60:
                # Despill: pull the leftover green fringe back toward the
                # neighbouring plating instead of leaving a lime halo.
                pixels[x, y] = (r, min(g, int((r + b) * 0.55)), b, a)
    return image


def column_spans(image, min_width=20):
    width, height = image.size
    alpha = image.split()[3].load()
    filled = []
    for x in range(width):
        column = 0
        for y in range(height):
            if alpha[x, y] > 24:
                column += 1
                if column > 2:
                    break
        filled.append(column > 2)
    spans = []
    start = None
    for x, value in enumerate(filled):
        if value and start is None:
            start = x
        elif not value and start is not None:
            if x - start >= min_width:
                spans.append((start, x))
            start = None
    if start is not None and width - start >= min_width:
        spans.append((start, width))
    return spans


def pad_square(image):
    bbox = image.getbbox()
    part = image.crop(bbox)
    side = max(part.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(part, ((side - part.width) // 2, (side - part.height) // 2))
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    sheet = key_out(Image.open(SHEET))
    spans = column_spans(sheet)
    if len(spans) != len(ROLES):
        raise SystemExit(
            f"expected {len(ROLES)} cogs on the sheet, found {len(spans)}: "
            f"{spans}"
        )
    os.makedirs(OUT_DIR, exist_ok=True)
    for (left, right), role in zip(spans, ROLES):
        part = sheet.crop((left, 0, right, sheet.height))
        out = os.path.join(OUT_DIR, f"{role}.png")
        pad_square(part).save(out)
        print("wrote", out, "from columns", left, right)


if __name__ == "__main__":
    main()
