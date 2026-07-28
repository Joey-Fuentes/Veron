/* micro-c: minimal signal.h, Linux.
 *
 * tcc's runtime installs handlers so a crash in JIT-compiled code produces a
 * backtrace rather than a bare fault (tccrun.c). It needs six names.
 *
 * The numbers are Linux's and are ABI, not choices -- a wrong value here would
 * install a handler for the wrong signal, which is the kind of thing that
 * looks like it works until something crashes. */
#ifndef _MICROC_SIGNAL_H
#define _MICROC_SIGNAL_H

#include <stdint.h>

#define SIGILL   4
#define SIGABRT  6
#define SIGFPE   8
#define SIGSEGV 11
#define SIGBUS   7

#define SIGSTKSZ 8192

/* si_code values, so tcc's handler can say WHICH fault occurred. Linux's
 * numbering, and ABI like the signal numbers above. */
#define FPE_INTDIV 1
#define FPE_INTOVF 2
#define FPE_FLTDIV 3
#define FPE_FLTOVF 4
#define FPE_FLTUND 5
#define FPE_FLTRES 6
#define FPE_FLTINV 7
#define FPE_FLTSUB 8

#define ILL_ILLOPC 1
#define ILL_ILLOPN 2
#define ILL_ILLADR 3
#define ILL_ILLTRP 4
#define ILL_PRVOPC 5
#define ILL_PRVREG 6
#define ILL_COPROC 7
#define ILL_BADSTK 8

#define BUS_ADRALN 1
#define BUS_ADRERR 2
#define BUS_OBJERR 3

#define SEGV_MAPERR 1
#define SEGV_ACCERR 2

/* LAYOUTS HERE MUST MATCH THE KERNEL, NOT glibc, AND NOT WHATEVER micro-c
 * WOULD PRODUCE FROM `int`.
 *
 * micro-c makes `int` EIGHT bytes. Written with int, si_code landed at offset
 * 16 where the kernel puts it at 8, so a handler reading si_code would have
 * read si_pad0. Every field is therefore explicitly sized.
 *
 * Only si_signo and si_code are read by tcc's handler; the rest is padding to
 * the kernel's 128-byte siginfo. */
typedef struct siginfo_t {
    int32_t si_signo;
    int32_t si_errno;
    int32_t si_code;
    int32_t si_pad0;
    uint64_t si_pad[14];
} siginfo_t;

typedef struct sigset_t { uint64_t __bits[16]; } sigset_t;

typedef struct stack_t {
    void* ss_sp;
    int32_t ss_flags;
    int32_t ss_pad;
    uint64_t ss_size;
} stack_t;

/* THE KERNEL'S ORDER, WHICH IS NOT glibc'S. On Linux/aarch64 the raw
 * rt_sigaction structure is
 *
 *     handler, flags, restorer, mask
 *
 * The version previously here was handler, mask, flags, restorer -- glibc's
 * shape, near enough to look right and completely wrong as an argument to the
 * syscall. It has never mattered because sigaction is stubbed in runtime.c and
 * never reaches the kernel; it would have mattered the moment it did, and the
 * failure would have been a handler installed on the wrong signal with the
 * wrong flags.
 *
 * sa_handler and sa_sigaction are the same slot, read either as a plain
 * handler or as the three-argument form selected by SA_SIGINFO. */
struct sigaction {
    union {
        void* sa_handler;
        void* sa_sigaction;
    };
    uint64_t sa_flags;
    void* sa_restorer;
    sigset_t sa_mask;
};

#define SIG_BLOCK   0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2

#define SA_SIGINFO 4
#define SA_ONSTACK 0x08000000

int sigaction(int signum, struct sigaction* act, struct sigaction* oldact);
int sigemptyset(sigset_t* set);
int sigaddset(sigset_t* set, int signum);
int sigprocmask(int how, sigset_t* set, sigset_t* oldset);
int sigaltstack(stack_t* ss, stack_t* old);
void* signal(int signum, void* handler);

#endif
