#!/bin/sh
# tools/mkimage-in-box.sh -- an ext4 image of a system, made BY that system:
# its own python writes a sorted, uid-0 tar of itself, its own mke2fs
# (e2fsprogs >= 1.47.1, which takes a tar as -d input) lays the filesystem
# out in the tar's order, its own debugfs normalises the timestamps.
#
#     sh tools/mkimage-in-box.sh SYSROOT OUT.img SIZE_MB
#
# WHY, 2026-08-27: two CI runs published two different images from a system
# whose 15,455 files were byte-identical (files.tsv 769856ba... both times).
# `mke2fs -d DIR` on the host walked the tree in the host filesystem's
# readdir order -- the volume's hash seed, different on every VM -- and
# recorded each file's owner as the uid that built it (runner on CI, veron
# on a laptop). And /sbin/mke2fs was the HOST's e2fsprogs: 1.47.0 on the
# runner, 1.47.4 on the image. A tar fixes the order and the ownership; the
# box fixes the tool. UUID, hash_seed, feature set and the normaliser are
# unchanged from build_img in stages/5-user-space/build.sh.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
SYS="$(readlink -f "$1")"; OUT="$2"; SZ="$3"
OUTDIR="$(cd "$(dirname "$OUT")" && pwd)"; OUTNAME="$(basename "$OUT")"
rm -f "$OUTDIR/$OUTNAME" "$OUTDIR/$OUTNAME.tar"
bwrap --unshare-all --die-with-parent \
  --ro-bind "$SYS" / --proc /proc --dev /dev --tmpfs /tmp --dir /tmp/v \
  --ro-bind "$ROOT/tools/pack.py" /tmp/v/pack.py \
  --ro-bind "$ROOT/spikes/stage5/tools/normalize-ext4.py" /tmp/v/normalize-ext4.py \
  --ro-bind "$SYS" /tmp/v/sys --bind "$OUTDIR" /tmp/v/out \
  --setenv PATH /usr/bin:/usr/sbin --setenv TZ UTC --setenv LC_ALL C \
  /usr/bin/sh -c '
    set -e
    /usr/bin/python3 /tmp/v/pack.py --tar-only --exclude var/cache/fontconfig "/tmp/v/out/'"$OUTNAME"'.tar" /tmp/v/sys
    /usr/sbin/mke2fs -q -t ext4 -d "/tmp/v/out/'"$OUTNAME"'.tar" \
      -U 00000000-0000-4000-8000-000000000001 \
      -E hash_seed=00000000-0000-4000-8000-000000000002 \
      -O ^has_journal,^resize_inode,^dir_index,^metadata_csum \
      -m 0 -b 4096 "/tmp/v/out/'"$OUTNAME"'" "'"$SZ"'M"
    rm -f "/tmp/v/out/'"$OUTNAME"'.tar"
    /usr/bin/python3 /tmp/v/normalize-ext4.py "/tmp/v/out/'"$OUTNAME"'"
    echo "  image: made in the box by $(mke2fs -V 2>&1 | head -1)"'
