# stage4-complete.yml — one job, tcc to a booting Linux

**Status: GREEN, 2026-07-27, run 81944089602, 61.4 minutes.**

```
VERON-BOOT-OK        Linux 7.1.5 aarch64
VERON-COMPILER       Linux version 7.1.5 (gcc (GCC) 15.2.0, GNU ld ...)
VERON-TESTS          pass=8 fail=0
VERON-GCC-IN-GUEST   ok compiled and ran, rc=42 (expect 42)
GCC-EXERCISE         pass=10 fail=0
```

The kernel's own version string names the compiler that built it. That gcc
15.2.0 was built by a gcc 10.2.0 that tcc built, four steps earlier in the same
process.

---

## What it proves that nothing else did

```
tcc  →  gcc 4.7.4  →  gcc 4.7.4  →  gcc 10.2.0  →  gcc 15.2.0
                                                        ↓
                                          linux 7.1.5 + userland
                                                        ↓
                                            QEMU boot, compile in guest
```

Every other box here starts from a host-built cross toolchain **on purpose**, so
a failure localises to one question — `hermetic-gcc10` says so in its header,
`hermetic-gcc15` and `-gcc16` add *"this box never triggers another and no other
box triggers it."* That is the right shape and they keep it.

The cost was that the two green chains never touched. `tcc-builds-gcc-arm64`
ended at a gcc 10 that nothing consumed; the gcc that booted in `hermetic-gcc15`
was built by the runner's gcc. Same version numbers, different ancestry.

This job walks it in one process. `VERON-GCC-IN-GUEST rc=42` is the line that
matters: a compiler descended from tcc, running inside the kernel that same
chain built, compiling and running a program.

## The join is one substitution

LFS chapters 5.2 and 5.3 build binutils and gcc pass 1 with whatever `gcc` is on
`PATH` — the runner's. Everything above them is already built by the cross
toolchain those two steps produce. So pointing **only those two** at the
tcc-built gcc 10 moves the entire sysroot, kernel and boot onto tcc's line.

The `SEED` step does it, and checks the one thing that could have stopped it:
that gcc 10 was configured `--prefix=/work/out10` *inside* bwrap, and chapters
5.2/5.3 run on the host where `/work` does not exist. GCC relocates itself by
computing its own location, so it works — but SEED compiles and runs a program
to find out in seconds rather than letting a `configure` report only "no" forty
minutes later.

That gcc 10 → gcc 15 step was not a guess: `hermetic-gcc10`'s ATTEMPT 1 proves
it green in 10.4 minutes.

## Where the steps come from

34 steps. **28 are copied byte-for-byte** from `tcc-builds-gcc-arm64` (the tcc
half) and `hermetic-gcc15` (the sysroot/kernel/boot half), with step names
unchanged so any of them can be diffed against its source.

Four are not:

| step | what is different |
|---|---|
| `Install` | union of both halves' packages |
| `5.2 binutils pass 1` | +4-line guard exporting `CC="$CHAIN_CC"` |
| `5.3 gcc pass 1` | same guard |
| `SEED` | new — the join, 20 lines |

Earlier drafts of this file *paraphrased* those recipes and spent six revisions
rediscovering the reasons for flags that were already written down. Nothing here
is retyped from memory. Every failure this job hit in the end was in one of the
four steps above, never in the 28.

## No cache, deliberately

`hermetic-gcc15` caches its sysroot because it rebuilds the same one every run.
A cached sysroot here would have been seeded by some earlier run's compiler, and
restoring one would boot a system that did not descend from *this* run's tcc
while the log said it did. An hour of compute is cheaper than a false claim.

## It fits in one job

The earlier argument against a single job read the **350-minute timeout** on
`tcc-builds-gcc-arm64` as if it were a runtime. It is a guard. Measured:

| | |
|---|---|
| tcc → 4.7.4 → 4.7.4 → 10.2.0 | 14.1 min |
| LFS sysroot, cold, no cache | ~17 min |
| gcc 10 → gcc 15.2.0 | 10.4 min |
| **whole chain, measured** | **61.4 min** |

The ceiling is six hours.

## What it does not claim

- **tcc's own provenance.** Host-built here, outside the box — the declared
  hole, and stage 3's open rung (`spikes/stage3/README.md`).
- **Reproducibility.** One run is one run. Criterion 2 wants N byte-identical
  rebuilds and this contributes one attestation, not a comparison.
- **3-stage bootstrap or DejaGnu.** Deferred, as in every other rung job.
- **gcc 16 or an -rc kernel.** `hermetic-gcc16` answers that, alone, on its own
  trigger.
- **That it replaces any existing box.** It does not. They answer localised
  questions and stay useful precisely because they start from a host base. This
  one answers the end-to-end question and is worth exactly as much as its
  weakest rung.

## Running it

Triggers on push to its own file, and on `workflow_dispatch` with a
`tcc_source` input (`pinned-series` — the `sources/tcc.toml` pin plus the arm64
asm series — or `mob`).
