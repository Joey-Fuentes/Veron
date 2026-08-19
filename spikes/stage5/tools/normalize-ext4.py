#!/usr/bin/env python3
# normalize-ext4.py -- make an ext4 image byte-reproducible.
#
# THE PROBLEM, in the order it was uncovered.
#
# 1. Two images built seconds apart differed at cmp -l positions 1073, 1089,
#    1289 and 2045-2048: superblock +48 s_wtime, +64 s_lastcheck,
#    +264 s_mkfs_time, +1020 s_checksum -- plus inode ctimes.
#
# 2. SOURCE_DATE_EPOCH DOES NOT FIX THIS. That was the first guess and it was
#    wrong: reproduced against mke2fs 1.47.0 with the variable exported and
#    the same offsets still differed.
#
# 3. A debugfs `ssv` pass fixed it on a small image and NOT on a real one,
#    for two reasons that only appear at scale:
#
#      a. BACKUP SUPERBLOCKS. A 600 MB filesystem has copies at blocks 32768
#         and 98304; `ssv` writes only the primary. The remaining diffs sat
#         at 134217777 = 32768*4096 + 49, which is s_wtime in the first
#         backup.
#      b. DEBUGFS RE-STAMPS s_wtime ON CLOSE. Setting wtime and then running
#         the inode pass in a second session re-dirtied the field that had
#         just been set. Ordering matters: inodes FIRST, superblocks LAST.
#
# 4. Keeping metadata_csum would mean recomputing s_checksum (crc32c over the
#    first 1020 bytes). e2fsck cannot do it for us -- it stamps its own
#    timestamps while repairing, so it never converges. Rather than ship an
#    unverified checksum implementation, metadata_csum is DISABLED at mkfs
#    time and declared. That is consistent with has_journal, dir_index and
#    resize_inode already being off for the same reason, and it is a real
#    tradeoff rather than a free one: the image loses metadata checksumming.
#    Re-enabling it needs a correct crc32c and is worth doing later.

import os
import re
import struct
import subprocess
import sys
import os
def _veron_tool(name):
    """Prefer the built e2fsprogs tool (ruled 2026-08-18) when the image
    build points us at the staged rootfs; else fall back to PATH."""
    r = os.environ.get("VERON_ROOTFS", "")
    if r:
        cand = os.path.join(r, "usr/sbin", name)
        if os.path.exists(cand):
            return cand
    return name

SB_OFFSET = 1024
# s_mtime, s_wtime, s_lastcheck, s_mkfs_time
TIME_FIELDS = (0x2C, 0x30, 0x40, 0x108)


def tool(name):
    for p in (f"/usr/sbin/{name}", f"/sbin/{name}", name):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    sys.exit(f"normalize-ext4: {name} not found")


def sha(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def main(img, ts_epoch=946684800, ts_str="20000101000000"):
    debugfs, dumpe2fs = tool(_veron_tool("debugfs")), tool("dumpe2fs")
    before = sha(img)

    info = subprocess.run([dumpe2fs, img], capture_output=True, text=True).stdout
    m = re.search(r"^Block size:\s+(\d+)", info, re.M)
    n = re.search(r"^Inode count:\s+(\d+)", info, re.M)
    if not m or not n:
        sys.exit("normalize-ext4: could not read the geometry")
    bs, inodes = int(m.group(1)), int(n.group(1))

    if "metadata_csum" in info:
        print("  WARNING: metadata_csum is enabled. Patching the superblock")
        print("  will invalidate s_checksum. Build with -O ^metadata_csum.")

    # 1. INODES FIRST. mke2fs -d stamps ctime/atime/mtime/crtime with wall
    #    clock as it copies the tree. This must precede the superblock patch,
    #    because debugfs updates s_wtime when it closes a write session.
    cmds = "".join(
        f"sif <{i}> ctime {ts_str}\nsif <{i}> atime {ts_str}\n"
        f"sif <{i}> mtime {ts_str}\nsif <{i}> crtime {ts_str}\n"
        for i in range(1, inodes + 1))
    p = subprocess.run([debugfs, "-w", "-f", "/dev/stdin", img],
                       input=cmds, capture_output=True, text=True)
    if p.returncode != 0:
        print(f"  debugfs inode pass rc={p.returncode}")

    # 2. SUPERBLOCKS LAST, ALL COPIES, WRITTEN DIRECTLY. `ssv` only reaches
    #    the primary, and going through debugfs would re-stamp s_wtime again.
    locs = [SB_OFFSET] + [int(b) * bs
                          for b in re.findall(r"Backup superblock at (\d+)", info)]
    with open(img, "r+b") as f:
        for base in locs:
            for off in TIME_FIELDS:
                f.seek(base + off)
                f.write(struct.pack("<I", ts_epoch))

    after = sha(img)
    print(f"  normalize-ext4: {inodes} inodes, {len(locs)} superblock copies")
    print(f"    before {before}")
    print(f"    after  {after}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: normalize-ext4.py <image>")
    main(sys.argv[1])
