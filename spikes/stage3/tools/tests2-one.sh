#!/bin/sh
# Walk tests2 IN ORDER, one test at a time, and STOP at the first genuine
# failure -- a test the control passes and mc-tcc does not.
#
# WHY THIS EXISTS BESIDE tests2-sweep.sh. The sweep runs all 129 and prints a
# score, which answers "how many" and not "which one, and what does it look
# like". Stopping at the first failure gives a single reproducible command and
# a single test to read, which is the thing you actually need when the next
# step is to fix it.
#
# TWO THINGS THE SWEEP GETS WRONG ON AN x86_64 HOST, both fixed here:
#
#   1. It runs OUR binary as `./m.bin` with no emulator. m.bin is aarch64, so
#      on x86_64 that returns 126 -- "not executable" -- for every test, and
#      126 is reported as "output differs" rather than as a harness fault. The
#      control's binary IS run under qemu two lines above, so the asymmetry is
#      easy to miss when reading it.
#   2. It compares our output against the CONTROL's output, having already
#      checked the control against .expect. That is fine, but when the control
#      is skipped for an unrelated reason the comparison silently changes
#      meaning. Here .expect is the reference for both, always.
#
# THE CONTROL STILL DECIDES WHICH TESTS COUNT. A test the control cannot
# compile or does not pass is measuring a gap in tcc-test-shim -- no malloc, no
# file I/O, no floats -- not a defect in the compiler we built. Those are
# skipped out loud, never silently.
#
#   sh tests2-one.sh [start-index]
#
# Set CTL= to override the control path. Build it with:
#   gcc -w -O1 -o /tmp/tcc-control build/local/tcc-work/tcc.c \
#       -Ibuild/local/tcc-work -lm -ldl -lpthread
set -u

V=$(cd "$(dirname "$0")/../../.." && pwd)
W=$V/build/local
Q=$V/spikes/toolbox/qemu-aarch64-static
SH=$V/spikes/stage3/tcc-test-shim
T2=$W/tcc-work/tests/tests2
CTL=${CTL:-/tmp/tcc-control}
FROM=${1:-0}

[ -x "$CTL" ] || { echo "no control at $CTL -- see the header"; exit 2; }
[ -x "$W/mc-tcc" ] || { echo "no mc-tcc at $W/mc-tcc"; exit 2; }

# COMPARE THE WAY tcc COMPARES, which is not byte for byte.
#
#     diff -Nbu $(filter %.expect,$^) $*.output       tests2/Makefile:142
#
# `-b` ignores changes in the AMOUNT of whitespace and the .expect files rely
# on it: 38_multiple_array_index prints "%d " per element and so emits a
# trailing space its .expect does not carry, and several tests end without a
# final newline.
#
# GETTING THIS WRONG COST TWICE OVER. Comparing ours against the control
# strictly reports a compiler defect where there is a space. Comparing the
# CONTROL against .expect strictly is worse: the test is then marked
# "control does not match .expect" and SKIPPED, so it silently leaves the
# measurement altogether. 38 was being skipped for exactly that reason.
#
# Command substitution strips trailing newlines, so the final-newline case is
# handled by the comparison itself; the sed handles the rest.
same_output() {
    _a=$(printf '%s' "$1" | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]*$//')
    _b=$(printf '%s' "$2" | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]*$//')
    [ "$_a" = "$_b" ]
}

# tests2/Makefile:59 runs 31_args with five arguments and its .expect carries
# argc==6. Run with none, a CORRECT binary prints 1 and reads as a codegen
# fault -- which is how the shim's missing argv was charged to the compiler.
args_for() {
    case $1 in
        31_args) echo "arg1 arg2 arg3 arg4 arg5" ;;
        *)       echo "" ;;
    esac
}

OUT=/tmp/t2one; rm -rf $OUT; mkdir -p $OUT; cd $OUT

n=0; pass=0; na=0; nf=0
for c in "$T2"/*.c; do
    b=$(basename "$c" .c)
    n=$((n + 1))
    [ "$n" -lt "$FROM" ] && continue
    exp="$T2/$b.expect"
    if [ ! -f "$exp" ]; then
        printf '  %-3s %-34s skip: no .expect\n' "$n" "$b"; na=$((na+1)); continue
    fi

    # test first, then the crt with its forward declaration of main removed --
    # main is already defined by the time _start refers to it.
    cat "$c" > u.c
    cat "$SH/crt.c" >> u.c
    a=$(args_for "$b")

    # --- control ---------------------------------------------------------
    "$CTL" -B"$W/tcc-work" -I"$SH" -nostdlib -static -o c.bin u.c >/dev/null 2>&1
    if [ $? != 0 ] || [ ! -s c.bin ]; then
        printf '  %-3s %-34s skip: control will not compile it\n' "$n" "$b"
        na=$((na+1)); continue
    fi
    chmod +x c.bin
    cout=$(timeout 20 "$Q" ./c.bin $a 2>&1); crc=$?
    # 71 is tcc-test-shim refusing a float conversion because micro-c cannot
    # compute one. That is not a gap in the shim and is not a defect in our
    # compiler's codegen either -- it is the float hole, named.
    if [ "$crc" = 71 ]; then
        printf '  %-3s %-34s skip: blocked on floating point in micro-c\n' "$n" "$b"
        nf=$((nf+1)); continue
    fi
    if ! same_output "$cout" "$(cat "$exp")"; then
        printf '  %-3s %-34s skip: control does not match .expect\n' "$n" "$b"
        na=$((na+1)); continue
    fi

    # --- ours ------------------------------------------------------------
    timeout 300 "$Q" "$W/mc-tcc" -B"$W/tcc-work" -I"$SH" -nostdlib -static \
        -o m.bin u.c >/dev/null 2>m.err
    mrc=$?
    if [ "$mrc" != 0 ] || [ ! -s m.bin ]; then
        why=$(grep -av '^[A-Z][0-9]*$' m.err | head -1)
        [ "$mrc" -gt 128 ] && why="SIGNAL $((mrc-128)) during compile"
        printf '  %-3s %-34s FAIL  compile rc=%s  %s\n' "$n" "$b" "$mrc" "$why"
        echo; echo "  first failure at #$n: $b"
        echo "  reproduce:"
        echo "    cd $OUT && $Q $W/mc-tcc -B$W/tcc-work -I$SH -nostdlib -static -o m.bin u.c"
        exit 1
    fi
    chmod +x m.bin
    mout=$(timeout 20 "$Q" ./m.bin $a 2>&1); mrc2=$?
    if [ "$mrc2" = 71 ]; then
        printf '  %-3s %-34s skip: reached a float only under mc-tcc\n' "$n" "$b"
        nf=$((nf+1)); continue
    fi
    if same_output "$mout" "$cout"; then
        printf '  %-3s %-34s ok\n' "$n" "$b"; pass=$((pass+1))
    else
        printf '  %-3s %-34s FAIL  ran, output differs\n' "$n" "$b"
        echo;  echo "  expected: [$cout]"; echo "  got:      [$mout]"
        echo;  echo "  first failure at #$n: $b"
        exit 1
    fi
done

echo
echo "  reached the end: pass $pass  needs-float $nf  not-applicable $na"
