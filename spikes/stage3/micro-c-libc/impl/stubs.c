/* micro-c: STUBS ONLY -- enough to LINK, not enough to RUN.
 *
 * M2libc covers 34 of the 59 functions a compiled libtcc.c references. These
 * are the other 25. They exist so the link can be attempted at all, and every
 * one of them is wrong on purpose:
 *
 *   - the strtoX family returns 0, so any number tcc parses comes out zero
 *   - setjmp/longjmp do nothing, so tcc's error recovery would fall through
 *   - the signal and semaphore calls are no-ops
 *   - qsort does not sort
 *
 * A tcc linked against this will start and will not work. The point is to
 * find out whether the LINK closes -- which no amount of parsing can tell us
 * -- and to leave a list of exactly what a real runtime owes.
 *
 * NOT ON ANY BUILD PATH.
 */

/* environ IS A DEFINITION, NOT A STUB FUNCTION.
 *
 * tcc references it at tccrun.c:213 on the `-run` path. It used to resolve by
 * accident: micro-c turned `extern char** environ;` into a fresh null global
 * in whichever unit declared it, so every link found "a" definition and none
 * of them was the right one. EXPERIMENT-zzl stopped that, and this link set --
 * the ladder's, which uses stubs.c rather than runtime.c -- then had nothing
 * defining the symbol and every rung from E onward failed to link.
 *
 * Two runtimes exist and they are easy to forget about individually:
 *
 *     runtime.c   the real one    tcc-two-ways, local-tcc.sh
 *     stubs.c     link-only       micro-c-builds-tcc (the ladder)
 *
 * Anything libtcc.c references has to exist in BOTH. zzl was verified against
 * the first and not the second, which is how the ladder broke. */
char** environ;

int strtol(char* s, char** e, int b) { return 0; }
int strtoll(char* s, char** e, int b) { return 0; }
int strtoul(char* s, char** e, int b) { return 0; }
int strtoull(char* s, char** e, int b) { return 0; }
int strtod(char* s, char** e) { return 0; }
int strtof(char* s, char** e) { return 0; }
int strtold(char* s, char** e) { return 0; }
int ldexpl(int x, int e) { return 0; }

int setjmp(void* env) { return 0; }
void longjmp(void* env, int v) { return; }

int sigaction(int n, void* a, void* o) { return 0; }
int sigaddset(void* s, int n) { return 0; }
int sigemptyset(void* s) { return 0; }
int sigprocmask(int h, void* s, void* o) { return 0; }

int sem_init(void* s, int p, int v) { return 0; }
int sem_wait(void* s) { return 0; }
int sem_post(void* s) { return 0; }

void qsort(void* b, int n, int s, void* c) { return; }
char* strerror(int e) { return "error"; }
int mprotect(void* a, int l, int p) { return 0; }
void __clear_cache(void* b, void* e) { return; }

int time(int* t) { return 0; }
void* localtime(int* t) { return 0; }
void* freopen(char* f, char* m, void* s) { return 0; }
char* realpath(char* p, char* r) { return 0; }
