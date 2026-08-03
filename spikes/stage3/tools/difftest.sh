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
gap_failed=0; gap_passed=0

# A case whose first line says KNOWN GAP is EXPECTED to fail. It documents
# something micro-c does not do yet, with the reasoning in the file.
#
# Two things follow, and both matter:
#   - a known gap failing does NOT fail the run, so "green" stays meaningful
#     and nobody has to remember which failure is the acceptable one
#   - a known gap PASSING is reported loudly, because it means either the gap
#     was closed or the case stopped testing what it claims to
is_known_gap() {
    head -5 "$1" | grep -q "KNOWN GAP"
}

# A CASE THE amd64 COLUMN CANNOT EXPRESS.
#
# Not every construct is portable across the two columns, and pretending
# otherwise costs more than it saves. A bitfield WRITE emits aarch64 mnemonics
# literally --
#     emit_out("and_x0,x1,x0\n");
# -- so on amd64 it does not assemble at all:
#     Received invalid other; and_x0,x1,x0
# That is a real gap in micro-c and it is recorded in the case, but it is not
# the thing the case is testing, and marking it KNOWN GAP would be wrong in the
# other direction: the case PASSES on aarch64, and a known gap that passes is
# reported loudly, which would be a permanent false alarm.
#
# So a case may declare the architecture it applies to, and the other column
# skips it WITH THE REASON PRINTED -- never silently, because a silent skip is
# how a suite quietly stops testing something.
is_arch_only() {
    head -8 "$1" | grep -q "AARCH64 ONLY"
}

# A case whose header says BITMASK returns one bit per probe instead of
# stopping at the first failure, so one run describes the whole shape. Decode
# it here rather than making the reader do arithmetic on a number in a log.
is_bitmask() {
    head -8 "$1" | grep -q "BITMASK"
}

decode_bits() {
    v="$1"; b=1; out=""
    while [ "$b" -le 64 ]; do
        if [ "$((v / b % 2))" = 1 ]; then out="$out $b"; fi
        b=$((b * 2))
    done
    echo "$out"
}

for c in "$CASES"/*.c; do
    [ -e "$c" ] || continue
    name=$(basename "$c" .c)

    # BEFORE ANYTHING ELSE. Checked first because the construct may not
    # assemble on this column at all, and a skip decided after the attempt is
    # not a skip -- it is a failure with an excuse printed next to it.
    # AND ONLY ON THE OTHER COLUMN. This checked the MARKER and not the ARCH,
    # so an AARCH64 ONLY case was skipped on aarch64 too -- which is the one
    # column it exists to run on. Cases 73 and 91 have therefore never run
    # anywhere, on either architecture, since the marker was introduced: the
    # aarch64 log says "SKIPPED on amd64" and nobody reads a skip.
    #
    # That is the same failure mode the marker was invented to prevent, in the
    # other direction. A silent skip is how a suite quietly stops testing
    # something; a skip that names the wrong architecture is how it stops
    # while looking deliberate.
    if is_arch_only "$c" && [ "$ARCH" != "aarch64" ]; then
        printf '  %-28s SKIPPED on %s: %s\n' "$name" "$ARCH" \
            "$(head -8 "$c" | sed -n '2p' | sed 's|^ *\* *||')"
        continue
    fi

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

    if is_known_gap "$c"; then
        if [ "$m_rc" = 0 ]; then
            printf '  %-28s KNOWN GAP NOW PASSES -- close it or fix the case\n' "$name"
            gap_passed=$((gap_passed + 1))
        elif is_bitmask "$c"; then
            # A KNOWN GAP IS STILL A MEASUREMENT, AND IT WAS BEING DISCARDED.
            #
            # "known gap (expected)" says a case failed as predicted. For a
            # bitmask case that throws away the only thing it produces: WHICH
            # probes failed. A gap is closed by watching its bits go out one
            # at a time -- 100-elf-header-type-discrimination is precisely
            # that shape, where bit 16 and bit 32 firing together means
            # something different from bit 32 firing alone.
            #
            # The verdict does not change and the run stays green; only the
            # diagnosis is kept rather than dropped.
            if [ "$m_rc" -gt 127 ]; then
                printf '  %-28s known gap -- BITMASK %s IS OUT OF RANGE, fix the case\n' \
                    "$name" "$m_rc"
            else
                printf '  %-28s known gap (expected), bitmask %s -- failing probes:%s\n' \
                    "$name" "$m_rc" "$(decode_bits "$m_rc")"
            fi
            gap_failed=$((gap_failed + 1))
        else
            printf '  %-28s known gap (expected)\n' "$name"
            gap_failed=$((gap_failed + 1))
        fi
    elif [ "$m_rc" = 0 ]; then
        pass=$((pass + 1))
    elif is_bitmask "$c"; then
        # AN EXIT CODE ABOVE 128 IS INDISTINGUISHABLE FROM A SIGNAL at the
        # shell, so a bitmask that reaches into that range reports itself as a
        # signal number that does not exist. Say so instead of decoding a
        # value that cannot be trusted.
        if [ "$m_rc" -gt 127 ]; then
            printf '  %-28s BITMASK %s IS OUT OF RANGE -- fix the case to stay under 128\n' \
                "$name" "$m_rc"
        else
            printf '  %-28s bitmask %s -- failing probes:%s\n' \
                "$name" "$m_rc" "$(decode_bits "$m_rc")"
        fi
        fail=$((fail + 1))
    elif [ "$m_rc" -gt 128 ]; then
        printf '  %-28s SIGNAL %s (gcc returns 0)\n' "$name" "$((m_rc - 128))"
        # A CRASH CARRIES NO RETURN CODE, so a case with six numbered steps
        # says only "it died". Anything the program managed to write before
        # dying is the only thing left, and it was being captured and thrown
        # away. Cases do not print today; this costs two lines and means one
        # that does will be heard.
        if [ -s "$T/m.out" ]; then
            printf '  %-28s   last output: %s\n' "" "$(tail -c 120 "$T/m.out" | tr '\n' ' ')"
        fi
        fail=$((fail + 1))
    else
        printf '  %-28s returns %s, gcc returns 0\n' "$name" "$m_rc"
        fail=$((fail + 1))
    fi
done

echo
echo "  pass $pass   fail $fail   known-gap $gap_failed   will-not-compile $skipped   broken-case $broken"
if [ "$gap_passed" != 0 ]; then
    echo "  $gap_passed known gap(s) now pass -- that is news, not noise"
fi
[ "$fail" = 0 ] || exit 1
