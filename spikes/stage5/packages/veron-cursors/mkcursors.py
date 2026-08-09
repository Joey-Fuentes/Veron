#!/usr/bin/env python3
"""Generate an XCursor theme, because there was no pointer at all.

WHY THIS EXISTS RATHER THAN A PINNED THEME. labwc said, on every boot:

    Could not create cursor theme for 'default'
    Could not load cursor theme, disabling named cursors support

wlroots/xcursor/xcursor.c:515 reads XCURSOR_PATH, then XDG_DATA_HOME, then a
built-in directory. This system had a theme in none of them, so the compositor
drew no pointer and the browser was unusable by hand.

EVERY UPSTREAM THEME COSTS MORE THAN IT LOOKS. Bibata builds its 596 SVGs with
`cbmp`, an npm package that rasterises through a HEADLESS BROWSER, then
`ctgen` from clickgen, a pip install -- Node.js plus a browser plus network, in
a sandbox that has none of them. xcursorgen from X.org is the other route and
links libX11, libXcursor and libpng: the X11 tail this project declines
everywhere else.

So this generates the cursors instead, the same way veron-system generates the
wallpaper and the C.utf8 locale: a build product with a pinned digest, not a
downloaded artifact.

THE FORMAT IS READ OUT OF THE PARSER THAT WILL CONSUME IT --
wlroots-0.19.1/xcursor/xcursor.c, which documents it in the comments above
xcursor_file_load_images:

    magic   0x72756358      "Xcur", LSBFirst
    header  16              XCURSOR_FILE_HEADER_LEN = 4*4
    version 1<<16 | 0       XCURSOR_FILE_MAJOR 1, MINOR 0
    ntoc    n               then n * 12 bytes of table of contents

    toc entry:  type, subtype (= nominal size), position

    image chunk: header(36) type(0xfffd0002) subtype(size) version(1)
                 width height xhot yhot delay
                 then width*height ARGB32 little-endian pixels

WHAT THESE LOOK LIKE. Plain. A filled arrow, an I-beam, a hand, a watch, and
the resize set -- drawn with arithmetic, no font and no image library. They
will not flatter a designer next to Bibata. They are a pointer where there was
none, and every byte of them is generated here from source you can read.
"""
import os, struct, sys

MAGIC   = 0x72756358
IMGTYPE = 0xfffd0002
SIZES   = (24, 32, 48, 64)      # nominal sizes; wlroots picks the nearest

FG   = (0xff, 0xff, 0xff, 0xff)   # white fill
EDGE = (0xff, 0x11, 0x11, 0x14)   # near-black outline
NONE = (0x00, 0x00, 0x00, 0x00)


def blank(n):
    return [[NONE] * n for _ in range(n)]


def put(px, x, y, c):
    n = len(px)
    if 0 <= x < n and 0 <= y < n:
        px[y][x] = c


def fill_rect(px, x0, y0, w, h, c):
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            put(px, x, y, c)


def outline(px, c=EDGE):
    """Ring every filled pixel with c, so the cursor reads on any background.

    THIS IS THE WHOLE REASON THE CURSORS ARE VISIBLE. A white arrow on a white
    page is not a pointer. Drawn as a separate pass rather than by hand so the
    outline is exactly one pixel everywhere and cannot drift as shapes change.
    """
    n = len(px)
    ring = []
    for y in range(n):
        for x in range(n):
            if px[y][x][0] == 0:
                for dx, dy in ((1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)):
                    sx, sy = x + dx, y + dy
                    if 0 <= sx < n and 0 <= sy < n and px[sy][sx] == FG:
                        ring.append((x, y)); break
    for x, y in ring:
        put(px, x, y, c)


def poly_fill(px, pts, c=FG):
    """Scanline point-in-polygon fill.

    SHAPES ARE POLYGONS ON A 32-UNIT GRID, SCALED, rather than loops over
    rectangles. The first arrow here was drawn with per-row widths and its
    tail came out three pixels long at 24px and fine at 64 -- the shape
    changed with the size, which is exactly what a cursor must not do. A
    polygon scaled once and filled by the same rule at every size cannot
    drift.
    """
    n = len(px)
    for y in range(n):
        xs = []
        for i in range(len(pts)):
            x0, y0 = pts[i]
            x1, y1 = pts[(i + 1) % len(pts)]
            if (y0 <= y < y1) or (y1 <= y < y0):
                xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
        xs.sort()
        for i in range(0, len(xs) - 1, 2):
            for x in range(int(round(xs[i])), int(round(xs[i + 1])) + 1):
                put(px, x, y, c)


def arrow(n):
    """The classic left_ptr, hotspot on the tip.

    The outline is the standard X11 shape: apex top-left, a straight left
    edge down, then the notch and tail. Coordinates are the 32-unit grid.
    """
    px = blank(n)
    s = n / 32.0
    pts = [(2, 2), (2, 21), (7.5, 16.5), (11, 24), (14.5, 22.5),
           (11, 15.5), (17.5, 15.5)]
    poly_fill(px, [(x * s, y * s) for x, y in pts])
    outline(px)
    return px, (int(2 * s), int(2 * s))


def ibeam(n):
    """Text cursor: a vertical bar with serifs, hotspot in the middle."""
    px = blank(n)
    s = n / 32.0
    cx, top, bot = n // 2, int(6 * s), int(26 * s)
    fill_rect(px, cx - max(1, int(s / 2)), top, max(1, int(s)), bot - top, FG)
    for y in (top, bot - max(1, int(s))):
        fill_rect(px, cx - int(3 * s), y, int(6 * s), max(1, int(s)), FG)
    outline(px)
    return px, (cx, (top + bot) // 2)


def hand(n):
    """Link pointer: index finger raised over a fist with folded knuckles.

    THE ONE A BROWSER SHOWS ON EVERY LINK, so it is worth more than a blob.
    The first version was two rectangles and read as a paddle; the knuckles
    are what make it a hand at 24px.
    """
    px = blank(n)
    s = n / 32.0
    def R(x, y, w, h):
        fill_rect(px, int(x * s), int(y * s),
                  max(1, int(w * s)), max(1, int(h * s)), FG)
    R(12, 3, 4, 13)          # index finger, raised
    R(16, 9, 3, 7)           # middle knuckle
    R(19, 10, 3, 6)          # ring knuckle
    R(22, 11, 3, 5)          # little knuckle
    R(9, 12, 4, 6)           # thumb, folded across
    R(9, 15, 16, 11)         # the fist
    outline(px)
    return px, (int(14 * s), int(3 * s))


def watch(n):
    """Busy: a filled disc with a notch out of the top-right quadrant."""
    px = blank(n)
    s = n / 32.0
    cx = cy = n // 2
    r = int(10 * s)
    for y in range(n):
        for x in range(n):
            dx, dy = x - cx, y - cy
            if dx * dx + dy * dy <= r * r:
                if not (dx > 0 and dy < 0 and abs(dx) + abs(dy) > r * 0.9):
                    put(px, x, y, FG)
    outline(px)
    return px, (cx, cy)


def bar(n, horizontal):
    """Resize: a double-headed arrow. Hotspot at centre."""
    px = blank(n)
    s = n / 32.0
    c = n // 2
    lo, hi = int(5 * s), int(27 * s)
    t = max(1, int(2 * s))
    if horizontal:
        fill_rect(px, lo, c - t // 2, hi - lo, t, FG)
        for i in range(int(5 * s)):
            fill_rect(px, lo + i, c - i // 1 - t, 1, 2 * i + 2 * t, FG)
            fill_rect(px, hi - i - 1, c - i // 1 - t, 1, 2 * i + 2 * t, FG)
    else:
        fill_rect(px, c - t // 2, lo, t, hi - lo, FG)
        for i in range(int(5 * s)):
            fill_rect(px, c - i - t, lo + i, 2 * i + 2 * t, 1, FG)
            fill_rect(px, c - i - t, hi - i - 1, 2 * i + 2 * t, 1, FG)
    outline(px)
    return px, (c, c)


def cross(n):
    """Precision crosshair, hotspot dead centre."""
    px = blank(n)
    s = n / 32.0
    c = n // 2
    t = max(1, int(s))
    fill_rect(px, int(4 * s), c - t // 2, int(24 * s), t, FG)
    fill_rect(px, c - t // 2, int(4 * s), t, int(24 * s), FG)
    outline(px)
    return px, (c, c)


SHAPES = {
    "left_ptr":       arrow,
    "xterm":          ibeam,
    "hand2":          hand,
    "watch":          watch,
    "sb_h_double_arrow": lambda n: bar(n, True),
    "sb_v_double_arrow": lambda n: bar(n, False),
    "crosshair":      cross,
}

# ALIASES ARE NOT DECORATION. Wayland clients and wlroots request cursors by
# the CSS/xdg names on the left; every one of them resolving to something is
# the difference between a pointer that changes over a text field and a
# compositor that gives up. `default` is the name labwc asked for and could
# not find.
ALIASES = {
    "default": "left_ptr", "arrow": "left_ptr", "top_left_arrow": "left_ptr",
    "left_ptr_watch": "watch", "progress": "watch", "wait": "watch",
    "text": "xterm", "ibeam": "xterm",
    "pointer": "hand2", "pointing_hand": "hand2", "hand1": "hand2",
    "grab": "hand2", "grabbing": "hand2", "openhand": "hand2",
    "col-resize": "sb_h_double_arrow", "ew-resize": "sb_h_double_arrow",
    "e-resize": "sb_h_double_arrow", "w-resize": "sb_h_double_arrow",
    "h_double_arrow": "sb_h_double_arrow", "size_hor": "sb_h_double_arrow",
    "row-resize": "sb_v_double_arrow", "ns-resize": "sb_v_double_arrow",
    "n-resize": "sb_v_double_arrow", "s-resize": "sb_v_double_arrow",
    "v_double_arrow": "sb_v_double_arrow", "size_ver": "sb_v_double_arrow",
    "cell": "crosshair", "cross": "crosshair", "tcross": "crosshair",
    "move": "crosshair", "all-scroll": "crosshair", "fleur": "crosshair",
}


def encode(entries):
    """Serialise (size, pixels, hotspot) into one XCursor file.

    Layout is fixed by xcursor.c: a 16-byte header, ntoc * 12 bytes of table
    of contents, then the chunks. Chunk positions are absolute file offsets,
    so the TOC can only be written once the sizes are known -- computed here
    rather than seeked back over, so the writer stays a single forward pass.
    """
    ntoc = len(entries)
    pos = 16 + ntoc * 12
    toc, chunks = [], []
    for size, px, (hx, hy) in entries:
        n = len(px)
        body = bytearray()
        for row in px:
            for a, r, g, b in row:
                body += struct.pack("<I", (a << 24) | (r << 16) | (g << 8) | b)
        chunk = struct.pack("<IIIIIIIII", 36, IMGTYPE, size, 1,
                            n, n, hx, hy, 0) + bytes(body)
        toc.append(struct.pack("<III", IMGTYPE, size, pos))
        chunks.append(chunk)
        pos += len(chunk)
    out = struct.pack("<IIII", MAGIC, 16, (1 << 16), ntoc)
    return out + b"".join(toc) + b"".join(chunks)


def main(dest):
    cdir = os.path.join(dest, "usr/share/icons/Veron/cursors")
    os.makedirs(cdir, exist_ok=True)
    for name, fn in SHAPES.items():
        entries = []
        for size in SIZES:
            px, hot = fn(size)
            entries.append((size, px, hot))
        with open(os.path.join(cdir, name), "wb") as f:
            f.write(encode(entries))
    # SYMLINKS, NOT COPIES. 40-odd aliases as real files would be ~40x the
    # bytes for identical content, and the install listing would say so.
    for alias, target in ALIASES.items():
        p = os.path.join(cdir, alias)
        if os.path.lexists(p):
            os.remove(p)
        os.symlink(target, p)
    # A SECOND THEME NAMED `default`, BECAUSE ONE CONSUMER WILL NOT ASK FOR
    # ANY OTHER -- AND MADE OF FILE SYMLINKS, BECAUSE A SYMLINKED DIRECTORY
    # DOES NOT SURVIVE STAGING.
    #
    # labwc can be told the theme name; XCURSOR_THEME=Veron reaches it through
    # labwc-session. wpewebkit cannot. WPECursorTheme.cpp:134 is
    #
    #     return create("default", 24);
    #
    # hardcoded, and create() then tries exactly three names -- the one passed,
    # then "default", then "Adwaita" -- searching XDG data dirs for
    # icons/<name>/cursors. It reads no XCURSOR_THEME and no XCURSOR_PATH, so
    # a theme called Veron is invisible to it whatever the environment says:
    #
    #     Could not create cursor theme for 'default'
    #     Could not load cursor theme, disabling named cursors support
    #
    # THE CLIENT DRAWS ITS OWN POINTER, which is why this is not cosmetic.
    # Under Wayland the compositor shows a default cursor, but a client calls
    # wl_pointer.set_cursor to change it -- the I-beam over a text field and
    # the hand over a link come from the BROWSER's theme, not labwc's. Without
    # this there is a pointer everywhere except inside the page.
    #
    # THE FIRST ATTEMPT WAS `icons/default -> Veron`, ONE SYMLINK, AND IT WAS
    # SILENTLY LOST. The build step asserted it and passed; the guest test
    # failed. os.walk puts a symlink-to-a-directory in `dirs`, never in
    # `files`, so stage_into's `for fn in files` never sees it and the
    # os.makedirs above creates a real EMPTY directory in its place. A
    # symlinked directory cannot survive staging as written.
    #
    # FILE symlinks do survive -- stage_into checks os.path.islink(src) inside
    # the files loop and recreates them with os.symlink -- so `default` is a
    # real directory of links pointing back at Veron's files. Same bytes, one
    # source of truth, and it stages correctly.
    ddir = os.path.join(dest, "usr/share/icons/default/cursors")
    os.makedirs(ddir, exist_ok=True)
    for name in list(SHAPES) + list(ALIASES):
        p = os.path.join(ddir, name)
        if os.path.lexists(p):
            os.remove(p)
        os.symlink(os.path.join("../../Veron/cursors", name), p)
    with open(os.path.join(dest, "usr/share/icons/default/index.theme"), "w") as f:
        f.write("[Icon Theme]\nName=default\nInherits=Veron\n")

    tdir = os.path.join(dest, "usr/share/icons/Veron")
    with open(os.path.join(tdir, "index.theme"), "w") as f:
        f.write("[Icon Theme]\nName=Veron\n"
                "Comment=Generated cursors. No blobs, no X11, no Node.\n")
    with open(os.path.join(tdir, "cursor.theme"), "w") as f:
        f.write("[Icon Theme]\nInherits=Veron\n")
    print(f"  {len(SHAPES)} cursors, {len(ALIASES)} aliases, sizes {SIZES}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
