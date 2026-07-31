/* micro-c: minimal setjmp.h. tcc uses jmp_buf/setjmp/longjmp for its error
 * recovery path (tcc.h:858, plus 6 longjmp sites).
 *
 * IT IS AN ARRAY TYPEDEF NOW, which is how a real libc writes it: the name
 * then decays to a pointer when passed, so setjmp takes it by REFERENCE
 * rather than by value.
 *
 * The previous note here said micro-c could not parse a typedef of an array
 * type, that this was therefore a plain struct, and that "the array typedef is
 * a real micro-c gap rather than a self-inflicted one" once something needed
 * it. Something did -- tcc's own
 *
 *     jmp_buf main_jb;                       tcc.h
 *     tcc_setjmp(s1, main_jb, ...)           tccrun.c:250
 *
 * fails with "cannot convert 'struct __jmp_buf' to 'void *'" against a struct,
 * because a struct does not decay. So the gap was closed in micro-c instead of
 * worked around again here; see the array-typedef note in cc_core.c's
 * global_typedef.
 *
 * A POINTER TYPEDEF WOULD ALSO HAVE COMPILED, and would have been worse: it
 * makes `jmp_buf main_jb;` reserve eight bytes instead of 256, so setjmp would
 * write through an uninitialised pointer. It compiles, it links, and it is
 * wrong only at run time -- the single failure class this project exists to
 * avoid. The array form reserves the storage. */
#ifndef _MICROC_SETJMP_H
#define _MICROC_SETJMP_H

struct __jmp_buf { long __opaque[32]; };
typedef long jmp_buf[32];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);

#endif
