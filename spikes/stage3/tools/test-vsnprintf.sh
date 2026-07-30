#!/bin/sh
# TEST M2libc's vsnprintf AGAINST THE PLATFORM'S, NOT AGAINST ITSELF.
#
#     sh spikes/stage3/tools/test-vsnprintf.sh [m2libc-dir]
#
# Needs gcc and nothing else. About a second. No micro-c, no emulator, no
# network -- so it can gate, and it did not exist when it was needed.
#
# WHY. tcc's predefs are built with
#
#     cstr_printf(cs, "#define __TINYC__ 9%.2s\n", &TCC_VERSION[4]);
#
# and cstr_printf is two lines around vsnprintf. M2libc's format loop compared
# the character after `%` against six conversions and treated anything else --
# a flag, a width, a precision, a length modifier -- as literal text, so that
# line produced `#define __TINYC__ 92s` and every `#if __TINYC__` in tcc's own
# test suite failed with "invalid number" at tcctest.c:337.
#
# The half that matters more is invisible: an unrecognised specification did
# not call va_arg, so every conversion AFTER it read the wrong slot. tcc uses
# 41 `%lx`, 24 `%p` and 11 `%08x`; a diagnostic mixing them printed plausible
# numbers taken from the wrong values, with nothing to indicate it.
#
# HOW. The function is compiled by gcc under the name m2_vsnprintf and its
# output compared with the platform snprintf, format by format. That is the
# whole idea behind difftest.sh applied one layer down: a reference that is
# known good and is not the thing being tested.
#
# TWO THINGS THIS CANNOT CHECK, said here rather than discovered later:
#
#   - the RESUME path. vfprintf chunks through the format and restarts from
#     __vsnprintf_string_offset; glibc's va_list is an array type and cannot be
#     assigned, so the harness copies with va_copy and the snapshot semantics
#     are not exercised. Only a real run under micro-c tests that.
#   - anything where int and long differ in width AND the caller's intent
#     differs from the modifier. gcc's int is four bytes and micro-c's is
#     eight, so this harness is the stricter of the two -- which is how the
#     `%d`-fetched-as-long bug was caught, since micro-c cannot see it.
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
M2LIBC=${1:-$ROOT/spikes/reference/m2libc}
SRC="$M2LIBC/stdio.c"
[ -f "$SRC" ] || { echo "FAIL: no stdio.c in $M2LIBC"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# THE FUNCTION IS EXTRACTED, NOT REIMPLEMENTED. A copy of the logic in the test
# would pass while the real one failed, which is the failure mode this whole
# directory exists to avoid.
python3 - "$SRC" "$T/body.c" <<'PY'
import sys
src = open(sys.argv[1]).read()
# START AT THE HELPERS, NOT AT THE FUNCTION.
#
# A gate that cannot run against the broken input cannot show it is broken, and
# this one twice could not. Extracting from the function alone left
# INLINE_STRSCPY undefined ("expected ';' before '}'"); extracting from the
# macro left __unsigned_integer_to_string and __integer_to_string undefined at
# link time. Both times the harness said "will not compile" about a version
# whose BEHAVIOUR was the thing under test -- which reads as a broken test
# rather than a broken library.
start = src.index("char* __unsigned_integer_to_string")
end = src.index("#undef INLINE_STRSCPY")
body = src[start:end]
body = body.replace(
    "int vsnprintf(char* s, size_t n, const char* format, va_list arg)",
    "int m2_vsnprintf(char* s, size_t n, const char* format, va_list arg)")
# glibc's va_list is an array type. M2libc's is assignable and the function
# relies on that; the harness has to copy instead.
body = body.replace("__vsnprintf_ap = ap_save;", "va_copy(__vsnprintf_ap, ap_save);")
body = body.replace("__vsnprintf_ap = arg;",     "va_copy(__vsnprintf_ap, arg);")
body = body.replace("ap_save = arg;",            "va_copy(ap_save, arg);")
body = body.replace("va_list ap_save;",          "va_list ap_save; va_copy(ap_save, arg);")
open(sys.argv[2], "w").write(body)
PY

cat > "$T/main.c" <<'EOF'
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
int __vsnprintf_string_offset;
va_list __vsnprintf_ap;
#include "body.c"

static int m2_snprintf(char *s, size_t n, const char *f, ...)
{ va_list ap; int r; va_start(ap, f); r = m2_vsnprintf(s, n, f, ap); va_end(ap); return r; }

#define BUF 512
static int fails = 0, checks = 0;
static void ck(const char *label, const char *got, const char *want)
{
    checks++;
    if (strcmp(got, want)) {
        fails++;
        printf("  FAIL %-20s got [%s]  want [%s]\n", label, got, want);
    }
}
#define T1(fmt, arg) do { m2_snprintf(a,BUF,fmt,arg); snprintf(b,BUF,fmt,arg); ck(fmt,a,b); } while(0)
#define T0(fmt)      do { m2_snprintf(a,BUF,fmt);     snprintf(b,BUF,fmt);     ck(fmt,a,b); } while(0)

int main(void)
{
    char a[BUF], b[BUF];

    /* the one that started it: tccpp.c:3631 */
    T1("#define __TINYC__ 9%.2s", "28rc");

    /* every conversion tcc actually uses, in frequency order */
    T1("%s", "hello");    T1("%d", 42);        T1("%d", -42);
    T1("%x", 48879);      T1("%lx", 48879L);   T1("%u", 4000000000U);
    T1("%c", 'Z');        T0("%%");            T1("%i", -7);
    T1("%ld", -123456789L);                    T1("%lu", 123456789UL);
    T1("%o", 64);         T1("%X", 48879);
    T1("%08x", 48879);    T1("%04x", 255);     T1("%02x", 5);
    T1("%04X", 255);      T1("%08X", 48879);   T1("%02X", 5);
    T1("%-2d", 3);        T1("%4d", 42);       T1("%02d", 7);
    T1("%3d", 4);         T1("%2d", 4);        T1("%6x", 255);

    /* width and precision, the whole shape */
    T1("%.3s", "abcdef"); T1("%.0s", "abcdef"); T1("%.10s", "abc");
    T1("%10s", "abc");    T1("%-10s|", "abc");  T1("%.5d", 42);
    T1("%.5d", -42);      T1("%8.3d", 7);       T1("%-8.3d|", 7);
    T1("%+d", 42);        T1("%+d", -42);       T1("% d", 42);
    T1("%.0d", 0);        T1("%#x", 255);       T1("%08.3d", 5);

    /* `*` takes its value from the argument list, and a negative width
       means left-justify rather than a huge field */
    m2_snprintf(a,BUF,"[%*d]",6,42);        snprintf(b,BUF,"[%*d]",6,42);        ck("%*d", a, b);
    m2_snprintf(a,BUF,"[%-*d]",6,42);       snprintf(b,BUF,"[%-*d]",6,42);       ck("%-*d", a, b);
    m2_snprintf(a,BUF,"[%*d]",-6,42);       snprintf(b,BUF,"[%*d]",-6,42);       ck("negative *", a, b);
    m2_snprintf(a,BUF,"[%.*s]",3,"abcdef"); snprintf(b,BUF,"[%.*s]",3,"abcdef"); ck("%.*s", a, b);
    m2_snprintf(a,BUF,"[%*s]",8,"ab");      snprintf(b,BUF,"[%*s]",8,"ab");      ck("%*s", a, b);

    /* THE SILENT ONE. A specification the library does not fully understand
       must still consume its argument, or everything after it reads the wrong
       slot -- which prints a plausible number and says nothing. */
    m2_snprintf(a,BUF,"%lx|%s|%d",255L,"tail",7);
    snprintf(b,BUF,"%lx|%s|%d",255L,"tail",7);        ck("align after %lx", a, b);
    m2_snprintf(a,BUF,"%.2s|%s|%d","28rc","tail",7);
    snprintf(b,BUF,"%.2s|%s|%d","28rc","tail",7);     ck("align after %.2s", a, b);
    m2_snprintf(a,BUF,"%08x|%s|%d",255,"tail",7);
    snprintf(b,BUF,"%08x|%s|%d",255,"tail",7);        ck("align after %08x", a, b);

    /* the shape of a real tcc diagnostic */
    m2_snprintf(a,BUF,"%s:%d: %s '%s'","f.c",12,"error","x");
    snprintf(b,BUF,"%s:%d: %s '%s'","f.c",12,"error","x");
    ck("diagnostic shape", a, b);

    /* truncation must stay inside the buffer and must terminate */
    { char t[8];
      m2_snprintf(t, 8, "%s", "abcdefghijkl");
      checks++;
      if (strlen(t) > 7) { fails++; printf("  FAIL truncation overran: [%s]\n", t); } }

    /* AND THE RETURN VALUE ON TRUNCATION, which nothing here checked.
     *
     * Every check above compares OUTPUT. The return was never read, so
     * M2libc returning the bytes WRITTEN rather than the bytes WANTED passed
     * all 51 of them -- and made every grow-and-retry caller believe its
     * string fit:
     *
     *     len = vsnprintf(buf, size, fmt, ap);
     *     if (len >= size) { grow; retry; }        tccpp.c cstr_vprintf
     *
     * The property that matters to such a caller is `len >= size` when the
     * text did not fit, and an exact count when it did. M2libc reports the
     * limit rather than the true would-be length -- see patches/m2libc/0009
     * -- so the truncated case is checked as a bound, not an equality. */
    { char t[8]; char g[8]; int rm; int rg;
      rm = m2_snprintf(t, 4, "hello");
      rg = snprintf(g, 4, "hello");
      checks++;
      if (rm < 4) { fails++; printf("  FAIL truncated return %d, want >= 4 (glibc %d)\n", rm, rg); }
      checks++;
      if (strcmp(t, "hel")) { fails++; printf("  FAIL truncated text [%s] want [hel]\n", t); }

      rm = m2_snprintf(t, 8, "hello");
      rg = snprintf(g, 8, "hello");
      checks++;
      if (rm != rg) { fails++; printf("  FAIL exact return %d, glibc %d\n", rm, rg); }

      rm = m2_snprintf(t, 6, "%s-%d", "abcdef", 12345);
      checks++;
      if (rm < 6) { fails++; printf("  FAIL truncated-in-spec return %d, want >= 6\n", rm); }
      checks++;
      if (strlen(t) > 5) { fails++; printf("  FAIL truncated-in-spec overran [%s]\n", t); } }

    printf("\n%s: %d checks, %d failures\n", fails ? "FAIL" : "PASS", checks, fails);
    return fails ? 1 : 0;
}
EOF

gcc -w -I"$T" -o "$T/run" "$T/main.c" || { echo "FAIL: the harness will not compile"; exit 1; }

# A CRASH IS A RESULT, NOT AN ABSENCE OF ONE.
#
# Run against the pre-patch function this dies with SIGILL rather than printing
# failures: a specification that does not consume its argument leaves a later
# `%s` reading a non-pointer. Letting the signal escape prints "Illegal
# instruction" and nothing else, which reads as a broken harness. Say which it
# is.
set +e
"$T/run"
rc=$?
set -e
if [ "$rc" -gt 128 ]; then
    echo
    echo "FAIL: signal $((rc - 128)) -- the function under test crashed on the harness."
    echo "  A conversion that does not consume its argument leaves a later %s"
    echo "  reading a value that is not a pointer. That is the defect, not the test."
    exit 1
fi
exit "$rc"
