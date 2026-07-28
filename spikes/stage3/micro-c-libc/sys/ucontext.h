/* micro-c: minimal sys/ucontext.h. Referenced by tcc's backtrace path, which
 * we do not exercise; an opaque type is enough for the declarations to parse. */
#ifndef _MICROC_SYS_UCONTEXT_H
#define _MICROC_SYS_UCONTEXT_H
typedef struct { long __opaque[32]; } ucontext_t;
#endif
