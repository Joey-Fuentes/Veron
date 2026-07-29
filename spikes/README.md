# spikes/ — feasibility tracers (invariants SUSPENDED)

A spike is a throwaway/experimental program used to answer one question fast,
run under QEMU user-mode on CI. Spikes deliberately drop Veron's invariants
(bijective encoding, reproducibility, hermeticity, audit, no-committed-binaries)
— they are a proving ground, not Veron proper. See `PROGRESS.md` for the full
story and current state of the bootstrap toolkit.

## Bootstrap toolkit (live)

A working ARM64 pipeline, hand-written and byte-verified against the real
assembler:

```
program.s ──[stage0-as]──► code bytes ──[elf out]──► runnable executable
```

- `stage0-as/` — two-pass mnemonic assembler (assembler-complete). Language
  reference in `stage0-as/README.md`.
- `elf/` — wraps code bytes into a runnable, self-executable-marking ELF.

**The ladder reaches its hand-off.** `stage2-pico-c` builds **M2-Planet from
M2-Planet's own source**, and that binary reproduces upstream's reference
compiler byte for byte over five generations — so M2-Planet becomes the de-facto
"stage 3", with no throwaway intermediate compiler. One substitution remains (an
M2libc file whose only content is six `asm()` syscall functions our builtins
already supply). Details in `stage3/README.md` and
`stage2-pico-c/TARGET-SUBSET.md`.

Full progress log, spike inventory, and what's next: **`PROGRESS.md`**.

## Design & reference docs

- `stage2-pico-c/TARGET-SUBSET.md` — the C subset the ladder is working toward
  (derived from M2-Planet's self-host) and the stage-2 "floor" before stage 3.
  **Read this for the near-term plan.**
- `reference/` — pinned, read-only copies of the M2-Planet + M2libc source
  (the handoff target), vendored so the source can be consulted locally. Not part
  of the build; see `reference/README.md`.
- `toolbox/` — two committed development binaries: `qemu-aarch64-static`, so
  aarch64 output can be **run** on a non-aarch64 machine, and the pinned tcc
  tree already configured. Also not part of the build, and deliberately the one
  place in this repository holding something opaque — read `toolbox/README.md`
  for the version of each, where it came from, and why that exception is
  acceptable. Delete the directory and every workflow still passes; what you
  lose is the ability to work outside CI.

## Naming convention (for the generic `spike` matrix)

One source per architecture, tagged in the filename:

```
spikes/<name>/<name>.x86_64.s
spikes/<name>/<name>.aarch64.s
spikes/<name>/<name>.riscv64.s
```

The generic **spike** workflow picks up `spikes/**/*.<arch>.s` automatically for
each arch. A spike need not cover all three arches. Tools with their own
demos (like `stage0-as`, `elf`) have dedicated workflows instead.

## Run one locally (same script CI uses)

```bash
tools/spike.sh aarch64 spikes/hello/hello.aarch64.s
tools/spike.sh aarch64 spikes/hello/hello.aarch64.s --dump   # also disassemble
```

Prereqs locally: `qemu-user` and the cross-binutils packages (see `ci/Dockerfile`).

## Run in CI

Push anything under `spikes/**` → the relevant workflow(s) run and report to the
job summary. Note: because the generic **spike** matrix triggers on all of
`spikes/**`, a push to any spike re-runs that matrix over the existing spikes
(harmless). Tool-specific demos (`stage0-as-demo`, `elf-demo`, …) trigger on
their own paths.

---

## Where to start

The tree is split at **tcc**: stage 3 is everything up to and including reaching
tcc from the seed; stage 4 is everything tcc is then used to build.

| you are working on | read |
|---|---|
| **M2-Planet, or reaching tcc from it** | `stage3/README.md` — short, current |
| **anything above tcc** (gcc, userland, kernel, boot) | `stage4/README.md` — short, current |
| the plan for M2-Planet → tcc | `stage3/ROADMAP.md` |
| the plan for tcc → Linux | `stage4/ROADMAP.md` |
| the pin set and what is open at it | `UPSTREAM-PINS.md` |
| stage 0–2 history | `PROGRESS.md` — 150 KB, reference only |

**Stages 0–2 are complete.** Stage 2 builds M2-Planet; that M2-Planet reproduces
upstream's reference compiler byte for byte, and is a stable fixpoint over five
generations. Stage 3 is M2-Planet itself — there is no separately-written stage 3
— and its remaining rung is reaching an unmodified tcc from the seed. Stage 4
already has a pinned tcc and has used it to build a gcc that targets aarch64 and
a userland that boots as PID 1. **Its top rung now boots**: `hermetic-gcc16`
builds gcc 16.1.0 in a box with no host filesystem, builds linux v7.2-rc4 with
it, and boots that kernel under QEMU with the box's own glibc as PID 1 — gated
by three test suites. That box is LFS-shaped scaffolding above tcc, not the
bootstrap chain itself; see `stage4/README.md` for what it does and does not
claim.
