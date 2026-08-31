#!/usr/bin/env python3
# tools/manifest-shipped.py -- WHAT ACTUALLY SHIPS, AND HOW IT DIFFERS FROM
# WHAT THE RUNGS RECORDED.
#
# THE PROBLEM THIS EXISTS FOR. Phase B's rung B8 writes /out/manifest.tsv as
# the sysroot stands at the end of B8. phase_pack then copies that file into
# rel/ VERBATIM -- but between B8 and the copy it has run sysroot-trim.sh,
# which deletes whole trees and, more quietly, runs `strip --strip-debug`
# over three dozen executables. Stripping REWRITES BYTES. So the manifest
# shipped beside sysroot.tar.zst described a tree that no longer existed:
# measured on the 2026-08-30 amd64 artifact, 850 of its 10,414 entries named
# files that had been deleted and 46 more carried the pre-strip hash of a
# file that ships with different bytes -- /usr/bin/gcc recorded at 12,570,128
# bytes and 838f834b..., shipping at 2,414,296 bytes and 261439961f....
#
# Nobody was lied to on purpose; the manifest was simply taken at the wrong
# seam. A manifest that does not describe the artifact beside it cannot be
# used to verify that artifact, which is the only thing it is for.
#
# WHAT THIS WRITES. Two files, and the distinction is the point:
#
#   manifest-b8.tsv   what phase B built, before the trim. The record of the
#                     BUILD -- what the ladder produced, including the things
#                     deliberately dropped afterwards.
#   manifest.tsv      what is inside sysroot.tar.zst, hashed after the trim.
#                     The record of the ARTIFACT. This is what a verifier
#                     checks against.
#
# and a reconciliation showing every path where the two disagree, so the
# trim's effect is stated rather than inferred from a size drop.
#
#   usage: manifest-shipped.py TREE B8-MANIFEST OUT-MANIFEST [RECONCILE-LOG]
#
# Dependency-free python, run by the sysroot's own interpreter like every
# other packing step.
import hashlib
import os
import sys


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk_tree(root):
    """Every regular file, by path relative to the tree root, absolute-style.

    SYMLINKS ARE NOT HASHED and not listed. A symlink has no content of its
    own; tar records its target and the target is listed in its own right.
    Following them would double-count and, for the /bin -> usr/bin pair at
    the sysroot root, would count the entire tree twice.
    """
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            if os.path.islink(full):
                continue
            rel = "/" + os.path.relpath(full, root)
            try:
                out[rel] = (os.path.getsize(full), sha_file(full))
            except OSError as e:
                out[rel] = (-1, "UNREADABLE:%s" % e.errno)
    return out


def read_b8(path):
    """The B8 manifest, keyed by path. Columns: label, path, size, sha256.

    Non-B8 labels (IN, OUT.*, SEED) record inputs and intermediate outputs
    rather than sysroot contents and are carried through untouched.
    """
    ship, other = {}, []
    try:
        fh = open(path)
    except OSError:
        return ship, other
    with fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 4 and parts[0] == "B8":
                ship[parts[1]] = (int(parts[2]), parts[3])
            elif line.strip():
                other.append(line.rstrip("\n"))
    return ship, other


def main(tree, b8_path, out_path, log_path=None):
    shipped = walk_tree(tree)
    before, _ = read_b8(b8_path)

    with open(out_path, "w") as f:
        for p in sorted(shipped):
            size, sha = shipped[p]
            f.write("SHIP\t%s\t%d\t%s\n" % (p, size, sha))

    removed = sorted(set(before) - set(shipped))
    added = sorted(set(shipped) - set(before))
    rewritten = sorted(
        p for p in set(before) & set(shipped) if before[p][1] != shipped[p][1]
    )

    lines = []
    w = lines.append
    w("MANIFEST RECONCILIATION -- what B8 built vs what ships")
    w("  tree              : %s" % tree)
    w("  B8 entries        : %d" % len(before))
    w("  shipped files     : %d" % len(shipped))
    w("")
    w("  removed by trim   : %d" % len(removed))
    w("  rewritten by strip: %d" % len(rewritten))
    w("  in tree, never in B8: %d" % len(added))
    w("")

    # THE UNMANIFESTED FILES ARE LISTED IN FULL AND THE OTHERS ARE NOT.
    # "Removed by trim" is hundreds of paths and trim.txt already names the
    # trees they came from. A file that is in the artifact and was never
    # recorded by any rung is a different thing: it is content nobody
    # declared, and there should be few enough to read.
    if added:
        w("  --- IN THE ARTIFACT, RECORDED BY NO RUNG ---")
        w("  Each of these is either a build-time side effect (a cache, a")
        w("  marker) or something a rung created without hashing it. Neither")
        w("  is automatically wrong; both should be deliberate.")
        for p in added:
            size, sha = shipped[p]
            w("    %-52s %10d  %s" % (p, size, sha[:16]))
        w("")
    if rewritten:
        w("  --- REWRITTEN AFTER B8 (the strip pass) ---")
        for p in rewritten:
            w("    %s" % p)
            w("        B8   %10d  %s" % (before[p][0], before[p][1][:16]))
            w("        ship %10d  %s" % (shipped[p][0], shipped[p][1][:16]))
        w("")
    w("  manifest.tsv now describes the artifact; manifest-b8.tsv keeps the")
    w("  pre-trim record of what the ladder built.")

    text = "\n".join(lines) + "\n"
    sys.stdout.write(text)
    if log_path:
        with open(log_path, "w") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: manifest-shipped.py TREE B8-MANIFEST OUT-MANIFEST [LOG]\n"
        )
        raise SystemExit(2)
    raise SystemExit(main(*sys.argv[1:5]))
