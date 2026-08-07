#!/usr/bin/env python3
"""Binary P6 PPM -> PNG, with no image library.

qemu's `screendump` writes P6. Pillow is not installed on the runner and
python3 alone can emit a PNG: zlib for the IDAT, struct for the chunks.
"""
import struct, sys, zlib
src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
if not d.startswith(b"P6"):
    sys.exit(f"{src}: not a binary PPM (starts {d[:2]!r})")
# header: P6 <w> <h> <maxval>, whitespace-separated, # comments allowed
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
i += 1                                     # single whitespace after maxval
w, h, maxv = fields
if maxv != 255:
    sys.exit(f"{src}: maxval {maxv}, only 8-bit supported")
px = d[i:i + w*h*3]
if len(px) != w*h*3:
    sys.exit(f"{src}: short pixel data ({len(px)} of {w*h*3})")
raw = b"".join(b"\x00" + px[y*w*3:(y+1)*w*3] for y in range(h))
def chunk(t, b):
    c = t + b
    return struct.pack(">I", len(b)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
open(dst, "wb").write(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b""))
# A FRAME THAT IS ALL ONE COLOUR IS NOT A DESKTOP, and is what you get if the
# compositor never started. Counting distinct colours is the cheapest way to
# tell a rendered screen from a blank one.
print(f"  {w}x{h}, {len(set(px[k:k+3] for k in range(0, len(px), 3)))} distinct colour(s)")
