#!/bin/sh
# micro-c regression, written after discovering the previous one was VACUOUS.
#
# WHAT WENT WRONG BEFORE. The old check was, in essence:
#
#     M2-ref  -f OUR_PATCHED_SOURCES -o a.M1 ; ra=$?
#     M2TP    -f OUR_PATCHED_SOURCES -o b.M1 ; rb=$?
#     [ "$ra" = "$rb" ] && cmp -s a.M1 b.M1 && pass
#
# Both compilers FAILED on those inputs -- they need -I for stdio.h and never
# got it -- so both produced ZERO BYTES and exited 1. `1 = 1` is true and cmp
# on two empty files succeeds, so it printed "9/9 byte-identical" on every run
# from the first to the hundredth without ever compiling a line.
#
# It was not a weak test. It was not a test.
#
# THREE RULES THIS ONE FOLLOWS:
#
#   1. ASSERT THAT WORK HAPPENED. A comparison is only meaningful if both
#      sides produced output; zero bytes is a failure, not a match.
#   2. COMPARE AGAINST THE REFERENCE'S OWN SOURCES, not our patched ones. The
#      unpatched compiler cannot be expected to build our patched tree.
#   3. DO NOT DEMAND BYTE-IDENTICAL. We deliberately changed code generation
#      -- short-circuit && and ||, array member decay, padding. Identical
#      output would now mean the changes had NOT taken effect.
#
# What is checked instead: our compiler still compiles everything the
# reference compiles, and the differences are accounted for.
set -eu

REF="${1:-}"
OURS="${2:-}"
SRC="${3:-}"

if [ -z "$REF" ] || [ -z "$OURS" ] || [ -z "$SRC" ]; then
    echo "usage: $0 <reference-M2-Planet> <our-micro-c> <reference-source-dir>"
    exit 2
fi

M2LIBC="${M2LIBC:-$SRC/M2libc}"
FILES="cc.c cc_core.c cc_emit.c cc_globals.c cc_macro.c cc_reader.c cc_strings.c cc_types.c"

compiled=0
ours_only=0
ref_only=0
both_failed=0
identical=0
differ=0

for f in $FILES; do
    [ -f "$SRC/$f" ] || continue

    # set -e would abort the moment a compiler exits non-zero, BEFORE $? is
    # read -- which is how a check meant to tolerate failures becomes one that
    # dies on the first. Disabled around the two invocations only.
    : > /tmp/reg_ref.M1
    : > /tmp/reg_ours.M1
    set +e
    "$REF" --architecture aarch64 --expand-includes -I "$SRC" -I "$M2LIBC" \
           -f "$SRC/$f" -o /tmp/reg_ref.M1 2>/dev/null
    ra=$?
    "$OURS" --architecture aarch64 --expand-includes -I "$SRC" -I "$M2LIBC" \
            -f "$SRC/$f" -o /tmp/reg_ours.M1 2>/dev/null
    rb=$?
    set -e

    # ZERO BYTES IS NOT A MATCH. This is the assertion whose absence made the
    # old check meaningless.
    ref_size=$(wc -c < /tmp/reg_ref.M1 2>/dev/null || echo 0)
    our_size=$(wc -c < /tmp/reg_ours.M1 2>/dev/null || echo 0)

    if [ "$ra" != 0 ] || [ "$ref_size" -lt 100 ]; then
        if [ "$rb" = 0 ] && [ "$our_size" -ge 100 ]; then
            ours_only=$((ours_only + 1))
            printf '  %-16s ours compiles it, the reference does not\n' "$f"
        else
            both_failed=$((both_failed + 1))
            printf '  %-16s NEITHER compiles it\n' "$f"
        fi
        continue
    fi

    if [ "$rb" != 0 ] || [ "$our_size" -lt 100 ]; then
        ref_only=$((ref_only + 1))
        printf '  %-16s REGRESSION: the reference compiles it, we do not\n' "$f"
        continue
    fi

    compiled=$((compiled + 1))
    if cmp -s /tmp/reg_ref.M1 /tmp/reg_ours.M1; then
        identical=$((identical + 1))
        printf '  %-16s identical\n' "$f"
    else
        differ=$((differ + 1))
        printf '  %-16s differs (%s vs %s lines)\n' "$f" \
            "$(wc -l < /tmp/reg_ref.M1)" "$(wc -l < /tmp/reg_ours.M1)"
    fi
done

echo
echo "  both compiled : $compiled  (identical $identical, differ $differ)"
echo "  ours only     : $ours_only"
echo "  neither       : $both_failed"
echo "  REGRESSIONS   : $ref_only"

# The only hard failure is losing something the reference can still do.
# Differences are expected; a file we can no longer compile is not.
if [ "$ref_only" != 0 ]; then
    echo "  FAIL: we no longer compile something the reference does"
    exit 1
fi
if [ "$compiled" -lt 5 ]; then
    echo "  FAIL: only $compiled files were actually compiled by both --"
    echo "        too few for the comparison to mean anything"
    exit 1
fi
echo "  OK"
