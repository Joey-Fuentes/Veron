#!/bin/sh
# one.sh -- compile and run ONE case (or one throwaway file) through micro-c,
# print gcc's answer beside it, and optionally dump the emitted M1.
#
# The difftest loop is the right gate; this is the microscope. It exists
# because chasing a codegen bug means reading the emitted code for one
# expression, and difftest deliberately does not show you that.
#
#   sh one.sh <file.c> [amd64|aarch64] [--m1]
#
# Defaults to amd64, which this machine executes natively.
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
B="$ROOT/build/local"
SRC=$1
ARCH=${2:-amd64}
SHOW_M1=${3:-}

MICROC="$B/micro-c"
D="$B/m2libc/$ARCH"
MESCC="$B/mescc-bin"

case "$ARCH" in
    amd64)   BASE=0x00600000 ;;
    aarch64) BASE=0x00400000 ;;
    *) echo "unknown arch $ARCH" >&2; exit 2 ;;
esac

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# gcc first. If the reference does not agree with itself the case is broken and
# nothing measured against it means anything.
gcc -w -O0 -o "$T/ref" "$SRC"
set +e
"$T/ref" >"$T/ref.out" 2>&1
ref_rc=$?
set -e
echo "  gcc      rc=$ref_rc  out=[$(cat "$T/ref.out" | tr '\n' ' ')]"

set +e
"$MICROC" --architecture "$ARCH" --max-string 65536 -f "$SRC" -o "$T/m.M1" 2>"$T/cerr"
crc=$?
set -e
if [ "$crc" != 0 ]; then
    echo "  micro-c  WILL NOT COMPILE: $(head -2 "$T/cerr")"
    exit 1
fi

set +e
"$MESCC/M1" -f "$D/${ARCH}_defs.M1" -f "$D/libc-core.M1" -f "$T/m.M1" \
            --little-endian --architecture "$ARCH" -o "$T/m.hex2" 2>"$T/aerr"
a=$?
"$MESCC/hex2" --architecture "$ARCH" --little-endian --base-address "$BASE" \
              -f "$D/ELF-$ARCH.hex2" -f "$T/m.hex2" -o "$T/m.bin" 2>/dev/null
h=$?
set -e
if [ "$a" != 0 ] || [ "$h" != 0 ] || [ ! -s "$T/m.bin" ]; then
    echo "  micro-c  WILL NOT ASSEMBLE/LINK (M1=$a hex2=$h): $(head -2 "$T/aerr")"
    [ "$SHOW_M1" = "--m1" ] && cp "$T/m.M1" /tmp/one.M1 && echo "  M1 -> /tmp/one.M1"
    exit 1
fi

chmod +x "$T/m.bin"
set +e
if [ "$ARCH" = aarch64 ]; then
    "$ROOT/spikes/toolbox/qemu-aarch64-static" "$T/m.bin" >"$T/m.out" 2>&1
else
    "$T/m.bin" >"$T/m.out" 2>&1
fi
m_rc=$?
set -e
echo "  micro-c  rc=$m_rc  out=[$(cat "$T/m.out" | tr '\n' ' ')]"

if [ "$ref_rc" = "$m_rc" ] && cmp -s "$T/ref.out" "$T/m.out"; then
    echo "  AGREE"
else
    echo "  DIFFER   (gcc $ref_rc vs micro-c $m_rc)"
fi

if [ "$SHOW_M1" = "--m1" ]; then
    cp "$T/m.M1" /tmp/one.M1
    echo "  M1 -> /tmp/one.M1"
fi
