#!/bin/sh
# VOCABULARY CHECK: does every macro micro-c can emit actually EXIST for the
# architecture it is emitting for?
#
# WHY THIS EXISTS. The same failure kept recurring, one architecture at a time:
#
#   struct copy      emitted mov_x15,x1     -- not in aarch64's defs
#   struct copy      emitted mov_rbx,r15    -- not in amd64's defs
#   temp advance     emitted add_x16,x14,x16 -- not in aarch64's defs
#   setjmp           needed mov_x0,lr        -- not in aarch64's defs
#
# Each was found by ASSEMBLING or RUNNING, which costs a CI round when the
# target is not the machine doing the work. They are all the same mistake:
# code written against one architecture's macro list and checked against that
# same list.
#
# M2libc's *_defs.M1 files are the ground truth -- a macro either has an
# encoding there or it does not. So compile a corpus for EVERY architecture and
# check every emitted mnemonic against that architecture's definitions. No
# execution, no emulation, no runner.
#
# This cannot find logic bugs. It finds the entire class of "that instruction
# does not exist here", before anything is run.
set -eu

MICROC="${1:-}"
M2LIBC="${2:-}"
CORPUS="${3:-$(dirname "$0")/cases}"

if [ -z "$MICROC" ] || [ -z "$M2LIBC" ]; then
    echo "usage: $0 <micro-c> <m2libc-dir> [corpus-dir]"
    exit 2
fi

# The architectures with a defs file to check against.
ARCHES="${ARCHES:-amd64 aarch64 x86 armv7l riscv64}"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

total_missing=0

for arch in $ARCHES; do
    defs="$M2LIBC/$arch/${arch}_defs.M1"
    if [ ! -f "$defs" ]; then
        printf '  %-10s no defs file, skipped\n' "$arch"
        continue
    fi

    # Every macro this architecture defines.
    grep '^DEFINE ' "$defs" | awk '{print $2}' | sort -u > "$T/defined"

    : > "$T/emitted"
    compiled=0
    for c in "$CORPUS"/*.c; do
        [ -e "$c" ] || continue
        if "$MICROC" --architecture "$arch" --max-string 65536 \
                     -f "$c" -o "$T/out.M1" 2>/dev/null; then
            compiled=$((compiled + 1))
            # A macro line starts at column 1 with a mnemonic. Labels start
            # with ':', references with '&', immediates with '%' or a quote.
            grep -oE '^[a-z_][a-zA-Z0-9_]*[a-zA-Z0-9_,.@[\]!+-]*' "$T/out.M1" \
                >> "$T/emitted" || true
        fi
    done

    sort -u "$T/emitted" -o "$T/emitted"
    comm -23 "$T/emitted" "$T/defined" > "$T/missing" || true
    n=$(wc -l < "$T/missing")

    if [ "$n" = 0 ]; then
        printf '  %-10s %2d files, every emitted macro is defined\n' "$arch" "$compiled"
    else
        printf '  %-10s %2d files, %s EMITTED MACROS ARE NOT DEFINED:\n' "$arch" "$compiled" "$n"
        sed 's/^/      /' "$T/missing"
        total_missing=$((total_missing + n))
    fi
done

echo
if [ "$total_missing" = 0 ]; then
    echo "  OK: no undefined macros on any architecture"
    exit 0
fi
echo "  $total_missing undefined macro(s). Each one is an assembler error"
echo "  waiting to happen on an architecture nobody ran."
exit 1
