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
| `b <@pos>` / `b.cond <@pos>` | branch to absolute output byte-`pos` (offset computed; no label) |
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
| `udiv x<d> x<n> x<m>` | unsigned divide (`Xn / Xm`, `/0` → 0) |
| `adr x<d> <L>` \| `@<pos>` | address of label / numeric position into register |
| `ldrb w<t> x<n> x<m>` | load byte `[Xn + Xm]` |
| `strb w<t> x<n> x<m>` | store byte `[Xn + Xm]` |
| `ldr w<t> x<n>` | load word (32-bit) `[Xn]` |
| `str w<t> x<n>` | store word (32-bit) `[Xn]` |
| `ldr x<t> x<n>` | load doubleword (64-bit) `[Xn]` |
| `str x<t> x<n>` | store doubleword (64-bit) `[Xn]` |
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
- Load/store are register-indirect at offset 0 only (`[Xn]`); word `ldr w`/`str w`
  and doubleword `ldr x`/`str x` both exist — the first operand's width (`w`/`x`)
  selects the size. The 64-bit forms are what let a stage above build a real
  software call stack (saving/restoring a 64-bit `x30` or frame pointer in memory,
  which a 32-bit store would truncate).
- Branches accept either a **label** (`b X`) or a **numeric absolute output
  position** (`b @<pos>` / `bl @<pos>` / `b.eq @<pos>`), where `<pos>` is a byte offset into the
  assembled output and the assembler encodes `(pos - here)` itself. This lets a
  stage above emit control flow by **backpatched offset** instead of a label —
  removing the per-branch label so an emitted program can exceed the 128-label
  symtab cap. `bl @<pos>` works identically (base `0x94000000`), which is what lets
  the stage-1 resolver rewrite helper *calls* numerically too. Only `@` followed by a digit is numeric; a bare `@` remains the
  ordinary pool label `@`, so stage 1's label output is unaffected.
- **`adr`** likewise accepts a label (`adr xR X`) or a **numeric position**
  (`adr xR @<pos>`), encoding the PC-relative offset `(pos - here)`. Same `@`+digit
  disambiguation. This is what lets stage 1 resolve `adr`-to-data references
  numerically as well, so stage 1 can become a full **two-pass numeric resolver**
  (labels → positions → `@<pos>` for both branches and `adr`) and retire the
  single-char pool entirely — after which stage-2/3 label count is bounded only by
  memory, not the 128-entry symtab.
- Well-formed input assumed — minimal error checking (it's a spike).
- Input buffer is 256 KB (`.bss`, raised in m30 from 16 KB) so it can assemble the
  large label-free outputs stage 2 now produces; output is streamed (unbounded).

## See it run

Push under `spikes/stage0-as/**` → the **stage0-as-demo** workflow assembles a
counting loop and a memory store/load program, byte-compares them against the
real assembler, and runs them under QEMU (expecting exit 5 and 7). See
`spikes/PROGRESS.md` for the full picture.
