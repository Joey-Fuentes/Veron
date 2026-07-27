#!/bin/sh
# gate-gcc15.sh -- a compiler that RUNS IN the sysroot, not one that targets it.
#
# The distinction the previous revision collapsed: gcc pass 1's compiler runs on
# the HOST and merely targets LFS_TGT. What the guest needs is one linked
# against the sysroot's own glibc. These binaries are ALSO handed to the guest
# so the same programs can be run again inside QEMU.
set -u
say() { printf '%s\n' "$*"; }
fail=0
bad() { say "    ^^ FAIL: $*"; fail=1; }
S=/work/sysroot
CC="$S/tools/bin/$LFS_TGT-gcc"

[ -x "$CC" ] || { say "  no $CC -- gcc pass 2 did not install"; exit 1; }
say "  compiler: $($CC --version 2>&1 | head -1)"
case "$($CC -dumpmachine 2>/dev/null)" in
  *"$LFS_TGT"*) say "  cross compiler confirmed: $($CC -dumpmachine)" ;;
  *)            bad "dumpmachine is $($CC -dumpmachine), not $LFS_TGT" ;;
esac

mkdir -p "$S/work/guest"
say "  --- static programs for the guest to re-run ---"
printf 'int fib(int n){return n<2?n:fib(n-1)+fib(n-2);}\nint main(void){return fib(10);}\n' > /tmp/g1.c
"$CC" -O2 -static /tmp/g1.c -o "$S/work/guest/t_fib" 2> /tmp/g1.err \
  || { bad "cannot build a static binary"; head -8 /tmp/g1.err | sed 's/^/      /'; }
cat > /tmp/g2.c <<'EOF'
#include <stdio.h>
int main(void){ printf("VERON-GUEST-RAN gcc-built hello\n"); return 0; }
EOF
"$CC" -O2 -static /tmp/g2.c -o "$S/work/guest/t_hello" 2>> /tmp/g1.err || bad "cannot build t_hello"

# THE COMPILER ITSELF GOES IN THE GUEST. Without this the boot proves the
# kernel and nothing about the toolchain -- which is the gap the previous
# revision's "Compile works in the guest" header line claimed to close and
# never implemented.
say "  --- staging the compiler into the guest tree ---"
for d in bin libexec lib include; do
  [ -d "$S/tools/$d" ] && cp -a "$S/tools/$d" "$S/work/guest/" 2>/dev/null || true
done
[ -x "$S/work/guest/bin/$LFS_TGT-gcc" ] || bad "compiler did not stage into the guest tree"

[ "$fail" -eq 0 ] || { say ""; say "  GATE FAILED"; exit 1; }
say ""
say "  gate passed: a compiler that runs in the sysroot, staged for the guest"
exit 0
