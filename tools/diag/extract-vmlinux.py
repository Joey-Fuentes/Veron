#!/usr/bin/env python3
# tools/diag/extract-vmlinux.py -- extract the ELF vmlinux out of a bzImage, the way the kernel's
# scripts/extract-vmlinux does, without GNU grep -b or mktemp templates
# (busybox has neither). Finds the compressed payload's magic, decompresses
# it, keeps the result that starts with \x7fELF. gzip / xz / zstd.
import sys, zlib, lzma
d = open(sys.argv[1], 'rb').read()
magics = {b'\x1f\x8b\x08': 'gz', b'\xfd7zXZ\x00': 'xz', b'\x28\xb5\x2f\xfd': 'zst'}
for m, kind in magics.items():
    i = d.find(m)
    while i != -1:
        try:
            if kind == 'gz':
                out = zlib.decompressobj(31).decompress(d[i:])
            elif kind == 'xz':
                out = lzma.LZMADecompressor().decompress(d[i:])
            else:
                from compression import zstd
                out = zstd.ZstdDecompressor().decompress(d[i:])
            if out[:4] == b'\x7fELF':
                sys.stdout.buffer.write(out)
                print(kind, 'payload at', i, '->', len(out), 'bytes', file=sys.stderr)
                sys.exit(0)
        except Exception:
            pass
        i = d.find(m, i + 1)
print('no vmlinux found', file=sys.stderr)
sys.exit(1)
