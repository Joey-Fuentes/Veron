# Bootstrap Spike — Progress

*Status record for the feasibility-spike track. Last updated at: stage 0
assembler-complete.*

> **Scope: invariants SUSPENDED.** Everything described here lives under
> `spikes/` and is a *feasibility tracer*, not Veron proper. It deliberately
> drops the bijective-encoding rule, reproducibility, hermeticity, the
> round-trip audit, and the no-committed-binaries rigor. Its only job is to
> answer, cheaply: *can we build the ladder at all on this setup?* The real
> seed/stages (invariants ON) live under `seed/` and `stages/` and are not yet
> implemented. Nothing here should be copied into those without re-applying the
> invariants.

---

## 1. What this track is proving

That, on our actual setup — hand-written assembly, built by GNU `as`, run under
QEMU user-mode on GitHub Actions — we can construct a working toolchain from the
ground floor: source text → a running executable, using only tools we wrote.
Reference architecture is **ARM64** (`aarch64`); it round-trips most cleanly.

**Where we are now:** stage 0 is *assembler-complete*. The pipeline

```
program.s ──[stage0-as]──► code bytes ──[elf OUTPATH]──► runnable executable
```

works end to end, every instruction byte-verified against the real assembler,
and the produced binaries run under QEMU. The entire hand-written-assembly phase
is done. From here, higher stages are written **in stage-0's own language**, not
hand-encoded.

---

## 2. The toolkit

Two live tools, both hand-written in ARM64 assembly, both built by GNU `as`:

### `stage0-as`  (`spikes/stage0-as/stage0-as.aarch64.s`)
A two-pass mnemonic assembler. Reads line-oriented assembly-with-labels on
stdin, emits raw ARM64 machine-code bytes on stdout. Pass 1 records label
positions; pass 2 emits with branch/`adr` offsets resolved. See the language
reference in `spikes/stage0-as/README.md`.

### `elf`  (`spikes/elf/elf.aarch64.s`)
Reads raw code bytes on stdin, wraps them in a minimal static ELF, writes a
runnable file to the path given as `argv[1]`, and sets it executable itself
(`openat` mode 0755 + `fchmod`). The 120-byte header is a fixed template (proven
by `elf-proto`); only `p_filesz`/`p_memsz` are patched from the code length.
Currently emits an **R+W+X** segment (spike convenience, so programs can use
memory).

Compose them: `program.s | stage0-as | elf out && ./out`.

---

## 3. How everything is verified

Two independent checks, used throughout:

- **Byte-compare against the real assembler.** For any instruction, we assemble
  the equivalent with `aarch64-linux-gnu-as`, extract `.text` with `objcopy`,
  and diff it against `stage0-as`'s output. Byte-identical output means the
  encoding is provably correct (the reference toolchain is ground truth). Any
  mismatch pinpoints the exact instruction.
- **Run under QEMU.** Pipe through `elf`, run the result with `qemu-aarch64`,
  and check the exit code / output. This catches semantic (not just encoding)
  bugs.

Every tool's demo uses one or both. This is why the tools could be written in
one shot without a local ARM64 runtime: the CI demo is the test.

---

## 4. Spike inventory

| Path | What it is | Status |
|------|-----------|--------|
| `spikes/hello/hello.{x86_64,aarch64,riscv64}.s` | write() a string, exit — smoke tests for the qemu-user CI loop | **live** — all three pass |
| `spikes/stage0-arm64/stage0.aarch64.s` | first experimental stage 0: ARM64 hello in mnemonics | reference / superseded by `stage0-as` |
| `spikes/stage0-arm64/stage0-handencoded.aarch64.s` | same program with hand-computed `.inst` words; the round-trip lesson | reference (teaches the seed's core idea) |
| `spikes/seedas/seed-as.aarch64.s` | hex0-style loader (hex text → bytes) | proof of an alternative stage-0 shape; not the chosen path |
| `spikes/stage0-as/stage0-as.aarch64.s` | **the** mnemonic assembler (labels, two-pass, memory, data) | **live** — assembler-complete |
| `spikes/elf/elf.aarch64.s` | **the** ELF wrapper tool | **live** |
| `spikes/elf-proto/elf_proto.py` | throwaway: pinned the ELF header byte layout | superseded (its bytes are baked into `elf`) |

Workflows: `spike.yml` (3-arch smoke matrix), `stage0-as-demo.yml` (the main
stage-0 test: loop + memory + byte-compares), `elf-demo.yml`,
`stage0-roundtrip.yml`, `seedas-demo.yml`, `elf-proto.yml`.

---

## 5. Milestones reached (in order)

1. qemu-user CI loop proven on all three arches (hello world).
2. Wrote and ran hand ARM64 assembly (experimental stage 0).
3. Hand-encoded instructions as raw `.inst` words; confirmed the **round-trip**
   (bytes → intended instructions) via disassembly.
4. `seed-as`: a hex0-style loader — proved an asm program can consume input and
   emit a binary.
5. `stage0-as` v1: a real mnemonic assembler (`mov`/`svc` → machine code),
   byte-identical to real `as`.
6. `elf` tool: wraps code bytes into a runnable, self-`chmod`-ing executable.
   Full pipeline text → executable working.
7. `stage0-as` + labels/two-pass + `add`/`cmp`/branches: a **loop** assembles
   byte-identically and runs.
8. `stage0-as` + memory/addressing (`adr`/`ldrb`/`strb`/`ldr`/`str`).
9. `stage0-as` + `sub`/`mov`-reg/`cmp`-imm/`.byte`/`.ascii`; `elf` segment made
   writable → **runtime memory works**. **Stage 0 assembler-complete.**
10. `stage0-as` + **subroutines** (`bl`/`ret`/`br`/`blr`), **shifts**
   (`lsl`/`lsr`/`asr`), **logical** (`orr`/`and`), **wide-immediate** (`movk`) —
   the base a stage-1 assembler is written on. Each byte-identical to real `as`.
11. **Stage 1 (`macro-as`) capability #1: multi-character labels** —
   `spikes/stage1-as/stage1-as.s0`, the first tool written **in stage0-as's own
   language** (not hand-encoded). Resolves multi-char labels to single-char and
   pipes into `stage0-as`; output byte-identical to `as`, runs under QEMU.
12. **Stage 2 (`mini-c`) SEED** — `spikes/stage2-mini-c/stage2-mini-c.s1`,
   written **in stage-1's language** (multi-char labels). Compiles
   `int main(){return N;}` to aarch64 machine code that exits N. The first
   real compiler our own seed produces. Full ladder:
   `stage2.s1 | stage1 | stage0-as | elf`, then `prog.c | stage2 | stage0-as | elf`.
13. **Dev bench** — `spikes/bench/` (NOT part of the bootstrap): a Python model
   of `stage0-as` + a small ARM64 interpreter to develop/test `.s0`/`.s1` code
   locally before CI. `validate.py` pins it to CI ground truth; CI stays
   authoritative.

14. `stage0-as` + register `add`/`sub` and `mul` (madd-with-xzr) — the arithmetic
   base stage 2 needs to emit expression codegen. Byte-identical to real `as`;
   immediate `add`/`sub` forms unchanged (disambiguated by an `x` 3rd operand).
15. **Stage 2 expressions** — `return <expr>` grew from `N` to `+ -` (immediate
   chains), then `+ - *` with **precedence** (recursive descent, register
   codegen), then **parentheses** to any depth (shunting-yard, iterative, with a
   runtime **value stack** in `brk` memory). The general expression foundation.
16. **Stage 2 variables + assignment** — `int main(){ int a=<expr>; ... return
   <expr>; }`. Single-char names → labeled byte slots (`:a`..`:z`) in the emitted
   program via `adr`+`ldrb`/`strb`; a factor may be a number, variable, or
   `( expr )`. A statement loop drives the shunting-yard expression compiler.
17. **Stage 1 brk-buffer upgrade** — stage 1's inbuf/outbuf/nametable moved from
   image `.ascii` fillers to a `brk` heap (~20 KB each) with a `read` loop, using
   the new register `add`. Source shrank 15 KB → ~3 KB and it now handles large
   inputs without truncation — removing the growth ceiling for stage 2/3.
18. **Stage 2 word-sized variables** — variable slots went from 1-byte
   (`ldrb`/`strb`, `:a .byte 0`) to **4-byte word slots** (`ldr`/`str`, four
   `.byte 0` per slot), lifting the 0-255 storage limit so variable storage
   matches the 32-bit value stack. Change is confined to the emitted-code
   strings — `ldr w0 x1`/`str w0 x1` are the same encoding family as the value
   stack's `ldr w0 x9`/`str w0 x9`, so no stage0-as change was needed. Slots are
   word-aligned by construction (all-4-byte instructions precede the slot table).
   `stage2_ref.py` and a structural bench guard in `validate.py` are kept in
   sync. (With only `+ - *` and a mod-256 exit, byte vs word storage is
   exit-code-indistinguishable; the width becomes observable once `/` or
   comparisons arrive — hence the guard checks the emitted *forms*, not just
   exit codes.)

19. **Stage 2 control flow — `if`, `while`, reassignment** — the compiler now
   handles `if (<expr>) { … }`, `while (<expr>) { … }` (condition tested for
   nonzero), and reassignment `c=<expr>;`, all arbitrarily nested. Reassignment
   rode along because a `while` that can't mutate its condition is hollow. Codegen
   is **iterative with an explicit block stack** (a nested `bl` would clobber the
   return register, so recursion isn't free) — on `{` the compiler pushes the
   pending block's labels, on the matching `}` it pops and emits the close. Jump
   targets are **uppercase** labels `A`,`B`,… (variable slots are lowercase, so no
   collision); the condition reuses the existing shunting-yard expression engine
   plus `cmp x0 0` / `b.eq`. No new stage0-as instruction was needed (the required
   branches already existed). Statement dispatch was reworked to key on the second
   character (keyword ⇒ letter, reassignment ⇒ space/`=`), which removed the
   keyword/variable-name collision entirely (vars may be named `i`/`w`/`r`).
   Designed and proven on the bench first: `stage2_ref.py` gained an independent
   C-subset interpreter as a test oracle, and the `.s1` was checked against it
   through the real assembled ladder (nested loops, factorial, sum 1..10,
   nested `if`) before shipping; `validate.py` grew a matching structural +
   exit-code guard.

Notable bug found and fixed along the way: the hand-built ELF failed to run
because it lacked the execute bit — a *file-mode* issue, not a byte issue
(`readelf` was happy, QEMU was not). The `elf` tool now sets it itself.

**Milestone 20 — stage 2 gains relational `<` and `>`.** Conditions can now be
*relations*, not just nonzero-tests: `while(i<n)`, `if(a>b)`, count-up loops.
The operators sit below `+ - *` in precedence and yield `0`/`1`, composing with
arithmetic. Codegen is **branchless and label-free**: `a<b` is the sign bit of
the 64-bit difference `(a-b) >> 63` (`sub`/`mov`/`lsr` — no new stage0-as
instruction, no emitted branch), so it costs none of the 26 emitted-label slots.
Comparisons are **unsigned-32** (loads zero-extend). Verified through the real
assembled ladder (count-up sum, factorial via `i<5`, nested `<` loops, `>`
guards, precedence) and pinned in `validate.py`. Only `<`/`>` shipped this
increment: equality (`== != <= >=`) needs ~8 more single-char labels than the
stage-1 pool (62, `A-Za-z0-9`) has room for — the compiler is at 61 — so the
next increment expands stage-1's label pool first.

---

## 6. What's next

The plan is a **capability-jump ladder**: keep each rung minimal, and write each
stage in the language of the stage below.

- **Stage 1** — DONE (multi-character labels) and upgraded to `brk` buffers so it
  can process large stage-2/3 sources. See `spikes/stage1-as/`.
- **Stage 2** — in progress. Compiles `int main(){ … }` with **word-sized**
  variables, declaration + **reassignment**, `+ - *` expressions plus the
  **relational** operators `<` and `>` (precedence, parentheses), and **control
  flow** (`if`/`while`, nested). Conditions can be relations or nonzero-tests.
  Next increments toward an M2-Planet-grade subset: **expand stage-1's 62-char
  label pool** (the binding constraint on stage-2 growth), then **equality
  operators** (`== != <= >=`), then `/` (needs `udiv` in stage0-as).
- **Stage 3** — written in stage-2's language, once stage 2 is a usable C subset.
- **Hand-off**: grow stage 2/3 to M2-Planet-grade C, then hand to the borrowed
  live-bootstrap chain (see `spikes/borrow-m2/`, `spikes/livebootstrap/`).

Scope rule: add the smallest capability per rung that makes the next rung
writable. If a stage feels unwieldy to write, that's the signal to add one small
convenience to the stage below — not to push through pain.
