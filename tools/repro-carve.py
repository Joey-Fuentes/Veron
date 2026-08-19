#!/usr/bin/env python3
# Carve a named ext4 partition out of a raw GPT image so dumpe2fs can read its
# superblock. Writes <image>.<partition>. Dependency-free python.
import struct
import sys


def carve(path, want):
    d = open(path, "rb").read()
    if d[512:520] != b"EFI PART":
        print("  %s: not a GPT image" % path)
        return
    part_lba = struct.unpack("<Q", d[512 + 72:512 + 80])[0]
    num = struct.unpack("<I", d[512 + 80:512 + 84])[0]
    esz = struct.unpack("<I", d[512 + 84:512 + 88])[0]
    base = part_lba * 512
    for k in range(num):
        e = d[base + k * esz: base + k * esz + esz]
        if e[0:16] == b"\x00" * 16:
            continue
        name = e[56:128].decode("utf-16-le", "replace").rstrip("\x00")
        first = struct.unpack("<Q", e[32:40])[0] * 512
        last = struct.unpack("<Q", e[40:48])[0] * 512 + 511
        if want.lower() in name.lower():
            out = path + "." + want
            open(out, "wb").write(d[first:last + 1])
            print("  carved %s (%s): %d bytes -> %s" % (name, path, last + 1 - first, out))
            return
    print("  %s: no partition matching %r" % (path, want))


if __name__ == "__main__":
    want = sys.argv[1]
    for p in sys.argv[2:]:
        carve(p, want)
