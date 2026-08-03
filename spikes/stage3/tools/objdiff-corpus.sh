#!/bin/sh
# THE GATE THAT FOUND THE ADDEND BUG, AND THE SHARPEST INSTRUMENT IN THIS TREE.
#
# THE IDEA. tcc's source is one thing; the compiler that compiles it is the
# variable. Build a CONTROL tcc with gcc and the SUBJECT tcc with micro-c from
# the same tree, run both over a large real corpus, and `cmp` the objects. Any
# byte that differs is a place micro-c and gcc disagree about what tcc means.
#
# WHY IT BEATS EVERYTHING ELSE HERE. The case suites, the stage-2 corpus, the
# tests2 sweep and the arithmetic sweep were ALL GREEN while mc-tcc was
# silently writing a zero addend into every `pointer = array + N` relocation --
# see EXPERIMENT-zzzzc. The self-compilation fixpoint was green too, because a
# fixpoint proves a compiler is STABLE and not that it is correct. This found
# it in one run: one object out of 250 differed, by a single byte, and that
# byte was the addend.
#
# It is also the only instrument here that needs no expected values. gcc's tcc
# and micro-c's tcc are the same program; if they disagree about a single byte
# of output, one of them is wrong, and it is not the one gcc built.
#
# WHAT COUNTS AS AN EXPECTED DIFFERENCE. Floating point, and only that.
# micro-c has no floats -- it maps float, double and long double onto one
# word-sized integer -- and the tcc-microc series gives the tcc it builds an
# eight-byte long double. So anything float-shaped legitimately differs. On
# musl 1.2.5 that is src/math plus floatscan.c, vfprintf.c and getloadavg.c.
# A divergence OUTSIDE that set is a defect.
#
# usage:  objdiff-corpus.sh <workdir> <corpus-root> [include-flags...]
#
#   <workdir>      a directory local-tcc.sh has already built in: it needs
#                  mc-tcc and tcc-work/
#   <corpus-root>  a tree of .c/.S files. musl is the one this was written
#                  against; any large C project works.
#
# The control is built here rather than assumed, from tcc-work's own source, so
# the two compilers can never be reading different trees -- which is the
# mistake that cost a round in the <float.h> episode.
set -eu

WORK="${1:-}"
CORPUS="${2:-}"
[ -n "$WORK" ] && [ -n "$CORPUS" ] || { echo "usage: $0 <workdir> <corpus-root> [-I...]"; exit 2; }
shift 2
WORK=$(cd "$WORK" && pwd)
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
Q="$ROOT/spikes/toolbox/qemu-aarch64-static"
[ "$(uname -m)" = "aarch64" ] && Q=""
L="$ROOT/spikes/stage3/micro-c-libc"

[ -x "$WORK/mc-tcc" ] || { echo "FAIL: no mc-tcc in $WORK -- run local-tcc.sh first"; exit 1; }
[ -d "$WORK/tcc-work" ] || { echo "FAIL: no tcc-work in $WORK"; exit 1; }

CTL=/tmp/objdiff-control-tcc
echo "== building the control tcc with gcc, from tcc-work's own source =="
# libtcc1-softfloat.c supplies sf_from_int and sf_from_f32, which the
# tcc-microc constant-folder patch calls and which no host library has.
( cd "$WORK/tcc-work" && gcc -w -O1 -o "$CTL" tcc.c "$L/impl/libtcc1-softfloat.c" \
    -I . -lm -ldl -lpthread ) || { echo "FAIL: control would not build"; exit 1; }
echo "   $("$CTL" -v 2>&1 | head -1)"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
find "$CORPUS" \( -name '*.c' -o -name '*.S' \) | sort > "$T/files"
echo "== $(wc -l < "$T/files") files =="

same=0; diffn=0; skip=0; subjonly=0
cd "$WORK/tcc-work"
while IFS= read -r f; do
    "$CTL" -B. "$@" -c -o "$T/c.o" "$f" >/dev/null 2>&1; a=$?
    if [ -n "$Q" ]; then "$Q" "$WORK/mc-tcc" -B. "$@" -c -o "$T/s.o" "$f" >/dev/null 2>&1
    else "$WORK/mc-tcc" -B. "$@" -c -o "$T/s.o" "$f" >/dev/null 2>&1; fi
    b=$?
    if [ "$a" != 0 ] || [ "$b" != 0 ]; then
        skip=$((skip + 1))
        # THE ASYMMETRIC CASE IS THE INTERESTING ONE: the control compiled it
        # and the subject did not. That is a defect even though no bytes can
        # be compared.
        if [ "$a" = 0 ]; then
            subjonly=$((subjonly + 1))
            printf '  SUBJECT WILL NOT COMPILE  %s\n' "${f#$CORPUS/}"
        fi
        continue
    fi
    if cmp -s "$T/c.o" "$T/s.o"; then
        same=$((same + 1))
    else
        diffn=$((diffn + 1))
        printf '  differs  %-52s %s bytes\n' "${f#$CORPUS/}" \
            "$(cmp -l "$T/c.o" "$T/s.o" 2>/dev/null | wc -l)"
    fi
done < "$T/files"

echo
printf '  identical %s   differ %s   both-failed %s   SUBJECT-ONLY FAILURES %s\n' \
    "$same" "$diffn" "$((skip - subjonly))" "$subjonly"
echo "  Read the 'differs' list: anything that is not floating point is a defect."
[ "$subjonly" = 0 ] || exit 1
