#!/bin/sh
# DIFFERENTIAL TEST ONE LEVEL UP: the same program compiled by the CONTROL tcc
# and by the micro-c-built tcc, both RUN, and their output compared.
#
#     sh spikes/stage3/tools/difftest-tcc.sh <workdir> [program.c]
#
# difftest.sh asks whether micro-c generates correct code. This asks whether
# the tcc micro-c BUILT generates correct code, which is the question stage 3
# actually exists to answer, and nothing was asking it.
#
# WHY IT MATTERS MORE THAN IT LOOKS. Every stage-3 fault before this was chased
# through markers in a 350,000-line compile, on CI, against tcctest.c or tcc's
# own source -- inputs big enough that a failure could be almost anything. The
# program below is fifteen lines and freestanding: no libc, no crt, no
# -nostdinc argument, no headers at all. It is hermetic by construction and it
# runs under the committed emulator in about a second.
#
# THE STEP THAT DOES THE MOST WORK is comparing the OBJECT files first. If the
# two tccs emit byte-identical objects, codegen, relocation records and the
# symbol table are all correct and the entire search is in the link. That
# acquitted half the compiler in one command and turned "hello world prints
# nothing" into "one wrong LDR displacement", which was a missing GOT entry,
# which was an allocation sized through a scaled expression -- EXPERIMENT-zzt.
#
# WHAT THE CONTROL IS. A tcc built by gcc from the same pin with the same
# patches. It is the yardstick everywhere else in this stage and it is the
# yardstick here. Point CONTROL_TCC at one; if it is a cross compiler running
# on the host, that is fine -- only its OUTPUT is compared, and the output is
# aarch64 either way.
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=${1:?usage: difftest-tcc.sh <workdir> [program.c]}
WORK=$(cd "$WORK" && pwd)
PROG=${2:-}
Q="$ROOT/spikes/toolbox/qemu-aarch64-static"
MC="$WORK/mc-tcc"
SRC="$WORK/tcc-work"
CONTROL="${CONTROL_TCC:-}"

[ -x "$MC" ]  || { echo "FAIL: no mc-tcc in $WORK -- run local-tcc.sh first"; exit 1; }
[ -d "$SRC" ] || { echo "FAIL: no tcc-work in $WORK -- run local-tcc.sh first"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

if [ -z "$PROG" ]; then
    # FREESTANDING ON PURPOSE. A libc would put its own code between the
    # compiler and the answer, and there is no in-repo libc a real C compiler
    # can compile against anyway -- M2libc's stdarg.h uses __va_list, an
    # M2-Planet builtin, and micro-c-libc declares printf without `...`.
    # Syscalls direct means the only code in the binary is the code under test.
    PROG="$T/hello.c"
    cat > "$PROG" <<'EOF'
static long sys3(long n, long a, long b, long c)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    __asm__ __volatile__("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}
void _start(void)
{
    sys3(64, 1, (long)"hello, world\n", 13);   /* write */
    sys3(93, 0, 0, 0);                          /* exit  */
}
EOF
    EXPECT="hello, world"
else
    EXPECT=""
fi

echo "== subject: the tcc micro-c built =="
set +e
"$Q" "$MC" -B"$SRC" -I"$SRC" -I"$SRC/include" -nostdlib -c -o "$T/mc.o" "$PROG" 2>"$T/mc.cerr"
mc_c=$?
"$Q" "$MC" -B"$SRC" -I"$SRC" -I"$SRC/include" -nostdlib -static -o "$T/mc.bin" "$PROG" 2>"$T/mc.lerr"
mc_l=$?
set -e
echo "  compile rc=$mc_c   link rc=$mc_l   $( [ -f "$T/mc.bin" ] && stat -c%s "$T/mc.bin" || echo 0 ) bytes"

if [ -z "$CONTROL" ]; then
    echo "  (no CONTROL_TCC set -- running the subject alone)"
else
    echo "== control: the tcc gcc built =="
    set +e
    "$CONTROL" -B"$(dirname "$CONTROL")" -nostdlib -c -o "$T/ctl.o" "$PROG" 2>/dev/null
    "$CONTROL" -B"$(dirname "$CONTROL")" -nostdlib -static -o "$T/ctl.bin" "$PROG" 2>/dev/null
    set -e
    echo "  $( [ -f "$T/ctl.bin" ] && stat -c%s "$T/ctl.bin" || echo 0 ) bytes"

    # THE OBJECT COMPARISON IS THE ONE THAT SAVES THE MOST TIME.
    echo "== objects =="
    if [ -f "$T/mc.o" ] && [ -f "$T/ctl.o" ]; then
        if cmp -s "$T/mc.o" "$T/ctl.o"; then
            echo "  BYTE-IDENTICAL -- codegen, relocations and symbols are all correct;"
            echo "  anything wrong from here is in the LINK"
        else
            echo "  DIFFER by $(cmp -l "$T/mc.o" "$T/ctl.o" | wc -l) bytes -- the fault is in CODEGEN,"
            echo "  so difftest.sh is the tool, not this one"
        fi
    else
        echo "  one side produced no object"
    fi

    echo "== executables =="
    if [ -f "$T/mc.bin" ] && [ -f "$T/ctl.bin" ]; then
        cmp -s "$T/mc.bin" "$T/ctl.bin" \
            && echo "  BYTE-IDENTICAL" \
            || echo "  differ by $(cmp -l "$T/mc.bin" "$T/ctl.bin" | wc -l) bytes"
    fi
fi

echo "== run =="
run() {
    [ -f "$2" ] || { printf '  %-9s no binary\n' "$1"; return; }
    set +e
    out=$(timeout 60 "$Q" "$2" 2>&1); rc=$?
    set -e
    printf '  %-9s exit=%-4s output=[%s]\n' "$1" "$rc" "$out"
    eval "${3}_out=\$out"
}
run subject "$T/mc.bin" mc
[ -n "$CONTROL" ] && run control "$T/ctl.bin" ctl

# A CRASH AND A SILENT SUCCESS LOOK THE SAME FROM THE EXIT CODE. The binary
# that printed nothing here exited 0: write() had been handed a null pointer
# and returned -EFAULT, which _start ignored. Compare the OUTPUT.
if [ -n "$EXPECT" ]; then
    echo "== verdict =="
    if [ "${mc_out:-}" = "$EXPECT" ]; then
        echo "  PASS: the micro-c-built tcc produced a working program"
        exit 0
    fi
    echo "  FAIL: expected [$EXPECT], got [${mc_out:-}]"
    echo "  a valid ELF that exits 0 and prints nothing is the shape to expect"
    echo "  from a wrong address, not from a crash -- check the .got"
    exit 1
fi
