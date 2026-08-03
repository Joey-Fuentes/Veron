#!/bin/sh
# THE USUAL ARITHMETIC CONVERSIONS, SWEPT RATHER THAN SAMPLED.
#
# WHY THIS IS NOT A CASE. Every other defect in this tree is a parse path: name
# the cause, fix it, and one case in tools/cases is a fair witness. The usual
# arithmetic conversions are not a path, they are a RULE OVER A SPACE -- every
# combination of two operand types, an operator, a literal base and a literal
# suffix. A rule like that cannot be verified at four points, and case 110 has
# exactly four.
#
# Case 110 was also written FROM the bug, so it passing is close to
# tautological. MICRO-C.md records the general form of that mistake: "a test
# suite written from bugs already found measures what has been fixed, not what
# remains". Borrowing stage 2's corpus is how that was escaped last time; this
# generates the space instead of borrowing someone else's.
#
# WHAT IT FOUND, in order, none of which case 110 probes:
#   0x87654321L        typed unsigned int; C89 3.1.3.2 puts an l/L suffix on
#                      the list `long, unsigned long`, skipping unsigned int
#   0x87654321UL       same, for the unsigned-long list
#   char vs UINT_MAX   the integer promotions run FIRST, so an operand
#                      narrower than int has to convert too
#   char * 0x80000000  unsigned int arithmetic is modulo 2^32; a 64-bit
#                      register kept bits the type does not have
#   char + 0xFFFFFFFF  the additive path has its own code for pointer scaling
#                      and never reached the conversion at all
#
# BATCHED, BECAUSE THE OBVIOUS SHAPE DOES NOT FINISH. One program per point
# means gcc, micro-c, M1, hex2 and a run for each of ~12,000 points -- 60,000
# processes. Each program here carries CHUNK points, so the whole space costs
# about 64 compiles per side.
#
# HOW A POINT IS CHECKED. gcc is the oracle: C defines the answer and gcc
# agrees with C on integer conversions. The gcc build PRINTS its answers; those
# are baked into a second program as a string, and the micro-c build
# self-checks against them and returns 1 + the index of the first
# disagreement. So the two compilers never have to agree about printf, the
# subject stays freestanding, and a failure names the exact point rather than
# the batch.
#
# usage: [ARCH=amd64|aarch64] uac-sweep.sh <micro-c> <m2libc> <mescc-bin> [types]
#
# NO GLOBBING. The operator list contains `*`, and an unquoted `$OPS` in a
# `for` expands it against the working directory -- the first version of this
# swept `char == README.txt` and called 271 of 400 points "gcc would not build
# it". A harness that generates its own operators has to stop the shell reading
# them as patterns.
# THE FIELD SEPARATOR IS NOT `|`. It was, and `|` is also one of the twelve
# operators -- so every eleventh point generated `(x  2147483647)` with the
# operator silently dropped, and gcc refused the whole batch. A generator whose
# data includes shell metacharacters has to pick a separator its data cannot
# contain; `~` appears in no operator, value or literal here.
set -eu
set -f

MICROC="${1:-}"
M2LIBC="${2:-}"
MESCC="${3:-}"
ARCH="${ARCH:-amd64}"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)

if [ -z "$MICROC" ] || [ -z "$M2LIBC" ] || [ -z "$MESCC" ]; then
    echo "usage: [ARCH=amd64|aarch64] $0 <micro-c> <m2libc-dir> <mescc-bin> [types]"
    exit 2
fi

# aarch64 output cannot run on an amd64 host. Same guard, and same reason, as
# difftest-qemu.sh: a suite reporting "everything failed" because it is on the
# wrong machine is worse than one that refuses to run.
Q=""
if [ "$ARCH" = "aarch64" ] && [ "$(uname -m)" != "aarch64" ]; then
    Q="$ROOT/spikes/toolbox/qemu-aarch64-static"
    [ -x "$Q" ] || { echo "FAIL: $Q missing"; exit 1; }
fi

D="$M2LIBC/$ARCH"
BASE=0x600000
[ "$ARCH" = "aarch64" ] && BASE=0x400000
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# THE SPACE. char and short are in because the integer promotions run before
# anything else, and a promotion that forgets its signedness is this same
# defect wearing a smaller type -- which is what the sweep caught.
TYPES="${4:-char signed_char unsigned_char short unsigned_short int unsigned_int long unsigned_long}"

# The BASE and the SUFFIX select a constant's type in C89 3.1.3.2 -- the half
# of this where three of the five findings were.
LITS="2147483647 2147483648 0x7FFFFFFF 0x80000000 0x87654321 0x87654321u 0x87654321L 0x87654321UL 020653502441 4294967295 0xFFFFFFFF 0xFFFFFFFFu 1 0 -1"
OPS="== != < > <= >= + - * & | ^"
VALS="0 1 -1 2147483647 -2147483648 -2023406815 65535 -1431655766"

CHUNK=192          # points per program; stays under 250 so 1+index fits an rc

ctype() {
    case "$1" in
        signed_char)    echo "signed char" ;;
        unsigned_char)  echo "unsigned char" ;;
        unsigned_short) echo "unsigned short" ;;
        unsigned_int)   echo "unsigned int" ;;
        unsigned_long)  echo "unsigned long" ;;
        *)              echo "$1" ;;
    esac
}

total=0; agree=0; bad=0; chunks=0; skipped=0
first=""

for t in $TYPES; do
  T_C=$(ctype "$t")

  : > "$T/points"
  for v in $VALS; do
    for lit in $LITS; do
      for op in $OPS; do
        echo "$v~$lit~$op" >> "$T/points"
      done
    done
  done

  n_points=$(wc -l < "$T/points")
  off=0
  while [ "$off" -lt "$n_points" ]; do
    chunks=$((chunks + 1))
    sed -n "$((off + 1)),$((off + CHUNK))p" "$T/points" > "$T/chunk"
    n_chunk=$(wc -l < "$T/chunk")

    # ---- the oracle: gcc computes and PRINTS the answers ----
    {
      echo '#include <stdio.h>'
      echo 'int main(void) {'
      printf '\t%s x; int a; int b;\n' "$T_C"
      while IFS='~' read -r v lit op; do
        printf '\tx = (%s)(%s); a = (x %s %s) ? 1 : 0; b = (%s %s x) ? 1 : 0; putchar(48 + a + 2*b);\n' \
               "$T_C" "$v" "$op" "$lit" "$lit" "$op"
      done < "$T/chunk"
      echo '        return 0;'
      echo '}'
    } > "$T/oracle.c"

    if ! gcc -w -O0 -o "$T/oracle" "$T/oracle.c" 2>/dev/null; then
        skipped=$((skipped + n_chunk)); off=$((off + CHUNK)); continue
    fi
    exp=$("$T/oracle")

    # ---- the subject: same points, gcc's answers baked in, self-checking ----
    {
      printf 'char* expected = "%s";\n' "$exp"
      echo 'int main(void) {'
      printf '\t%s x; int a; int b;\n' "$T_C"
      i=0
      while IFS='~' read -r v lit op; do
        printf '\tx = (%s)(%s); a = (x %s %s) ? 1 : 0; b = (%s %s x) ? 1 : 0;\n' \
               "$T_C" "$v" "$op" "$lit" "$lit" "$op"
        printf '\tif(a + 2*b != expected[%s] - 48) return %s;\n' "$i" "$((i + 1))"
        i=$((i + 1))
      done < "$T/chunk"
      echo '        return 0;'
      echo '}'
    } > "$T/subject.c"

    set +e
    "$MICROC" --architecture "$ARCH" --max-string 65536 -f "$T/subject.c" -o "$T/s.M1" 2>/dev/null
    c=$?
    set -e
    if [ "$c" != 0 ]; then
        echo "  $T_C chunk at $off: micro-c WILL NOT COMPILE IT"
        bad=$((bad + 1)); [ -z "$first" ] && first="$T_C@$off"
        off=$((off + CHUNK)); total=$((total + n_chunk)); continue
    fi

    set +e
    "$MESCC/M1" -f "$D/${ARCH}_defs.M1" -f "$D/libc-core.M1" -f "$T/s.M1" \
                --little-endian --architecture "$ARCH" -o "$T/s.hex2" 2>/dev/null
    a1=$?
    "$MESCC/hex2" --architecture "$ARCH" --little-endian --base-address "$BASE" \
                  -f "$D/ELF-$ARCH.hex2" -f "$T/s.hex2" -o "$T/s.bin" 2>/dev/null
    h=$?
    set -e
    if [ "$a1" != 0 ] || [ "$h" != 0 ] || [ ! -s "$T/s.bin" ]; then
        echo "  $T_C chunk at $off: DOES NOT ASSEMBLE OR LINK"
        bad=$((bad + 1)); [ -z "$first" ] && first="$T_C@$off"
        off=$((off + CHUNK)); total=$((total + n_chunk)); continue
    fi

    chmod +x "$T/s.bin"
    set +e
    if [ -n "$Q" ]; then "$Q" "$T/s.bin" >/dev/null 2>&1; else "$T/s.bin" >/dev/null 2>&1; fi
    rc=$?
    set -e

    total=$((total + n_chunk))
    if [ "$rc" = 0 ]; then
        agree=$((agree + n_chunk))
    else
        # rc is 1 + the index of the FIRST disagreement in this chunk, so the
        # exact point is named rather than the batch blamed.
        pt=$(sed -n "${rc}p" "$T/chunk")
        bv=$(echo "$pt" | cut -d'~' -f1)
        bl=$(echo "$pt" | cut -d'~' -f2)
        bo=$(echo "$pt" | cut -d'~' -f3)
        want=$(printf '%s' "$exp" | cut -c"$rc")
        printf '  %-15s x=%-13s %-2s %-13s  gcc=%s  micro-c disagrees\n' \
               "$T_C" "$bv" "$bo" "$bl" "$want"
        agree=$((agree + rc - 1))
        bad=$((bad + 1))
        [ -z "$first" ] && first="$T_C  x=$bv  $bo  $bl"
    fi
    off=$((off + CHUNK))
  done
done

echo
printf '  %s  %s points in %s programs: agree %s   PROGRAMS WITH A MISMATCH %s   gcc-would-not-build %s\n' \
    "$ARCH" "$total" "$chunks" "$agree" "$bad" "$skipped"
if [ "$bad" != 0 ]; then
    echo "  first mismatch: $first"
    exit 1
fi
