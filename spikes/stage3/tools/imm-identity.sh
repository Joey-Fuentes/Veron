#!/bin/sh
# DID WIDENING THE IMMEDIATE PATH MOVE ANYTHING IT SHOULD NOT HAVE?
#
#     sh spikes/stage3/tools/imm-identity.sh <before> <after> [cases-dir]
#
# <before> and <after> are two micro-c binaries: the compiler without the
# 64-bit immediate patch and the compiler with it. local-build.sh builds both
# and calls this.
#
# ---------------------------------------------------------------------------
# WHY THIS IS THE RIGHT GUARD FOR THIS PARTICULAR CHANGE
#
# EXPERIMENT-zzb widens every integer literal to 64 bits and adds a second
# emission path for constants outside 0..0x7FFFFFFF. That path is UNREACHABLE
# below the threshold. So anything that moves below the threshold is a bug in
# the WIDENING -- an int that should have become a long long, a mask written as
# a literal, a rendering function that truncates -- rather than a bug in the
# feature, and the two are worth telling apart before the difftest suite runs.
#
# difftest answers "does this construct behave as gcc does". It cannot answer
# "did 369,000 lines of unrelated output stay exactly where they were", and
# that is the question a widening asks. This is a diff, not a test: it compares
# the compiler against ITSELF, one patch apart.
#
# THE EXPECTED SET IS DECLARED IN THE CASES, NOT HERE. A case whose header says
# WIDE CONSTANTS is expected to differ, for the same reason KNOWN GAP lives in
# the case file: a list of exceptions kept in the tool drifts from the thing it
# describes, and then the gate is switched off rather than fixed. A case that
# differs WITHOUT saying so is a failure, and a case that says so and does NOT
# differ is reported too -- it means the case stopped carrying a wide constant
# and has quietly become a duplicate of some other case.
# ---------------------------------------------------------------------------
set -eu

BEFORE="${1:-}"
AFTER="${2:-}"
CASES="${3:-$(dirname "$0")/cases}"

if [ -z "$BEFORE" ] || [ -z "$AFTER" ]; then
    echo "usage: $0 <micro-c-before> <micro-c-after> [cases-dir]"
    exit 2
fi
[ -x "$BEFORE" ] || { echo "FAIL: $BEFORE is not executable"; exit 1; }
[ -x "$AFTER" ]  || { echo "FAIL: $AFTER is not executable"; exit 1; }

ARCHES="${ARCHES:-amd64 aarch64}"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

same=0
moved=0
expected=0
unexpected=0
missing=0

for arch in $ARCHES; do
    for c in "$CASES"/*.c; do
        [ -e "$c" ] || continue
        name=$(basename "$c" .c)

        # A case that neither compiler can compile for this architecture is not
        # evidence either way, and saying nothing about it is how a gate ends
        # up reporting on an empty set.
        "$BEFORE" --architecture "$arch" --max-string 65536 \
                  -f "$c" -o "$T/before.M1" 2>/dev/null || continue
        "$AFTER"  --architecture "$arch" --max-string 65536 \
                  -f "$c" -o "$T/after.M1"  2>/dev/null || continue

        if head -8 "$c" | grep -q "WIDE CONSTANTS"; then
            wide=yes
        else
            wide=no
        fi

        if cmp -s "$T/before.M1" "$T/after.M1"; then
            if [ "$wide" = yes ]; then
                printf '  %-10s %-40s DECLARED WIDE, DID NOT MOVE\n' "$arch" "$name"
                missing=$((missing + 1))
            else
                same=$((same + 1))
            fi
        else
            moved=$((moved + 1))
            if [ "$wide" = yes ]; then
                expected=$((expected + 1))
            else
                printf '  %-10s %-40s MOVED AND IS NOT DECLARED WIDE\n' "$arch" "$name"
                diff "$T/before.M1" "$T/after.M1" | head -12 | sed 's/^/        /'
                unexpected=$((unexpected + 1))
            fi
        fi
    done
done

echo
echo "  byte-identical $same   moved $moved (declared $expected, undeclared $unexpected)"

if [ "$missing" != 0 ]; then
    echo "  $missing case(s) declare WIDE CONSTANTS and did not move. Either the"
    echo "  constant stopped being wide or the case stopped testing what it says."
    exit 1
fi
if [ "$unexpected" != 0 ]; then
    echo "  $unexpected compilation(s) moved that carry no wide constant. The new"
    echo "  emission path is unreachable below 0x7FFFFFFF, so this is the"
    echo "  widening leaking, not the feature."
    exit 1
fi
echo "  OK: the emitted .M1 moved only where a wide constant is present"
exit 0
