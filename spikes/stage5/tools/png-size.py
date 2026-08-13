#!/usr/bin/env python3
"""Print a PNG's dimensions as WxH.

WHY THIS EXISTS. The desktop test captured a frame and called that a pass, so
every desktop.png it ever produced was the kernel decompressor on qemu's
default VGA device -- identical across runs, for as long as the test had
existed. The compositor was on virtio-gpu, a second display screendump never
looked at. Checking the size is the cheapest thing that tells those apart
without knowing what the desktop is supposed to look like: the VGA text console
is 720x400 and the compositor is not.

The header is fixed-layout -- 8-byte signature, then a length and the type
'IHDR', then width and height as big-endian uint32 -- so this needs no imaging
library, which matters because the runner has none.
"""
import struct
import sys

with open(sys.argv[1], "rb") as f:
    head = f.read(24)

if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
    sys.exit("not a PNG")

width, height = struct.unpack(">II", head[16:24])
print(f"{width}x{height}")
