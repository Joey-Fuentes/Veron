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

Notable bug found and fixed along the way: the hand-built ELF failed to run
because it lacked the execute bit — a *file-mode* issue, not a byte issue
(`readelf` was happy, QEMU was not). The `elf` tool now sets it itself.

---

## 6. What's next

The plan is a **capability-jump ladder**: keep each rung minimal, and write each
stage in the language of the stage below.

- **Stage 1** — DONE for capability #1 (**multi-character labels**), see
  `spikes/stage1-as/`. Written in stage0-as's language, byte-verified. Next
  stage-1 increments add only what **stage 2** (a small C compiler, written in
  stage-1's language) actually needs.
- **Stage 2** — written in stage-1's language, adding the next capability.
- **Stage 3** — written in stage-2's language. Each rung easier than the last.

Scope rule: add the smallest capability per rung that makes the next rung
writable. If a stage feels unwieldy to write, that's the signal to add one small
convenience to the stage below — not to push through pain.
