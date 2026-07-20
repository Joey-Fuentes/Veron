// ============================================================================
// Veron — EXPERIMENTAL stage 0  (ARM64 / AArch64)
// ============================================================================
//
//   *** THIS IS A FEASIBILITY TRACER, NOT VERON PROPER. ***
//   Architectural invariants are SUSPENDED here on purpose:
//     - no bijective-encoding rule       (we let the assembler do its thing)
//     - no reproducibility / hermeticity  (we just want it to run)
//     - no round-trip audit               (that's the real seed-as, later)
//   Goal: prove we can WRITE ARM64 assembly on our qemu-user CI setup, run it,
//   and customize it. This file is meant to be edited and grown.
//
// It writes "hello from Veron stage0\n" to stdout and exits 0, using raw Linux
// syscalls (no libc) so it links fully static and runs under qemu-aarch64 with
// nothing else present.
//
// Run it (locally or in CI) via the spike runner:
//     tools/spike.sh aarch64 spikes/stage0-arm64/stage0.aarch64.s
//     tools/spike.sh aarch64 spikes/stage0-arm64/stage0.aarch64.s --dump
//
// ---------------------------------------------------------------------------
// ARM64 facts you need to customize this:
//   * Every instruction is exactly 4 bytes, fixed width. (This regularity is
//     why ARM64 is the reference arch for the real seed.)
//   * Linux AArch64 syscall convention:
//         syscall number -> x8
//         args           -> x0, x1, x2, x3, x4, x5
//         invoke         -> svc #0
//         return value   -> x0
//   * Syscall numbers used here (generic arm64 table):
//         write = 64        exit = 93
// ---------------------------------------------------------------------------

    .text
    .global _start              // ld looks for _start as the entry point

_start:
    // --- write(fd=1, buf=msg, count=len) -----------------------------------
    mov     x0, #1              // x0 = fd = 1 (stdout)
    adr     x1, msg             // x1 = address of msg (PC-relative; ±1MB range,
                                //      fine because msg is a few bytes away)
    mov     x2, #msg_len        // x2 = byte count to write
    mov     x8, #64             // x8 = syscall number: write
    svc     #0                  // trap into the kernel -> does the write

    // --- exit(status=0) ----------------------------------------------------
    mov     x0, #0              // x0 = exit status 0
    mov     x8, #93             // x8 = syscall number: exit
    svc     #0                  // trap into the kernel -> process exits here

    // (no ret: _start must not return; exit() never comes back)

// ---------------------------------------------------------------------------
// Data. Kept in .text so a single ADR reaches it and the binary stays minimal.
// .ascii does NOT append a NUL; we compute the length at assemble time instead
// of relying on a terminator, because write() takes an explicit count.
// ---------------------------------------------------------------------------
msg:
    .ascii  "hello from Veron stage0\n"
    msg_len = . - msg           // '.' is the current address; minus msg's
                                //   address = the string's length in bytes.
