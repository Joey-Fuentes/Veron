#!/usr/bin/env python3
# Compare two directory trees byte for byte: same set of paths, and each file's
# sha256 identical. Says exactly which files differ or are missing. Used to test
# whether firmware preparation (fetch + install + zstd + prune) is deterministic
# run to run. Dependency-free python.
import hashlib
import os
import sys


def walk(root):
    out = {}
    for dp, _, fns in os.walk(root):
        for fn in fns:
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root)
            try:
                h = hashlib.sha256(open(full, "rb").read()).hexdigest()
            except OSError:
                h = "UNREADABLE"
            out[rel] = h
    return out


def main(a, b):
    ta, tb = walk(a), walk(b)
    pa, pb = set(ta), set(tb)

    only_a = sorted(pa - pb)
    only_b = sorted(pb - pa)
    common = pa & pb
    differ = sorted(p for p in common if ta[p] != tb[p])

    print("tree A: %d files (%s)" % (len(ta), a))
    print("tree B: %d files (%s)" % (len(tb), b))
    print()
    if only_a:
        print("%d path(s) only in A:" % len(only_a))
        for p in only_a[:40]:
            print("  A-only  %s" % p)
    if only_b:
        print("%d path(s) only in B:" % len(only_b))
        for p in only_b[:40]:
            print("  B-only  %s" % p)
    if differ:
        print("%d file(s) present in both but DIFFERING bytes:" % len(differ))
        for p in differ[:60]:
            print("  DIFFER  %s" % p)
            print("     A %s" % ta[p][:32])
            print("     B %s" % tb[p][:32])
        if len(differ) > 60:
            print("  ... and %d more" % (len(differ) - 60))

    total = len(only_a) + len(only_b) + len(differ)
    print()
    if total == 0:
        print("IDENTICAL: the two trees match byte for byte.")
        return 0
    print("NOT IDENTICAL: %d path(s) differ (%d A-only, %d B-only, %d changed)."
          % (total, len(only_a), len(only_b), len(differ)))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
