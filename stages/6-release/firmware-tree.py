#!/usr/bin/env python3
# stages/6-release/firmware-tree.py -- the linux-firmware tree, laid out from
# WHENCE: every "File:" copied, every "Link: a -> b" made a symlink.
#
#     firmware-tree.py SRC DST
#
# This is what linux-firmware's `make install` (copy-firmware.sh) does,
# without the shell script: that script computes link targets with GNU
# `realpath -m -s`, which the released system's busybox realpath does not
# have -- four thousand "realpath: -m: No such file" lines on the first
# in-box run (2026-08-27) and a tree whose links were not checked. WHENCE
# is the manifest; reading it is a pure function of the bytes, and the
# result is counted and verified: every File exists, every Link resolves.
import os, shutil, sys

src, dst = sys.argv[1:3]
whence = os.path.join(src, "WHENCE")
files, links = [], []
for raw in open(whence, encoding="utf-8", errors="surrogateescape"):
    line = raw.rstrip("\n")
    for key in ("RawFile:", "File:"):
        if line.startswith(key):
            files.append(line[len(key):].strip().strip('"')); break
    else:
        if line.startswith("Link:"):
            rest = line[5:].strip()
            if "->" in rest:
                a, b = rest.split("->", 1)
                links.append((a.strip().strip('"'), b.strip().strip('"')))
os.makedirs(dst, exist_ok=True)
missing = []
for f in sorted(set(files)):
    s = os.path.join(src, f)
    if not os.path.isfile(s):
        missing.append(f); continue
    d = os.path.join(dst, f)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copyfile(s, d); os.chmod(d, 0o644)
broken = []
for a, b in sorted(set(links)):
    d = os.path.join(dst, a)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    if os.path.lexists(d): os.remove(d)
    os.symlink(b, d)
    if not os.path.exists(d): broken.append((a, b))
for extra in ("WHENCE", "WHENCE.ubuntu"):
    p = os.path.join(src, extra)
    if os.path.isfile(p): shutil.copyfile(p, os.path.join(dst, extra))
for e in sorted(os.listdir(src)):
    if e.startswith(("LICEN", "GPL")) or e == "LICENSES":
        s, d = os.path.join(src, e), os.path.join(dst, e)
        shutil.copytree(s, d, dirs_exist_ok=True) if os.path.isdir(s) else shutil.copyfile(s, d)
print(f"  firmware tree: {len(set(files))} files, {len(set(links))} links from WHENCE"
      f"{'; MISSING files: ' + str(len(missing)) if missing else ''}{'; BROKEN links: ' + str(len(broken)) if broken else ''}")
for m in missing[:10]: print("    missing:", m)
for a, b in broken[:10]: print("    broken:", a, "->", b)
if missing or broken:
    sys.exit(1)
