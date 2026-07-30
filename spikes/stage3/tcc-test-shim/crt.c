/* A FREESTANDING crt AND JUST ENOUGH stdio TO RUN tcc's OWN TESTS.
 *
 * tests2/00_assignment.c wants <stdio.h>, printf("%d\n", a), and a main() that
 * something calls. The box has no libc and no crt, so this supplies all three
 * in C that mc-tcc compiles itself.
 *
 * printf implements ONLY what the tests being run actually use, and ABORTS on
 * anything else rather than printing something plausible. A shim that quietly
 * mishandled a conversion would make a test fail as though the compiler were
 * wrong, which is the failure this whole exercise exists to avoid.
 */
#include <stdarg.h>

static long sys3(long n, long a, long b, long c)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    __asm__ __volatile__("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

static char obuf[4096];
static int olen;

static void flushit(void) { if (olen) sys3(64, 1, (long)obuf, olen); olen = 0; }
static void emit(char c) { if (olen == 4096) flushit(); obuf[olen] = c; olen = olen + 1; }

static void emits(const char *s) { while (*s) { emit(*s); s = s + 1; } }

static void emitl(long v, int base, int sgn)
{
    char t[24];
    int i;
    unsigned long u;
    i = 0;
    if (sgn && v < 0) { emit('-'); u = -v; } else u = v;
    if (u == 0) { emit('0'); return; }
    while (u) { t[i] = "0123456789abcdef"[u % base]; u = u / base; i = i + 1; }
    while (i) { i = i - 1; emit(t[i]); }
}

static void unsupported(char c)
{
    emits("\n[shim: printf %");
    emit(c);
    emits(" is not implemented]\n");
    flushit();
    sys3(93, 70, 0, 0);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    const char *p;
    va_start(ap, fmt);
    for (p = fmt; *p; p++) {
        if (*p != '%') { emit(*p); continue; }
        p++;
        if (*p == 'd' || *p == 'i') emitl(va_arg(ap, int), 10, 1);
        else if (*p == 'u') emitl(va_arg(ap, unsigned int), 10, 0);
        else if (*p == 'x') emitl(va_arg(ap, unsigned int), 16, 0);
        else if (*p == 'c') emit(va_arg(ap, int));
        else if (*p == 's') emits(va_arg(ap, char *));
        else if (*p == 'l') { p++; if (*p == 'd') emitl(va_arg(ap, long), 10, 1);
                              else if (*p == 'u') emitl(va_arg(ap, unsigned long), 10, 0);
                              else if (*p == 'x') emitl(va_arg(ap, unsigned long), 16, 0);
                              else unsupported(*p); }
        else if (*p == '%') emit('%');
        else unsupported(*p);
    }
    va_end(ap);
    flushit();
    return 0;
}

int puts(const char *s) { emits(s); emit('\n'); flushit(); return 0; }
int putchar(int c) { emit(c); flushit(); return c; }

int main(void);
void _start(void) { int r; r = main(); flushit(); sys3(93, r, 0, 0); }
