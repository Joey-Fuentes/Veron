#!/bin/sh
# DIFFERENTIAL TEST: the same program compiled by gcc and by micro-c, both RUN,
# and their behaviour compared.
#
# WHY THIS SHOULD HAVE EXISTED FIRST. Every codegen bug found so far was found
# by reading emitted assembly after a CI round pointed at a function:
#
#     array members loaded instead of decaying to an address
#     array members sized by the element's target type
#     &s->member not loading s first
#     global string data unpadded, so functions landed unaligned
#     && and || not short-circuiting
#
# Every one of them is a few lines of C that behaves differently under gcc.
# Each cost a CI round trip -- fetch, patch, compile 350,000 lines, assemble,
# link, run, read markers -- to locate, and then a careful read of assembly to
# identify. A test that compiles twenty lines twice and compares two exit codes
# would have caught all of them in under a second, locally.
#
# The reason it did not exist is that the work was aimed at aarch64, which this
# machine cannot run. micro-c also targets amd64, which it can. That was true
# the entire time.
#
# HOW IT WORKS. Each case is a self-contained C program that returns 0 on
# success and a distinct non-zero code on each way it can fail. gcc's result is
# the reference -- if gcc does not return 0 the case itself is wrong, and it
# says so rather than blaming micro-c.
set -eu

MICROC="${1:-}"
M2LIBC="${2:-}"
MESCC="${3:-}"
CASES="${4:-$(dirname "$0")/cases}"

# ARCH defaults to amd64 because that is what a development machine usually
# is, and the whole point of this tool is that it needs no emulation. Set it
# to aarch64 on an aarch64 runner and the SAME cases are checked where the
# faults that resisted six CI rounds actually happen.
#
# gcc is still the reference either way: on the aarch64 runner it is a native
# aarch64 gcc, so the comparison stays like-for-like.
ARCH="${ARCH:-amd64}"
BASE_ADDR="${BASE_ADDR:-0x600000}"
if [ "$ARCH" = "aarch64" ]; then BASE_ADDR="0x400000"; fi

if [ -z "$MICROC" ] || [ -z "$M2LIBC" ] || [ -z "$MESCC" ]; then
    echo "usage: [ARCH=amd64|aarch64] $0 <micro-c> <m2libc-dir> <mescc-tools-dir> [cases-dir]"
    exit 2
fi

D="$M2LIBC/$ARCH"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0; fail=0; broken=0; skipped=0

for c in "$CASES"/*.c; do
    [ -e "$c" ] || continue
    name=$(basename "$c" .c)

    # gcc is the reference. -O0 so the comparison is against straightforward
    # code rather than against the optimiser.
    if ! gcc -w -O0 -o "$T/ref" "$c" 2>/dev/null; then
        printf '  %-28s CASE IS BROKEN: gcc will not compile it\n' "$name"
        broken=$((broken + 1))
        continue
    fi
    set +e
    "$T/ref" >"$T/ref.out" 2>&1
    ref_rc=$?
    set -e
    if [ "$ref_rc" != 0 ]; then
        printf '  %-28s CASE IS BROKEN: gcc build returns %s, expected 0\n' "$name" "$ref_rc"
        broken=$((broken + 1))
        continue
    fi

    set +e
    "$MICROC" --architecture "$ARCH" --max-string 65536 -f "$c" -o "$T/m.M1" 2>"$T/cerr"
    crc=$?
    set -e
    if [ "$crc" != 0 ]; then
        printf '  %-28s micro-c CANNOT COMPILE IT: %s\n' "$name" \
            "$(head -1 "$T/cerr" | cut -c1-48)"
        skipped=$((skipped + 1))
        continue
    fi

    set +e
    # libc-core, not libc-full: full's _start calls __init_malloc, which
    # lives in M2libc's C sources and is not linked here. These cases do not
    # allocate, so core is both sufficient and a smaller thing to be wrong.
    "$MESCC/M1" -f "$D/${ARCH}_defs.M1" -f "$D/libc-core.M1" -f "$T/m.M1" \
                --little-endian --architecture "$ARCH" -o "$T/m.hex2" 2>/dev/null
    a=$?
    "$MESCC/hex2" --architecture "$ARCH" --little-endian --base-address "$BASE_ADDR" \
                  -f "$D/ELF-$ARCH.hex2" -f "$T/m.hex2" -o "$T/m.bin" 2>/dev/null
    h=$?
    set -e
    if [ "$a" != 0 ] || [ "$h" != 0 ] || [ ! -s "$T/m.bin" ]; then
        printf '  %-28s DOES NOT ASSEMBLE OR LINK (M1=%s hex2=%s)\n' "$name" "$a" "$h"
        fail=$((fail + 1))
        continue
    fi

    chmod +x "$T/m.bin"
    set +e
    "$T/m.bin" >"$T/m.out" 2>&1
    m_rc=$?
    set -e

    if [ "$m_rc" = 0 ]; then
        pass=$((pass + 1))
    elif [ "$m_rc" -gt 128 ]; then
        printf '  %-28s SIGNAL %s (gcc returns 0)\n' "$name" "$((m_rc - 128))"
        fail=$((fail + 1))
    else
        printf '  %-28s returns %s, gcc returns 0\n' "$name" "$m_rc"
        fail=$((fail + 1))
    fi
done

echo
echo "  pass $pass   fail $fail   will-not-compile $skipped   broken-case $broken"
[ "$fail" = 0 ] || exit 1
