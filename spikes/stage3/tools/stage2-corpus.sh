#!/bin/sh
# RUN STAGE 2's CONFORMANCE CORPUS THROUGH STAGE 3.
#
#     [ARCH=amd64|aarch64] sh spikes/stage3/tools/stage2-corpus.sh \
#         <micro-c> <m2libc-patched> <mescc-bin> [corpus.tsv]
#
# Run local-build.sh first; this wants its patched m2libc and its M1/hex2.
#
# ---------------------------------------------------------------------------
# WHY THIS IS WORTH RUNNING
#
# spikes/stage2-pico-c/corpus/conformance.tsv is 426 small C programs with
# their expected exit codes. They were written to measure stage 2 -- pico-c --
# and stage 3 has never been asked to compile any of them.
#
# That makes them the one thing the stage-3 case suite structurally is not:
# tools/cases/ was written FROM bugs already found, so it measures what has
# been fixed. This corpus was written against a different compiler, for a
# different rung, by someone not looking for these bugs. Every failure here is
# a construct nobody chose.
#
# THE CORPUS'S EXPECTED EXIT CODE IS THE REFERENCE, NOT gcc's, AND THAT IS A
# DEPARTURE FROM difftest.sh. gcc is asked as well, but only as an advisory.
#
# The reason is the first row of the file:
#
#     int main(){int a=2000; return a*a*a/1000;}      corpus expects 0
#
# 2000^3 is 8e9. With a 64-bit int that is 8000000/1000 -> 8000000, and
# 8000000 & 0xff is 0. With gcc's 32-bit int it overflows to -589934592, and
# the process exits 146. Neither compiler is wrong; they disagree about the
# width of `int`, and the corpus was written for a compiler whose int is eight
# bytes -- which is exactly what micro-c is. Blaming micro-c for matching the
# corpus, or the corpus for not matching gcc, would both be wrong.
#
# So: micro-c is scored against the corpus. Where gcc gives a third answer that
# is REPORTED, because a row where all three differ is worth looking at, but it
# does not fail the run.
#
# THE SEPARATOR IS 0x1F, NOT A TAB, and that is load-bearing -- see the corpus
# README. argv is empty on 414 of the 426 rows, and `read a b c` on tabs
# collapses the empty middle field and shifts the program source into argv.
# ---------------------------------------------------------------------------
set -eu

MICROC="${1:-}"
M2LIBC="${2:-}"
MESCC="${3:-}"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TSV="${4:-$ROOT/spikes/stage2-pico-c/corpus/conformance.tsv}"

if [ -z "$MICROC" ] || [ -z "$M2LIBC" ] || [ -z "$MESCC" ]; then
    echo "usage: [ARCH=amd64|aarch64] $0 <micro-c> <m2libc> <mescc-bin> [tsv]"
    exit 2
fi

ARCH="${ARCH:-amd64}"
BASE_ADDR="${BASE_ADDR:-0x600000}"
[ "$ARCH" = "aarch64" ] && BASE_ADDR="0x400000"

# NATIVE IF WE CAN, EMULATED IF WE MUST. Same rule as verify-imm64.sh: on an
# aarch64 runner these run directly, which answers the caveat the emulator
# cannot.
HOST=$(uname -m)
RUN=""
if [ "$ARCH" = "aarch64" ] && [ "$HOST" != "aarch64" ]; then
    RUN="$ROOT/spikes/toolbox/qemu-aarch64-static"
    [ -x "$RUN" ] || { echo "FAIL: no emulator at $RUN"; exit 1; }
fi
if [ "$ARCH" = "amd64" ] && [ "$HOST" != "x86_64" ]; then
    echo "  SKIPPED: ARCH=amd64 and this host is $HOST, which cannot execute it."
    echo "  A skip is not a pass; run the aarch64 column instead."
    exit 0
fi

D="$M2LIBC/$ARCH"
[ -f "$D/${ARCH}_defs.M1" ] || { echo "FAIL: no $D/${ARCH}_defs.M1"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PRELUDE_ARGS=""
if [ "${PRELUDE:-1}" != 0 ]; then
    for h in sys/types.h stddef.h stdarg.h stdint.h stdio.h stdlib.h string.h unistd.h; do
        [ -f "$M2LIBC/$h" ] && PRELUDE_ARGS="$PRELUDE_ARGS -f $M2LIBC/$h"
    done
fi

# ---------------------------------------------------------------------------
# THE RUNTIME, COMPILED ONCE.
#
# 24 of the 426 call calloc and 13 call brk, so libc-core is not enough and
# libc-full's _start calls __init_malloc, which lives in M2libc's C sources.
# Those are compiled here once by micro-c itself and joined into every program
# -- which also means this corpus exercises micro-c on M2libc, not only on the
# 426 programs.
# ---------------------------------------------------------------------------
echo "  building the M2libc runtime with micro-c ($ARCH)"
H="-f $M2LIBC/stdarg.h -f $M2LIBC/sys/types.h -f $M2LIBC/stddef.h"
# shellcheck disable=SC2086
"$MICROC" --architecture "$ARCH" --max-string 65536 \
    -f "$M2LIBC/ctype.c" $H \
    -f "$M2LIBC/$ARCH/linux/unistd.c" -f "$M2LIBC/$ARCH/linux/fcntl.c" \
    -f "$M2LIBC/fcntl.c" -f "$M2LIBC/stdlib.c" -f "$M2LIBC/string.c" \
    -f "$M2LIBC/stdio.h" -f "$M2LIBC/stdio.c" -f "$M2LIBC/bootstrappable.c" \
    -o "$T/rt.M1" 2>"$T/rterr" \
    || { echo "  FAIL: micro-c could not compile M2libc:"; sed 's/^/    /' "$T/rterr"; exit 1; }

# CODE BEFORE STRINGS. Concatenating units naively interleaves their string
# sections, so a function can land off a 4-byte boundary and every call to it
# is SIGBUS on aarch64. See local-tcc.sh; this is the same join.
join2() {
    out="$1"; shift
    : > "$out.code"; : > "$out.strs"
    for f in "$@"; do
        sed '/^# Program strings$/,$d'   "$f" >> "$out.code"
        sed -n '/^# Program strings$/,$p' "$f" >> "$out.strs"
    done
    cat "$out.code" "$out.strs" > "$out"; rm -f "$out.code" "$out.strs"
}

pass=0; fail=0; nocompile=0; nolink=0; badrow=0; widthdiff=0; n=0
: > "$T/failures.txt"
: > "$T/gccdiff.txt"

while IFS=$(printf '\037') read -r want argv src; do
    [ -n "${src:-}" ] || continue
    n=$((n + 1))
    id=$(printf '%03d' "$n")
    printf '%s\n' "$src" > "$T/p.c"

    # --- gcc, advisory only. See the header for why it is not the reference.
    ref_rc="$want"
    if gcc -w -o "$T/ref" "$T/p.c" 2>/dev/null; then
        set +e
        # shellcheck disable=SC2086
        "$T/ref" $argv >/dev/null 2>&1
        ref_rc=$?
        set -e
    else
        ref_rc="(gcc will not compile it)"
    fi
    if [ "$ref_rc" != "$want" ]; then
        widthdiff=$((widthdiff + 1))
        printf 'row %s  gcc says %s, corpus says %s\n    %s\n' "$id" "$ref_rc" \
            "$want" "$src" >> "$T/gccdiff.txt"
    fi

    # --- micro-c, TWO TIERS, AND THE ORDER IS THE POINT --------------------
    #
    # TIER 1 IS EXACTLY STAGE 2's CONDITIONS: the program as written, nothing
    # in front of it, linked against libc-core alone. Most of the corpus needs
    # nothing else, and it is the only tier under which a program that defines
    # its OWN calloc or brk -- there are several -- means what it says.
    #
    # TIER 2 adds `#include` lines and the M2libc runtime, for the rows that
    # call calloc, brk or exit. pico-c does not require a declaration before a
    # call and micro-c does, so bare they stop at "calloc is not a defined
    # symbol". That is a difference in language surface, not a codegen result.
    #
    # THE HEADERS HAVE TO BE #included, NOT PASSED AS -f FILES. Handing micro-c
    # `-f stdlib.h -f prog.c` leaves calloc undefined anyway; only
    # `--expand-includes -I m2libc` with a real #include registers it. That
    # cost a round to notice and is exactly the kind of thing that makes a
    # harness quietly measure the wrong thing.
    tier=1
    cp "$T/p.c" "$T/build.c"
    set +e
    "$MICROC" --architecture "$ARCH" --max-string 65536 \
        -f "$T/build.c" -o "$T/p.M1" 2>"$T/cerr"
    crc=$?
    set -e
    if [ "$crc" != 0 ]; then
        tier=2
        { printf '#include <stdlib.h>\n#include <unistd.h>\n#include <stdio.h>\n'
          cat "$T/p.c"; } > "$T/build.c"
        set +e
        "$MICROC" --architecture "$ARCH" --expand-includes --max-string 65536 \
            -I "$M2LIBC" -f "$T/build.c" -o "$T/p.M1" 2>"$T/cerr"
        crc=$?
        set -e
    fi
    if [ "$crc" != 0 ]; then
        printf '  row %s  WILL NOT COMPILE: %s\n' "$id" \
            "$(head -1 "$T/cerr" | cut -c1-60)"
        printf 'row %s  WILL NOT COMPILE  %s\n    %s\n' "$id" \
            "$(head -1 "$T/cerr" | cut -c1-60)" "$src" >> "$T/failures.txt"
        nocompile=$((nocompile + 1)); continue
    fi

    link_it() {   # $1 = libc .M1 stem, $2 = extra unit or empty
        if [ -n "$2" ]; then join2 "$T/all.M1" "$T/p.M1" "$2"
        else cp "$T/p.M1" "$T/all.M1"; fi
        "$MESCC/M1" -f "$D/${ARCH}_defs.M1" -f "$D/$1.M1" -f "$T/all.M1" \
                    --little-endian --architecture "$ARCH" -o "$T/p.hex2" 2>"$T/lerr" \
          && "$MESCC/hex2" --architecture "$ARCH" --little-endian \
                    --base-address "$BASE_ADDR" -f "$D/ELF-$ARCH.hex2" \
                    -f "$T/p.hex2" -o "$T/p.bin" 2>>"$T/lerr"
    }

    set +e
    if [ "$tier" = 1 ]; then link_it libc-core ""; else link_it libc-full "$T/rt.M1"; fi
    lrc=$?
    if [ "$lrc" != 0 ] || [ ! -s "$T/p.bin" ]; then
        # A tier-1 program can still need the runtime -- it may call a libc
        # function it declared itself. Retry rather than call it a link failure.
        tier=2
        link_it libc-full "$T/rt.M1"
        lrc=$?
    fi
    set -e
    if [ "$lrc" != 0 ] || [ ! -s "$T/p.bin" ]; then
        printf '  row %s  WILL NOT LINK: %s\n' "$id" "$(head -1 "$T/lerr" | cut -c1-40)"
        printf 'row %s  WILL NOT LINK\n    %s\n' "$id" "$src" >> "$T/failures.txt"
        nolink=$((nolink + 1)); continue
    fi

    chmod +x "$T/p.bin"
    set +e
    if [ -n "$RUN" ]; then
        # shellcheck disable=SC2086
        timeout 20 "$RUN" "$T/p.bin" $argv >/dev/null 2>&1
    else
        # shellcheck disable=SC2086
        timeout 20 "$T/p.bin" $argv >/dev/null 2>&1
    fi
    got=$?
    set -e

    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
    else
        if [ "$got" -gt 128 ] 2>/dev/null; then
            printf '  row %s  SIGNAL %s (expected %s)\n' "$id" "$((got - 128))" "$want"
        else
            printf '  row %s  returns %s, expected %s\n' "$id" "$got" "$want"
        fi
        printf 'row %s  got %s want %s\n    %s\n' "$id" "$got" "$want" "$src" \
            >> "$T/failures.txt"
        fail=$((fail + 1))
    fi
done < "$TSV"

cp "$T/failures.txt" "${FAILURES_OUT:-/dev/null}" 2>/dev/null || true
cp "$T/gccdiff.txt" "${GCCDIFF_OUT:-/dev/null}" 2>/dev/null || true

echo
printf '  %s  %s rows: pass %s   wrong-answer %s   will-not-compile %s   will-not-link %s\n' \
    "$ARCH" "$n" "$pass" "$fail" "$nocompile" "$nolink"
printf '  %s rows where gcc gives a different answer from the corpus (int width)\n' "$widthdiff"

[ "$fail" = 0 ] && [ "$nocompile" = 0 ] && [ "$nolink" = 0 ] && exit 0
exit 1
