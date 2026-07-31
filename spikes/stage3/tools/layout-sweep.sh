#!/bin/sh
# HOW OFTEN DOES THE HEAP CORRUPTION LAND SOMEWHERE FATAL?
#
# The stray write that corrupts tcc's allocator list happens in one place; the
# FAILURE happens wherever the damaged thing is next touched, which depends on
# the whole allocation history. So the same source, compiled by the same
# mc-tcc, succeeds or fails on the length of its own FILENAME:
#
#     a.c ab.c abc.c        rc=0    compiles
#     abcd.c ... abcdefgh.c rc=1    realloc: pointer was never returned
#
# Identical bytes, identical binary. The filename is stored on the heap, so its
# length shifts every later allocation.
#
# WHAT THIS MEANS FOR EVERY OTHER MEASUREMENT HERE. A single compile that
# succeeds is not evidence of a fix, and a single compile that fails is not
# evidence of a regression -- both are one sample from a distribution nobody
# was controlling. Bisecting the INPUT finds filename lengths, not language
# constructs; bisecting the COMPILER compares two different allocation
# histories. This script turns the layout into a swept parameter instead of an
# uncontrolled one: same source, N filename lengths, count how many survive.
#
#   sh layout-sweep.sh <mc-tcc> [source.c] [max-len]
#
# A fix for the corruption should drive the failure count to ZERO across the
# whole sweep. Anything less is the damage moving, not going away.
set -u

V=$(cd "$(dirname "$0")/../../.." && pwd)
W=$V/build/local
Q=$V/spikes/toolbox/qemu-aarch64-static
SH=$V/spikes/stage3/tcc-test-shim

MCTCC=${1:?usage: layout-sweep.sh <mc-tcc> [source.c] [max-len]}
SRC=${2:-}
MAX=${3:-24}

# ABSOLUTE, BECAUSE THIS SCRIPT cd's INTO A TEMP DIRECTORY. A relative
# `build/local/mc-tcc` then resolves to nothing, every compile fails to start,
# and the sweep reports a full column of failures that say nothing about the
# compiler -- the same shape as a harness that never ran. Resolve both paths
# while the caller's working directory is still current.
case "$MCTCC" in /*) ;; *) MCTCC="$(cd "$(dirname "$MCTCC")" && pwd)/$(basename "$MCTCC")" ;; esac
if [ -n "$SRC" ]; then
    case "$SRC" in /*) ;; *) SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")" ;; esac
fi
[ -x "$MCTCC" ] || { echo "no mc-tcc at $MCTCC"; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Default source: the shape of tests2/00_assignment -- a declaration, a
# statement, a declaration after a statement, and multiple declarators.
if [ -z "$SRC" ]; then
    cat > "$T/src" <<'EOF'
#include <stdio.h>
int main(void)
{
   int a;
   a = 42;
   printf("%d\n", a);
   int b = 64;
   printf("%d\n", b);
   int c = 12, d = 34;
   printf("%d, %d\n", c, d);
   return 0;
}
EOF
    cat "$SH/crt.c" >> "$T/src"
else
    cat "$SRC" > "$T/src"
fi

ok=0; realloc_fail=0; sig=0; other=0
echo "  mc-tcc: $(basename "$MCTCC")   source: ${SRC:-<00_assignment shape>}"
echo

cd "$T"
i=1
while [ "$i" -le "$MAX" ]; do
    # a filename of exactly length i+2 ("<i chars>.c")
    name=$(awk -v n="$i" 'BEGIN{s="";for(j=0;j<n;j++)s=s "x";print s}').c
    cp src "$name"
    timeout 300 "$Q" "$MCTCC" -B"$W/tcc-work" -I"$SH" -nostdlib -static \
        -o out.bin "$name" >/dev/null 2>err.txt
    rc=$?
    if [ "$rc" = 0 ]; then
        ok=$((ok+1)); mark="ok"
    elif [ "$rc" -gt 128 ]; then
        sig=$((sig+1)); mark="SIGNAL $((rc-128))"
    elif grep -aq 'realloc:' err.txt; then
        realloc_fail=$((realloc_fail+1)); mark="realloc corruption"
    else
        other=$((other+1)); mark="rc=$rc $(grep -av '^[A-Z][0-9]*$' err.txt | head -1)"
    fi
    printf '  namelen %-3s  %s\n' "$((i+2))" "$mark"
    rm -f "$name"
    i=$((i+1))
done

echo
echo "  ok $ok   realloc $realloc_fail   signal $sig   other $other   (of $MAX)"
