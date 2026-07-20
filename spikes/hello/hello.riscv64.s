# hello.riscv64.s — smoke-test spike: write() a string, exit(0).
# Linux riscv64 syscall ABI: nr in a7, args in a0, a1, a2; `ecall`.
#
# NOTE: data is placed FIRST here (before _start), unlike the x86_64/aarch64
# spikes. Reason: the RISC-V `li` pseudo-instruction rejects a *forward*-
# referenced symbol as its immediate (gas: "illegal operands `li a2,len'"),
# so `len` must be defined BEFORE it is used. `.balign 4` then re-aligns
# _start, because RISC-V instructions must sit on a 4-byte boundary and the
# string above is not a multiple of 4 bytes long.
#
# Spikes may use pseudo-ops (li / la); only the real stage-0 seed obeys the
# no-pseudo-ops / bijective-encoding rule, and the seed is RV64I base (the OS
# target is RV64GC).

    .section .text

msg:
    .ascii  "hello from riscv64\n"
    .set    len, . - msg        # absolute constant (string length) — known HERE,
                                #   so the backward `li a2, len` below is legal

    .balign 4                   # instructions must be 4-byte aligned
    .global _start
_start:
    li      a0, 1               # fd = stdout
    la      a1, msg             # buf (backward reference — fine)
    li      a2, len             # count (len already defined above)
    li      a7, 64              # sys_write
    ecall

    li      a0, 0               # status = 0
    li      a7, 93              # sys_exit
    ecall
