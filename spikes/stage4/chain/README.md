# spikes/stage4/chain — the stage-4 chain, and what is actually proven about it

## What this directory is

The shared machinery behind `.github/workflows/stage4-complete.yml`. It exists
because the previous revision of that workflow reimplemented — badly — five
things that already worked elsewhere in this repository, and then had to
relearn every lesson those implementations had already paid for.

| file | what it is | provenance |
|---|---|---|
| `box.sh` | the sandbox | **verbatim extraction** from `tcc-builds-gcc-arm64.yml` |
| `fetch.sh` | hardened fetch + pin verification | **extraction** from `hermetic-gcc15.yml`, plus new `sources/` verification |
| `seal.sh` | content-hash the hand-off between rungs | **new** |
| `rung1.sh` | tcc → 4.7.4 → 4.7.4 → 10.2.0 | **port** of `tcc-builds-gcc-arm64.yml` |
| `rung2.sh` | gcc 10 → sysroot → 15.2.0 | **port** of `hermetic-gcc15.yml` |
| `rung3.sh` | kernel + userland + initramfs | **port** of `hermetic-gcc15.yml` |
| `gate-gcc10.sh`, `gate-gcc15.sh` | assertions, not reports | **port** |

The distinction in that last column is load-bearing. Read the next section
before running this.

## Run history

| run | got to | died on |
|---|---|---|
| 81901874247 | step 3 of 18 | `apt-get` without `sudo`; `RESULT` printed a full proof banner anyway |
| 81907665505 | rung 1, first pass | `GMP_VER: parameter not set` — the rung scripts read the workflow's `env:` block, which `--clearenv` does not carry into the box |
| 81908437787 | rung 1, gcc 10 | `make: *** [Makefile:958: all] Error 2`. tcc built gcc 4.7.4 (2 min) and that gcc rebuilt it (5 min); all six sources pin-verified. Two defects of mine surfaced: the failure diagnostics printed make's directory chatter instead of the compiler error, and the build log was never uploaded, so the actual error is unrecoverable without a rerun. Both fixed in r3. |

| 81910448983 | rung 1, bootstrap comparison | The comparison ran and failed — on my setup, not on the compilers. gcc records its configure line in the binary, so B carried `CC=/work/g47a/bin/gcc` and C carried `CC=/work/g47/bin/gcc`, one character shorter; everything after it shifted and `cmp` reported the first difference at ELF64's `e_shoff`. Decoded, the differing bytes were `a/bin` against `/bin`. Fixed in r4: the builder path, the prereq prefix and the build directory all go through fixed paths (`/work/cc-prev` repointed by symlink, `/work/prereq`, `/work/bld`) so B and C record byte-identical configure lines. |

r4 also splits the comparison in two, because r3 conflated two questions.
**Stripped** images answer "does the code match" — the compiler question.
**Raw** images additionally cover recorded build metadata, which is this
script's business rather than the compiler's. A metadata-only difference now
reports as one, and both are still failures: the intended state is
byte-identical and nothing is waved through. On any difference the two
configure lines are printed, because in 81910448983 the entire discrepancy was
one character of that string and finding it cost a 12-minute run and a hexdump.

### Two things r3 changed because they were wrong, not because they broke

**The passes are no longer numbered.** They were `STAGE 1/2/3`, inherited from
`tcc-builds-gcc-arm64`. But `ARCHITECTURE.md` §2, `AGENTS.md` §4, that job, and
this workflow's own rungs already give a small integer beside "stage" four
different meanings, and the first two disagree in a way that is an open
stop-and-ask. Adding a fifth scheme made a log line unreadable without knowing
which file the reader had open. The passes are named by the transition they
perform.

**The fixpoint check was measuring the wrong pair, and pre-declaring the
answer.** It compared build A's `cc1` (compiled by tcc) against build B's
(compiled by gcc) — two different compilers, which have no reason to emit
identical code — and annotated the inevitable difference "expected at this
rung; 3-stage bootstrap is deferred". A check with one possible outcome, and a
comment ensuring that outcome reads as success, is the same defect as the gate
that printed "expect exit 55" and exited 0 regardless.

r3 builds a third 4.7.4 and compares **B against C**: identical source,
identical `--prefix`, compilers that are themselves identical-source 4.7.4.
Those *should* be byte-identical, so a difference is a real finding — a tcc
miscompilation surviving a generation, or non-determinism. It is a hard failure
with `cmp -l` offsets printed. Cost is one extra 4.7.4 build, which run
81908437787 measured at 2–5 minutes against a 330-minute budget.

What 81907665505 established, which is the part worth keeping: rung 0 built the
patched tcc at the pinned commit and sealed it; rung 1's seam check verified the
restored tree against that seal and passed; `fetch.sh` pin-verified 4.7.4 and
4.8.5 against `sources/gcc.toml` and reported four unpinned inputs with their
hashes; and when the chain broke, the ledger named the three missing records,
said "THE CHAIN DOES NOT CONNECT", and exited 1 **without printing a claim**.
That last line is the whole reason this workflow was restructured.

The `--clearenv` failure is worth keeping too, in the sense that `set -u` turned
it into a one-line stop at the first use rather than a build of `gmp-` that
failed incomprehensibly forty minutes later.

## Status — read this before believing anything

**None of this has been executed.** It was written by reading the jobs that do
work and the log of run 81901874247, which failed eight seconds in. The
scaffolding is transcribed from code that has survived this runner; the rung
bodies are ports, and a port is a fresh draft with a good source, not a tested
build.

What I would expect to hold on a first run:

- the environment steps (`sudo`, `bubblewrap`, `cpio`, `qemu-system-arm`, the
  AppArmor profile) — these were the eight-second failure and its successors
- `box.sh` — it is byte-for-byte the box that already runs
- `fetch.sh`'s transport hardening — likewise
- `seal.sh` — small, self-contained, and the only genuinely new logic
- the reporting: `${PIPESTATUS[0]}` on every box call, and a `RESULT` that
  cannot print a claim without records to back it

What I would expect to need iteration:

- **`rung2.sh`.** LFS chapter 5–6 has the most incidental detail per line of any
  part of this, and `hermetic-gcc15.yml` carries roughly 2,000 lines of it —
  the `-Werror=attributes` fix, `_GNU_SOURCE` having to arrive as a *config
  string* because `Makefile.flags` swallows it otherwise, the header/libc
  pairing rationale, `PERL=true` for bison's doc rules. This port carries the
  ordering and the configure lines. It does not carry all of that.
- **`rung3.sh`'s kernel config.** `defconfig` plus `olddefconfig` for
  linux 7.1.5 on `-M virt` is the shape `hermetic-gcc15` uses, but its exact
  option set was arrived at by five separate boot failures.
- **The `HOSTCC` choice in `rung3.sh`.** Pointing HOSTCC at the cross compiler
  is correct in spirit — nothing in the image should come from the runner — but
  the kernel's host tools want a *native* compiler and on aarch64 building
  aarch64 these coincide only if the cross compiler can produce host-runnable
  binaries. If it can't, the fix is a native `gcc 15` alongside the cross one,
  not reaching back to the runner's.

Treat a red first run as expected and read the first red line. That is what the
per-rung logs and `${PIPESTATUS[0]}` are for.

## The design change, stated plainly

`stage4-complete` was one job. It is now four rungs plus a ledger gate. This is
a design change and per `AGENTS.md` §2a it is a human decision — it was made
deliberately, and the reasoning belongs in the record:

1. **It could not fit.** `tcc-builds-gcc-arm64` budgets 350 minutes for a strict
   subset of the same work, and 360 is the public-runner ceiling.
2. **A monolith proves the chain once.** Criterion 2 wants N byte-identical
   rebuilds. Sealed hashes get *stronger* with repetition: a rung whose output
   hash moves while its inputs did not is a reproducibility finding, and the
   monolith had no way to express that.
3. **The seam was never the risk it was treated as.** The real gap between the
   rung jobs was that the gcc 10 one produced and the gcc 10 the next consumed
   shared a version number and nothing else. Re-running everything in one
   process removes the hand-off; declaring and verifying a content hash
   *closes* it, and leaves an input graph behind (criterion 3).

`ARCHITECTURE.md` should record this before the next agent inherits it.

## Two things still open

**The ladder numbering.** `AGENTS.md` §4 documents stages 0–5 — `seed-as` at 0,
a FORK LINE between 3 and 4, libc entering as a stage-4 parameter.
`ARCHITECTURE.md` §2 documents stages 1–7 — `seed-as` at 1, stage 4 as
"tcc → Linux boot", no fork line. Under the AGENTS.md table, a kernel and a
userland are stage *5* work and this workflow is misnamed. Invariant #3 is
phrased in the old numbering, so what it currently constrains is ambiguous.
This is a §2a stop-and-ask and it is not resolved here.

**Repo hygiene the chain touches.** `tools/__pycache__/*.pyc` and the five LFS
book tarballs under `spikes/stage4/books/` are committed binaries (invariant #1)
and vendored upstream archives (#6). `.gitignore` covers neither. `fetch.sh`
reports unpinned inputs rather than failing on them, because failing today would
red every run — but that count lands in each chain record, so it is visible and
countable rather than absent.

## Running a rung locally

`box.sh` takes `W` and `REPO` and nothing else, so the same box CI uses runs on
a developer machine — the `tools/spike.sh` principle, that local and CI can
never drift:

```bash
sudo apt-get install -y bubblewrap
W="$PWD/work" REPO="$PWD" sh spikes/stage4/chain/box.sh --show-mask
W="$PWD/work" REPO="$PWD" sh spikes/stage4/chain/box.sh /bin/sh /work/rung1.sh
```

`seal.sh` needs no sandbox at all:

```bash
sh spikes/stage4/chain/seal.sh hash work/out10
sh spikes/stage4/chain/seal.sh chain records/rung*.json
```
