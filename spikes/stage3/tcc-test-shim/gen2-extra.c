/* WHAT gen2 STILL NEEDS, ON TOP OF crt.c.
 *
 * Step 13's census reports the symbols gen2.o references and nothing
 * provides. With libtcc1 built by mc-tcc the compiler-support bucket is empty
 * and 49 libc names remain; crt.c and micro-c-libc/impl/runtime.c already
 * supply 30 of them. This file is the other 19, and it exists so that step B
 * -- "link gen2" -- can be attempted at all:
 *
 *     atoi close errno fdopen fseek ftell getcwd getenv longjmp lseek
 *     open read setjmp snprintf strpbrk strstr unlink vfprintf vsnprintf
 *
 * IT IS NOT A LIBC AND IT IS NOT THE musl RUNG. MICRO-C.md is explicit that
 * mc-tcc does not need to build a libc and that musl 1.2.5 is the next rung;
 * that stays true. What this is for is the FIXPOINT -- gen1 builds gen2, gen2
 * builds gen3, gen2 == gen3 -- which is stage 3's own step 2 through 5 and
 * has never been attempted because gen2 would not link. A bootstrap libc is
 * what live-bootstrap uses for exactly this position: the weak compiler gets
 * a small one, and the first real compiler builds the real one.
 *
 * EVERYTHING HERE IS COMPILED BY mc-tcc, so it is subject to the same
 * compiler the fixpoint is measuring. That is deliberate: a runtime built by
 * something else would make gen2 a hybrid and the comparison meaningless.
 *
 * WHAT IS HONEST ABOUT IT AND WHAT IS NOT:
 *   - the syscalls are real
 *   - setjmp/longjmp are a real AAPCS pair, tested (see below)
 *   - getenv always answers "unset", which is true of the box
 *   - fdopen does not buffer and ignores the mode, which is all tcc's use
 *     of it needs
 *   - the formatter handles what tcc's diagnostics actually emit and ABORTS
 *     on anything else rather than printing something plausible, the same
 *     rule crt.c's printf follows and for the same reason
 */
#include <stdio.h>
#include <stdarg.h>

/* ---------------------------------------------------------------- syscalls */
static long g_sys3(long n, long a, long b, long c)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    __asm__ __volatile__("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

static long g_sys4(long n, long a, long b, long c, long d)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    __asm__ __volatile__("svc #0" : "+r"(x0)
                         : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}

/* A RAW SYSCALL RETURNS -errno. Anything in [-4095,-1] is a failure, and the
 * caller expects -1 with errno set -- the same convention the mmap fix in
 * crt.c records. */
int errno;

static long g_ret(long r)
{
    if (r < 0 && r > -4096) { errno = (int)-r; return -1; }
    return r;
}

#define G_AT_FDCWD (-100)

int open(const char *path, int flags, int mode)
{
    return (int)g_ret(g_sys4(56, G_AT_FDCWD, (long)path, (long)flags, (long)mode));
}

int close(int fd)                        { return (int)g_ret(g_sys3(57, fd, 0, 0)); }
long read(int fd, void *b, unsigned long n) { return g_ret(g_sys3(63, fd, (long)b, (long)n)); }
long lseek(int fd, long off, int whence)    { return g_ret(g_sys3(62, fd, off, whence)); }
int unlink(const char *p)                { return (int)g_ret(g_sys3(35, G_AT_FDCWD, (long)p, 0)); }

char *getcwd(char *buf, unsigned long size)
{
    if (g_ret(g_sys3(17, (long)buf, (long)size, 0)) < 0) return 0;
    return buf;
}

/* THE BOX HAS NO ENVIRONMENT, and saying so is the honest answer rather than
 * inventing one. tcc reads CPATH, LIBRARY_PATH and TCC_OPTIONS through this;
 * all three being unset is exactly the state a sealed box is in. */
char *getenv(const char *name) { return 0; }

/* ------------------------------------------------------------ string, misc */
int atoi(const char *s)
{
    int n; int neg;
    n = 0; neg = 0;
    while (*s == ' ' || *s == '\t') s = s + 1;
    if (*s == '-') { neg = 1; s = s + 1; }
    else if (*s == '+') s = s + 1;
    while (*s >= '0' && *s <= '9') { n = n * 10 + (*s - '0'); s = s + 1; }
    if (neg) return -n;
    return n;
}

char *strpbrk(const char *s, const char *set)
{
    const char *p;
    while (*s) {
        p = set;
        while (*p) { if (*p == *s) return (char *)s; p = p + 1; }
        s = s + 1;
    }
    return 0;
}

char *strstr(const char *h, const char *n)
{
    const char *a; const char *b;
    if (!*n) return (char *)h;
    while (*h) {
        a = h; b = n;
        while (*a && *b && *a == *b) { a = a + 1; b = b + 1; }
        if (!*b) return (char *)h;
        h = h + 1;
    }
    return 0;
}

/* -------------------------------------------------------------- FILE extras
 * crt.c owns the FILE table and fopen/fclose/fread/fwrite/fgetc/fgets. These
 * three are the rest of what tcc reaches for. */
FILE *fdopen(int fd, const char *mode)
{
    FILE *f;
    f = fopen("/dev/null", "r");        /* borrow a slot from crt.c's table */
    if (!f) return 0;
    close(f->fd);
    f->fd = fd;
    f->eof = 0;
    f->err = 0;
    return f;
}

int fseek(FILE *f, long off, int whence)
{
    if (!f || !f->used) return -1;
    if (lseek(f->fd, off, whence) < 0) return -1;
    f->eof = 0;
    return 0;
}

long ftell(FILE *f)
{
    if (!f || !f->used) return -1;
    return lseek(f->fd, 0, 1 /* SEEK_CUR */);
}

/* ------------------------------------------------------------ the formatter
 * ONE CORE, THREE ENTRY POINTS. crt.c carries two copies of its dispatch
 * because collapsing them needed a va_list handed to a helper, and that had
 * not been measured under this compiler. It has been now -- an argument list
 * forwarded to a helper and consumed there returns the right values under
 * mc-tcc -- so the three added here share one core.
 *
 * The conversions are the ones tcc's own diagnostics use: %d %i %u %x %X %c
 * %s %p %% with l/ll/z length modifiers, and a width. A float conversion
 * ABORTS: mc-tcc cannot yet emit a floating-point constant (step 11b), so
 * formatting one would print a confidently wrong number. */
static char *g_out;
static unsigned long g_left;
static unsigned long g_count;
static FILE *g_file;

static void g_emit(char c)
{
    g_count = g_count + 1;
    if (g_file) { fputc(c, g_file); return; }
    if (g_left > 1) { *g_out = c; g_out = g_out + 1; g_left = g_left - 1; }
}

static void g_str(const char *s) { while (*s) { g_emit(*s); s = s + 1; } }

/* STRAIGHT TO FD 2, bypassing every sink. */
static void g_diag(const char *s)
{
    unsigned long n;
    n = 0;
    while (s[n]) n = n + 1;
    g_sys3(64, 2, (long)s, (long)n);
}

static void g_num(unsigned long v, int base, int sgn, const char *digits, int width)
{
    char tmp[32];
    int i; int neg;
    long sv;
    neg = 0;
    if (sgn) { sv = (long)v; if (sv < 0) { neg = 1; v = (unsigned long)(-sv); } }
    i = 0;
    if (v == 0) { tmp[i] = '0'; i = i + 1; }
    while (v) { tmp[i] = digits[v % base]; i = i + 1; v = v / base; }
    if (neg) { tmp[i] = '-'; i = i + 1; }
    while (width > i) { g_emit(' '); width = width - 1; }
    while (i > 0) { i = i - 1; g_emit(tmp[i]); }
}

static void g_fmt(const char *f, va_list ap)
{
    int w; int lng; int prec;
    while (*f) {
        if (*f != '%') { g_emit(*f); f = f + 1; continue; }
        f = f + 1;
        w = 0; lng = 0;
        while (*f == '-' || *f == '0' || *f == '+' || *f == ' ' || *f == '#') f = f + 1;
        /* `%*s` TAKES ITS WIDTH FROM AN ARGUMENT, and that argument must be
         * consumed whether or not the width is honoured -- skipping it leaves
         * every later conversion reading one slot early. tcc indents its
         * include trace with exactly this:
         *     printf("=> %*s%s\n", (int)(ptr - stack), "", buf);   tccpp.c:1418
         */
        if (*f == '*') { w = va_arg(ap, int); if (w < 0) w = 0; f = f + 1; }
        else while (*f >= '0' && *f <= '9') { w = w * 10 + (*f - '0'); f = f + 1; }
        /* AND THE PRECISION IS NOT DECORATION EITHER. tcc builds every -D
         * on the command line with
         *     cstr_printf(&s1->cmdline_defs, "#define %.*s %s\n",
         *                 (int)(eq-sym), sym, value);        libtcc.c:865
         * where `sym` is the whole "ONE_SOURCE=1" and the precision is what
         * cuts it at the '='. Consuming the argument but ignoring the width
         * emitted `#define ONE_SOURCE=1 1`, and the preprocessor then read
         *     tcc.h:356: error: bad preprocessor expression: #if = 1 1
         * -- a define whose NAME contained the '=' and whose body was the
         * rest. cstr_vprintf routes through vsnprintf here, so this is the
         * implementation that decides it. */
        prec = -1;
        if (*f == '.') {
            f = f + 1;
            prec = 0;
            if (*f == '*') { prec = va_arg(ap, int); f = f + 1; }
            else while (*f >= '0' && *f <= '9') { prec = prec * 10 + (*f - '0'); f = f + 1; }
            if (prec < 0) prec = -1;
        }
        while (*f == 'l' || *f == 'z') { lng = 1; f = f + 1; }
        if (*f == 'd' || *f == 'i')
            g_num(lng ? (unsigned long)va_arg(ap, long) : (unsigned long)(long)va_arg(ap, int),
                  10, 1, "0123456789", w);
        else if (*f == 'u')
            g_num(lng ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int),
                  10, 0, "0123456789", w);
        else if (*f == 'x')
            g_num(lng ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int),
                  16, 0, "0123456789abcdef", w);
        else if (*f == 'X')
            g_num(lng ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int),
                  16, 0, "0123456789ABCDEF", w);
        else if (*f == 'p') { g_str("0x"); g_num(va_arg(ap, unsigned long), 16, 0, "0123456789abcdef", 0); }
        else if (*f == 'c') g_emit(va_arg(ap, int));
        else if (*f == 's') {
            char *s; int i;
            s = va_arg(ap, char *);
            if (!s) s = "(null)";
            i = 0;
            while (s[i] && (prec < 0 || i < prec)) i = i + 1;
            while (w > i) { g_emit(' '); w = w - 1; }
            w = 0;
            while (w < i) { g_emit(s[w]); w = w + 1; }
        }
        else if (*f == '%') g_emit('%');
        else {
            /* TO stderr, NOT TO THE SINK. Routed through g_str this message
             * lands in the caller's buffer whenever the entry point is
             * vsnprintf -- so the abort that follows it had no explanation
             * anywhere, which cost one round. */
            char m[64];
            m[0] = 0;
            g_diag("[gen2-extra: unimplemented conversion %");
            m[0] = *f; m[1] = ']'; m[2] = '\n'; m[3] = 0;
            g_diag(m);
            abort();
        }
        f = f + 1;
    }
}

int vfprintf(FILE *f, const char *fmt, va_list ap)
{
    g_file = f; g_out = 0; g_left = 0; g_count = 0;
    g_fmt(fmt, ap);
    g_file = 0;
    return (int)g_count;
}

int vsnprintf(char *buf, unsigned long n, const char *fmt, va_list ap)
{
    g_file = 0; g_out = buf; g_left = n; g_count = 0;
    g_fmt(fmt, ap);
    if (n > 0) *g_out = 0;
    return (int)g_count;
}

int snprintf(char *buf, unsigned long n, const char *fmt, ...)
{
    va_list ap; int r;
    va_start(ap, fmt);
    r = vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return r;
}

/* ------------------------------------------------------------ setjmp/longjmp
 * A REAL AAPCS PAIR, IN tcc's OWN DIALECT.
 *
 * impl/setjmp-aarch64.c is written in M2libc's MACRO dialect -- asm("mov_x0,x17")
 * -- which only micro-c can compile, and it saves micro-c's four registers
 * rather than the callee-saved set. gen2.o is ordinary AAPCS code from
 * mc-tcc, so it needs the ordinary thing: x19-x28, fp, lr and sp.
 *
 * FILE SCOPE, NOT INLINE, because setjmp has to control its own prologue and
 * observe the caller's sp; no constraint syntax gives that.
 *
 * d8-d15 ARE NOT SAVED, and that is a decision rather than an omission. The
 * ABI makes them callee-saved, so a value live in one across a longjmp would
 * be lost -- but tcc's use is `if (setjmp(s1->error_jmp_buf) == 0) { compile }`
 * with tcc_error longjmping out, and everything live on that path is being
 * abandoned. Adding them needs stp/ldp on d-registers, which the arm64
 * assembler patch series has not been measured on; taking the narrower thing
 * that is tested beats the wider thing that is not.
 *
 * MEASURED, under mc-tcc on qemu-aarch64: setjmp returns 0, a longjmp from
 * five frames deep delivers 7, and longjmp(jb, 0) delivers 1 as C requires. */
__asm__(
".global setjmp\n"
"setjmp:\n"
"    stp x19, x20, [x0, #0]\n"
"    stp x21, x22, [x0, #16]\n"
"    stp x23, x24, [x0, #32]\n"
"    stp x25, x26, [x0, #48]\n"
"    stp x27, x28, [x0, #64]\n"
"    stp x29, x30, [x0, #80]\n"
"    mov x2, sp\n"
"    str x2, [x0, #104]\n"
"    mov w0, #0\n"
"    ret\n"
".global _setjmp\n"
"_setjmp:\n"
"    b setjmp\n"
".global longjmp\n"
"longjmp:\n"
"    ldp x19, x20, [x0, #0]\n"
"    ldp x21, x22, [x0, #16]\n"
"    ldp x23, x24, [x0, #32]\n"
"    ldp x25, x26, [x0, #48]\n"
"    ldp x27, x28, [x0, #64]\n"
"    ldp x29, x30, [x0, #80]\n"
"    ldr x2, [x0, #104]\n"
"    mov sp, x2\n"
"    cmp w1, #0\n"
"    csinc w0, w1, wzr, ne\n"
"    ret\n");
