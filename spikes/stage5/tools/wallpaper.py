#!/usr/bin/env python3
"""Generate spikes/stage5/packages/*/veron-system/files/usr/share/veron/wallpaper.png.

WHY A GENERATOR AND NOT AN IMAGE. A wallpaper is content, and content in this
tree has to come from somewhere recorded. A photograph would be someone else's
work under someone else's licence -- the Unsplash License has no SPDX id, and
`veron-system` says `license = "MIT"`. This is ours: the committed PNG is
DERIVED, this file is the source, and re-running it reproduces the bytes.

    python3 spikes/stage5/tools/wallpaper.py --check     # regenerate and diff
    python3 spikes/stage5/tools/wallpaper.py --write     # update both copies

STDLIB ONLY, DELIBERATELY. zlib and struct write a PNG in about twenty lines,
and requiring Pillow would mean the one file nobody can regenerate on a fresh
checkout is the one whose whole point is being regenerable.

DETERMINISTIC, WITH NO USE OF `random`. Every value comes from a fixed integer
hash of its coordinates, so the output does not depend on the interpreter's
seeding, its version, or the order anything is evaluated in. Two machines get
the same bytes, which is the only reason `--check` is worth running.
"""

import argparse
import hashlib
import math
import os
import struct
import sys
import zlib

WIDTH, HEIGHT = 1280, 800

# The horizon sits above centre: the sky is the subject and the ground is a
# base for it. 0.58 puts the ridgeline near the lower third line.
HORIZON = 0.58

# WHERE THE LAND STOPS AND THE WATER STARTS. The first render had the nearest
# range filling everything below it, and the bottom third of the screen was a
# flat dark slab -- exactly the part of a wallpaper that sits behind nothing
# and has to hold up on its own. A shoreline turns that slab into a reflection.
SHORE = 0.66


# ---------------------------------------------------------------- noise

def _h(x, y, seed):
    """A 32-bit integer hash of a lattice point. No PRNG state anywhere."""
    n = (x * 374761393 + y * 668265263 + seed * 2147483647) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return (n ^ (n >> 16)) / 0xFFFFFFFF


def _smooth(t):
    """Quintic ease. Cubic leaves visible creases along the lattice lines."""
    return t * t * t * (t * (t * 6 - 15) + 10)


def ridge_noise(x, octaves, seed):
    """1-D fractal noise in [0,1], for a horizon line.

    RIDGED rather than plain: each octave is folded about its midpoint, which
    turns rounded hills into peaks with sharp tops and soft valleys. A plain
    sum of octaves reads as sand dunes; Vestrahorn does not.
    """
    total, amp, freq, norm = 0.0, 1.0, 1.0, 0.0
    for o in range(octaves):
        p = x * freq
        i = math.floor(p)
        f = _smooth(p - i)
        a, b = _h(int(i), 0, seed + o), _h(int(i) + 1, 0, seed + o)
        v = a + (b - a) * f
        total += (1.0 - abs(v * 2.0 - 1.0)) * amp
        norm += amp
        amp *= 0.5
        freq *= 2.0
    return total / norm


# ---------------------------------------------------------------- colour

def lerp(a, b, t):
    return a + (b - a) * t


def ramp(stops, t):
    """Piecewise-linear colour ramp. stops is [(position, (r,g,b)), ...]."""
    t = min(max(t, 0.0), 1.0)
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        if t <= p1:
            k = 0.0 if p1 == p0 else (t - p0) / (p1 - p0)
            return tuple(lerp(c0[j], c1[j], k) for j in range(3))
    return stops[-1][1]


# THE SKY, BOTTOM-LIT. Read top to bottom: near-black indigo overhead, a long
# blue-violet body, then the band of rose and amber that only exists in the
# twenty minutes after the sun has gone.
SKY = [
    (0.00, (10, 14, 32)),
    (0.30, (26, 32, 68)),
    (0.55, (58, 52, 104)),
    (0.75, (116, 74, 122)),
    (0.88, (196, 110, 116)),
    (0.96, (238, 156, 112)),
    (1.00, (250, 196, 140)),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true", help="write the PNG files")
    ap.add_argument("--check", action="store_true",
                    help="regenerate and diff against what is committed")
    ap.add_argument("--out", action="append", default=[],
                    help="explicit output path (repeatable)")
    a = ap.parse_args()

    png = render()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    targets = a.out or [
        os.path.join(root, "packages", "veron-system",
                     "files", "usr", "share", "veron", "wallpaper.png"),
        os.path.join(root, "packages-amd64", "veron-system",
                     "files", "usr", "share", "veron", "wallpaper.png"),
    ]

    if a.check:
        # A CHECK THAT CANNOT FAIL IS WORSE THAN NO CHECK -- AGENTS.md 2c. A
        # missing file is a failure here, not a skip: it is exactly the state
        # where a stale committed image would go unnoticed.
        bad = 0
        want = hashlib.sha256(png).hexdigest()
        for t in targets:
            if not os.path.exists(t):
                print(f"  MISSING  {t}")
                bad = 1
                continue
            got = hashlib.sha256(open(t, "rb").read()).hexdigest()
            state = "ok  " if got == want else "STALE"
            print(f"  {state} {got[:16]}  {t}")
            bad |= got != want
        print("VERON-WALLPAPER-OK" if not bad else "VERON-WALLPAPER-STALE")
        return 1 if bad else 0

    if a.write:
        for t in targets:
            os.makedirs(os.path.dirname(t), exist_ok=True)
            with open(t, "wb") as f:
                f.write(png)
            print(f"  wrote {len(png)} bytes  {t}")
        print(f"  sha256 {hashlib.sha256(png).hexdigest()}")
        return 0

    ap.print_help()
    return 2


def render():
    """The whole image, as PNG bytes."""
    horizon_px = HEIGHT * HORIZON
    shore_px = int(HEIGHT * SHORE)

    # THE RIDGELINE IS SAMPLED ONCE PER COLUMN, NOT PER PIXEL. Three ranges at
    # different scales and depths: far ones are higher, hazier and flatter,
    # near ones are darker and sharper. That difference is the entire sense of
    # distance in the image -- with one range it reads as a cardboard cutout.
    ranges = [
        # (seed, octaves, horizontal scale, height px, base y offset, colour, haze)
        (17, 5, 2.6, 150, -10, (78, 76, 110), 0.58),
        (43, 7, 3.8, 122, 4,   (46, 44, 72),  0.30),
        (91, 8, 5.6, 88,  34,  (20, 19, 34),  0.09),
    ]
    profiles = []
    for seed, octaves, scale, height, offset, colour, haze in ranges:
        prof = [horizon_px + offset - ridge_noise(x / WIDTH * scale, octaves, seed) * height
                for x in range(WIDTH)]
        profiles.append((prof, colour, haze))

    # The afterglow sits behind the peaks, slightly right of centre so the
    # composition is not a mirror.
    glow_x, glow_y, glow_r = WIDTH * 0.58, horizon_px, WIDTH * 0.42

    # PASS 1: EVERYTHING ABOVE THE WATERLINE, INTO A BUFFER. The reflection has
    # to read those pixels back, and recomputing the scene per reflected row
    # would mean the sky and its reflection could drift apart the moment either
    # is edited. One scene, sampled twice.
    scene = []
    for y in range(shore_px):
        row = []
        for x in range(WIDTH):
            t = min(1.0, y / horizon_px)
            r, g, b = ramp(SKY, t)
            if y < horizon_px:
                # AFTERGLOW, ADDED NOT BLENDED, so it lifts the band near the
                # peaks without washing the colour out of it.
                d = math.hypot(x - glow_x, (y - glow_y) * 1.9) / glow_r
                if d < 1.0:
                    k = (1.0 - d) ** 2.4 * 80.0
                    r, g, b = r + k * 1.00, g + k * 0.62, b + k * 0.42

            # THE RANGES, FAR TO NEAR. A column is inside a range if it is
            # below that range's profile; the nearest one wins, so they are
            # drawn in order and the last write stands.
            for prof, colour, haze in profiles:
                if y >= prof[x]:
                    sky_here = ramp(SKY, t)
                    r = lerp(colour[0], sky_here[0], haze)
                    g = lerp(colour[1], sky_here[1], haze)
                    b = lerp(colour[2], sky_here[2], haze)
            row.append((r, g, b))
        scene.append(row)

    # PASS 2: THE WATER. Wet sand at low tide mirrors nearly perfectly, which
    # is what the reflection is doing here -- compressed, darkened, and pulled
    # toward grey with distance, because a reflection is never as saturated as
    # the thing reflected.
    rows = []
    for y in range(HEIGHT):
        row = bytearray()
        for x in range(WIDTH):
            if y < shore_px:
                r, g, b = scene[y][x]
            else:
                depth = (y - shore_px) / max(1, HEIGHT - shore_px)
                # COMPRESSED 1.9x: the reflected image is foreshortened because
                # the water is a plane seen at a glancing angle. Mirroring it
                # one-to-one looks like a fold in a photograph.
                sy = shore_px - (y - shore_px) * 1.9
                # RIPPLE AS A HORIZONTAL DISPLACEMENT OF THE SAMPLE, not as a
                # brightness stripe painted over the top. Displacing what is
                # sampled is what actually happens on water, and it is the
                # difference between a reflection and a lighting effect.
                sy += math.sin(x * 0.011 + depth * 9.0) * (1.0 + depth * 7.0)
                si = int(sy)
                if si < 0:
                    si = 0
                if si >= shore_px:
                    si = shore_px - 1
                r, g, b = scene[si][x]
                grey = (r + g + b) / 3.0
                mix = 0.80 - 0.26 * depth
                fade = 0.80 - 0.34 * depth
                r = lerp(grey, r, mix) * fade
                g = lerp(grey, g, mix) * fade
                b = lerp(grey, b, mix + 0.06) * fade
                # The wet strip right at the shoreline catches the sky brightly.
                if depth < 0.10:
                    k = (0.10 - depth) / 0.10 * 26.0
                    r, g, b = r + k, g + k * 0.9, b + k * 0.85

            # VIGNETTE, GENTLY. It keeps the eye off the corners, where the
            # bar and the window shadows already live.
            vx = (x / WIDTH - 0.5) * 2.0
            vy = (y / HEIGHT - 0.5) * 2.0
            v = 1.0 - 0.20 * min(1.0, (vx * vx + vy * vy) * 0.62)
            r, g, b = r * v, g * v, b * v

            # ORDERED DITHER AT ONE LEAST-SIGNIFICANT BIT. A 1280x800 gradient
            # quantised straight to 8 bits bands visibly across the sky, and
            # the banding is worse on the emulated framebuffer than on a
            # laptop. A 4x4 Bayer offset under a single level costs nothing
            # visually and removes it. Full-amplitude noise would look like
            # grain and would also triple the PNG.
            d = (BAYER[(y & 3) * 4 + (x & 3)] / 16.0) - 0.5
            row += bytes((clamp(r + d), clamp(g + d), clamp(b + d)))
        rows.append(bytes(row))

    return encode_png(rows)


BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]


def clamp(v):
    return 0 if v < 0 else (255 if v > 255 else int(v + 0.5))


def encode_png(rows):
    """Minimal PNG writer: 8-bit truecolour, filter 0, one IDAT.

    FILTER 0 ON EVERY ROW rather than a per-row heuristic. The heuristic is
    where two PNG writers disagree, and this file's whole claim is that it
    reproduces byte for byte on any machine. A flat filter costs a little size
    on a smooth image and costs nothing in determinism.
    """
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    # LEVEL 9 AND AN EXPLICIT wbits, so the stream does not depend on zlib's
    # defaults changing between versions.
    comp = zlib.compressobj(9, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY)
    idat = comp.compress(raw) + comp.flush()
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


if __name__ == "__main__":
    sys.exit(main())
