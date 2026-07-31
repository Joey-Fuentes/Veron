#!/bin/sh
# Every tests2 case, through mc-tcc, with a gcc-built tcc from the SAME source
# as the control.
#
# THE CONTROL DECIDES WHICH TESTS COUNT. A test the control cannot pass is
# measuring a gap in tcc-test-shim -- no malloc, no file I/O, no floats -- not
# a defect in the compiler we built. Only tests the control passes can fail
# against us.
#
# THE CONTROL HAS TO BE BUILT FIRST, AND NOTHING ELSE BUILDS IT.
#
#     gcc -w -O1 -o /tmp/tcc-control <workdir>/tcc-work/tcc.c \
#         -I<workdir>/tcc-work -lm -ldl -lpthread
#
# The tree is already configured for arm64, so that gcc build is an aarch64
# CROSS compiler running on x86_64 -- which is exactly the control wanted: same
# source, same target, different builder. Override the path with CTL=.
#
# Without it every test reports "control will not compile it" and the sweep
# says 0 pass / 0 fail / 129 not-applicable, which looks like a clean run and
# is a harness that never started.
#
# BOTH SIDES GET THE SAME SINGLE FILE. test.c and crt.c are concatenated first
# so that the control and mc-tcc are handed byte-identical input; feeding one
# of them two files and the other one would measure the multi-TU path instead
# of codegen, which is a different question.
#
# THREE BUCKETS, NOT TWO. tcc-test-shim aborts with a distinct exit status
# depending on WHOSE gap stopped it:
#
#     70   [shim: ...]        the shim is incomplete. Our harness's fault.
#     71   [needs-float: ...] the conversion is fine and MICRO-C cannot hold
#                             the value. Blocked on the compiler.
#
# Ten tests2 programs land in the second and were being reported as the first,
# which charged this directory for a floating-point implementation it cannot
# have until micro-c grows one. They are counted separately now.
#
# ARGS. tests2/Makefile:59 runs 31_args with five arguments and its .expect
# carries argc==6. Running it with none makes a correct binary print 1 and look
# broken, so the table below mirrors that line.
#
# THE EMULATOR. Our binary is aarch64 and this script is normally run on an
# x86_64 development machine. Running it as `./m.bin` returns 126 for every
# test and reports it as "output differs" -- the control two lines above was
# already going through the emulator, which makes the asymmetry easy to read
# past. Both sides go through $Q.
set -u
V=$(cd "$(dirname "$0")/../../.." && pwd)
W=$V/build/local
Q=$V/spikes/toolbox/qemu-aarch64-static
SH=$V/spikes/stage3/tcc-test-shim
T2=$W/tcc-work/tests/tests2
CTL=${CTL:-/tmp/tcc-control}
OUT=/tmp/sweep
rm -rf $OUT; mkdir -p $OUT
cd $OUT

[ -x "$CTL" ] || { echo "no control at $CTL -- see the header"; exit 2; }
[ -x "$W/mc-tcc" ] || { echo "no mc-tcc at $W/mc-tcc"; exit 2; }

# tests2/Makefile:59. Kept here rather than parsed out of the Makefile because
# there are two entries and one of them (46_grep) wants file I/O the shim does
# not have, so it never becomes applicable anyway.
args_for() {
    case $1 in
        31_args) echo "arg1 arg2 arg3 arg4 arg5" ;;
        *)       echo "" ;;
    esac
}

# COMPARE THE WAY tcc COMPARES: `diff -Nbu`, tests2/Makefile:142. `-b` ignores
# changes in the AMOUNT of whitespace and the .expect files rely on it --
# 38_multiple_array_index emits a trailing space per element that its .expect
# does not carry. Comparing strictly marks those failed and reports a compiler
# defect where there is a space.
same_output() {
    _a=$(printf '%s' "$1" | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]*$//')
    _b=$(printf '%s' "$2" | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]*$//')
    [ "$_a" = "$_b" ]
}

pass=0; fail=0; na=0; nf=0
: > /tmp/sweep-pass.txt; : > /tmp/sweep-fail.txt; : > /tmp/sweep-na.txt
: > /tmp/sweep-needs-float.txt

for c in "$T2"/*.c; do
  b=$(basename "$c" .c)
  exp="$T2/$b.expect"
  [ -f "$exp" ] || { echo "$b  no .expect" >> /tmp/sweep-na.txt; na=$((na+1)); continue; }

  # test first, then the crt. The declaration of main in crt.c is stripped for
  # tidiness only -- it is an empty parameter list now and no longer conflicts
  # with any of the three main shapes the suite uses, so leaving it in also
  # works.
  cat "$c" > u.c
  cat "$SH/crt.c" >> u.c
  a=$(args_for "$b")

  # --- control -------------------------------------------------------------
  "$CTL" -B"$W/tcc-work" -I"$SH" -nostdlib -static -o c.bin u.c >/dev/null 2>&1
  if [ $? != 0 ] || [ ! -s c.bin ]; then
    echo "$b  control will not compile it" >> /tmp/sweep-na.txt; na=$((na+1)); continue
  fi
  chmod +x c.bin
  cout=$(timeout 20 "$Q" ./c.bin $a 2>&1); crc=$?
  # THE CONTROL HITTING 71 IS NOT A SHIM GAP. It means the test prints a float,
  # which the shim deliberately refuses because micro-c cannot compute one.
  # Naming that separately is the whole point of the split status.
  if [ "$crc" = 71 ]; then
    echo "$b  blocked on floating point in micro-c, not a shim gap" >> /tmp/sweep-needs-float.txt
    nf=$((nf+1)); continue
  fi
  if ! same_output "$cout" "$(cat "$exp")"; then
    echo "$b  control output differs from .expect (rc=$crc)" >> /tmp/sweep-na.txt
    na=$((na+1)); continue
  fi

  # --- ours ----------------------------------------------------------------
  timeout 180 "$Q" "$W/mc-tcc" -B"$W/tcc-work" -I"$SH" -nostdlib -static \
      -o m.bin u.c >/dev/null 2>m.err
  mrc=$?
  if [ "$mrc" != 0 ] || [ ! -s m.bin ]; then
    why=$(grep -av '^[A-Z][0-9]*$' m.err | head -1)
    [ "$mrc" -gt 128 ] && why="SIGNAL $((mrc-128)) during compile"
    echo "$b  COMPILE rc=$mrc  $why" >> /tmp/sweep-fail.txt
    fail=$((fail+1)); continue
  fi
  chmod +x m.bin
  # UNDER THE EMULATOR. m.bin is aarch64; running it directly on an x86_64
  # host returns 126 for every test and reads as "output differs".
  mout=$(timeout 20 "$Q" ./m.bin $a 2>&1); mrc2=$?
  if [ "$mrc2" = 71 ]; then
    echo "$b  reached a float only under mc-tcc" >> /tmp/sweep-needs-float.txt
    nf=$((nf+1)); continue
  fi
  if same_output "$mout" "$cout"; then
    echo "$b" >> /tmp/sweep-pass.txt; pass=$((pass+1))
  else
    echo "$b  RAN rc=$mrc2 but output differs" >> /tmp/sweep-fail.txt
    fail=$((fail+1))
  fi
done

echo
echo "  tests2 through mc-tcc:  pass $pass   fail $fail   needs-float $nf   not-applicable $na"
echo "    needs-float is blocked on micro-c having no floating point;"
echo "    not-applicable is blocked on tcc-test-shim. /tmp/sweep-*.txt has both."
