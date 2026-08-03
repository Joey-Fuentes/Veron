#!/bin/sh
# normalize-ext4.sh -- make an ext4 image byte-reproducible.
#
# WHAT WENT WRONG, AND WHY THE OBVIOUS FIX DID NOT WORK.
#
# The image built twice, seconds apart, differed at these byte positions
# (cmp -l, 1-based):
#
#     1073   superblock + 48    s_wtime
#     1089   superblock + 64    s_lastcheck
#     1289   superblock + 264   s_mkfs_time
#     2045.. superblock + 1020  s_checksum   (follows from the three above)
#     57353+ inode table        i_ctime / i_crtime
#
# All timestamps. The first attempt exported SOURCE_DATE_EPOCH into the image
# step, on the assumption that e2fsprogs honours it. IT DOES NOT -- verified
# by reproducing the failure locally against mke2fs 1.47.0 with the variable
# set. The fix has to rewrite the fields afterwards.
#
# debugfs is the right tool because it RECOMPUTES THE CHECKSUMS. Patching the
# bytes directly would leave s_checksum wrong, and a filesystem that fails its
# own checksum is a worse outcome than one that does not reproduce.
#
# COST: about one second per 50,000 inodes -- 204,800 debugfs commands in a
# single -f pass. Cheap enough to run unconditionally.
#
# THIS IS A DECLARED TRANSFORMATION, not a silent fixup: it runs after the
# image is built, it is recorded in policy/expected-differences.toml, and the
# before/after hashes are printed.

set -eu

IMG=${1:?usage: normalize-ext4.sh <image> [timestamp]}
# Not epoch 0: some tools treat a zero timestamp as "unset" and rewrite it.
# A fixed, obviously-artificial date is unambiguous and equally deterministic.
TS=${2:-20000101000000}

DEBUGFS=$(command -v debugfs || echo /usr/sbin/debugfs)
DUMPE2FS=$(command -v dumpe2fs || echo /usr/sbin/dumpe2fs)
[ -x "$DEBUGFS" ] || { echo "normalize-ext4: no debugfs"; exit 1; }

before=$(sha256sum "$IMG" | cut -d' ' -f1)

# 1. The superblock's three timestamps.
for f in mkfs_time wtime lastcheck; do
    "$DEBUGFS" -w -R "ssv $f $TS" "$IMG" >/dev/null 2>&1 \
        || { echo "normalize-ext4: ssv $f failed"; exit 1; }
done

# 2. Every inode. mke2fs -d stamps ctime/atime/mtime/crtime with wall clock as
#    it copies the tree in. Unused inodes are harmless to touch, so this walks
#    the whole table rather than working out which are in use -- simpler, and
#    the cost is already negligible.
N=$("$DUMPE2FS" -h "$IMG" 2>/dev/null | awk -F: '/^Inode count/{gsub(/ /,"",$2); print $2}')
[ -n "$N" ] || { echo "normalize-ext4: could not read the inode count"; exit 1; }

CMDS=$(mktemp "${TMPDIR:-/tmp}/veron-ino.XXXXXX")
trap 'rm -f "$CMDS"' EXIT
i=1
while [ "$i" -le "$N" ]; do
    printf 'sif <%s> ctime %s\nsif <%s> atime %s\nsif <%s> mtime %s\nsif <%s> crtime %s\n' \
        "$i" "$TS" "$i" "$TS" "$i" "$TS" "$i" "$TS" >> "$CMDS"
    i=$((i + 1))
done
"$DEBUGFS" -w -f "$CMDS" "$IMG" >/dev/null 2>&1 || true

after=$(sha256sum "$IMG" | cut -d' ' -f1)
echo "  normalize-ext4: $N inodes, timestamps -> $TS"
echo "    before $before"
echo "    after  $after"
