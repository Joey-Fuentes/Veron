# spikes/borrow-tcc — real program on aarch64 + a reach toward tcc (tracer)

**Invariants SUSPENDED.** A follow-on to `spikes/borrow-m2`. Two independent
parts; the first gates the run, the second is a best-effort probe that never
fails the run.

## The arch reality this spike is shaped around

The borrowed toolchain splits by architecture:

- `M2-Planet` + `mescc-tools` + `M2libc` support **aarch64** (our reference arch).
- **Mes and tcc do NOT.** Mes's `mescc` backends are i386, x86_64, armv4,
  riscv64 — no aarch64 — and live-bootstrap's `mes`/`tcc` steps only handle
  x86, amd64, riscv64. So the rung that reaches tcc runs on **amd64**, natively
  (no QEMU). An arm64 tcc, if wanted later, is a cross-compile *from* the amd64
  tcc (tcc can target arm64), not a native bootstrap.

## Part A — a real program on aarch64 (gates the run)

Self-hosts `M2-Planet` on aarch64 — this is upstream's own `test1000` recipe:
the host `M2-Planet` compiles M2-Planet's *own source* to an aarch64 binary via
`M2-Planet -> blood-elf -> M1 -> hex2`. That aarch64 compiler is then run under
`qemu-aarch64` to compile a small program, and its output is byte-compared
against the host compiler's output for the same input. Byte-identical =⇒ the
aarch64-built compiler genuinely works. This is a real, non-trivial program on
our reference arch, not a toy.

## Part B — reach toward tcc on amd64 (best-effort probe)

tcc comes only via Mes, so this builds the borrowed tools for **amd64** and then
builds **Mes** (`bin/mes-m2`) using Mes's own `kaem.x86_64` bootstrap driven by
`M2-Planet`. Mes is the rung **directly below tcc**: once Mes builds, tcc is the
next step (that step needs live-bootstrap's nyacc + mescc environment and is the
heavier follow-on, intentionally out of scope for this quick tracer). This part
is `continue-on-error`: it reports how far it got and does **not** fail the run,
so we learn exactly where the seam sits whatever happens.

## Honesty note

Nothing here is compiled by *our* seed — the compiler is the borrowed
`M2-Planet` throughout. This proves the borrowed ladder runs on our setup and
locates the tcc seam; it is not a claim that Veron's own rungs reached tcc.

`M2-Planet`, `mescc-tools`, `M2libc`, and `mes` are fetched as upstream build
dependencies (same category as gcc/musl/linux), not vendored. Cloned at branch
tip; reproducibility is suspended for spikes (pin to SHAs when graduating).
