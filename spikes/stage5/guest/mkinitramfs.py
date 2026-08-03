#!/usr/bin/env python3
# mkinitramfs.py -- stage 5's boot archive.
#
# Two files: a statically linked busybox lifted from the sysroot, and
# guest/init. Nothing else -- no loader, no libc, nothing that has to stay in
# step with the sysroot.
#
# WHY THIS WRITES newc ITSELF instead of piping to cpio(1). The shell version
# did `find | sort | cpio -o -H newc 2>/dev/null | gzip`, and on a machine
# with no cpio that produced a 20-BYTE ARCHIVE and reported success -- the
# redirect swallowed "cpio: not found" and gzip happily compressed nothing.
# A silently empty initramfs boots to a kernel panic three steps later, which
# is a terrible place to learn about a missing host tool.
#
# newc is a fixed 110-byte ASCII header plus padding. Writing it here removes
# a host dependency, makes determinism explicit rather than dependent on which
# cpio is installed, and is testable anywhere Python runs.
#
# DETERMINISM, every knob explicit because each default varies:
#   sorted member order    a raw directory walk is readdir order, which is
#                          filesystem state rather than content
#   mtime 0                the header records it
#   uid/gid 0              no name lookup, no host user leaking in
#   gzip mtime 0           gzip stores a timestamp unless told not to

import gzip
import os
import shutil
import stat
import subprocess
import sys

MAGIC = b"070701"
TRAILER = "TRAILER!!!"


def header(ino, mode, nlink, size, namesize, dev=0, rdev=0):
    # 13 fields, 8 hex digits each, after the 6-byte magic.
    f = [ino, mode, 0, 0, nlink, 0, size, 0, 0, dev, rdev, namesize, 0]
    return MAGIC + b"".join(b"%08X" % v for v in f)


def pad4(n):
    return (4 - (n % 4)) % 4


def add(out, path, arcname, ino):
    st = os.lstat(path)
    mode = st.st_mode
    data = b""
    if stat.S_ISREG(mode):
        with open(path, "rb") as fh:
            data = fh.read()
    elif stat.S_ISLNK(mode):
        data = os.readlink(path).encode()

    name = arcname.encode() + b"\0"
    out.write(header(ino, mode, 1, len(data), len(name)))
    out.write(name)
    out.write(b"\0" * pad4(110 + len(name)))
    if data:
        out.write(data)
        out.write(b"\0" * pad4(len(data)))


def build(sysroot, outpath):
    here = os.path.dirname(os.path.abspath(__file__))
    bb = os.path.join(sysroot, "usr", "bin", "busybox")
    if not os.path.isfile(bb):
        sys.exit(f"no busybox at {bb}")

    # STATIC OR NOTHING. A dynamic busybox needs the loader and libc in here
    # too, and then this archive has to track the sysroot's glibc. Check
    # rather than assume -- this is exactly the sort of thing that changes.
    try:
        out = subprocess.run(["readelf", "-l", bb], capture_output=True, text=True)
        if "INTERP" in out.stdout:
            sys.exit("busybox is DYNAMIC -- this initramfs would not run. "
                     "Add the loader and libc, or build busybox static.")
    except FileNotFoundError:
        print("  (readelf absent -- could not confirm busybox is static)")

    staging = outpath + ".d"
    shutil.rmtree(staging, ignore_errors=True)
    for d in ("bin", "proc", "sys", "dev", "mnt/root"):
        os.makedirs(os.path.join(staging, d), exist_ok=True)
    shutil.copy2(bb, os.path.join(staging, "bin", "busybox"))
    shutil.copy2(os.path.join(here, "init"), os.path.join(staging, "init"))
    os.chmod(os.path.join(staging, "init"), 0o755)
    os.chmod(os.path.join(staging, "bin", "busybox"), 0o755)

    entries = []
    for root, dirs, files in os.walk(staging):
        dirs.sort()
        for n in sorted(dirs) + sorted(files):
            p = os.path.join(root, n)
            entries.append((os.path.relpath(p, staging), p))
    entries.sort()

    raw = outpath + ".cpio"
    with open(raw, "wb") as out:
        for i, (arc, p) in enumerate(entries, start=1):
            add(out, p, arc, i)
        name = TRAILER.encode() + b"\0"
        out.write(header(0, 0, 1, 0, len(name)))
        out.write(name)
        out.write(b"\0" * pad4(110 + len(name)))

    # mtime=0 so the gzip header carries no timestamp.
    with open(raw, "rb") as fi, open(outpath, "wb") as fo:
        # filename="" AND mtime=0. GzipFile otherwise stores fileobj.name in
        # the header, so two archives with identical contents differed purely
        # because they were written to different paths -- which is the FNAME
        # field, the exact thing `gzip -n` suppresses.
        with gzip.GzipFile(filename="", fileobj=fo, mode="wb",
                           compresslevel=9, mtime=0) as gz:
            shutil.copyfileobj(fi, gz)
    os.remove(raw)
    shutil.rmtree(staging, ignore_errors=True)

    size = os.path.getsize(outpath)
    # A REAL SIZE CHECK. The whole reason this file exists is that the shell
    # version emitted 20 bytes and called it success.
    if size < 4096:
        sys.exit(f"initramfs is only {size} bytes -- something went wrong")
    import hashlib
    h = hashlib.sha256(open(outpath, "rb").read()).hexdigest()
    print(f"  {outpath}  {size} bytes")
    print(f"    {h}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: mkinitramfs.py <sysroot> <out.cpio.gz>")
    build(sys.argv[1], sys.argv[2])
