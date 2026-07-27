#!/bin/sh
# gate-gcc10.sh -- assert, do not report.
#
# This step used to be named GATE and behave as a report: it printed
# "expect exit 55" beside the real value and exited 0 regardless, so a gcc that
# answered 99 went green. A check that cannot fail is not a check, and that
# rule is this repository's own.
set -u
say() { printf '%s\n' "$*"; }
fail=0
bad() { say "    ^^ FAIL: $*"; fail=1; }

[ -x /work/out10/bin/gcc ] || { say "  no gcc 10 to test"; exit 1; }
[ -x /work/out10/bin/g++ ] || { say "  no g++ 10 to test"; exit 1; }
export LD_LIBRARY_PATH=/work/out10/lib64:/work/out10/lib:/work/out2/lib64

# 1. C CODEGEN, NOT --version. fib exercises a conditional, a subtraction and
# recursion, and RUNNING it is what separates codegen from mere compilation.
say "  --- gcc 10 on C (expect exit 55) ---"
printf 'int fib(int n){return n<2?n:fib(n-1)+fib(n-2);}\n'  > /tmp/c10.c
printf 'int main(void){return fib(10);}\n'                 >> /tmp/c10.c
rm -f /tmp/c10
/work/out10/bin/gcc -O2 /tmp/c10.c -o /tmp/c10 2> /tmp/c10.err
say "    compile+link rc=$?"
[ -s /tmp/c10.err ] && head -8 /tmp/c10.err | sed 's/^/      /'
if [ -x /tmp/c10 ]; then /tmp/c10; got=$?; say "    ran: exit=$got"
  [ "$got" -eq 55 ] || bad "fib(10) returned $got, not 55"
else bad "no binary -- gcc 10 cannot link"; fi

# 2. C++, AND EXCEPTIONS SPECIFICALLY. A compiler with broken exceptions passes
# any test whose program merely returns a constant.
say "  --- gcc 10 on C++ with exceptions (expect exit 7) ---"
cat > /tmp/x10.cc <<'EOF'
#include <stdexcept>
int main(){ try { throw std::runtime_error("x"); } catch (const std::exception&) { return 7; } return 1; }
EOF
rm -f /tmp/x10
/work/out10/bin/g++ -O2 /tmp/x10.cc -o /tmp/x10 2> /tmp/x10.err
say "    compile+link rc=$?"
[ -s /tmp/x10.err ] && head -8 /tmp/x10.err | sed 's/^/      /'
if [ -x /tmp/x10 ]; then /tmp/x10; got=$?; say "    ran: exit=$got"
  [ "$got" -eq 7 ] || bad "exception test returned $got, not 7"
else bad "no binary -- g++ 10 cannot link"; fi

# 3. IS IT A RUNG UP? A gcc 10 that is really the 4.7 underneath it would pass
# everything above.
v=$(/work/out10/bin/gcc -dumpversion 2>/dev/null)
say "  --- version: $v ---"
case "$v" in 10.*) say "    is gcc 10" ;; *) bad "dumpversion says $v, not 10.x" ;; esac

[ "$fail" -eq 0 ] || { say ""; say "  GATE FAILED"; exit 1; }
say ""
say "  gate passed: gcc 10 compiles, links, runs, and handles exceptions"
exit 0
