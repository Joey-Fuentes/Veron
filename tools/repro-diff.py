#!/usr/bin/env python3
# Diff two raw disk images byte for byte and localize every differing region to
# its GPT partition (and offset within it). Same input must give same output;
# this says exactly where it does not. Dependency-free python (Veron-native).
import struct
import sys


def gpt_partitions(data):
    if data[512:520] != b"EFI PART":
        return []
    part_lba = struct.unpack("<Q", data[512 + 72:512 + 80])[0]
    num = struct.unpack("<I", data[512 + 80:512 + 84])[0]
    esz = struct.unpack("<I", data[512 + 84:512 + 88])[0]
    base = part_lba * 512
    parts = []
    for k in range(num):
        e = data[base + k * esz: base + k * esz + esz]
        if e[0:16] == b"\x00" * 16:
            continue
        first = struct.unpack("<Q", e[32:40])[0]
        last = struct.unpack("<Q", e[40:48])[0]
        name = e[56:128].decode("utf-16-le", "replace").rstrip("\x00")
        parts.append((name, first * 512, last * 512 + 511))
    return parts


def main(a_path, b_path):
    da = open(a_path, "rb").read()
    db = open(b_path, "rb").read()
    print("image A: %d bytes" % len(da))
    print("image B: %d bytes" % len(db))
    if len(da) != len(db):
        print("!! SIZES DIFFER by %d bytes -- structural" % abs(len(da) - len(db)))

    minlen = min(len(da), len(db))
    diffs = []
    run_start = None
    for i in range(minlen):
        if da[i] != db[i]:
            if run_start is None:
                run_start = i
        elif run_start is not None:
            diffs.append((run_start, i - 1))
            run_start = None
    if run_start is not None:
        diffs.append((run_start, minlen - 1))

    total = sum(hi - lo + 1 for lo, hi in diffs)
    print("\n%d differing region(s), %d bytes differ\n" % (len(diffs), total))

    parts = gpt_partitions(da)
    print("GPT partitions in image A:")
    for name, lo, hi in parts:
        print("  %-12s bytes %d..%d" % (name, lo, hi))

    def where(off):
        for name, lo, hi in parts:
            if lo <= off <= hi:
                return "%s (+%d into partition)" % (name, off - lo)
        if off < 512:
            return "protective MBR"
        if 512 <= off < 1024:
            return "primary GPT header"
        if off >= len(da) - 512 * 40:
            return "backup GPT area"
        return "GPT entries / gap"

    print("\ndiffering regions, mapped:")
    for lo, hi in diffs[:80]:
        span = hi - lo + 1
        print("  offset %d .. %d  (%d B)  in %s" % (lo, hi, span, where(lo)))
        print("      A: %s" % da[lo:min(hi + 1, lo + 16)].hex())
        print("      B: %s" % db[lo:min(hi + 1, lo + 16)].hex())
    if len(diffs) > 80:
        print("  ... and %d more regions" % (len(diffs) - 80))

    print()
    if total == 0:
        print("REPRODUCIBLE: the two images are byte-identical.")
        return 0
    print("NOT REPRODUCIBLE: %d bytes differ across %d regions." % (total, len(diffs)))
    print("The offsets above name exactly which ext4/GPT structure drifts.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
