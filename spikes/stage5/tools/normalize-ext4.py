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
#
# 5. OWNERSHIP IS THE BUILDER'S UID, AND IT REACHED EVERY INODE.
#    `mke2fs -d` copies the tree with whatever uid/gid the build user
#    happens to have -- 1000 on the laptop, 1001 on the CI runner. Every
#    inode in the image then differs. G3 measured it on 2026-08-30: two
#    images of provably identical trees (15,632 of 15,634 files equal by
#    manifest, the two exceptions explained) differing in 310,832,411
#    bytes, first diffs at 1037/1041 -- s_free_blocks_count and
#    s_free_inodes_count -- then the group descriptors, then a third of
#    the data area. The per-file manifest cannot see this: files.tsv
#    records mode, not owner.
#
#    0/0 IS THE CORRECT VALUE, NOT MERELY A DETERMINISTIC ONE. A root
#    filesystem is root-owned, and the sibling `veron rootfs` tar has
#    always written uid/gid 0 explicitly for exactly this reason -- the
#    image path simply never got the same treatment. Shipping the
#    builder's uid was a defect in its own right, not only a
#    reproducibility one: in a laptop-built image the unprivileged
#    desktop user (uid 1000) owned /usr, and could rewrite the system's
#    own binaries.
#
#    WHAT MUST NOT BE ROOT IS SET AT BOOT, BY DESIGN AND BY NECESSITY.
#    The build runs unprivileged, so chown at build time is impossible --
#    dinit.d/scripts/chrony-start says so in its own comment, having
#    tried it -- and dinit.d/scripts/device-nodes chowns /home/veron,
#    /run/labwc.log and /persist when the system starts. Normalising
#    every inode here therefore removes nothing the running system needs.

import os
import re
import struct
import subprocess
import sys
import os
def _veron_tool(name):
    """The BUILT e2fsprogs tool (ruled 2026-08-18), returned as an argv
    PREFIX. The built binaries are dynamic for the Veron sysroot, so a CI
    host are STATIC (recipe: no --enable-elf-shlibs), so they run directly here
    and on Veron alike -- one path, no loader. When VERON_ROOTFS is set we
    use the built tool; else the host one. Returned as an argv prefix that
    callers splice in.
    """
    r = os.environ.get("VERON_ROOTFS", "")
    if r:
        cand = os.path.join(r, "usr/sbin", name)
        if os.path.exists(cand):
            return [cand]   # static binary: runs directly, like on Veron
    return [tool(name)]     # host fallback keeps the /usr/sbin resolution

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
    debugfs, dumpe2fs = _veron_tool("debugfs"), _veron_tool("dumpe2fs")
    before = sha(img)

    info = subprocess.run([*dumpe2fs, img], capture_output=True, text=True).stdout
    m = re.search(r"^Block size:\s+(\d+)", info, re.M)
    n = re.search(r"^Inode count:\s+(\d+)", info, re.M)
    if not m or not n:
        sys.exit("normalize-ext4: could not read the geometry")
    bs, inodes = int(m.group(1)), int(n.group(1))

    if "metadata_csum" in info:
        print("  WARNING: metadata_csum is enabled. Patching the superblock")
        print("  will invalidate s_checksum. Build with -O ^metadata_csum.")

    # 1. INODES FIRST. mke2fs -d stamps ctime/atime/mtime/crtime with wall
    #    clock as it copies the tree, and copies the build user's uid/gid
    #    onto every path. This must precede the superblock patch, because
    #    debugfs updates s_wtime when it closes a write session.
    #
    #    uid/gid ARE SET IN THE SAME PASS AND NOT A SECOND ONE, for the
    #    ordering reason above: a separate session would re-dirty s_wtime
    #    after the superblock had been fixed. Reserved and unallocated
    #    inodes are included exactly as they already are for the times --
    #    their fields are zero, so writing zero is a no-op.
    cmds = "".join(
        f"sif <{i}> ctime {ts_str}\nsif <{i}> atime {ts_str}\n"
        f"sif <{i}> mtime {ts_str}\nsif <{i}> crtime {ts_str}\n"
        f"sif <{i}> uid 0\nsif <{i}> gid 0\n"
        for i in range(1, inodes + 1))
    p = subprocess.run([*debugfs, "-w", "-f", "/dev/stdin", img],
                       input=cmds, capture_output=True, text=True)
    if p.returncode != 0:
        # A FAILED NORMALISATION IS FATAL, AND IT SAYS WHY.
        #
        # This printed the return code and CARRIED ON. The built static
        # debugfs aborted (rc=-6, SIGABRT) on the GitHub runner on two runs
        # in a row; its stderr -- the one line that would have named the
        # cause -- was captured here and discarded, and an image whose
        # inodes were never normalised was built, hashed and compared as if
        # the pass had run. Two consecutive builds on the same runner then
        # disagreed by 67,867 bytes and VERON-IMAGE-REPRO-DIFF fired for the
        # first time ever, one layer away from where the fault was.
        #
        # A normaliser that did not normalise has no image to hand back.
        sig = -p.returncode if p.returncode < 0 else None
        print(f"  debugfs inode pass FAILED rc={p.returncode}"
              + (f" (killed by signal {sig})" if sig else ""))
        print(f"  debugfs: {debugfs[0]}")
        err = (p.stderr or "").strip().splitlines()
        out = (p.stdout or "").strip().splitlines()
        print("  --- stderr (%d line(s), last 20) ---" % len(err))
        for ln in err[-20:]:
            print("    " + ln)
        print("  --- stdout (%d line(s), last 5) ---" % len(out))
        for ln in out[-5:]:
            print("    " + ln)
        sys.exit("normalize-ext4: inode pass did not complete -- refusing to "
                 "hand back an unnormalised image")

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
    print(f"  normalize-ext4: {inodes} inodes (times and uid/gid 0:0), "
          f"{len(locs)} superblock copies")
    print(f"    before {before}")
    print(f"    after  {after}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: normalize-ext4.py <image>")
    main(sys.argv[1])
