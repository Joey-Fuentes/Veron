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

/* environ is set up by libc-full's _start. Walking it is all getenv is. */
extern char** environ;

char* getenv(char* name)
{
	char** e = environ;
	unsigned long n = strlen(name);
	unsigned long k;

	if(NULL == e) return NULL;

	while(NULL != e[0])
	{
		k = 0;
		while(k < n)
		{
			if(e[0][k] != name[k]) break;
			k = k + 1;
		}
		if(k == n)
		{
			if(e[0][n] == '=') return e[0] + n + 1;
		}
		e = e + 1;
	}
	return NULL;
}

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

void* localtime(long* t) { return NULL; }

char* realpath(char* path, char* resolved)
{
	if(NULL == resolved) return path;
	unsigned long n = strlen(path);
	memcpy(resolved, path, n + 1);
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
