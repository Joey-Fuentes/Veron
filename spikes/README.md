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

Full progress log, spike inventory, and what's next: **`PROGRESS.md`**.

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
