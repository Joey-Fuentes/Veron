#!/bin/sh
# CAN mc-tcc BUILD A libc? -- the prerequisites, measured rather than assumed.
#
# WHY THIS EXISTS. stage 4 already proved the recipe: a musl 1.2.5 + BusyBox
# userland compiled entirely by tcc boots as PID 1 (spikes/stage4/TCC-USERLAND.md).
# But that tcc was built by the HOST's gcc -- stage4-complete.yml names it "the
# one declared hole". Stage 3's job is to remove the hole, which means mc-tcc
# has to clear the same bar, and nothing was checking whether it does.
#
# WHY IT MATTERS BEYOND SELF-HOSTING. mc-tcc must eventually compile binutils
# and gcc with no host anything. That needs a libc built IN-CHAIN, because the
# stage 3 box has no /usr at all -- only busybox. live-bootstrap solves the same
# problem by building mes-libc with a weak compiler and then musl with tcc; our
# direct route has M2libc in mes-libc's place already, so musl-built-by-mc-tcc
# is the next rung either way.
#
# WHAT IS CHECKED, and each is a thing musl actually needs:
#
#   A  libtcc1 for arm64 -- tcc's OWN runtime, from tcc's own sources. Every
#      program mc-tcc links needs it: __addtf3 and the other soft-float
#      helpers, __clear_cache, alloca. Note libtcc1.c is NOT in the arm64 build
#      (ARM64_O = lib-arm64.o $(COMMON_O)); reaching for it gives a misleading
#      "unsupported CPU type" that says nothing about the compiler.
#
#   B  musl's IDIOMS -- weak_alias, hidden visibility, __typeof, a weak symbol
#      tested for null. musl is built out of these; a libc cannot be compiled
#      by a compiler that lacks them.
#
#   C  REGISTER-CONSTRAINED SYSCALLS, COMPILED AND RUN. This is the one that
#      cannot be checked by compiling alone. musl's syscall layer pins operands
#      to x8/x0-x5 with register asm; a compiler that accepts the syntax and
#      allocates a different register produces a binary that makes the WRONG
#      SYSCALL and says nothing. So the rung is executed and its output and
#      exit status are checked -- freestanding, own _start, no libc under it.
#
# WHAT IT DOES NOT CHECK. Whether musl itself compiles. That needs musl, which
# is pinned in sources/musl.toml and not vendored. This measures the floor musl
# stands on; clearing it is necessary and not sufficient.
#
#   sh runtime-ladder.sh [workdir]        default build/local
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
W=${1:-$ROOT/build/local}
case "$W" in /*) ;; *) W="$(cd "$W" && pwd)" ;; esac
Q="$ROOT/spikes/toolbox/qemu-aarch64-static"
T="$W/tcc-work"
MC="$W/mc-tcc"

[ -x "$MC" ] || { echo "no mc-tcc at $MC -- run local-tcc.sh first"; exit 2; }
[ -d "$T" ] || { echo "no tcc tree at $T"; exit 2; }

# NATIVE OR EMULATED, decided once. On an aarch64 runner the emulator is not
# only unnecessary, it is an x86_64 binary and cannot run at all.
if [ "$(uname -m)" = aarch64 ]; then RUN=""; else RUN="$Q"; fi

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

echo
echo "== A. libtcc1 for arm64, from tcc's own sources =="
# The arm64 object list, read from tcc's lib/Makefile rather than guessed:
#   ARM64_O = lib-arm64.o $(COMMON_O)
#   COMMON_O = stdatomic.o atomic.o builtin.o alloca.o alloca-bt.o
#   LIN_O = dsohandle.o
a_ok=0; a_n=0
for f in lib-arm64.c stdatomic.c atomic.S builtin.c alloca.S alloca-bt.S dsohandle.c; do
    a_n=$((a_n + 1))
    rm -f "$D/o.o" "$D/e"
    set +e
    timeout 300 $RUN "$MC" -B"$T" -I"$T" -w -c -o "$D/o.o" "$T/lib/$f" 2>"$D/e"
    rc=$?
    set -e
    if [ "$rc" = 0 ] && [ -s "$D/o.o" ]; then
        a_ok=$((a_ok + 1))
        printf '   %-16s ok  %s bytes\n' "$f" "$(wc -c < "$D/o.o")"
    else
        printf '   %-16s FAIL rc=%s  %s\n' "$f" "$rc" \
            "$(grep -av '^[A-Z][0-9]*$' "$D/e" | head -1 | cut -c1-44)"
        fail=1
    fi
done
echo "   libtcc1: $a_ok of $a_n"

echo
echo "== B. musl's idioms =="
b_ok=0; b_n=0
idiom() {
    b_n=$((b_n + 1))
    printf '%s\n' "$2" > "$D/i.c"
    rm -f "$D/i.o"
    set +e
    timeout 120 $RUN "$MC" -B"$T" -I"$T" -w -c -o "$D/i.o" "$D/i.c" 2>"$D/e"
    rc=$?
    set -e
    if [ "$rc" = 0 ]; then
        b_ok=$((b_ok + 1)); printf '   %-32s ok\n' "$1"
    else
        printf '   %-32s FAIL  %s\n' "$1" \
            "$(grep -av '^[A-Z][0-9]*$' "$D/e" | head -1 | cut -c1-40)"
        fail=1
    fi
}
idiom "weak_alias" 'int __real_fn(void){return 1;}
extern __typeof(__real_fn) fn __attribute__((weak, alias("__real_fn")));'
idiom "hidden visibility" 'int h(void) __attribute__((__visibility__("hidden")));
int h(void){return 2;}'
idiom "__typeof" 'int a; __typeof(a) b; int f(void){ b=1; return b; }'
idiom "weak symbol tested for null" 'int maybe(void) __attribute__((weak));
int f(void){ return maybe ? maybe() : 0; }'
echo "   idioms: $b_ok of $b_n"

echo
echo "== C. register-constrained syscalls, COMPILED AND RUN =="
# Freestanding: own _start, no libc, no crt. If this passes, the layer musl's
# entire syscall surface is built on works -- and it is checked by RUNNING,
# because a wrong register allocation compiles cleanly and calls the wrong
# syscall.
cat > "$D/r1.c" <<'EOF'
static long sc1(long n, long a){
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = a;
  __asm__ __volatile__ ("svc 0" : "+r"(x0) : "r"(x8) : "memory","cc");
  return x0;
}
static long sc3(long n, long a, long b, long c){
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  __asm__ __volatile__ ("svc 0" : "+r"(x0) : "r"(x8),"r"(x1),"r"(x2) : "memory","cc");
  return x0;
}
void _start(void){
  const char* m = "syscalls work\n";
  sc3(64, 1, (long)m, 14);
  sc1(93, 7);
}
EOF
rm -f "$D/r1.bin"
set +e
timeout 300 $RUN "$MC" -B"$T" -nostdlib -static -o "$D/r1.bin" "$D/r1.c" 2>"$D/e"
crc=$?
set -e
if [ "$crc" != 0 ] || [ ! -s "$D/r1.bin" ]; then
    echo "   rung 1: WILL NOT BUILD rc=$crc  $(grep -av '^[A-Z][0-9]*$' "$D/e" | head -1)"
    fail=1
else
    chmod 0755 "$D/r1.bin"
    set +e
    out=$($RUN "$D/r1.bin" 2>&1); rrc=$?
    set -e
    # exit 7 AND the right bytes. Either alone can pass while the other is
    # wrong: a bad write still exits 7, and a bad exit still prints.
    if [ "$rrc" = 7 ] && [ "$out" = "syscalls work" ]; then
        echo "   rung 1: ok -- write() correct, exit(7) correct"
    else
        echo "   rung 1: WRONG  exit=$rrc (want 7)  out=[$out] (want [syscalls work])"
        fail=1
    fi
fi

echo
if [ "$fail" = 0 ]; then
    echo "  FLOOR CLEAR: mc-tcc has what a libc build stands on."
    echo "  Necessary, not sufficient -- musl itself is untested until it is fetched."
else
    echo "  NOT CLEAR: something musl needs is missing above."
fi
exit 0
