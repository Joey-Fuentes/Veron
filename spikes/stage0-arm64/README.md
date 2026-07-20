# spikes/stage0-arm64 — EXPERIMENTAL stage 0 (feasibility tracer)

**Architectural invariants are SUSPENDED here, on purpose.** This is *not*
Veron proper. It exists to prove we can write, assemble, and run ARM64 assembly
on the qemu-user CI setup, and to give us a readable cradle to grow toward the
real `seed-as`.

Deliberately dropped here: the bijective-encoding rule, reproducibility,
hermeticity, the round-trip audit, and the no-committed-binaries rigor. The
real seed (`seed/`) will honor all of that; this tracer does not. Do not copy
patterns from here into `seed/` without re-applying the invariants.

## Run

```bash
tools/spike.sh aarch64 spikes/stage0-arm64/stage0.aarch64.s
tools/spike.sh aarch64 spikes/stage0-arm64/stage0.aarch64.s --dump   # see emitted bytes
```

It also runs automatically in CI — the spike workflow picks up
`spikes/**/*.aarch64.s`. Expected output: `hello from Veron stage0`, exit code 0.

(With `--dump`, the disassembly shows the 8 real instructions followed by a few
lines of "garbage" — that's the string data, which lives in `.text` and objdump
tries to decode as instructions. Harmless.)

## Where this goes next

Grow this file toward `seed-as` one small step at a time — e.g. hand-emit a
couple of chosen instructions and confirm the round-trip (`--dump`, compare)
before adding any assembler logic. When it starts becoming the real assembler,
it graduates *out* of `spikes/` into `seed/aarch64/` — and at that point the
invariants switch back **on**.
