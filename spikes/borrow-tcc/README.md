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
mes-step driver. That heavier follow-on is intentionally out of scope for this tracer.

**Precise cross-arch status (corrected — the earlier "amd64-only, Mes/tcc have no
aarch64 backend" was directionally right but imprecise).** M2-Planet *does* target
aarch64 (that's what this spike runs). The gap is one rung up: **MesCC has no _native_
aarch64 backend** — its code generators are x86 (i386) and **armhf** (32-bit ARM) only
(GNU Mes 0.27 / current manual: "aarch64-linux uses mes for armhf-linux"). Guix reaches
aarch64 by running the **armhf Mes** on aarch64 hardware and lifting to 64-bit;
live-bootstrap's Mes→tcc→gcc upper half is x86-framed with no aarch64 config. So a native
arm64 gcc is a **porting** effort, and two routes exist: (1) the **armhf-Mes detour**,
which is **hardware-viable on our CI** — GitHub's `ubuntu-24.04-arm`/`22.04-arm` runners
are Cobalt 100 / Neoverse N2, which keeps **AArch32 EL0**; a freestanding static armhf
binary runs **natively** (verified, exit 42, no emulation — see
`.github/workflows/armhf-probe.yml`) — but it's a build-out and is **fragile** (breaks if
the fleet moves to Cobalt 200 / Neoverse V3, which drops AArch32; keep the probe as a
canary); or (2) **cross-compile from the amd64 gcc** the chain lands (durable). Current
lean: (2). Deferred behind reaching M2-Planet either way.

## Honesty note

Nothing here is compiled by *our* seed — the compiler is the borrowed
`M2-Planet` throughout. `M2-Planet`, `mescc-tools`, `M2libc` are fetched as
upstream build dependencies (like gcc/musl/linux), not vendored; cloned at
branch tip (reproducibility suspended for spikes).
