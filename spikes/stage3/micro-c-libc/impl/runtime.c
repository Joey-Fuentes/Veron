/* micro-c: REAL implementations of the runtime functions M2libc lacks.
 *
 * These replace stubs.c, which returned 0 from everything. That was fine while
 * the question was "does the pipeline close"; it is useless the moment the
 * question becomes "can this tcc compile a program", because a compiler built
 * on functions that return 0 produces zeros.
 *
 * WHAT IS HERE AND WHAT IS NOT. Everything below is a genuine implementation
 * except where a comment says otherwise. setjmp and longjmp are in
 * setjmp-aarch64.c because they cannot be written in C.
 *
 * Written against micro-c, so: no float arithmetic anywhere (float is still a
 * word-sized integer in this compiler), and nothing depends on `int` being
 * four bytes.
 */

#include <stddef.h>

/* micro-c does not predefine NULL and stddef.h here is M2libc's, which
 * defines it only under some configurations. Defining it locally is safer
 * than depending on which stddef.h wins the include search. */
#ifndef NULL
#define NULL 0
#endif

void* malloc(unsigned long size);
void free(void* ptr);
void* memcpy(void* dest, void* src, unsigned long n);
unsigned long strlen(char* s);

/* ------------------------------------------------------------------ */
/* The strtoX family.                                                   */
/*                                                                      */
/* tcc parses its own numeric literals in tccpp.c, so these are NOT on   */
/* the hot path for compiling C. They are used for option values and     */
/* for #line directives. Base 0 means "0x is hex, leading 0 is octal,    */
/* otherwise decimal", which is what the standard says and what tcc      */
/* relies on.                                                           */
/* ------------------------------------------------------------------ */

static int digit_value(int c)
{
	if(c >= '0' && c <= '9') return c - '0';
	if(c >= 'a' && c <= 'z') return c - 'a' + 10;
	if(c >= 'A' && c <= 'Z') return c - 'A' + 10;
	return -1;
}

static long strto_common(char* nptr, char** endptr, int base, int* negative)
{
	char* p = nptr;
	long value = 0;
	int any = 0;
	int d;

	while(*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p = p + 1;

	negative[0] = 0;
	if(*p == '-')
	{
		negative[0] = 1;
		p = p + 1;
	}
	else if(*p == '+')
	{
		p = p + 1;
	}

	if(base == 0)
	{
		if(*p == '0')
		{
			if(p[1] == 'x' || p[1] == 'X')
			{
				base = 16;
				p = p + 2;
			}
			else
			{
				base = 8;
				p = p + 1;
				any = 1;      /* a lone "0" is a valid zero */
			}
		}
		else
		{
			base = 10;
		}
	}
	else if(base == 16)
	{
		if(*p == '0')
		{
			if(p[1] == 'x' || p[1] == 'X') p = p + 2;
		}
	}

	while(*p != 0)
	{
		d = digit_value(*p);
		if(d < 0) break;
		if(d >= base) break;
		value = value * base + d;
		any = 1;
		p = p + 1;
	}

	/* endptr points at nptr when nothing was consumed -- the standard's way
	 * of saying "no conversion", and callers check for it. */
	if(NULL != endptr)
	{
		if(any) endptr[0] = p;
		else endptr[0] = nptr;
	}
	return value;
}

long strtol(char* nptr, char** endptr, int base)
{
	int neg;
	long v = strto_common(nptr, endptr, base, &neg);
	if(neg) return -v;
	return v;
}

unsigned long strtoul(char* nptr, char** endptr, int base)
{
	int neg;
	unsigned long v = strto_common(nptr, endptr, base, &neg);
	if(neg) return -v;
	return v;
}

long strtoll(char* nptr, char** endptr, int base)
{
	return strtol(nptr, endptr, base);
}

unsigned long strtoull(char* nptr, char** endptr, int base)
{
	return strtoul(nptr, endptr, base);
}

/* ------------------------------------------------------------------ */
/* qsort.                                                               */
/*                                                                      */
/* tccgen.c sorts switch cases with it, so a switch statement in the     */
/* program being compiled will not work without this.                   */
/*                                                                      */
/* Insertion sort, deliberately. It is O(n^2), and the arrays are case   */
/* labels and eh_frame entries -- tens of elements, not thousands. A     */
/* quicksort here would be more code, more places to be subtly wrong,    */
/* and no faster at these sizes. If something large is ever sorted this  */
/* will be visible as time, not as wrongness.                           */
/* ------------------------------------------------------------------ */

typedef int (*qsort_cmp)(void*, void*);

void qsort(void* base, unsigned long nmemb, unsigned long size, qsort_cmp compar)
{
	char* a = base;
	char* tmp;
	unsigned long i;
	unsigned long j;

	if(nmemb < 2) return;
	if(size == 0) return;

	tmp = malloc(size);
	if(NULL == tmp) return;

	i = 1;
	while(i < nmemb)
	{
		memcpy(tmp, a + i * size, size);
		j = i;
		while(j > 0)
		{
			if(compar(a + (j - 1) * size, tmp) <= 0) break;
			memcpy(a + j * size, a + (j - 1) * size, size);
			j = j - 1;
		}
		memcpy(a + j * size, tmp, size);
		i = i + 1;
	}

	free(tmp);
}

/* ------------------------------------------------------------------ */
/* Small odds and ends.                                                 */
/* ------------------------------------------------------------------ */

/* tcc prints this after a failed open. The messages are the common errno
 * values on Linux; anything else gets a generic string rather than a lie. */
char* strerror(int errnum)
{
	if(errnum == 1) return "Operation not permitted";
	if(errnum == 2) return "No such file or directory";
	if(errnum == 4) return "Interrupted system call";
	if(errnum == 5) return "Input/output error";
	if(errnum == 9) return "Bad file descriptor";
	if(errnum == 12) return "Cannot allocate memory";
	if(errnum == 13) return "Permission denied";
	if(errnum == 17) return "File exists";
	if(errnum == 20) return "Not a directory";
	if(errnum == 21) return "Is a directory";
	if(errnum == 22) return "Invalid argument";
	if(errnum == 28) return "No space left on device";
	return "Unknown error";
}

/* getenv IS M2libc's, NOT OURS.
 *
 * There used to be a copy here, over `extern char** environ;` -- and nothing
 * anywhere defines `environ`. micro-c used to turn that extern into a fresh
 * null global of its own, so the copy linked, returned NULL for every lookup,
 * and looked like it worked. Two rounds of bisection ran with environment
 * switches that silently did nothing because of it.
 *
 * Now that `extern` declares rather than defines, the reference is unresolved
 * and the link fails -- correctly. M2libc's stdlib.c has a getenv that reads
 * the environment properly, so the right answer is to not have a second one.
 */

/* environ ITSELF STILL HAS TO EXIST, because tcc references it:
 *
 *     extern char **environ;                       tccrun.c:213
 *     char **envp = environ;                       tccrun.c:214
 *
 * Only on the `-run` path, which this spike never takes -- everything here is
 * `-c`. So this is a DEFINITION so the link resolves, and it is null because
 * nothing sets it: M2libc's _start does not pass envp through. If `-run` is
 * ever wanted, that is the thing to fix, and the null here will produce an
 * immediate and obvious failure rather than a subtle one.
 *
 * It is defined once, here, on purpose. Before `extern` was fixed, every unit
 * that declared it got its own silent copy. */
char** environ;


/* HONEST STUBS -- these do not do what their names say, and every one of them
 * is only reached on a path tcc does not need to compile a program.
 *
 *   time/localtime  timestamps in debug info and ELF headers. Returning a
 *                   fixed value makes output REPRODUCIBLE, which is worth
 *                   more here than a real clock.
 *   realpath        path canonicalisation; returning the input unchanged is
 *                   correct whenever the path is already absolute.
 *   mprotect        only needed to run JIT-compiled code in memory.
 *   freopen         only used by the -o option handling.
 *   sem_*           only with CONFIG_TCC_SEMLOCK, which is off.
 *   sig*            only to pretty-print a crash in JIT mode.
 *   __clear_cache   an instruction-cache flush, only needed before EXECUTING
 *                   generated code; harmless when only writing it to a file.
 */
long time(long* t)
{
	if(NULL != t) t[0] = 0;
	return 0;
}

/* gettimeofday -- REQUIRED TO LINK tcc's REAL DRIVER, AND IT RETURNS A
 * CONSTANT ON PURPOSE.
 *
 * tcc.c's main() calls it; libtcc.c does not, which is why nothing needed it
 * until the front end was compiled. M2libc has no time syscall wrapper.
 *
 * ZERO IS THE ANSWER, NOT A DEGRADED ONE. A build must be a pure function of
 * its inputs, so nothing on the build path may read a clock. Returning a real
 * time here would be a reproducibility hole disguised as a courtesy: two
 * builds of identical source would differ, which is the invariant the whole
 * ladder exists to defend.
 *
 * AUDITED RATHER THAN ASSUMED. The first version of this comment claimed the
 * only consumer was `-bench`. That was a guess. Every clock source reachable
 * in the tcc tree, checked:
 *
 *   gettimeofday   tcc.c:283 ONLY -- the -bench counters, printed to stderr
 *                  and read by nothing. The guess was right; it was still a
 *                  guess when it was written down.
 *   time()         tccpp.c:3425, expanding __DATE__ and __TIME__ -- and this
 *                  one DOES reach emitted bytes. Already stubbed to 0 above,
 *                  so those macros are already deterministic here.
 *   ar_date        NOT clock-derived. tcctools.c initialises it to the
 *                  literal "0           ", so tcc's own -ar is deterministic
 *                  by construction. Claimed otherwise here before checking.
 *   tccpe.c:761    TimeDateStamp, commented out upstream, and PE is not a
 *                  target of this ladder.
 *
 * A consumer that wants a real time is a reproducibility bug, and should fail
 * visibly rather than be quietly satisfied. */
int gettimeofday(void* tv, void* tz)
{
	long* p = tv;
	if(NULL != p)
	{
		p[0] = 0;
		p[1] = 0;
	}
	return 0;
}

void* localtime(long* t) { return NULL; }

/* WITH resolved == NULL, THE CALLER OWNS THE RESULT AND WILL FREE IT.
 *
 * This returned `path` itself, which has the right VALUE for an already
 * absolute path -- the note above says so and it is true -- but the wrong
 * OWNERSHIP, and tcc frees what it is handed:
 *
 *     if (!!(p1 = realpath(f1, NULL))) {
 *         if (!!(p2 = realpath(f2, NULL))) {
 *             ret = PATHCMP(p1, p2);
 *             libc_free(p2);                    // realpath() requirement
 *         }
 *         libc_free(p1);
 *     }                                              libtcc.c:492
 *
 * so the caller's own buffer went to free(). One of the two is
 * `e->filename` inside a CachedInclude --
 *
 *     typedef struct CachedInclude {
 *         int ifndef_macro; int once; int hash_next; char filename[1];
 *     } CachedInclude;
 *
 * -- whose `filename` sits at offset 12, and the allocator said exactly that:
 *
 *     M2libc: free: INTERIOR pointer into a live block (12)
 *
 * ONE PATH REACHES IT, WHICH IS WHY IT LOOKED LIKE A HEAP BUG.
 * normalized_PATHCMP is called from search_cached_include only when a cached
 * entry has `once` set -- so it needs a header with `#pragma once` included a
 * SECOND time. tests2/18_include.c does that three ways over two lines, and
 * it was the last program in the suite failing for a reason that was not
 * floating point. Nothing else in tcc calls realpath, so nothing else showed
 * it, and the damage surfaced as a corrupt-looking free far from its cause.
 *
 * POSIX is explicit: with a null second argument the result is obtained as
 * though by malloc and the caller frees it. A copy is what that costs. */
/* AND IT HAS TO CANONICALISE, not just copy.
 *
 * With the ownership fixed, 18_include still printed
 *     counter 0 / counter 1 / counter 2
 * where tcc prints `counter 0` once: the header carries `#pragma once` and is
 * included three times, spelled
 *     "18_include2.h"   "./18_include2.h"   "../tests2/18_include2.h"
 * search_cached_include only recognises the second and third as the same file
 * if realpath maps them onto the first, and a copy does not.
 *
 * LEXICAL IS ENOUGH HERE, AND THE REASON IS IN parse_include. Every path this
 * is asked about was built as `include_dir + "/" + name`, so it is already
 * ABSOLUTE by the time it arrives -- "/x/tests2/./18_include2.h" and
 * "/x/tests2/../tests2/18_include2.h". Collapsing "." and ".." over an
 * absolute path needs no filesystem access, which matters in a box with no
 * getcwd and no symlink resolution.
 *
 * WHAT IT DOES NOT DO, PLAINLY: it does not resolve symlinks, and a RELATIVE
 * path is returned copied but uncollapsed, because making one absolute needs
 * a working directory this runtime does not have. Neither is reachable from
 * tcc's single call site. Said here rather than discovered later. */
char* realpath(char* path, char* resolved)
{
	unsigned long n;
	unsigned long i;
	unsigned long w;

	n = strlen(path);
	if(NULL == resolved)
	{
		resolved = malloc(n + 1);
		if(NULL == resolved) return NULL;
	}

	if('/' != path[0])
	{
		memcpy(resolved, path, n + 1);
		return resolved;
	}

	/* Walk the source a component at a time, writing the kept ones. `w`
	 * always points just past the last '/' written. */
	w = 0;
	i = 0;
	while(i < n)
	{
		if('/' == path[i])
		{
			/* collapse a run of slashes */
			if((w > 0) && ('/' == resolved[w - 1])) { i = i + 1; continue; }
			resolved[w] = '/';
			w = w + 1;
			i = i + 1;
			continue;
		}

		/* a component starts at i; find its end */
		unsigned long j = i;
		while((j < n) && ('/' != path[j])) j = j + 1;

		if((j - i == 1) && ('.' == path[i]))
		{
			/* "." -- drop it, and the slash we just wrote */
			i = j + 1;
			continue;
		}
		if((j - i == 2) && ('.' == path[i]) && ('.' == path[i + 1]))
		{
			/* ".." -- drop the previous component too, but never
			 * walk above the root. */
			if(w > 1)
			{
				w = w - 1;                       /* the trailing '/' */
				while((w > 1) && ('/' != resolved[w - 1])) w = w - 1;
			}
			i = j + 1;
			continue;
		}

		while(i < j)
		{
			resolved[w] = path[i];
			w = w + 1;
			i = i + 1;
		}
	}

	/* a trailing slash on a non-root path is not part of the name */
	if((w > 1) && ('/' == resolved[w - 1])) w = w - 1;
	if(0 == w) { resolved[0] = '/'; w = 1; }
	resolved[w] = 0;
	return resolved;
}

int mprotect(void* addr, unsigned long len, int prot) { return 0; }
void* freopen(char* f, char* m, void* s) { return NULL; }
int sem_init(void* s, int p, int v) { return 0; }
int sem_wait(void* s) { return 0; }
int sem_post(void* s) { return 0; }
int sigaction(int n, void* a, void* o) { return 0; }
int sigaddset(void* s, int n) { return 0; }
int sigemptyset(void* s) { return 0; }
int sigprocmask(int h, void* s, void* o) { return 0; }
void __clear_cache(void* b, void* e) { return; }

/* Float parsing. micro-c maps float, double and long double onto ONE
 * word-sized integer type, so there is no representation to parse into and
 * nothing correct to return. These exist so the link closes; any program that
 * reaches them is already getting wrong answers from every other float
 * operation in the compiler. */

/* ===================================================================
 * strtod, IN INTEGER ARITHMETIC, BECAUSE THE COMPILER HAS NONE.
 *
 * These three were stubs:
 *
 *     int strtod(char* s, char** e) { if(NULL != e) e[0] = s; return 0; }
 *
 * and tcc converts every floating-point literal in every program it compiles
 * with exactly one line:
 *
 *     tokc.d = strtod(token_buf, NULL);              tccpp.c:2468
 *
 * so EVERY float constant mc-tcc emitted was 0.0. That is the whole of the
 * "micro-c has no floating point" gap as it reaches tcc -- not the code
 * generator, which is correct, and not the float model, but three stubs.
 * Measured before: `5.008` came out as 0000000000000000 and
 * `(int)(5.008*1000)` as 0.
 *
 * NO FLOAT OPERATION APPEARS BELOW. micro-c compiles this file and has no
 * floating-point arithmetic at all, so the IEEE754 bit pattern is assembled
 * with integers and handed back through a union. That also makes it correct
 * under mc-tcc, which compiles this same file for gen2 and DOES have floats:
 * a `return bits;` from a double-returning function would convert there and
 * reinterpret here, which is two different functions from one source.
 *
 * EXACT, NOT APPROXIMATE. A decimal literal is m * 10^d for integers m and d,
 * so the conversion is one rational number rounded to 53 bits. A small bignum
 * makes it correctly rounded BY CONSTRUCTION rather than accurate to within
 * some argued-about number of ulps -- which matters, because these values are
 * what a compiler writes into .data.ro as its reading of what the programmer
 * typed.
 *
 * HEXADECIMAL FLOATS TOO, and leaving them out cost a round. C99 requires
 * strtod to accept 0x1p28 and tcc hands it the whole literal, so a strtod that
 * stops at the 'x' returns 0.0. musl's printf scales with exactly that
 * constant --
 *     if (y) y *= 0x1p28, e2-=28;              vfprintf.c, fmt_fp
 * -- so every %f, %e and %g printed 0.000000 while the value reaching fmt_fp
 * was provably exact. Traced inside the box's own musl: the argument arrived
 * as 4014083126e978d5 and that one line turned it into zero.
 *
 * MEASURED AGAINST glibc's strtod, bit for bit: 6,676 chosen values -- every
 * power of ten from 1e-320 to 1e308, DBL_MIN, DBL_MAX written out in full,
 * the smallest subnormal, 900-digit integers, ties -- 400,000 random decimal
 * ones, and 82,209 hexadecimal ones covering every power of two from 2^-1100
 * to 2^1100. 488,885 of 488,885 identical, including the sign of zero and the
 * end pointer.
 * =================================================================== */

#define NLIMB 160
#define NDIG  800               /* significant decimal digits kept */

static int ishex(int c)
{
    if (c >= '0' && c <= '9') return 1;
    if (c >= 'a' && c <= 'f') return 1;
    if (c >= 'A' && c <= 'F') return 1;
    return 0;
}

static int hexval(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return c - 'A' + 10;
}

static char DIG[NDIG];

static unsigned int NUM[NLIMB];
static unsigned int DEN[NLIMB];
static unsigned int QUO[NLIMB];
static unsigned int T[NLIMB];
static int NUMN;
static int DENN;
static int QUON;

static void bset(unsigned int *a, int *n, unsigned long v)
{
    int i;
    i = 0;
    while (i < NLIMB) { a[i] = 0; i = i + 1; }
    a[0] = (unsigned int)(v & 0xffffffffUL);
    a[1] = (unsigned int)((v >> 32) & 0xffffffffUL);
    *n = 2;
    while (*n > 1 && a[*n - 1] == 0) *n = *n - 1;
}

/* a *= m, with m < 2^32 */
static void bmul(unsigned int *a, int *n, unsigned long m)
{
    unsigned long carry;
    unsigned long cur;
    int i;
    carry = 0;
    i = 0;
    while (i < *n) {
        cur = (unsigned long)a[i] * m + carry;
        a[i] = (unsigned int)(cur & 0xffffffffUL);
        carry = cur >> 32;
        i = i + 1;
    }
    while (carry != 0) {
        a[i] = (unsigned int)(carry & 0xffffffffUL);
        carry = carry >> 32;
        i = i + 1;
        *n = i;
    }
}

/* a += v, v < 2^32 */
static void badd(unsigned int *a, int *n, unsigned long v)
{
    unsigned long carry;
    unsigned long cur;
    int i;
    carry = v;
    i = 0;
    while (carry != 0) {
        if (i >= *n) { a[i] = 0; *n = i + 1; }
        cur = (unsigned long)a[i] + carry;
        a[i] = (unsigned int)(cur & 0xffffffffUL);
        carry = cur >> 32;
        i = i + 1;
    }
}

/* a <<= k */
static void bshl(unsigned int *a, int *n, int k)
{
    int words;
    int bits;
    int i;
    unsigned long cur;
    unsigned long carry;

    words = k / 32;
    bits = k % 32;
    if (words > 0) {
        i = *n - 1;
        while (i >= 0) { a[i + words] = a[i]; i = i - 1; }
        i = 0;
        while (i < words) { a[i] = 0; i = i + 1; }
        *n = *n + words;
    }
    if (bits > 0) {
        carry = 0;
        i = 0;
        while (i < *n) {
            cur = ((unsigned long)a[i] << bits) | carry;
            a[i] = (unsigned int)(cur & 0xffffffffUL);
            carry = cur >> 32;
            i = i + 1;
        }
        if (carry != 0) { a[*n] = (unsigned int)carry; *n = *n + 1; }
    }
}

static int bbits(unsigned int *a, int n)
{
    int i;
    unsigned int t;
    int b;
    i = n - 1;
    while (i > 0 && a[i] == 0) i = i - 1;
    if (a[i] == 0) return 0;
    t = a[i];
    b = 0;
    while (t != 0) { t = t >> 1; b = b + 1; }
    return i * 32 + b;
}

/* compare a and b */
static int bcmp(unsigned int *a, int an, unsigned int *b, int bn)
{
    int i;
    i = NLIMB - 1;
    while (i >= 0) {
        unsigned int x;
        unsigned int y;
        x = 0; y = 0;
        if (i < an) x = a[i];
        if (i < bn) y = b[i];
        if (x != y) { if (x > y) return 1; return -1; }
        i = i - 1;
    }
    return 0;
}

/* a -= b, assuming a >= b */
static void bsub(unsigned int *a, int *an, unsigned int *b, int bn)
{
    unsigned long borrow;
    unsigned long x;
    unsigned long y;
    int i;
    borrow = 0;
    i = 0;
    while (i < NLIMB) {
        x = (unsigned long)a[i];
        y = 0;
        if (i < bn) y = (unsigned long)b[i];
        y = y + borrow;
        if (x >= y) { a[i] = (unsigned int)(x - y); borrow = 0; }
        else { a[i] = (unsigned int)(x + 0x100000000UL - y); borrow = 1; }
        i = i + 1;
    }
    while (*an > 1 && a[*an - 1] == 0) *an = *an - 1;
}

static int bzero(unsigned int *a, int n)
{
    int i;
    i = 0;
    while (i < n) { if (a[i] != 0) return 0; i = i + 1; }
    return 1;
}

/* the top `want` bits of a, plus a sticky flag if anything was dropped */
static unsigned long btop(unsigned int *a, int n, int want, int *sticky, int *shift)
{
    int b;
    int drop;
    unsigned long v;
    int i;

    b = bbits(a, n);
    drop = b - want;
    *shift = drop;
    *sticky = 0;
    if (drop <= 0) {
        v = 0;
        i = b - 1;
        while (i >= 0) {
            v = (v << 1) | (unsigned long)((a[i / 32] >> (i % 32)) & 1);
            i = i - 1;
        }
        return v;
    }
    v = 0;
    i = b - 1;
    while (i >= drop) {
        v = (v << 1) | (unsigned long)((a[i / 32] >> (i % 32)) & 1);
        i = i - 1;
    }
    i = drop - 1;
    while (i >= 0) {
        if (((a[i / 32] >> (i % 32)) & 1) != 0) { *sticky = 1; i = 0; }
        i = i - 1;
    }
    return v;
}

/* assemble: sign, a 54-bit significand (the low bit is the round bit),
 * sticky, and the binary exponent of the significand's TOP bit */
static unsigned long assemble(int neg, unsigned long sig54, int sticky, int topexp)
{
    unsigned long mant;
    unsigned long rbit;
    long e;
    unsigned long out;
    int drop;
    int sub;

    sub = 0;
    if (sig54 == 0) {
        if (neg) return 0x8000000000000000UL;
        return 0;
    }

    /* INVARIANT: value = sig54 * 2^(topexp - 53), sig54's top bit at 53. */

    /* SUBNORMALS ARE NOT ZERO, and treating them as zero lost every value
     * below 2.2e-308 -- including DBL_MIN itself and the whole denormal range
     * the C standard requires a conforming implementation to represent.
     * Below 2^-1022 the exponent stops moving and the significand loses bits
     * instead, so the extra bits are dropped HERE, into sticky, before the
     * rounding rather than after it. */
    if (topexp < -1022) {
        sub = 1;
        drop = -1022 - topexp;
        if (drop >= 54) {
            if (neg) return 0x8000000000000000UL;
            return 0;
        }
        if ((sig54 & ((1UL << drop) - 1)) != 0) sticky = 1;
        sig54 = sig54 >> drop;
        topexp = topexp + drop;
        if (sig54 == 0) {
            /* everything rounded away except possibly a tie upward */
            if (sticky) {
                out = 1;
                if (neg) out = out | 0x8000000000000000UL;
                return out;
            }
            if (neg) return 0x8000000000000000UL;
            return 0;
        }
    }

    mant = sig54 >> 1;
    rbit = sig54 & 1;
    e = (long)topexp;                    /* value = mant * 2^(e-52) */

    /* round to nearest, ties to even */
    if (rbit != 0) {
        if (sticky != 0 || (mant & 1) != 0) {
            mant = mant + 1;
            if (mant == 0x20000000000000UL) { mant = mant >> 1; e = e + 1; }
        }
    }

    /* A SHIFTED-DOWN SIGNIFICAND IS STILL SUBNORMAL. The shift above leaves
     * topexp at -1022, which reads as a perfectly ordinary exponent and sent
     * every denormal back down the normal path -- where the implicit leading
     * bit is added again, so each came out exactly 2^52 too large. The flag
     * remembers what the shift was for. */
    e = e + 1023;
    if (sub) e = 0;
    if (e >= 2047) {                     /* overflow -> infinity */
        out = 0x7ff0000000000000UL;
        if (neg) out = out | 0x8000000000000000UL;
        return out;
    }
    if (e <= 0) {
        /* SUBNORMAL. The significand carries no implicit bit, so it is stored
         * whole -- and if rounding pushed it to 2^52 the same bit pattern is
         * the smallest NORMAL, which is exactly the right answer. */
        out = mant;
        if (neg) out = out | 0x8000000000000000UL;
        return out;
    }

    out = ((unsigned long)e << 52) | (mant & 0xfffffffffffffUL);
    if (neg) out = out | 0x8000000000000000UL;
    return out;
}

static unsigned long strtod_bits(char *s, char **end)
{
    int neg;
    int ndig;
    int dexp;
    int seen;
    int i;
    char *p;
    int expneg;
    int ex;
    int extra;

    p = s;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p = p + 1;

    neg = 0;
    if (*p == '-') { neg = 1; p = p + 1; }
    else if (*p == '+') p = p + 1;

    /* HEXADECIMAL FLOATS ARE A DIFFERENT NUMBER, not a different spelling.
     *
     * C99 requires strtod to accept 0x1p28, and tcc hands it the whole literal
     * -- so a strtod that stops at the 'x' returns 0.0 for it. musl's printf
     * scales with exactly that constant:
     *
     *     if (y) y *= 0x1p28, e2-=28;              vfprintf.c, fmt_fp
     *
     * so every %f, %e and %g printed 0.000000 while the value reaching fmt_fp
     * was exact -- traced, with the argument arriving as 4014083126e978d5 and
     * the scale step turning it into zero. Nine of nine hex forms were wrong.
     *
     * The mantissa is base 16 and the exponent after 'p' is a power of TWO, so
     * no decimal scaling is involved at all: shift the digits into place and
     * assemble. Exact by construction, like the decimal path. */
    if (*p == '0' && (p[1] == 'x' || p[1] == 'X')
        && (ishex(p[2]) || (p[2] == '.' && ishex(p[3])))) {
        unsigned long m;
        int bexp;
        int any;
        int sticky2;
        p = p + 2;
        m = 0;
        bexp = 0;
        any = 0;
        sticky2 = 0;
        while (ishex(*p)) {
            any = 1;
            if (m < 0x1000000000000000UL) m = (m << 4) | (unsigned long)hexval(*p);
            else { bexp = bexp + 4; if (hexval(*p) != 0) sticky2 = 1; }
            p = p + 1;
        }
        if (*p == '.') {
            p = p + 1;
            while (ishex(*p)) {
                any = 1;
                if (m < 0x1000000000000000UL) { m = (m << 4) | (unsigned long)hexval(*p); bexp = bexp - 4; }
                else if (hexval(*p) != 0) sticky2 = 1;
                p = p + 1;
            }
        }
        if (*p == 'p' || *p == 'P') {
            char *save2;
            int en;
            int eneg;
            save2 = p;
            p = p + 1;
            eneg = 0;
            if (*p == '-') { eneg = 1; p = p + 1; }
            else if (*p == '+') p = p + 1;
            if (*p >= '0' && *p <= '9') {
                en = 0;
                while (*p >= '0' && *p <= '9') { if (en < 100000) en = en * 10 + (*p - '0'); p = p + 1; }
                if (eneg) bexp = bexp - en; else bexp = bexp + en;
            } else p = save2;
        }
        if (end != 0) *end = p;
        if (m == 0) { if (neg) return 0x8000000000000000UL; return 0; }
        /* normalise to 54 significant bits, folding the rest into sticky */
        {
            int b;
            unsigned long t;
            t = m; b = 0;
            while (t) { t = t >> 1; b = b + 1; }
            if (b > 54) {
                int drop2;
                drop2 = b - 54;
                if ((m & ((1UL << drop2) - 1)) != 0) sticky2 = 1;
                m = m >> drop2;
                bexp = bexp + drop2;
            } else if (b < 54) {
                m = m << (54 - b);
                bexp = bexp - (54 - b);
            }
            /* value = m * 2^bexp, m has bit 53 as its top */
            return assemble(neg, m, sticky2, bexp + 53);
        }
    }

    /* EVERY SIGNIFICANT DIGIT IS KEPT, not the first nineteen.
     *
     * Truncating the decimal mantissa at what fits in a 64-bit integer and
     * calling the rest a sticky bit is wrong, and wrong in a way that only
     * shows up on long inputs: dropping DECIMAL digits is not the same as
     * dropping BINARY bits, and the discarded tail can be worth more than
     * half an ulp. It cost 48 of 400,000 random values, every one of them one
     * ulp low. The digits go into the bignum instead, where the conversion is
     * exact by construction.
     *
     * The cap is on the count, not the value: past NDIG significant digits
     * nothing can reach the 53rd bit except through sticky, and NDIG is set
     * far above the 768 that the worst-case decimal needs. */
    ndig = 0;
    dexp = 0;
    seen = 0;
    extra = 0;
    while (*p == '0') { seen = 1; p = p + 1; }        /* leading zeros */
    while (*p >= '0' && *p <= '9') {
        seen = 1;
        if (ndig < NDIG) { DIG[ndig] = (char)(*p - '0'); ndig = ndig + 1; }
        else { dexp = dexp + 1; if (*p != '0') extra = 1; }
        p = p + 1;
    }
    if (*p == '.') {
        p = p + 1;
        if (ndig == 0) {
            /* 0.000123 -- the zeros after the point are not significant */
            while (*p == '0') { seen = 1; dexp = dexp - 1; p = p + 1; }
        }
        while (*p >= '0' && *p <= '9') {
            seen = 1;
            if (ndig < NDIG) { DIG[ndig] = (char)(*p - '0'); ndig = ndig + 1; dexp = dexp - 1; }
            else if (*p != '0') extra = 1;
            p = p + 1;
        }
    }
    if (!seen) { if (end != 0) *end = s; return 0; }

    if (*p == 'e' || *p == 'E') {
        char *save;
        save = p;
        p = p + 1;
        expneg = 0;
        if (*p == '-') { expneg = 1; p = p + 1; }
        else if (*p == '+') p = p + 1;
        if (*p >= '0' && *p <= '9') {
            ex = 0;
            while (*p >= '0' && *p <= '9') {
                if (ex < 100000) ex = ex * 10 + (*p - '0');
                p = p + 1;
            }
            if (expneg) dexp = dexp - ex; else dexp = dexp + ex;
        } else p = save;
    }
    if (end != 0) *end = p;

    if (ndig == 0) { if (neg) return 0x8000000000000000UL; return 0; }

    /* OUT OF RANGE ON MAGNITUDE, not on the exponent alone, and decided
     * before any bignum work. The value is about 10^(ndig+dexp): testing dexp
     * by itself let "1e400" out early and a 900-digit integer through, which
     * is the case that would have overrun the limbs. DBL_MAX is 1.8e308 and
     * the smallest subnormal is 4.9e-324, so these bounds are loose by an
     * order of magnitude on each side and still bound the arithmetic. */
    if (ndig + dexp > 320) { if (neg) return 0xfff0000000000000UL; return 0x7ff0000000000000UL; }
    if (ndig + dexp < -350) { if (neg) return 0x8000000000000000UL; return 0; }

    bset(NUM, &NUMN, 0);
    i = 0;
    while (i < ndig) {
        bmul(NUM, &NUMN, 10);
        badd(NUM, &NUMN, (unsigned long)DIG[i]);
        i = i + 1;
    }

    if (dexp >= 0) {
        i = 0;
        while (i < dexp) { bmul(NUM, &NUMN, 10); i = i + 1; }
        {
            int sticky;
            int shift;
            unsigned long sig;
            int b;
            b = bbits(NUM, NUMN);
            sig = btop(NUM, NUMN, 54, &sticky, &shift);
            if (extra) sticky = 1;
            if (b < 54) { sig = sig << (54 - b); }
            return assemble(neg, sig, sticky, b - 1);
        }
    } else {
        int nd;
        int shiftby;
        int qbits;
        int sticky;
        int j;
        int b;

        nd = -dexp;
        bset(DEN, &DENN, 1);
        i = 0;
        while (i < nd) { bmul(DEN, &DENN, 10); i = i + 1; }

        /* Shift the numerator so the quotient is certain to have >= 55 bits.
         * bits(num) - bits(den) + shift >= 55 is the requirement; a little
         * extra costs nothing and removes the edge case. */
        shiftby = bbits(DEN, DENN) - bbits(NUM, NUMN) + 60;
        if (shiftby < 0) shiftby = 0;
        bshl(NUM, &NUMN, shiftby);

        /* schoolbook long division, one bit at a time, most significant
         * first. QUO collects the quotient; NUM becomes the remainder. */
        qbits = bbits(NUM, NUMN) - bbits(DEN, DENN) + 1;
        if (qbits < 1) qbits = 1;
        i = 0;
        while (i < NLIMB) { QUO[i] = 0; i = i + 1; }
        QUON = NLIMB;

        j = qbits - 1;
        while (j >= 0) {
            int k;
            /* is (den << j) <= num ? */
            k = j;
            {
                int TN;
                int z;
                z = 0;
                while (z < NLIMB) { T[z] = 0; z = z + 1; }
                z = 0;
                while (z < DENN) { T[z] = DEN[z]; z = z + 1; }
                TN = DENN;
                bshl(T, &TN, k);
                if (bcmp(NUM, NUMN, T, TN) >= 0) {
                    bsub(NUM, &NUMN, T, TN);
                    QUO[j / 32] = QUO[j / 32] | (1U << (j % 32));
                }
            }
            j = j - 1;
        }

        /* THE REMAINDER IS A STICKY BIT AND btop OVERWROTE IT. A non-empty
         * remainder means the quotient is short of the true value, so a tie
         * must round UP -- and passing &sticky straight into btop reset it to
         * whatever the quotient's own dropped bits said. Twenty-four values,
         * all one ulp low. Kept separately and combined. */
        sticky = 0;
        if (!bzero(NUM, NUMN)) sticky = 1;
        if (extra) sticky = 1;
        {
            int shift;
            int qsticky;
            unsigned long sig;
            b = bbits(QUO, QUON);
            qsticky = 0;
            sig = btop(QUO, QUON, 54, &qsticky, &shift);
            if (qsticky) sticky = 1;
            if (b < 54) sig = sig << (54 - b);
            /* value = quotient * 2^-shiftby */
            return assemble(neg, sig, sticky, b - 1 - shiftby);
        }
    }
}

/* NARROWING TO float, ALSO IN INTEGERS. A cast would be one instruction under
 * mc-tcc and nothing at all under micro-c, which is the whole reason this file
 * cannot use one. */
static unsigned int strtod_to_f32(unsigned long b)
{
    unsigned long sign;
    long ex;
    unsigned long mant;
    unsigned int rbit;
    unsigned int sticky;
    unsigned int m24;
    unsigned int out;
    int drop;

    sign = (b >> 63) & 1;
    ex = (long)((b >> 52) & 0x7ff);
    mant = b & 0xfffffffffffffUL;

    if (ex == 0x7ff) {                       /* inf or nan */
        out = (unsigned int)(sign << 31) | 0x7f800000;
        if (mant != 0) out = out | 0x400000;
        return out;
    }
    if (ex == 0 && mant == 0) return (unsigned int)(sign << 31);

    if (ex == 0) { ex = -1022; }             /* subnormal double -> flushes */
    else { mant = mant | 0x10000000000000UL; ex = ex - 1023; }

    ex = ex + 127;
    if (ex >= 255) return (unsigned int)(sign << 31) | 0x7f800000;

    drop = 29;                               /* 53 significand bits -> 24 */
    if (ex <= 0) {
        drop = drop + (int)(1 - ex);
        ex = 0;
        if (drop >= 54) return (unsigned int)(sign << 31);
    }
    rbit = (unsigned int)((mant >> (drop - 1)) & 1);
    sticky = 0;
    if ((mant & ((1UL << (drop - 1)) - 1)) != 0) sticky = 1;
    m24 = (unsigned int)(mant >> drop);
    if (rbit != 0) {
        if (sticky != 0 || (m24 & 1) != 0) {
            m24 = m24 + 1;
            if (m24 == 0x1000000) { m24 = m24 >> 1; ex = ex + 1; }
        }
    }
    if (ex >= 255) return (unsigned int)(sign << 31) | 0x7f800000;
    if (ex == 0) return (unsigned int)(sign << 31) | m24;
    return (unsigned int)(sign << 31) | ((unsigned int)ex << 23) | (m24 & 0x7fffff);
}

/* THE THREE ENTRY POINTS. A union rather than a cast: what was computed is a
 * bit pattern, not a number that needs converting. The signatures match
 * stdlib.h exactly -- mc-tcc compiles this file too and checks them. */
union strtod_pun64 { double d; unsigned long u; };
union strtod_punld { long double d; unsigned long u; };
union strtod_pun32 { float f; unsigned int u; };

double strtod(const char* nptr, char** endptr)
{
    union strtod_pun64 v;
    v.u = strtod_bits((char*)nptr, endptr);
    return v.d;
}

/* long double IS double here -- tcc-microc patch 0001 sets LDOUBLE_SIZE to 8
 * and says why. */
long double strtold(const char* nptr, char** endptr)
{
    union strtod_punld v;
    v.u = strtod_bits((char*)nptr, endptr);
    return v.d;
}

float strtof(const char* nptr, char** endptr)
{
    union strtod_pun32 v;
    v.u = strtod_to_f32(strtod_bits((char*)nptr, endptr));
    return v.f;
}

int ldexpl(int x, int exp) { return 0; }
