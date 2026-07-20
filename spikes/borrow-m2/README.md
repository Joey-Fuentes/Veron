# spikes/borrow-m2 — no-host toolchain runs here (feasibility tracer)

**Invariants SUSPENDED.** This spike answers one question cheaply: *does the
known, no-host bootstrap toolchain run on our setup, targeting `aarch64`?*

It stands up the lower rungs of the established source-only toolchain and uses
them to turn a C file into a running `aarch64` binary with **no host C
cross-compiler in the target path**:

```
test.c ──[M2-Planet --architecture aarch64]──► test.M1     (C subset → M1 assembly)
       ──[M1 + M2libc aarch64 defs/libc-core]─► test.hex2   (assemble)
       ──[hex2 + M2libc aarch64 ELF header]───► test.elf    (link → static ELF)
       ──[qemu-aarch64]───────────────────────► exit code   (checked)
```

The two test programs are deliberately tiny and need **no C library**:
`libc-core.M1`'s `_start` calls `main()` and uses its return value as the
process exit code. `return42.c` proves the pipeline end to end (exit 42);
`loopsum.c` adds a `while` loop with a local accumulator to exercise real
codegen (exit 45).

## Upstream dependencies (not vendored)

`M2-Planet`, `mescc-tools`, and `M2libc` are fetched by the workflow purely as
**upstream build dependencies** — the same category as gcc/musl/linux further
up the ladder — and are **not** copied into this repo. They are cloned at a
branch (not yet pinned to a commit); reproducibility is suspended for spikes.

## Why this exists

It de-risks and decouples: reaching a real C toolchain is already-solved,
trodden work, so proving it runs on our CI is *integration*, not authoring.
That lets the hand-written rungs (`stage0-as`, and next `stage1`) be built and
verified independently, without blocking on a from-scratch C compiler.

## Not this

This does **not** claim our own seed compiled anything — the compiler here is
the borrowed `M2-Planet`. It proves the mechanism works on our setup. See
`spikes/PROGRESS.md` for how this fits the overall plan.

## See it run

Push under `spikes/borrow-m2/**` → the **borrow-m2-demo** workflow fetches the
toolchain, builds the two programs for `aarch64`, and runs them under QEMU
(expecting exit 42 and 45).
