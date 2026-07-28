/* micro-c: minimal setjmp.h. tcc uses jmp_buf/setjmp/longjmp for its error
 * recovery path (tcc.h:858, plus 6 longjmp sites).
 *
 * NOT `typedef struct {...} jmp_buf[1];`, which is how real libcs write it so
 * the name decays to a pointer when passed. micro-c cannot parse a typedef of
 * an ARRAY type, and adding that feature to suit a header of our own would be
 * the tail wagging the dog -- so this is a plain struct. The consequence is
 * that setjmp() takes it by value here rather than by reference, which is
 * wrong for a working setjmp and irrelevant for parsing tcc's source. When
 * there is a runtime behind this, it needs revisiting; the array typedef is
 * then a real micro-c gap rather than a self-inflicted one. */
#ifndef _MICROC_SETJMP_H
#define _MICROC_SETJMP_H

struct __jmp_buf { long __opaque[32]; };
typedef struct __jmp_buf jmp_buf;

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);

#endif
