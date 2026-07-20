# hello.x86_64.s — smoke-test spike: write() a string, exit(0).
# Linux x86_64 syscall ABI: nr in rax, args in rdi, rsi, rdx; `syscall`.
# Spikes may use full assembler conveniences; only the real stage-0 seed
# obeys the no-pseudo-ops / bijective-encoding rule.

    .section .text
    .global _start
_start:
    mov     $1, %rax            # sys_write
    mov     $1, %rdi            # fd = stdout
    lea     msg(%rip), %rsi     # buf
    mov     $len, %rdx          # count
    syscall

    mov     $60, %rax           # sys_exit
    xor     %edi, %edi          # status = 0
    syscall

    .section .rodata
msg:
    .ascii  "hello from x86_64\n"
    len = . - msg
