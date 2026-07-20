# spikes/stage0-as — SPIKE stage-0 assembler (feasibility tracer)

**Invariants SUSPENDED.** Hand-written in ARM64 assembly, built by GNU `as`. A
two-pass mnemonic assembler: reads line-oriented assembly-with-labels on stdin,
emits raw ARM64 machine-code bytes on stdout. This is the last tool written in
raw assembly — higher stages are written in *this* language.

```
program.s | stage0-as > code.bin          # mnemonics -> raw code bytes
program.s | stage0-as | elf out && ./out  # ...through elf -> runnable
```

## Language reference

One item per line. Leading whitespace is fine. Register operands are one letter
(`w`/`x`) followed by a number. Labels are a **single character**.

| Syntax | Meaning |
|--------|---------|
| `mov x<d> <imm>` | load 16-bit immediate (MOVZ) |
| `mov x<d> x<n>` | register move |
| `add x<d> x<n> <imm>` | add immediate |
| `sub x<d> x<n> <imm>` | subtract immediate |
| `cmp x<n> x<m>` | compare registers |
| `cmp x<n> <imm>` | compare with immediate |
| `b <L>` | unconditional branch to label |
| `b.eq / b.ne / b.lt / b.ge <L>` | conditional branch |
| `bl <L>` | branch-and-link to label (sets x30) |
| `ret` | return via x30 |
| `br x<n>` | branch to register |
| `blr x<n>` | branch-to-register-and-link |
| `orr x<d> x<n> x<m>` | bitwise OR (combine fields) |
| `and x<d> x<n> x<m>` | bitwise AND (mask) |
| `lsl/lsr/asr x<d> x<n> x<m>` | shift by register amount |
| `movk x<d> <imm> <shift>` | insert 16-bit imm at shift 0/16/32/48 |
| `add/sub x<d> x<n> x<m>` | register add/sub (3rd operand `x..`) |
| `mul x<d> x<n> x<m>` | multiply (= madd with xzr) |
| `adr x<d> <L>` | address of label into register |
| `ldrb w<t> x<n> x<m>` | load byte `[Xn + Xm]` |
| `strb w<t> x<n> x<m>` | store byte `[Xn + Xm]` |
| `ldr w<t> x<n>` | load word `[Xn]` |
| `str w<t> x<n>` | store word `[Xn]` |
| `svc` | supervisor call (`svc #0`) |
| `:<L>` | define label `<L>` at current position |
| `.byte <imm>` | emit one byte |
| `.ascii "text"` | emit string bytes (`\n` supported) |
| `# ...` | comment to end of line |

Linux arm64 syscall ABI (for `svc`): number in `x8`, args in `x0..x5`.
Common numbers: `read=63 write=64 openat=56 fchmod=52 close=57 exit=93`.

**Two passes:** pass 1 records each `:label` position; pass 2 emits bytes with
branch and `adr` offsets resolved. Offsets are differences of output positions,
so they need no load address.

## Known limits (motivate later stages)

- Labels are single-character (multi-char labels are stage 1's job).
- Subroutines (`bl`/`ret`/`br`/`blr`) plus shifts (`lsl`/`lsr`/`asr`), logical (`orr`/`and`), and wide-immediate (`movk`) were added as the base stage 1 (macro-as) is written on. Shifts/`movk` take register/immediate forms sufficient to emit ARM64 encodings from within stage-1 code.
- 16-bit immediates only (`mov`), 12-bit for `add`/`sub`/`cmp`.
- Well-formed input assumed — minimal error checking (it's a spike).

## See it run

Push under `spikes/stage0-as/**` → the **stage0-as-demo** workflow assembles a
counting loop and a memory store/load program, byte-compares them against the
real assembler, and runs them under QEMU (expecting exit 5 and 7). See
`spikes/PROGRESS.md` for the full picture.
