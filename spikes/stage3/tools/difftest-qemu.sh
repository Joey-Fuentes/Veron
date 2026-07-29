#!/bin/sh
# difftest ON aarch64, under the committed emulator.
#
#     sh spikes/stage3/tools/difftest-qemu.sh <workdir>
#
# difftest.sh runs each case binary directly, which only works when the host is
# the target. This runs the same cases through spikes/toolbox/qemu-aarch64-static
# so the aarch64 side can be checked on an x86_64 machine.
#
# WHY IT MATTERS. amd64 tolerates unaligned access and aarch64 faults on it, so
# a whole class of bug is invisible natively and fatal on the target. Four bugs
# in this work were exactly that. Two cases -- 05 and 16 -- have failed only
# here, and 05 turned out to be three wrong instruction encodings in M2libc
# rather than a compiler bug at all.
#
# gcc remains the reference: each case is built and run natively first, and a
# case gcc does not return 0 on is reported as broken rather than blamed on
# micro-c. That is the same rule difftest.sh follows.
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=${1:-$ROOT/build/local}
# ABSOLUTE, because these scripts cd into it and a relative path given on the
# command line stops resolving the moment they do.
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
Q="$ROOT/spikes/toolbox/qemu-aarch64-static"
D="$WORK/m2libc/aarch64"
CASES="$ROOT/spikes/stage3/tools/cases"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

[ -x "$Q" ] || { echo "FAIL: $Q is missing or not executable"; exit 1; }
[ -f "$D/aarch64_defs.M1" ] || { echo "FAIL: run local-build.sh first"; exit 1; }

# THE PATCHED TABLE, ASSERTED. Assembling against the vendored copy makes
# cases 05 and 46 fail against a compiler that passes them, which reads as a
# codegen bug and is not one.
grep -q '^DEFINE add_x0,x16,x0 0002008b' "$D/aarch64_defs.M1" \
    || { echo "FAIL: $D is the UNPATCHED table"; exit 1; }

pass=0; fail=0; gap=0; broken=0
for c in "$CASES"/*.c; do
    [ -e "$c" ] || continue
    name=$(basename "$c" .c)

    if ! gcc -w -O0 -o "$T/ref" "$c" 2>/dev/null; then
        printf '  %-42s CASE IS BROKEN: gcc will not compile it\n' "$name"
        broken=$((broken + 1)); continue
    fi
    set +e; "$T/ref" >/dev/null 2>&1; ref_rc=$?; set -e
    if [ "$ref_rc" != 0 ]; then
        printf '  %-42s CASE IS BROKEN: gcc returns %s\n' "$name" "$ref_rc"
        broken=$((broken + 1)); continue
    fi

    set +e
    "$WORK/micro-c" --architecture aarch64 --max-string 65536 \
        -f "$c" -o "$T/m.M1" 2>/dev/null
    crc=$?
    set -e
    if [ "$crc" != 0 ]; then
        printf '  %-42s micro-c CANNOT COMPILE IT\n' "$name"
        fail=$((fail + 1)); continue
    fi

    set +e
    "$WORK/mescc-bin/M1" -f "$D/aarch64_defs.M1" -f "$D/libc-core.M1" \
        -f "$T/m.M1" --little-endian --architecture aarch64 -o "$T/m.hex2" 2>/dev/null
    a=$?
    "$WORK/mescc-bin/hex2" --architecture aarch64 --little-endian \
        --base-address 0x400000 -f "$D/ELF-aarch64.hex2" -f "$T/m.hex2" \
        -o "$T/m.bin" 2>/dev/null
    h=$?
    set -e
    if [ "$a" != 0 ] || [ "$h" != 0 ] || [ ! -s "$T/m.bin" ]; then
        printf '  %-42s DOES NOT ASSEMBLE OR LINK\n' "$name"
        fail=$((fail + 1)); continue
    fi

    chmod +x "$T/m.bin"
    set +e; timeout 30 "$Q" "$T/m.bin" >/dev/null 2>&1; rc=$?; set -e

    if head -8 "$c" | grep -q "KNOWN GAP"; then
        if [ "$rc" = 0 ]; then
            printf '  %-42s KNOWN GAP NOW PASSES -- close it or fix the case\n' "$name"
        else
            gap=$((gap + 1))
        fi
    elif [ "$rc" = 0 ]; then
        pass=$((pass + 1))
    elif [ "$rc" -gt 128 ]; then
        printf '  %-42s SIGNAL %s (gcc returns 0)\n' "$name" "$((rc - 128))"
        fail=$((fail + 1))
    else
        printf '  %-42s returns %s, gcc returns 0\n' "$name" "$rc"
        fail=$((fail + 1))
    fi
done

echo
echo "  aarch64  pass $pass   fail $fail   known-gap $gap   broken-case $broken"
[ "$fail" = 0 ] || exit 1
