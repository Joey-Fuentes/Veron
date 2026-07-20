# spikes/borrow-tcc — real program on aarch64 (tracer)

**Invariants SUSPENDED.** Follow-on to `spikes/borrow-m2`.

## What runs

- **GATE — real program on aarch64.** A small but real program (a `sq()`
  function called in a loop: `sum of squares 1..5`) is compiled for aarch64 by
  the borrowed `M2-Planet`, assembled with `M1`, linked with `hex2`, and run
  under `qemu-aarch64` → exit **55**. This exercises function calls, multiply,
  and a loop — real codegen, on the non-debug path proven green in `borrow-m2`.

- **BONUS (non-gating) — self-host M2-Planet on aarch64.** The host `M2-Planet`
  compiles its *own* source to an aarch64 binary (non-debug, plain ELF header),
  which is run under `qemu-aarch64` to compile a program; its output is
  byte-compared to the host build. Reported but **not** gating.

## Why non-debug

An earlier cut built the self-host binary with `--debug` + `blood-elf` + the
debug ELF header (`ELF-aarch64-debug.hex2`) and it segfaulted instantly under
qemu-user — that debug layout is only ever run on real aarch64 upstream, never
under qemu-user. This cut uses the plain header / no debug, matching the shape
that ran green in `borrow-m2`.

## Part B (reach tcc via Mes) — deferred

The probe reached Mes's build and stopped at `Unable to open ... include/mes/
config.h`: that header is **generated** (by Mes's `configure.sh`; live-bootstrap
creates it plus `@VERSION@` substitution and `catm` preprocessing before the
compile). So the base tools are fine — the Mes→tcc rung needs live-bootstrap's
mes-step driver, and it is **amd64-only** (Mes/tcc have no aarch64 backend).
That heavier follow-on is intentionally out of scope for this tracer.

## Honesty note

Nothing here is compiled by *our* seed — the compiler is the borrowed
`M2-Planet` throughout. `M2-Planet`, `mescc-tools`, `M2libc` are fetched as
upstream build dependencies (like gcc/musl/linux), not vendored; cloned at
branch tip (reproducibility suspended for spikes).
