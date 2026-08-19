#!/usr/bin/env python3
# Log the identity of a file or a whole tree: path, mode, size, sha256 -- one
# line each, sorted, stable. Drop this at every input and output seam so two
# runs' logs can be diffed to find EXACTLY where they diverge. Dependency-free
# python (Veron-native). A tree is walked in sorted order so the output is
# byte-stable; a single file prints one line. For a tree it also prints a final
# TREE-SHA: the sha256 of the manifest itself, so one line proves whole-tree
# identity across runs.
import hashlib
import os
import stat
import sys


def sha_file(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return "UNREADABLE"
    return h.hexdigest()


def line(root, path):
    rel = os.path.relpath(path, root) if root else path
    try:
        st = os.lstat(path)
    except OSError:
        return "%s\tMISSING" % rel
    mode = stat.filemode(st.st_mode)
    if stat.S_ISLNK(st.st_mode):
        return "%s\t%s\t%d\tSYMLINK->%s" % (rel, mode, st.st_size,
                                            os.readlink(path))
    if stat.S_ISDIR(st.st_mode):
        return None
    return "%s\t%s\t%d\t%s" % (rel, mode, st.st_size, sha_file(path))


def main(argv):
    label = argv[0] if argv else "(manifest)"
    targets = argv[1:]
    print("MANIFEST: %s" % label)
    if not targets:
        print("  (no targets given)")
        return 0
    for t in targets:
        if not os.path.exists(t) and not os.path.islink(t):
            print("  %s\tDOES NOT EXIST" % t)
            continue
        if os.path.isdir(t):
            entries = []
            for dp, dns, fns in os.walk(t):
                dns.sort()
                for fn in sorted(fns):
                    ln = line(t, os.path.join(dp, fn))
                    if ln:
                        entries.append(ln)
            entries.sort()
            for e in entries:
                print("  " + e)
            tree_sha = hashlib.sha256("\n".join(entries).encode()).hexdigest()
            print("  TREE-SHA %s  %s  (%d files)" % (tree_sha, t, len(entries)))
        else:
            ln = line(os.path.dirname(t) or ".", t)
            if ln:
                print("  " + ln)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
