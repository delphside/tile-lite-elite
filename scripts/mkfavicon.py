#!/usr/bin/env python3
"""mkfavicon.py — draw assets/favicon.ico.

The icon is a Scrabble-style tile carrying a letter T that is also a tree: a
trunk for the stem, an overhanging canopy for the crossbar, a bush beneath the
overhang. From the owner's school ceramics design (#103, 2026-09-05) — "a reddy
brown tree on the left, which at the top overhangs the right side. Underneath on
the right is a bush. The bush and the tree branch are aligned on the right."

**Why a generator and not just the .ico.** Every shape here is a rectangle
placed by hand on a 16-unit grid, because this machine has no image tooling —
no Pillow, no ImageMagick, no Inkscape. Without this file, changing the icon
means redoing that placement from scratch. With it, a tweak is an edit and one
command.

    python3 scripts/mkfavicon.py

Writes crates/ui/assets/favicon.ico. Deterministic: same input, same bytes, so a rerun
that changes nothing leaves the tree clean.
"""

import os
import struct
import sys
import zlib

# The app's own palette, from crates/ui/assets/main.css — the design and the
# board shared these colours before anyone arranged it.
FACE = (0xF6, 0xDC, 0xA4, 255)   # tile face
EDGE = (0xD4, 0xA2, 0x3A, 255)   # tile edge, bottom and right
BROWN = (0x8A, 0x2D, 0x1E, 255)  # trunk and canopy
GREEN = (0x4A, 0x6B, 0x2F, 255)  # bush
CLEAR = (0, 0, 0, 0)

SIZES = (16, 32, 48)

# Below this the canopy's notch is one pixel wide and reads as a broken bar
# rather than a tree, so at 16px the icon is a plain T. Small is the letter;
# large is the tree.
DETAIL_FROM = 24


def png(w, h, px):
    """A minimal RGBA PNG. Filter byte 0 on every row: the images are a few
    hundred bytes, so choosing filters per row would save nothing worth the
    code."""
    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    raw = b"".join(
        b"\x00" + bytes(v for x in range(w) for v in px[y][x]) for y in range(h)
    )
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def ico(images):
    """An ICO holding PNG payloads, which every browser has read since IE11.
    The BMP alternative is uncompressed BGRA plus a mask — about 15 KB here
    against 600 bytes — and buys compatibility with nothing we serve."""
    count = len(images)
    header = struct.pack("<HHH", 0, 1, count)
    offset = 6 + 16 * count
    entries, payloads = b"", b""
    for size, data in images:
        entries += struct.pack(
            "<BBBBHHII",
            size, size,   # 0 would mean 256; every size here is smaller
            0, 0,         # no palette, reserved
            1, 32,        # one plane, 32 bits per pixel
            len(data), offset,
        )
        payloads += data
        offset += len(data)
    return header + entries + payloads


def tile(n):
    """The tile: a rounded square, face colour, with the bottom and right edges
    darker so it reads as a physical piece rather than a sticker."""
    g = [[CLEAR] * n for _ in range(n)]
    r = max(1, int(n * 0.14))
    hi = n - 1
    lip = max(1, n // 16)
    for y in range(n):
        for x in range(n):
            cx = r if x < r else (hi - r if x > hi - r else x)
            cy = r if y < r else (hi - r if y > hi - r else y)
            if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
                continue
            g[y][x] = EDGE if (x >= hi - lip or y >= hi - lip) else FACE
    return g


def rect(g, x0, y0, x1, y1, col):
    n = len(g)
    for y in range(max(0, int(round(y0))), min(n, int(round(y1)) + 1)):
        for x in range(max(0, int(round(x0))), min(n, int(round(x1)) + 1)):
            g[y][x] = col


def tree(g, n):
    """Placed on a 16-unit grid so the same numbers work at every size."""
    u = n / 16.0
    left, right, top = 3.6 * u, 12.4 * u, 3.6 * u

    # Canopy: flat top, flat right edge. Deep on the left and thinning across,
    # then the right end drops below the bar so it curves over rather than
    # stopping square. At small sizes only the bar survives.
    rect(g, left, top, right, top + 1.5 * u, BROWN)
    if n >= DETAIL_FROM:
        rect(g, left, top + 1.5 * u, 9.2 * u, top + 2.4 * u, BROWN)
        rect(g, left, top + 2.4 * u, 7.4 * u, top + 3.0 * u, BROWN)
        rect(g, 11.2 * u, top + 1.5 * u, right, top + 2.8 * u, BROWN)

    tw = max(1, int(round(1.6 * u)))
    tx = int(round(5.4 * u))
    rect(g, tx, top + 2.6 * u, tx + tw - 1, 12.2 * u, BROWN)

    if n >= DETAIL_FROM:
        # Right edge flush with the canopy's, which is what makes the two read
        # as one composition rather than two objects.
        rect(g, 10.5 * u, 8.8 * u, right, 12.2 * u, GREEN)
        rect(g, 10.8 * u, 8.1 * u, right - 0.3 * u, 8.8 * u, GREEN)
        rect(g, 11.2 * u, 7.6 * u, right - 0.7 * u, 8.1 * u, GREEN)

    rect(g, 3.2 * u, 12.2 * u, right, 12.2 * u + max(0, round(0.35 * u)), BROWN)


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(here, "crates", "ui", "assets", "favicon.ico")

    images = []
    for n in SIZES:
        g = tile(n)
        tree(g, n)
        images.append((n, png(n, n, g)))

    blob = ico(images)
    with open(out, "wb") as f:
        f.write(blob)
    print(f"{out}: {len(blob)} bytes, sizes {', '.join(str(n) for n in SIZES)}")


if __name__ == "__main__":
    sys.exit(main())
