#!/usr/bin/env python3
# tools/diag/kernel-diff.py -- compare two kernel images with nothing but
# python3: extract both vmlinux (gzip/xz/zstd payload), report the first
# differing byte, and diff the printable strings.
#
#     python3 tools/diag/kernel-diff.py A B
import sys, re, hashlib, zlib, lzma

def extract(path):
    d = open(path, 'rb').read()
    for m, kind in {b'\x1f\x8b\x08': 'gz', b'\xfd7zXZ\x00': 'xz', b'\x28\xb5\x2f\xfd': 'zst'}.items():
        i = d.find(m)
        while i != -1:
            try:
                if kind == 'gz': out = zlib.decompressobj(31).decompress(d[i:])
                elif kind == 'xz': out = lzma.LZMADecompressor().decompress(d[i:])
                else:
                    from compression import zstd; out = zstd.ZstdDecompressor().decompress(d[i:])
                if out[:4] == b'\x7fELF': return out, kind, i
            except Exception: pass
            i = d.find(m, i + 1)
    sys.exit(f'{path}: no vmlinux payload found')

def strings(b, n=4):
    return set(s.decode('ascii') for s in re.findall(rb'[\x20-\x7e]{%d,}' % n, b))

a, b = sys.argv[1], sys.argv[2]
for p in (a, b): print(hashlib.sha256(open(p, 'rb').read()).hexdigest(), p)
ea, ka, oa = extract(a); eb, kb, ob = extract(b)
print(f'{a}: {ka} at {oa} -> {len(ea)} bytes;  {b}: {kb} at {ob} -> {len(eb)} bytes')
if ea == eb: print('vmlinux IDENTICAL'); sys.exit(0)
first = next((i for i, (x, y) in enumerate(zip(ea, eb)) if x != y), min(len(ea), len(eb)))
ndiff = sum(1 for x, y in zip(ea, eb) if x != y) + abs(len(ea) - len(eb))
print(f'first differing byte at {first}; {ndiff} bytes differ in total')
sa, sb = strings(ea), strings(eb)
only_a, only_b = sorted(sa - sb), sorted(sb - sa)
print(f'strings only in A: {len(only_a)}; only in B: {len(only_b)}')
for s in only_a[:40]: print('  A:', s[:160])
for s in only_b[:40]: print('  B:', s[:160])
# a window around the first difference, as hex, for the cases strings cannot name
lo = max(0, first - 32); print('bytes around the first difference:')
print('  A:', ea[lo:first + 32].hex()); print('  B:', eb[lo:first + 32].hex())
