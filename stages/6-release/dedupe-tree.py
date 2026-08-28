#!/usr/bin/env python3
# stages/6-release/dedupe-tree.py -- identical regular files (>= 4 KiB, same
# mode) become hardlinks, so one copy lands in the image. Sorted walk: the
# survivor is the first name in bytewise order, on every host.
import hashlib, os, sys
root = sys.argv[1]
seen = {}
relinked = saved = 0
for dirpath, dirs, files in sorted(os.walk(root)):
    dirs.sort()
    for f in sorted(files):
        p = os.path.join(dirpath, f)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        st = os.stat(p)
        if st.st_size < 4096:
            continue
        h = hashlib.sha256()
        with open(p, "rb") as fh:
            for c in iter(lambda: fh.read(1 << 20), b""):
                h.update(c)
        k = (h.hexdigest(), st.st_mode & 0o7777)
        if k in seen:
            os.unlink(p); os.link(seen[k], p)
            relinked += 1; saved += st.st_size
        else:
            seen[k] = p
print(f"  dedupe: {relinked} file(s) re-hardlinked, {saved // 1048576} MiB reclaimed")
