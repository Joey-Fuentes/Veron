// hello.aarch64.s — smoke-test spike: write() a string, exit(0).
// Linux arm64 syscall ABI: nr in x8, args in x0, x1, x2; `svc #0`.
// Spikes may use full assembler conveniences; only the real stage-0 seed
// obeys the no-pseudo-ops / bijective-encoding rule.

    .section .text
    .global _start
_start:
    mov     x0, #1              // fd = stdout
    adr     x1, msg             // buf
    mov     x2, #len            // count
    mov     x8, #64             // sys_write
    svc     #0

    mov     x0, #0              // status = 0
    mov     x8, #93             // sys_exit
    svc     #0

    .section .rodata
msg:
    .ascii  "hello from aarch64\n"
    len = . - msg
