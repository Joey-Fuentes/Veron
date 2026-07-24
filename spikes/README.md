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

**Milestone (m71): the ladder reaches its handoff.** `stage2-mini-c` builds **M2-Planet
from M2-Planet's own source**, and that binary compiles C to M1 — so M2-Planet becomes the
de-facto "stage 3", with no throwaway intermediate compiler. Demonstrated on CI in
`.github/workflows/stage3-m2-demo.yml`. One substitution (an M2libc file whose only content
is six `asm()` syscall functions our builtins already supply) and one remaining join (the
emitted `.M1` is not yet driven through M1/hex2). Details in
`stage2-mini-c/TARGET-SUBSET.md`.

Full progress log, spike inventory, and what's next: **`PROGRESS.md`**.

## Design & reference docs

- `stage2-mini-c/TARGET-SUBSET.md` — the C subset the ladder is working toward
  (derived from M2-Planet's self-host) and the stage-2 "floor" before stage 3.
  **Read this for the near-term plan.**
- `reference/` — pinned, read-only copies of the M2-Planet + M2libc source
  (the handoff target), vendored so the source can be consulted locally. Not part
  of the build; see `reference/README.md`.

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

| you are working on | read |
|---|---|
| **anything above M2-Planet** (Mes, tcc, gcc) | `stage3/README.md` — short, current |
| the forward plan / direct-path track | `stage3/ROADMAP.md` |
| the pin set and what is open at it | `UPSTREAM-PINS.md` |
| stage 0–2 history | `PROGRESS.md` — 150 KB, reference only |

**The ladder is complete.** Stage 2 builds M2-Planet; that M2-Planet reproduces
upstream's reference compiler byte for byte, and is a stable fixpoint over five
generations. Stage 3 is M2-Planet itself — there is no separately-written stage 3.
