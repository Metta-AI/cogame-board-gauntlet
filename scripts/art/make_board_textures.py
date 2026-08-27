#!/usr/bin/env python3
"""Author the two board textures this repo owns.

These are SURFACES, not characters, so they are drawn rather than
generated: a printed-board paper grain and a lacquered Quoridor wall
plank. The seat cogs are nano-banana renders of the Softmax cog and are
produced by generate_cog_sheet.py + split_cog_sheet.py; this script does
not own them.

    python3 scripts/art/make_board_textures.py

Writes data/board_grain.png (64x64, seamlessly tileable, --ink on
transparent) and data/wall_plank.png (96x24).
"""
import math
import os
import random

from PIL import Image

OUT_DIR = "data"
INK = (42, 31, 22)


def board_grain(size=64, seed=20260827):
    """A seamless paper grain: two wrapped sine fields plus a speckle."""
    rng = random.Random(seed)
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = image.load()
    speckle = [[rng.random() for _ in range(size)] for _ in range(size)]
    for y in range(size):
        for x in range(size):
            # Both fields use an integer number of periods across the tile,
            # so the texture wraps in x and y with no visible seam.
            fibre = (
                math.sin(2 * math.pi * 4 * x / size) *
                math.sin(2 * math.pi * 3 * y / size) * 0.5 + 0.5
            )
            weave = (
                math.sin(2 * math.pi * 8 * (x + y) / size) * 0.5 + 0.5
            )
            value = 0.55 * fibre + 0.25 * weave + 0.20 * speckle[y][x]
            alpha = int(max(0.0, min(value - 0.42, 1.0)) * 58)
            pixels[x, y] = (INK[0], INK[1], INK[2], alpha)
    return image


def wall_plank(width=96, height=24, seed=421):
    """A lacquered plank with an ink edge, drawn horizontally."""
    rng = random.Random(seed)
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pixels = image.load()
    base = (196, 152, 96)
    for y in range(height):
        # A soft top-to-bottom shade so the plank reads as a solid object
        # rather than a flat bar.
        shade = 1.10 - 0.42 * (y / max(height - 1, 1))
        for x in range(width):
            grain = 1.0 + 0.055 * math.sin(x * 0.42 + y * 1.7) + \
                0.03 * (rng.random() - 0.5)
            edge = x < 2 or x >= width - 2 or y < 2 or y >= height - 2
            if edge:
                pixels[x, y] = (INK[0], INK[1], INK[2], 255)
                continue
            pixels[x, y] = (
                min(255, int(base[0] * shade * grain)),
                min(255, int(base[1] * shade * grain)),
                min(255, int(base[2] * shade * grain)),
                255,
            )
    # A highlight along the top face.
    for x in range(3, width - 3):
        pixels[x, 3] = (238, 214, 176, 235)
    return image


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    board_grain().save(os.path.join(OUT_DIR, "board_grain.png"))
    wall_plank().save(os.path.join(OUT_DIR, "wall_plank.png"))
    print("wrote data/board_grain.png and data/wall_plank.png")


if __name__ == "__main__":
    main()
