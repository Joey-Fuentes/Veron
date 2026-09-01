#!/usr/bin/env python3
# tools/img-diff-files.py -- DIFF NAMED FILES OUT OF TWO ext4 IMAGES.
#
# img-compare.py answers WHICH entries differ. It stops at metadata, so when
# two files have the same size and different bytes it says CONTENT and gives a
# pair of hashes -- which is where the useful part starts and the tool ends.
# This is the next step: pull the named paths out of both images and show what
# actually changed inside them.
#
# WHY NOT JUST MOUNT THE IMAGES. A loop mount needs root, and the laptops this
# runs on are the same ones that cannot run the release tooling. debugfs reads
# the filesystem directly, needs no privileges, and is already in veron-tools
# because normalize-ext4 depends on it.
#
# WHAT IT PRINTS. Small files get a full unified diff. Large ones get the
# differing-line count, a sample, and -- because a 3.7 MB records file with
# sixty differing lines is not readable as a diff -- a breakdown of those lines
# grouped by their leading path component, so a pattern in WHERE they differ
# shows up without reading them all. --grep narrows to lines matching a
# pattern; --exclude drops lines matching one, which is how you ask "is
# anything differing here NOT the thing I already know about".
#
#   usage:
#     img-diff-files.py A.img B.img PATH [PATH...]
#     img-diff-files.py A.img B.img --exclude __pycache__ PATH [PATH...]
#     img-diff-files.py A.img B.img --grep 'perl5' PATH
#     img-diff-files.py A.img B.img --keep /var/tmp/dumps PATH
#
# Paths are image-absolute with or without the leading slash. Set
# DEBUGFS=veron-tools/debugfs to choose the archiver-trusted binary.
import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

DEBUGFS = os.environ.get("DEBUGFS", "debugfs")
FULL_DIFF_BYTES = 64 * 1024


def dump(img, path, out):
    """Extract one file. debugfs exits 0 whether or not it found anything, so
    the only reliable check is whether a file appeared."""
    subprocess.run([DEBUGFS, "-R", "dump /%s %s" % (path.lstrip("/"), out), img],
                   capture_output=True, text=True)
    return os.path.exists(out) and os.path.getsize(out) >= 0


def read_lines(p):
    with open(p, "rb") as f:
        return f.read().decode("utf-8", "replace").splitlines(keepends=True)


def group_of(line):
    """The leading path-ish token of a record line, for grouping.

    THE PATH IS NOT ALWAYS THE FIRST FIELD. files.tsv leads with the path,
    packages.tsv leads with a type flag ('F'), and grouping on field 0 there
    reports every difference under 'F' -- true and useless. Take the first
    field that looks like a path instead, and only fall back to the first
    word when no field does.
    """
    fields = [f.strip() for f in line.strip().split("\t") if f.strip()]
    for f in fields:
        if "/" in f and not f.startswith(("sha256", "0x")):
            return "/".join(f.split("/")[:3])
    return (fields[0].split(" ")[0][:40] if fields else "-")


def compare_one(img_a, img_b, path, work, args):
    name = path.strip("/").replace("/", "_")
    a = os.path.join(work, "A_" + name)
    b = os.path.join(work, "B_" + name)
    ok_a, ok_b = dump(img_a, path, a), dump(img_b, path, b)

    print("=" * 72)
    print(path)
    if not ok_a and not ok_b:
        print("  absent from BOTH images"); return 0
    if not ok_a:
        print("  A: absent   B: %d bytes  -- present only in B" % os.path.getsize(b)); return 1
    if not ok_b:
        print("  A: %d bytes  B: absent   -- present only in A" % os.path.getsize(a)); return 1

    sa, sb = os.path.getsize(a), os.path.getsize(b)
    la, lb = read_lines(a), read_lines(b)
    print("  A: %d bytes, %d lines    B: %d bytes, %d lines" % (sa, len(la), sb, len(lb)))

    if args.grep:
        rx = re.compile(args.grep)
        la = [l for l in la if rx.search(l)]
        lb = [l for l in lb if rx.search(l)]
        print("  --grep %r: %d/%d lines" % (args.grep, len(la), len(lb)))

    diff = [l for l in difflib.unified_diff(la, lb, "A", "B", n=0)
            if l.startswith(("+", "-")) and not l.startswith(("+++", "---"))]

    if args.exclude:
        rx = re.compile(args.exclude)
        kept = [l for l in diff if not rx.search(l)]
        print("  differing lines: %d total, %d after --exclude %r"
              % (len(diff), len(kept), args.exclude))
        # THIS NUMBER IS THE POINT OF --exclude. Zero means every difference
        # here is the thing already known about, and this file needs no
        # separate explanation. Non-zero means there is a second cause.
        diff = kept
    else:
        print("  differing lines: %d" % len(diff))

    if not diff:
        print("  IDENTICAL" if sa == sb else "  no differing lines after filtering")
        return 0 if sa == sb else 1

    if max(sa, sb) <= FULL_DIFF_BYTES and not args.grep and not args.exclude:
        print()
        for l in difflib.unified_diff(la, lb, "A", "B", n=1):
            sys.stdout.write("  " + l if l.endswith("\n") else "  " + l + "\n")
    else:
        groups = Counter(group_of(l[1:]) for l in diff)
        print("\n  differing lines grouped by leading path:")
        for g, n in groups.most_common(15):
            print("    %-52s %d" % (g, n))
        print("\n  first %d:" % min(args.sample, len(diff)))
        for l in diff[:args.sample]:
            sys.stdout.write("    " + (l if l.endswith("\n") else l + "\n"))
    return 1


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("image_a"); ap.add_argument("image_b")
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--grep", help="only consider lines matching this regex")
    ap.add_argument("--exclude", help="ignore differing lines matching this regex")
    ap.add_argument("--sample", type=int, default=20, help="differing lines to show")
    ap.add_argument("--keep", help="keep the dumped files in this directory")
    a = ap.parse_args()

    if not shutil.which(DEBUGFS) and not os.path.exists(DEBUGFS):
        sys.stderr.write("debugfs not found -- set DEBUGFS=veron-tools/debugfs\n")
        return 2

    work = a.keep or tempfile.mkdtemp(prefix="imgdiff.")
    os.makedirs(work, exist_ok=True)
    rc = 0
    try:
        for p in a.paths:
            rc |= compare_one(a.image_a, a.image_b, p, work, a)
    finally:
        print("=" * 72)
        if a.keep:
            print("dumps kept in %s" % work)
        else:
            shutil.rmtree(work, ignore_errors=True)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
