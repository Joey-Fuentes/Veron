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
 *
 * THE ABORT IS SPLIT IN TWO, and that split is the point of this file's
 * current shape. Ten of the thirteen tests2 programs that still differ do so
 * because micro-c HAS NO WORKING FLOATING POINT -- `double a = 12.5;
 * (long)a == 12` is false in a binary mc-tcc produces. A `%f` here would
 * therefore format a wrong value with perfect precision. Those ten were being
 * reported as "[shim: %f is not implemented]", which reads as an
 * incompleteness in THIS FILE and is not one: there is nothing to implement
 * here until the compiler can hold a double.
 *
 *     [shim: ...]        exit 70   this file is missing something. Our fault.
 *     [needs-float: ...] exit 71   the conversion is fine and THE COMPILER
 *                                  is not. Blocked on micro-c, not on here.
 *
 * The two exit statuses let a harness bucket them without parsing text.
 *
 * WHAT printf SUPPORTS: %d %i %u %o %x %X %c %s %%, the length modifiers
 * l / ll / z / h / hh, and left-justify and width (`%-4d`, `%9s`) which it
 * SKIPS rather than honours -- see the note in the parser for why skipping is
 * safe there and only there.
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

/* WHEN sbuf IS NON-NULL EVERY emit GOES THERE INSTEAD OF THE FD. That is all
 * sprintf is here: the same formatter with its sink swapped, rather than a
 * second copy of the conversion logic that could drift from this one. This
 * file already exists to keep formatting differences from being mistaken for
 * compiler defects, so having two formatters would be the wrong shape.
 */
static char *sbuf;
static long sn_out;

static void flushit(void) { if (sbuf) return; if (olen) sys3(64, 1, (long)obuf, olen); olen = 0; }
static void emit(char c)
{
    sn_out = sn_out + 1;
    if (sbuf) { sbuf[0] = c; sbuf = sbuf + 1; return; }
    if (olen == 4096) flushit();
    obuf[olen] = c; olen = olen + 1;
}

static void emits(const char *s) { while (*s) { emit(*s); s = s + 1; } }

/* WIDTH AND ZERO PADDING ARE IMPLEMENTED, NOT SKIPPED.
 *
 * An earlier version of this file skipped width and aborted on `%0`, on the
 * reasoning that `diff -b` forgives spacing but zero padding changes
 * characters. The first half was right and the second was the wrong
 * conclusion: zero padding is exactly computable, so refusing it was refusing
 * to do arithmetic rather than refusing to guess. `%02d` in 37_sprintf and
 * `%08X` in 73_arm64 were both blocked on that.
 *
 * The rule this file actually enforces is narrower than "flags are hard": emit
 * what is DETERMINED, abort on what would have to be INVENTED. Padding is
 * determined. A float is not.
 */
static void pad(char c, int n) { while (n > 0) { emit(c); n = n - 1; } }

static void emitl(long v, int base, int sgn, const char *digits,
                  int width, int zero, int left)
{
    char t[24];
    int i;
    int neg;
    int len;
    unsigned long u;

    i = 0; neg = 0;
    if (sgn && v < 0) { neg = 1; u = -v; } else u = v;
    if (u == 0) { t[0] = '0'; i = 1; }
    while (u) { t[i] = digits[u % base]; u = u / base; i = i + 1; }

    len = i + neg;
    if (left) {
        if (neg) emit('-');
        while (i) { i = i - 1; emit(t[i]); }
        pad(' ', width - len);
    } else if (zero) {
        /* the sign leads the zeros, never follows them */
        if (neg) emit('-');
        pad('0', width - len);
        while (i) { i = i - 1; emit(t[i]); }
    } else {
        pad(' ', width - len);
        if (neg) emit('-');
        while (i) { i = i - 1; emit(t[i]); }
    }
}

/* %s with a width and/or a precision. Precision TRUNCATES, which is why it
 * could not simply be skipped either. */
static void emitspad(const char *s, int width, int prec, int left)
{
    int len; int i;
    len = 0;
    while (s[len] && (prec < 0 || len < prec)) len = len + 1;
    if (!left) pad(' ', width - len);
    i = 0;
    while (i < len) { emit(s[i]); i = i + 1; }
    if (left) pad(' ', width - len);
}

/* THE TWO ABORTS. `spec` is the conversion as it was written -- "%08X", not
 * "%X" -- because which PART of it went unhandled is the whole diagnostic.
 */
static void shim_gap(const char *spec)
{
    emits("\n[shim: printf ");
    emits(spec);
    emits(" is not implemented]\n");
    flushit();
    sys3(93, 70, 0, 0);
}

static void needs_float(const char *spec)
{
    emits("\n[needs-float: printf ");
    emits(spec);
    emits(" is correct here; micro-c has no working floating point]\n");
    flushit();
    sys3(93, 71, 0, 0);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    const char *p;
    char spec[12];
    int sn;
    int lng;
    int bad;
    int width;
    int prec;
    int zero;
    int left;

    sbuf = 0;
    sn_out = 0;
    va_start(ap, fmt);
    p = fmt;
    while (*p) {
        if (*p != '%') { emit(*p); p = p + 1; continue; }

        /* Record the conversion verbatim as it is consumed, so an abort can
         * name what was actually written rather than what it reduced to.
         */
        spec[0] = '%';
        sn = 1;
        p = p + 1;

        /* FLAGS AND WIDTH.
         *
         * `-` and a width are SKIPPED rather than honoured. The comparison
         * these tests are judged by is tcc's own -- `diff -Nbu`,
         * tests2/Makefile:142 -- and `-b` ignores changes in the AMOUNT of
         * whitespace, so a field differing from the reference only in its
         * PADDING compares equal. `%9s` and `%-4d` are therefore free.
         *
         * NOTHING ELSE IS. Every other flag changes CHARACTERS rather than
         * spacing, and `-b` will not forgive any of them:
         *
         *     %08X   zero padding is digits                  -> abort
         *     %#x    prints a "0x" that is not in the .expect -> abort
         *     %+d    prints a sign that is not there          -> abort
         *     % d    a leading space, which at the start of a -> abort
         *            line is presence-vs-absence, not amount
         *     %.3s   precision TRUNCATES the string           -> abort
         *     %*d    consumes an argument, and skipping it    -> abort
         *            desynchronises every later va_arg
         *
         * Being generous here would be worse than not implementing it: a
         * skipped `#` prints a plausible number quietly missing two
         * characters, which is the exact class of failure this file exists to
         * make impossible.
         *
         * BUT AN UNSUPPORTED FLAG DOES NOT ABORT HERE. It only sets `bad`,
         * and the decision waits for the conversion character. `%.1f` appears
         * 64 times in tests2 and `%.1Lf` 29 more; aborting at the `.` would
         * file every one of them under "[shim: %. is not implemented]" --
         * charging this file for a precision it could implement in an hour,
         * when what actually blocks them is that micro-c cannot hold the
         * double being printed. The conversion decides which abort applies,
         * so the float answer wins over the flag answer whenever both are
         * true. That precedence IS the fix; splitting the abort without it
         * moves ninety-three call sites into the wrong bucket.
         */
        bad = 0; width = 0; prec = -1; zero = 0; left = 0;
        while (*p == '-' || *p == '0' || *p == '+' || *p == ' ' || *p == '#') {
            if (*p == '-') left = 1;
            else if (*p == '0') zero = 1;
            else bad = 1;                 /* + and space and # add characters */
            if (sn < 9) { spec[sn] = *p; sn = sn + 1; }
            p = p + 1;
        }
        if (*p == '*') {
            bad = 1;                      /* consumes an argument; cannot skip */
            if (sn < 9) { spec[sn] = *p; sn = sn + 1; }
            p = p + 1;
        } else {
            while (*p >= '0' && *p <= '9') {
                width = width * 10 + (*p - '0');
                if (sn < 9) { spec[sn] = *p; sn = sn + 1; }
                p = p + 1;
            }
        }
        if (*p == '.') {
            if (sn < 9) { spec[sn] = *p; sn = sn + 1; }
            p = p + 1;
            prec = 0;
            if (*p == '*') { bad = 1; if (sn < 9) { spec[sn] = *p; sn = sn + 1; } p = p + 1; }
            else while (*p >= '0' && *p <= '9') {
                prec = prec * 10 + (*p - '0');
                if (sn < 9) { spec[sn] = *p; sn = sn + 1; }
                p = p + 1;
            }
        }

        lng = 0;
        while (*p == 'l' || *p == 'z' || *p == 'h' || *p == 'L') {
            if (*p == 'l' || *p == 'z') lng = 1;
            if (sn < 10) { spec[sn] = *p; sn = sn + 1; }
            p = p + 1;
        }

        if (sn < 11) { spec[sn] = *p; sn = sn + 1; }
        spec[sn] = 0;

        /* THE FLOAT CONVERSIONS ARE ANSWERED FIRST, flags and all. */
        if (*p == 'f' || *p == 'F' || *p == 'e' || *p == 'E' ||
            *p == 'g' || *p == 'G' || *p == 'a' || *p == 'A') {
            /* NOT A GAP IN THIS FILE. See the header. */
            needs_float(spec);
        }
        if (bad) shim_gap(spec);
        /* precision on an INTEGER means minimum digits, which is a different
         * rule from width; only the string form is implemented. */
        if (prec >= 0 && *p != 's') shim_gap(spec);

        if (*p == 'd' || *p == 'i') {
            if (lng) emitl(va_arg(ap, long), 10, 1, "0123456789", width, zero, left);
            else emitl(va_arg(ap, int), 10, 1, "0123456789", width, zero, left);
        } else if (*p == 'u') {
            if (lng) emitl(va_arg(ap, unsigned long), 10, 0, "0123456789", width, zero, left);
            else emitl(va_arg(ap, unsigned int), 10, 0, "0123456789", width, zero, left);
        } else if (*p == 'x') {
            if (lng) emitl(va_arg(ap, unsigned long), 16, 0, "0123456789abcdef", width, zero, left);
            else emitl(va_arg(ap, unsigned int), 16, 0, "0123456789abcdef", width, zero, left);
        } else if (*p == 'X') {
            if (lng) emitl(va_arg(ap, unsigned long), 16, 0, "0123456789ABCDEF", width, zero, left);
            else emitl(va_arg(ap, unsigned int), 16, 0, "0123456789ABCDEF", width, zero, left);
        } else if (*p == 'o') {
            if (lng) emitl(va_arg(ap, unsigned long), 8, 0, "0123456789", width, zero, left);
            else emitl(va_arg(ap, unsigned int), 8, 0, "0123456789", width, zero, left);
        } else if (*p == 'c') {
            emit(va_arg(ap, int));
        } else if (*p == 's') {
            emitspad(va_arg(ap, char *), width, prec, left);
        } else if (*p == '%') {
            emit('%');
        } else {
            shim_gap(spec);
        }
        p = p + 1;
    }
    va_end(ap);
    flushit();
    return 0;
}

/* ---------------------------------------------------------------------------
 * JUST ENOUGH string.h AND stdlib.h.
 *
 * These are not here for completeness. Every one of them was blocking a
 * specific tests2 program at the CONTROL stage -- a gcc-built tcc could not
 * link test+shim at all -- which meant the test was reported "not applicable"
 * and silently left the measurement. Seventeen programs were sitting in that
 * bucket for want of memset, memmove, strlen, abort and write.
 *
 * memset and memmove matter more than the count suggests: tcc EMITS CALLS TO
 * THEM ITSELF for struct assignment and for zero-initialising an aggregate, so
 * a test that never names either still needs both to link. That is why
 * 90_struct-init and 131_return_struct_in_reg were blocked.
 */
void *memset(void *d, int c, unsigned long n)
{
    char *p; unsigned long i;
    p = (char *)d; i = 0;
    while (i < n) { p[i] = (char)c; i = i + 1; }
    return d;
}

void *memcpy(void *d, const void *s, unsigned long n)
{
    char *a; const char *b; unsigned long i;
    a = (char *)d; b = (const char *)s; i = 0;
    while (i < n) { a[i] = b[i]; i = i + 1; }
    return d;
}

/* OVERLAP IS THE WHOLE REASON memmove IS SEPARATE. Copying forward through a
 * region that overlaps to the right reads bytes this call already wrote.
 */
void *memmove(void *d, const void *s, unsigned long n)
{
    char *a; const char *b; unsigned long i;
    a = (char *)d; b = (const char *)s;
    if (a == b || n == 0) return d;
    if (a < b) { i = 0; while (i < n) { a[i] = b[i]; i = i + 1; } }
    else { i = n; while (i) { i = i - 1; a[i] = b[i]; } }
    return d;
}

int memcmp(const void *s1, const void *s2, unsigned long n)
{
    const unsigned char *a; const unsigned char *b; unsigned long i;
    a = (const unsigned char *)s1; b = (const unsigned char *)s2; i = 0;
    while (i < n) { if (a[i] != b[i]) return (int)a[i] - (int)b[i]; i = i + 1; }
    return 0;
}

unsigned long strlen(const char *s)
{
    unsigned long n; n = 0;
    while (s[n]) n = n + 1;
    return n;
}

char *strcpy(char *d, const char *s)
{
    unsigned long i; i = 0;
    while (s[i]) { d[i] = s[i]; i = i + 1; }
    d[i] = 0;
    return d;
}

char *strcat(char *d, const char *s)
{
    strcpy(d + strlen(d), s);
    return d;
}

int strcmp(const char *a, const char *b)
{
    unsigned long i; i = 0;
    while (a[i] && a[i] == b[i]) i = i + 1;
    return (int)(unsigned char)a[i] - (int)(unsigned char)b[i];
}

char *strncpy(char *d, const char *s, unsigned long n)
{
    unsigned long i; i = 0;
    while (i < n && s[i]) { d[i] = s[i]; i = i + 1; }
    while (i < n) { d[i] = 0; i = i + 1; }
    return d;
}

char *strchr(const char *s, int c)
{
    while (*s) { if (*s == (char)c) return (char *)s; s = s + 1; }
    if (c == 0) return (char *)s;
    return 0;
}

char *strrchr(const char *s, int c)
{
    const char *r; r = 0;
    while (*s) { if (*s == (char)c) r = s; s = s + 1; }
    if (c == 0) return (char *)s;
    return (char *)r;
}

int strncmp(const char *a, const char *b, unsigned long n)
{
    unsigned long i; i = 0;
    while (i < n) {
        if (a[i] != b[i]) return (int)(unsigned char)a[i] - (int)(unsigned char)b[i];
        if (a[i] == 0) return 0;
        i = i + 1;
    }
    return 0;
}

/* SIGNATURE COPIED FROM 108_constructor:1, which declares its own
 *     extern int write (int fd, void *buf, int len);
 * and is the only program in tests2 that calls it. A POSIX-shaped
 * `ssize_t write(int, const void *, size_t)` is rejected against that as an
 * incompatible redefinition, which put the test back in the not-applicable
 * bucket for a prototype rather than for anything it tests.
 */
int write(int fd, void *buf, int n)
{
    flushit();
    return (int)sys3(64, fd, (long)buf, (long)n);
}

void exit(int code) { flushit(); sys3(93, code, 0, 0); }

/* A real abort raises SIGABRT and a shell reports 134. Nothing in tests2
 * inspects the status -- 117_builtins calls it only on a failed assertion, so
 * reaching it at all is the failure. Terminating with the number a shell would
 * print keeps that readable.
 */
void abort(void) { flushit(); sys3(93, 134, 0, 0); }

/* A BUMP ALLOCATOR, AND IT DOES NOT FREE. tests2 programs are single-shot and
 * allocate a few hundred bytes; a free list would be more code than the thing
 * being tested. If a program ever exhausts this it gets a NULL rather than
 * silent corruption.
 */
static char heap[1048576];
static unsigned long heap_used;

void *malloc(unsigned long n)
{
    char *r;
    n = (n + 15) & ~15UL;              /* keep every block 16-aligned */
    if (heap_used + n > 1048576) return 0;
    r = heap + heap_used;
    heap_used = heap_used + n;
    return (void *)r;
}

void *calloc(unsigned long a, unsigned long b)
{
    void *p;
    p = malloc(a * b);
    if (p) memset(p, 0, a * b);
    return p;
}

void free(void *p) { }

void *realloc(void *p, unsigned long n)
{
    void *q;
    q = malloc(n);
    if (q && p) memcpy(q, p, n);
    return q;
}

int abs(int v) { if (v < 0) return -v; return v; }

/* sprintf shares printf's parser by pointing the sink at a caller buffer.
 * vprintf-style plumbing would be cleaner and needs a va_list pass-through
 * micro-c has not been measured on, so this stays a copy of the dispatch and
 * not of the conversions.
 */
int sprintf(char *out, const char *fmt, ...)
{
    va_list ap;
    const char *p;
    long n;
    int w; int z; int lf;

    sbuf = out;
    sn_out = 0;
    va_start(ap, fmt);
    p = fmt;
    while (*p) {
        if (*p != '%') { emit(*p); p = p + 1; continue; }
        p = p + 1;
        w = 0; z = 0; lf = 0;
        while (*p == '-' || *p == '0') { if (*p == '-') lf = 1; else z = 1; p = p + 1; }
        while (*p >= '0' && *p <= '9') { w = w * 10 + (*p - '0'); p = p + 1; }
        if (*p == 'd' || *p == 'i') emitl(va_arg(ap, int), 10, 1, "0123456789", w, z, lf);
        else if (*p == 'u') emitl(va_arg(ap, unsigned int), 10, 0, "0123456789", w, z, lf);
        else if (*p == 'x') emitl(va_arg(ap, unsigned int), 16, 0, "0123456789abcdef", w, z, lf);
        else if (*p == 'X') emitl(va_arg(ap, unsigned int), 16, 0, "0123456789ABCDEF", w, z, lf);
        else if (*p == 'c') emit(va_arg(ap, int));
        else if (*p == 's') emitspad(va_arg(ap, char *), w, -1, lf);
        else if (*p == '%') emit('%');
        else if (*p == 'l') {
            p = p + 1;
            while (*p == 'l') p = p + 1;
            if (*p == 'd' || *p == 'i') emitl(va_arg(ap, long), 10, 1, "0123456789", w, z, lf);
            else if (*p == 'u') emitl(va_arg(ap, unsigned long), 10, 0, "0123456789", w, z, lf);
            else if (*p == 'x') emitl(va_arg(ap, unsigned long), 16, 0, "0123456789abcdef", w, z, lf);
            else { sbuf = 0; shim_gap("%l?"); }
        }
        else { sbuf = 0; shim_gap("sprintf conversion"); }
        p = p + 1;
    }
    va_end(ap);
    n = sn_out;
    sbuf[0] = 0;
    sbuf = 0;
    return (int)n;
}

int puts(const char *s) { emits(s); emit('\n'); flushit(); return 0; }
int putchar(int c) { emit(c); flushit(); return c; }

/* THE ENTRY POINT, AND WHY IT IS ASSEMBLY.
 *
 * `_start` used to be an ordinary C function calling `main()` with no
 * arguments, so 31_args -- which prints argc and every argv -- read whatever
 * happened to be sitting in the argument registers and printed garbage. That
 * was counted against the compiler for as long as the shim was the thing
 * being misread.
 *
 * The kernel does not hand argc over in a register. At process entry `sp`
 * POINTS AT argc, with argv[] above it, then a NULL, then envp[]. Reading `sp`
 * from inside a C function does not work -- the prologue has already moved it
 * -- so the entry has to be assembly that captures `sp` before anything else
 * touches it and tail-calls a C function with it.
 *
 * mc-tcc assembles this; that is verified rather than assumed. `mov x0, sp`
 * and `b` are both covered by the arm64 assembler patch series, and a probe of
 * exactly this shape returns the right argc under mc-tcc and under the
 * gcc-built control alike.
 */
__asm__(".global _start\n"
        "_start:\n"
        "    mov x0, sp\n"
        "    b _start_c\n");

/* MAIN IS CALLED THROUGH A NO-PROTOTYPE POINTER, AND THAT IS NOT STYLE.
 *
 * This file is used two ways: concatenated AFTER the test (the local scripts)
 * and as a SEPARATE translation unit (the hermetic job hands both files to one
 * invocation). The two disagree about what is in scope here.
 *
 * In the separate-unit case main is not declared at all, so something has to
 * declare it. In the concatenated case main is already DEFINED above, as any
 * one of `int main(void)`, `int main()` or `int main(int, char **)` -- and a
 * definition carries its own prototype, which a later declaration cannot widen.
 * Calling `main(argc, argv, envp)` directly is then rejected outright:
 *
 *     u.c:246: error: too many arguments to function
 *
 * by tcc and by mc-tcc alike, for two of those three shapes. Passing FEWER
 * arguments is the thing C lets you get away with; passing more through a
 * visible prototype is not.
 *
 * A pointer whose type has an EMPTY parameter list supplies no information
 * about the arguments, so the call through it is unchecked, and every
 * conforming main -- which takes its arguments in x0/x1/x2 under the aarch64
 * ABI regardless of how many it declares -- reads exactly the ones it asked
 * for and ignores the rest. Both compilers accept this; that is measured, not
 * assumed.
 *
 * The declaration below is still needed for the separate-unit case, where
 * nothing else names main. In the concatenated case it follows the definition
 * and is simply redundant, which is legal -- an empty parameter list conflicts
 * with none of the three shapes. It is the CALL that had to change, not the
 * declaration.
 */
int main();
typedef int (*shim_mainfn)();

void _start_c(long *sp)
{
    int argc;
    char **argv;
    char **envp;
    shim_mainfn m;
    int i;
    int r;

    argc = (int)sp[0];
    argv = (char **)(sp + 1);
    /* envp begins one past argv's NULL terminator. */
    i = 0;
    while (argv[i]) i = i + 1;
    envp = argv + i + 1;

    m = (shim_mainfn)main;
    r = m(argc, argv, envp);
    flushit();
    sys3(93, r, 0, 0);
}
