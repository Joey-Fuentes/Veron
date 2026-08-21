#!/usr/bin/env python3
"""Find a window in a qemu screendump by the one thing a person uses: its colour.

    frame-find.py SHOT.ppm RRGGBB [--min-run N] [--tol T]

Prints one line,  "x y w h rows"  -- the bounding box of the LARGEST vertical
block of consecutive rows that each contain a horizontal run of at least
--min-run pixels within --tol of RRGGBB (per channel). Exit 0 if something
qualified, 1 if nothing did, 2 on a bad file.

WHY A RUN AND NOT A COUNT. The desktop wallpaper is a gradient; any single
colour appears in it as at most one thin band, never as a long flat run. A
window's flat surface (the flasher's white log pane, foot's dark background)
is hundreds of pixels of one value in a row. Asking for a run of N is what
separates "a window is here" from "the wallpaper passed through this colour".

WHY THE LARGEST BLOCK. A titlebar, a button face or a bar can share the colour
of the thing being looked for; the thing being looked for is the biggest
flat area of it on screen, so the biggest block wins and the rest are
ignored. x is taken from the block's fully-flat rows (the ones with the
longest run), because rows that carry text start their long run mid-row.

No image library: python3 alone reads qemu's binary P6, as ppm2png.py does.
"""
import sys

def parse_ppm(path):
    d = open(path, "rb").read()
    if not d.startswith(b"P6"):
        sys.exit(2)
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(d) and d[i:i+1].isspace():
            i += 1
        if d[i:i+1] == b"#":
            while d[i:i+1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while j < len(d) and not d[j:j+1].isspace():
            j += 1
        fields.append(int(d[i:j]))
        i = j
    i += 1
    w, h, maxv = fields
    if maxv != 255:
        sys.exit(2)
    px = d[i:i + w*h*3]
    if len(px) != w*h*3:
        sys.exit(2)
    return w, h, px

def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    path, hexcol = args[0], args[1]
    min_run, tol = 200, 2
    k = 2
    while k < len(args):
        if args[k] == "--min-run":
            min_run = int(args[k+1]); k += 2
        elif args[k] == "--tol":
            tol = int(args[k+1]); k += 2
        elif args[k] == "--size":
            w, h, _ = parse_ppm(path); print(f"{w} {h}"); return 0
        else:
            sys.exit(__doc__)
    want = bytes.fromhex(hexcol.lstrip("#"))
    w, h, px = parse_ppm(path)

    # per row: the longest qualifying run and where it starts
    rows = []          # (y, run_len, run_x0, run_x1)
    for y in range(h):
        row = px[y*w*3:(y+1)*w*3]
        best = (0, 0, 0); cur = 0; x0 = 0
        for x in range(w):
            p = row[x*3:x*3+3]
            if (abs(p[0]-want[0]) <= tol and abs(p[1]-want[1]) <= tol
                    and abs(p[2]-want[2]) <= tol):
                if cur == 0:
                    x0 = x
                cur += 1
                if cur > best[0]:
                    best = (cur, x0, x)
            else:
                cur = 0
        if best[0] >= min_run:
            rows.append((y, best[0], best[1], best[2]))

    if not rows:
        return 1

    # group consecutive rows into blocks; keep the tallest*widest one
    blocks, cur = [], [rows[0]]
    for r in rows[1:]:
        if r[0] == cur[-1][0] + 1:
            cur.append(r)
        else:
            blocks.append(cur); cur = [r]
    blocks.append(cur)
    def area(b):
        return len(b) * max(r[1] for r in b)
    blk = max(blocks, key=area)
    longest = max(r[1] for r in blk)
    flat = [r for r in blk if r[1] >= longest * 0.95]
    x0 = min(r[2] for r in flat)
    x1 = max(r[3] for r in flat)
    y0, y1 = blk[0][0], blk[-1][0]
    print(f"{x0} {y0} {x1 - x0 + 1} {y1 - y0 + 1} {len(blk)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
