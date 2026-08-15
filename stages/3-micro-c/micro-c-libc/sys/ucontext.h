/* micro-c: minimal sys/ucontext.h, aarch64.
 *
 * tcc's backtrace reads the interrupted program counter and frame pointer out
 * of a signal context (tccrun.c). On arm64 those are mcontext.pc and
 * mcontext.regs[29]; the other spellings in that file -- eip, arm_pc,
 * mc_rip, __gregs -- are the x86, arm32, BSD and RISC-V branches, compiled
 * out here.
 *
 * THE LAYOUT MUST MATCH THE KERNEL'S, not just parse. This mirrors Linux
 * arm64's struct sigcontext: fault address, x0..x30, sp, pc, pstate. If a
 * backtrace ever prints nonsense addresses, this file is the first place to
 * look -- and micro-c's 8-byte `int` means anything here declared `int` would
 * already be wrong, which is why every field is explicitly sized. */
#ifndef _MICROC_SYS_UCONTEXT_H
#define _MICROC_SYS_UCONTEXT_H

#include <stdint.h>

struct mcontext_t {
    uint64_t fault_address;
    uint64_t regs[31];      /* x0 .. x30; regs[29] is the frame pointer */
    uint64_t sp;
    uint64_t pc;
    uint64_t pstate;
};

typedef struct ucontext_t {
    uint64_t uc_flags;
    struct ucontext_t* uc_link;
    uint64_t uc_stack_ss_sp;
    uint64_t uc_stack_ss_flags;
    uint64_t uc_stack_ss_size;
    uint64_t uc_sigmask[16];
    struct mcontext_t uc_mcontext;
} ucontext_t;

#endif
