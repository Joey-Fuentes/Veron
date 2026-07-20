// ============================================================================
// Veron — EXPERIMENTAL stage 0, HAND-ENCODED  (ARM64 / AArch64)
// ============================================================================
//
//   *** FEASIBILITY TRACER — invariants SUSPENDED (spike zone). ***
//
// This is the same program as stage0.aarch64.s, but the instructions are no
// longer written as mnemonics for the assembler to encode. Instead WE compute
// the exact 32-bit machine-code word for each instruction and emit it raw with
// `.inst`. The assembler no longer chooses the bytes — we do. Disassembly
// (`--dump`) then proves each word decodes back to the instruction we intended.
//
// That is the seed's core idea in miniature:
//     we author the bytes  ->  disassemble  ->  confirm they mean what we meant
// The one exception below (`adr`) is left as a mnemonic on purpose — see NOTE.
//
// Run:
//     tools/spike.sh aarch64 spikes/stage0-arm64/stage0-handencoded.aarch64.s --dump
// It also runs in CI: the `stage0-roundtrip` workflow shows the disassembly.
//
// ---------------------------------------------------------------------------
// HOW TO ENCODE THESE INSTRUCTIONS (so you can compute more yourself)
//
// MOVZ (64-bit) — "move a 16-bit immediate into a register, zeroing the rest":
//
//    31 30 29 28 27 26 25 24 23 22 21 20               5 4     0
//   [ 1 | 1  0 | 1  0  0  1  0  1 | 0  0 |   imm16       |  Rd   ]
//    sf   opc      (fixed 100101)   hw=0     (value)        (reg)
//
//   base = 0xD2800000
//   word = base | (imm16 << 5) | Rd
//
//   mov x0,#1  -> 0xD2800000 | (1  << 5) | 0 = 0xD2800020
//   mov x2,#24 -> 0xD2800000 | (24 << 5) | 2 = 0xD2800302   (24 = current strlen)
//   mov x8,#64 -> 0xD2800000 | (64 << 5) | 8 = 0xD2800808   (64 = sys_write)
//   mov x0,#0  -> 0xD2800000 | (0  << 5) | 0 = 0xD2800000
//   mov x8,#93 -> 0xD2800000 | (93 << 5) | 8 = 0xD2800BA8   (93 = sys_exit)
//
// SVC #imm16 — "supervisor call" (the syscall trap):
//   word = 0xD4000001 | (imm16 << 5)   ;   svc #0 -> 0xD4000001
// ---------------------------------------------------------------------------

    .text
    .global _start
_start:
    .inst 0xd2800020        // mov x0, #1     -> fd = stdout
    adr   x1, msg           // NOTE: position-DEPENDENT. Its encoding depends on
                            //   the distance to msg, so hand-coding it means
                            //   hard-coding an offset that breaks if you add or
                            //   remove any instruction above. That bookkeeping
                            //   is exactly what LABELS solve — a later rung
                            //   (the macro-as / hex1-hex2 analog). For now we
                            //   let the assembler compute this one line.
    .inst 0xd2800302        // mov x2, #24    -> byte count (matches the string)
    .inst 0xd2800808        // mov x8, #64    -> sys_write
    .inst 0xd4000001        // svc #0         -> trap: do the write
    .inst 0xd2800000        // mov x0, #0     -> status 0
    .inst 0xd2800ba8        // mov x8, #93    -> sys_exit
    .inst 0xd4000001        // svc #0         -> trap: exit

msg:
    .ascii "hello from Veron stage0\n"      // 24 bytes (must match mov x2,#24)

// ---------------------------------------------------------------------------
// EXPECTED round-trip (objdump -d via `--dump`). The middle column is the raw
// word WE authored; the right column is what it decodes to. They must match
// our intent, and the program must still print and exit 0 — proving the bytes
// are both correct-meaning AND correct-executing:
//
//   <_start>:
//     d2800020   mov  x0, #0x1
//     100000e1   adr  x1, <msg>        (assembler-generated; offset 28 here)
//     d2800302   mov  x2, #0x18        (0x18 = 24)
//     d2800808   mov  x8, #0x40        (0x40 = 64)
//     d4000001   svc  #0x0
//     d2800000   mov  x0, #0x0
//     d2800ba8   mov  x8, #0x5d        (0x5d = 93)
//     d4000001   svc  #0x0
// ---------------------------------------------------------------------------
