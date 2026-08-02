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
int strtod(char* s, char** e) { if(NULL != e) e[0] = s; return 0; }
int strtof(char* s, char** e) { if(NULL != e) e[0] = s; return 0; }
int strtold(char* s, char** e) { if(NULL != e) e[0] = s; return 0; }
int ldexpl(int x, int exp) { return 0; }
