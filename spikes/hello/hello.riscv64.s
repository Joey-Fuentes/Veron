# hello.riscv64.s — smoke-test spike: write() a string, exit(0).
# Linux riscv64 syscall ABI: nr in a7, args in a0, a1, a2; `ecall`.
# Spikes may use full assembler conveniences (li/la are pseudo-ops); only the
# real stage-0 seed obeys the no-pseudo-ops / bijective-encoding rule, and the
# seed is RV64I base — the OS target is RV64GC.

    .section .text
    .global _start
_start:
    li      a0, 1               # fd = stdout
    la      a1, msg             # buf
    li      a2, len             # count
    li      a7, 64              # sys_write
    ecall

    li      a0, 0               # status = 0
    li      a7, 93              # sys_exit
    ecall

    .section .rodata
msg:
    .ascii  "hello from riscv64\n"
    len = . - msg
