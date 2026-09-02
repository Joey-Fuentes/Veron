#!/bin/sh
# tools/pack-in-box.sh -- run tools/pack.py INSIDE a box rooted at one of
# this project's own systems, so the tar is written by our python and the
# compression by our zstd, on every host.
#
#     sh tools/pack-in-box.sh SYSROOT OUT.tar.zst [-l LEVEL] [--record FILE] DIR
#     sh tools/pack-in-box.sh SYSROOT OUT.tar.zst [-l LEVEL] [--record FILE] -f FILE...
#
# SYSROOT is a directory with /usr/bin/python3 (the stage-4 sysroot, the
# stage-5 system). zstd comes from, in order: $VERON_TOOLS, ./veron-tools/
# (the bundle), /usr/bin/zstd on a Veron image; whichever is found is bound
# into the box as /veron-tools/zstd and pack.py records its hash. A foreign
# zstd (apt's, on a runner whose bundle predates the static CLI) is used and
# recorded as such -- the tar bytes still match, the .zst bytes will once
# the bundle carries ours.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
SYS="$1"; OUT="$2"; shift 2
Z=""
ZPROV=""
# THE zstd THIS BUILD MADE COMES FIRST. dest/zstd is a sibling of the sysroot
# being packed, present on both legs after chain, and static (the publish
# step's static_or_die checks exactly this binary before bundling it). The
# bundle is that same binary from an EARLIER run; the runner has none until
# publish creates one, so every CI pack fell through to /usr/bin/zstd --
# Ubuntu's -- while a laptop with a bundle from fetch-tools used ours.
# PACKED-BY said so in its own words: "(system, ...)" on one leg,
# "(veron-tools bundle, ...)" on the other, same tar hash, different archive.
# Same defect and same fix as mke2fs: the tool that lays the artifact is the
# one this build produced, and the record names it.
#
# stage 4 packs its lfs tree through this script too; it has no dest/zstd
# sibling and falls through to the bundle exactly as before.
_built="$(dirname "$SYS")/dest/zstd/usr/bin/zstd"
for c in "$_built" "${VERON_TOOLS:-/nonexistent}/zstd" "$ROOT/veron-tools/zstd" /usr/bin/zstd; do
  [ -x "$c" ] || continue; Z="$c"
  case "$c" in
    "$_built")               ZPROV="built (dest/zstd)";;
    "$ROOT/veron-tools/"*)   ZPROV="veron-tools bundle";;
    /usr/bin/*)              ZPROV="system";;
    *)                       ZPROV="VERON_TOOLS";;
  esac; break
done
[ -n "$Z" ] || { echo "pack-in-box: no zstd (VERON_TOOLS, veron-tools/, /usr/bin)"; exit 1; }
ZD="$(mktemp -d "$ROOT/box-pack.XXXXXX")"; cp "$Z" "$ZD/zstd"; chmod 755 "$ZD/zstd"
OUTDIR="$(cd "$(dirname "$OUT")" && pwd)"; OUTNAME="$(basename "$OUT")"
# THE ROOT IS READ-ONLY, so every mountpoint lives under the /tmp tmpfs:
# /tmp/v/in/N (inputs; a -f file keeps its basename, which pack.py uses as
# the member name), /tmp/v/out, /tmp/v/pack.py.
#
# TAR IN THE BOX, ZSTD ON THE HOST. The tar is what must be ours (python's
# tarfile on the sysroot's python: same bytes on every host). The zstd runs
# outside the box because a dynamically linked one -- apt's, on a runner
# without the bundle -- cannot exec inside a box rooted at our sysroot
# (CI, 2026-08-27: "No such file or directory: /tmp/v/tools/zstd", the
# loader, not the file). Which zstd it was is recorded either way.
opts=""; ins=""; binds=""; n=0; files=0; level=19; record=""
while [ $# -gt 0 ]; do
  case "$1" in
    -l) level="$2"; shift 2 ;;
    -f) opts="$opts -f"; files=1; shift ;;
    --record) record="$(readlink -f "$2" 2>/dev/null || printf '%s' "$2")"; shift 2 ;;
    *) n=$((n+1)); p="$(readlink -f "$1")"
       if [ "$files" = 1 ]; then b="/tmp/v/in/$n/$(basename "$p")"; else b="/tmp/v/in/$n"; fi
       binds="$binds --ro-bind $p $b"; ins="$ins $b"; shift ;;
  esac
done
TARNAME="${OUTNAME%.zst}"
# shellcheck disable=SC2086
if ! bwrap --unshare-all --die-with-parent \
  --ro-bind "$SYS" / --proc /proc --dev /dev --tmpfs /tmp --dir /tmp/v --dir /tmp/v/in \
  --ro-bind "$ROOT/tools/pack.py" /tmp/v/pack.py \
  --bind "$OUTDIR" /tmp/v/out $binds \
  --setenv PATH /usr/bin:/usr/sbin --setenv TZ UTC --setenv LC_ALL C \
  /usr/bin/python3 /tmp/v/pack.py --tar-only $opts "/tmp/v/out/$TARNAME" $ins > "$ZD/tar.line"; then
  rm -rf "$ZD"; echo "pack-in-box: tar failed"; exit 1
fi
"$ZD/zstd" -"$level" -T0 -q --no-progress -f -o "$OUTDIR/$OUTNAME" "$OUTDIR/$TARNAME" || { rm -rf "$ZD"; echo "pack-in-box: zstd failed"; exit 1; }
rm -f "$OUTDIR/$TARNAME"
tsha=$(cut -d' ' -f2 "$ZD/tar.line"); zsha=$(sha256sum "$ZD/zstd" | cut -d' ' -f1); osha=$(sha256sum "$OUTDIR/$OUTNAME" | cut -d' ' -f1)
line="packed-by  tar $tsha  zstd-binary $zsha ($ZPROV, level $level, -T0)  archive $osha  $OUTNAME"
echo "$line"; [ -n "$record" ] && { mkdir -p "$(dirname "$record")"; echo "$line" >> "$record"; }
rm -rf "$ZD"
