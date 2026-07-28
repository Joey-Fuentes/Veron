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

/* Only si_signo and si_code are read by tcc's handler; the rest is padding to
 * the kernel's 128-byte siginfo. */
typedef struct siginfo_t {
    int si_signo;
    int si_errno;
    int si_code;
    int si_pad0;
    unsigned long si_pad[14];
} siginfo_t;

typedef struct sigset_t { unsigned long __bits[16]; } sigset_t;

typedef struct stack_t {
    void* ss_sp;
    int ss_flags;
    unsigned long ss_size;
} stack_t;

/* sa_handler and sa_sigaction are a UNION in the real header -- the same slot,
 * read either as a plain handler or as the three-argument form selected by
 * SA_SIGINFO. tcc sets sa_sigaction. Declared as a union so both spellings
 * resolve to the same offset, which is what the kernel expects. */
struct sigaction {
    union {
        void* sa_handler;
        void* sa_sigaction;
    };
    unsigned long sa_mask[16];
    int sa_flags;
    void* sa_restorer;
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
