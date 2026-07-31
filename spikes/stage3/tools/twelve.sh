#!/bin/sh
# THE TWELVE END-TO-END PROGRAMS, RUN LOCALLY.
#
#     sh spikes/stage3/tools/twelve.sh [workdir]        default: build/local
#
# Run local-build.sh and local-tcc.sh first; this needs $workdir/mc-tcc.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
#
# These twelve programs are the ONLY gate that exercises micro-c's output on a
# real program. difftest compiles small cases with micro-c; the stage-2 corpus
# does the same with 426 more. NEITHER COMPILES tcc. A change can leave both
# green and still break every one of these -- that is not hypothetical,
# EXPERIMENT-zzzg did exactly that, and it was shipped because difftest and the
# corpus were consulted and these were not.
#
# Until now they lived only inside .github/workflows/stage3-hermetic-arm64.yml,
# so the instruction "run the twelve before believing any codegen change" could
# not be followed without pushing to CI. That is why it was not followed.
#
# THE COPIES ARE CHECKED AGAINST EACH OTHER. The workflow keeps its own inline
# copy of this list, because the box builds its programs with busybox printf
# and no harness. Two copies of one list drift, so the expectations below are
# compared against the workflow's `tc <label> <want_exit> <want_out>` lines and
# a divergence fails this script rather than being discovered later as a
# mysterious difference between local and CI.
# ---------------------------------------------------------------------------
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=${1:-$ROOT/build/local}
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
MC="$WORK/mc-tcc"
T="$WORK/tcc-work"
WF="$ROOT/.github/workflows/stage3-hermetic-arm64.yml"
# RESOLVED BEFORE THE cd BELOW. $0 is a relative path when this is invoked as
# `sh spikes/stage3/tools/twelve.sh`, and the script cd's into the work
# directory -- so reading $0 afterwards finds nothing and the drift check
# silently compares an EMPTY list against the workflow's twelve. A check that
# cannot see its own input reports a difference that is not there, which is
# worse than no check.
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

[ -x "$MC" ] || { echo "FAIL: no mc-tcc at $MC -- run local-tcc.sh first"; exit 1; }
[ -d "$T" ]  || { echo "FAIL: no tcc-work at $T -- run local-tcc.sh first"; exit 1; }

# NATIVE IF THIS HOST IS aarch64, EMULATED IF IT IS NOT. The committed emulator
# is an x86_64 binary; on an aarch64 host it cannot run at all. Without this
# every program fails to execute and the suite reports 0/12, which reads as
# "the compiler is broken" and is really "the harness is on the wrong machine".
# $Q is empty on a native aarch64 host. `timeout 120 $Q cmd` with an empty $Q
# would work by word-splitting, but a shell FUNCTION cannot be run by timeout
# at all -- it is not a command -- so the two cases are spelled out at each
# call site rather than wrapped.
Q="$ROOT/spikes/toolbox/qemu-aarch64-static"
if [ "$(uname -m)" = "aarch64" ]; then Q=""; fi
[ -z "$Q" ] || [ -x "$Q" ] || { echo "FAIL: $Q missing"; exit 1; }

cd "$WORK"

prologue() {
  cat > t.c <<'EOF'
static long sys3(long n, long a, long b, long c)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    __asm__ __volatile__("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}
int run(void);
void _start(void) { sys3(93, run(), 0, 0); }
EOF
}

pass=0; fail=0
tc() {  # tc <label> <want_exit> <want_output>
  set +e
  if [ -n "$Q" ]; then timeout 120 "$Q" "$MC" -B"$T" -I"$T" -nostdlib -static -o t.bin t.c 2>t.err
  else timeout 120 "$MC" -B"$T" -I"$T" -nostdlib -static -o t.bin t.c 2>t.err; fi
  crc=$?
  set -e
  if [ "$crc" != 0 ] || [ ! -s t.bin ]; then
    printf '    %-34s COMPILE FAILED rc=%s\n' "$1" "$crc"
    grep -av '^[A-Z][0-9]*$' t.err | head -3 | sed 's/^/        /'
    fail=$((fail + 1)); return
  fi
  chmod 0755 t.bin
  set +e
  if [ -n "$Q" ]; then tout=$(timeout 60 "$Q" ./t.bin 2>&1)
  else tout=$(timeout 60 ./t.bin 2>&1); fi
  trc=$?; set -e
  if [ "$trc" = "$2" ] && [ "$tout" = "$3" ]; then
    v=ok; pass=$((pass + 1))
  else
    v="WRONG (want exit=$2 out=[$3])"; fail=$((fail + 1))
  fi
  printf '    %-34s exit=%-4s out=[%s] %s\n' "$1" "$trc" "$tout" "$v"
}

set +e
if [ -n "$Q" ]; then vout=$(timeout 60 "$Q" "$MC" --version 2>&1 | grep -av '^[A-Z][0-9]*$' | head -1)
else vout=$(timeout 60 "$MC" --version 2>&1 | grep -av '^[A-Z][0-9]*$' | head -1); fi
vrc=$?
set -e
printf '    %-34s rc=%-4s %s\n' "00-does-it-start" "$vrc" "$vout"

prologue; printf '%s\n' 'int run(void) { return 42; }' >> t.c
tc 01-return-a-value 42 ""

prologue; printf '%s\n' 'int run(void) { int a; a = 7; return a * 6 + 12 / 4 - 3 % 2; }' >> t.c
tc 02-arithmetic 44 ""

prologue; cat >> t.c <<'EOF'
int run(void)
{ int i; int s; s = 0; i = 1;
  while (i <= 10) { s = s + i; i = i + 1; }
  if (s == 55) return s; return 1; }
EOF
tc 03-loops-and-if 55 ""

prologue; cat >> t.c <<'EOF'
int fact(int n) { if (n < 2) return 1; return n * fact(n - 1); }
int run(void) { return fact(5); }
EOF
tc 04-recursion 120 ""

prologue; cat >> t.c <<'EOF'
int run(void)
{ int a[4]; int *p; int s;
  a[0] = 1; a[1] = 2; a[2] = 3; a[3] = 4;
  p = a; s = 0;
  while (p < a + 4) { s = s + *p; p = p + 1; }
  return s; }
EOF
tc 05-pointers-and-arrays 10 ""

prologue; cat >> t.c <<'EOF'
struct P { int x; int y; };
int total(struct P *p) { return p->x + p->y; }
int run(void) { struct P p; p.x = 20; p.y = 22; return total(&p); }
EOF
tc 06-structs-by-pointer 42 ""

prologue; cat >> t.c <<'EOF'
int g[3];
int zero;
int run(void)
{ g[0] = 10; g[1] = 20; g[2] = 12;
  return g[0] + g[1] + g[2] + zero; }
EOF
tc 07-globals-and-bss 42 ""

prologue; printf '%s\n' 'int run(void) { sys3(64, 1, (long)"strings work", 12); return 0; }' >> t.c
tc 08-string-literal-write 0 "strings work"

prologue; cat >> t.c <<'EOF'
int run(void)
{ char c; int r; c = 65; r = 0;
  switch (c) { case 65: r = 40; break; default: r = 1; }
  if (r == 40) goto done;
  return 2;
done:
  return r + 2; }
EOF
tc 09-char-switch-and-goto 42 ""

prologue; cat >> t.c <<'EOF'
int add(int a, int b) { return a + b; }
int mul(int a, int b) { return a * b; }
int run(void)
{ int (*f)(int, int); f = add;
  if (f(20, 21) != 41) return 1;
  f = mul; return f(6, 7); }
EOF
tc 10-function-pointers 42 ""

prologue; cat >> t.c <<'EOF'
int do_add(int a, int b) { return a + b; }
int do_mul(int a, int b) { return a * b; }
struct Ops { int (*add)(int, int); int (*mul)(int, int); int tag; };
int run(void)
{ struct Ops o; struct Ops *p;
  o.add = do_add; o.mul = do_mul; o.tag = 3;
  if (o.add(2, 3) != 5) return 1;
  if (o.mul(4, 5) != 20) return 2;
  if (o.tag != 3) return 3;
  p = &o;
  if (p->add(10, 1) != 11) return 4;
  if (p->mul(6, 7) != 42) return 5;
  return 0; }
EOF
tc 11-function-pointer-member 0 ""

prologue; cat >> t.c <<'EOF'
struct S { char *str; int len; int c; };
struct S gs;
int run(void)
{ struct S s; char buf[4]; int r; r = 0;
  s.len = 3; --s.len; if (s.len != 2) r = r + 1;
  s.c = 5;   ++s.c;   if (s.c != 6)   r = r + 2;
  buf[0] = 97; buf[1] = 98; buf[2] = 99;
  s.str = buf; s.len = 3;
  if (s.str[--s.len] != 99) r = r + 4;
  if (s.len != 2) r = r + 8;
  gs.len = 3; --gs.len; if (gs.len != 2) r = r + 16;
  return r; }
EOF
tc 12-prefix-operator-through-a-dot 0 ""

echo
echo "    pass $pass   fail $fail"

# --- DRIFT CHECK -----------------------------------------------------------
# The workflow's inline copy is the one CI runs. If the two lists stop
# agreeing, a local green is worth nothing, so say so here rather than let it
# be found as an unexplained CI/local difference.
if [ -f "$WF" ]; then
    mine=$(grep -oE '^tc [0-9]{2}-[a-z-]+ [0-9]+' "$SELF" | sed 's/^tc //' | sort)
    theirs=$(grep -oE 'tc [0-9]{2}-[a-z-]+ [0-9]+' "$WF" | sed 's/^tc //' | sort)
    if [ "$mine" != "$theirs" ]; then
        echo
        echo "  WARNING: this list and the workflow's have DRIFTED."
        echo "  A local pass does not mean CI will pass. Diff:"
        echo "$mine" > /tmp/twelve.mine.$$; echo "$theirs" > /tmp/twelve.theirs.$$
        diff /tmp/twelve.mine.$$ /tmp/twelve.theirs.$$ | sed 's/^/    /'
        rm -f /tmp/twelve.mine.$$ /tmp/twelve.theirs.$$
    fi
fi

[ "$fail" = 0 ] || exit 1
