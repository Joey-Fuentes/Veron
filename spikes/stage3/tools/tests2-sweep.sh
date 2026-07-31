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
# BOTH SIDES GET THE SAME SINGLE FILE. mc-tcc cannot yet take two inputs in one
# invocation, so test.c and crt.c are concatenated first. Feeding the control
# two files and mc-tcc one would measure the multi-TU gap instead of codegen,
# which is a different open question and already recorded.
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

pass=0; fail=0; na=0
: > /tmp/sweep-pass.txt; : > /tmp/sweep-fail.txt; : > /tmp/sweep-na.txt

for c in "$T2"/*.c; do
  b=$(basename "$c" .c)
  exp="$T2/$b.expect"
  [ -f "$exp" ] || { echo "$b  no .expect" >> /tmp/sweep-na.txt; na=$((na+1)); continue; }

  # test first, then the crt with its forward declaration of main removed --
  # main is already defined by the time _start refers to it.
  cat "$c" > u.c
  grep -v '^int main(void);$' "$SH/crt.c" >> u.c

  # --- control -------------------------------------------------------------
  "$CTL" -B"$W/tcc-work" -I"$SH" -nostdlib -static -o c.bin u.c >/dev/null 2>&1
  if [ $? != 0 ] || [ ! -s c.bin ]; then
    echo "$b  control will not compile it" >> /tmp/sweep-na.txt; na=$((na+1)); continue
  fi
  chmod +x c.bin
  cout=$(timeout 20 "$Q" ./c.bin 2>&1); crc=$?
  if [ "$cout" != "$(cat "$exp")" ]; then
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
  mout=$(timeout 20 ./m.bin 2>&1); mrc2=$?
  if [ "$mout" = "$cout" ]; then
    echo "$b" >> /tmp/sweep-pass.txt; pass=$((pass+1))
  else
    echo "$b  RAN rc=$mrc2 but output differs" >> /tmp/sweep-fail.txt
    fail=$((fail+1))
  fi
done

echo
echo "  tests2 through mc-tcc:  pass $pass   fail $fail   not-applicable $na"
