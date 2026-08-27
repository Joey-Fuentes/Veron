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
for c in "${VERON_TOOLS:-/nonexistent}/zstd" "$ROOT/veron-tools/zstd" /usr/bin/zstd; do [ -x "$c" ] && { Z="$c"; break; }; done
[ -n "$Z" ] || { echo "pack-in-box: no zstd (VERON_TOOLS, veron-tools/, /usr/bin)"; exit 1; }
ZD="$(mktemp -d "$ROOT/box-pack.XXXXXX")"; cp "$Z" "$ZD/zstd"; chmod 755 "$ZD/zstd"
OUTDIR="$(cd "$(dirname "$OUT")" && pwd)"; OUTNAME="$(basename "$OUT")"
# THE ROOT IS READ-ONLY, so every mountpoint lives under the /tmp tmpfs:
# /tmp/v/in/N (inputs; a -f file keeps its basename, which pack.py uses as
# the member name), /tmp/v/out, /tmp/v/rec, /tmp/v/tools/zstd, /tmp/v/pack.py.
opts=""; ins=""; binds=""; n=0; recbind=""; recopt=""; files=0
while [ $# -gt 0 ]; do
  case "$1" in
    -l) opts="$opts -l $2"; shift 2 ;;
    -f) opts="$opts -f"; files=1; shift ;;
    --record) r="$(readlink -f "$2" 2>/dev/null || printf '%s' "$2")"; mkdir -p "$(dirname "$r")"; touch "$r"
              recbind="--bind $(dirname "$r") /tmp/v/rec"; recopt="--record /tmp/v/rec/$(basename "$r")"; shift 2 ;;
    *) n=$((n+1)); p="$(readlink -f "$1")"
       if [ "$files" = 1 ]; then b="/tmp/v/in/$n/$(basename "$p")"; else b="/tmp/v/in/$n"; fi
       binds="$binds --ro-bind $p $b"; ins="$ins $b"; shift ;;
  esac
done
# shellcheck disable=SC2086
if ! bwrap --unshare-all --die-with-parent \
  --ro-bind "$SYS" / --proc /proc --dev /dev --tmpfs /tmp --dir /tmp/v --dir /tmp/v/in --dir /tmp/v/out \
  --ro-bind "$ROOT/tools/pack.py" /tmp/v/pack.py --ro-bind "$ZD" /tmp/v/tools \
  --bind "$OUTDIR" /tmp/v/out $recbind $binds \
  --setenv PATH /usr/bin:/usr/sbin --setenv TZ UTC --setenv LC_ALL C --setenv VERON_TOOLS /tmp/v/tools \
  /usr/bin/python3 /tmp/v/pack.py $opts $recopt "/tmp/v/out/$OUTNAME" $ins; then
  rm -rf "$ZD"; echo "pack-in-box: failed"; exit 1
fi
rm -rf "$ZD"
