# The derivation phase — design

Everything works. This is the phase that makes it *provable*: every file on the
built system traceable to a derivation, every derivation traceable to a hashed
input, every input traceable to this repository or to a named external root.

`ARCHITECTURE.md` §3 defines the seven audit criteria and `ledger/README.md`
names the record fields. `lib/README.md` leaves one decision open — build on
Nix/Guix or implement the model here. This file resolves that, defines the
schema concretely, and sequences the work.

Nothing here changes what the ladder builds. It changes what the ladder
*records* while building it.

---

## The four goals, and why they are one problem

1. **One script, two environments.** `sh veron build` on a laptop and on the
   runner do the identical thing.
2. **Content-addressed derivations.** Inputs hashed, outputs hashed, the pair
   recorded, the cache keyed on it.
3. **Reproducibility, checked.** Two independent runs compared byte for byte,
   with expected differences declared rather than discovered.
4. **Traceable provenance.** For any file on the final system: the path back to
   the seed, viewable.

They are one problem because 4 is a query over the records 2 produces, 3 is 1
run twice and diffed, and 2 cannot be recorded honestly until 1 removes the
build logic from YAML.

---

## Decision 1 — the numbering, first, because everything keys on it

`README.md` records the disagreement plainly: `ARCHITECTURE.md` §2 numbers the
ladder 1–7 with no fork line; `AGENTS.md` §4 numbers it 0–5 with the flavor fork
between 3 and 4. The spike track carries a third numbering of its own (rungs
0–16 plus 3.5 and 4.5, then B0–B8).

A content-addressed store keys derivations by stage identity. Migrating spike
work into `stages/` under two competing schemes bakes the ambiguity into every
record and every path. **This has to be resolved before any record is written**,
and it is the cheapest item on the list.

Recommendation: keep `AGENTS.md` §4's 0–5 with the fork between 3 and 4 as
canonical — it is the one the directory layout already reflects — and rewrite
`ARCHITECTURE.md` §2 to match, with a note that the spike track's rung numbers
are a separate, local scheme that maps into it rather than competing with it.

---

## Decision 2 — implement the model, do not adopt Nix

`lib/README.md` leaves this open. The recommendation is to implement it, for
reasons specific to this project rather than general:

**What Nix would give:** a derivation engine, a store, a sandbox, a binary
cache, and a large body of existing work.

**What it would cost here:** Nix is a substantial host tool with a daemon, its
own store, and its own bootstrap. It would sit outside the box the way
`bubblewrap` does, so the tier-1 budget stays empty and the claim survives —
but it becomes another opaque thing to trust at exactly the layer this project
has worked hardest to keep legible. "Every file traceable to the Veron repo"
reads poorly if the tracing engine is 100k lines nobody in this project audited.

**What is actually missing is small.** The hard parts are done: bubblewrap
sealing, `--unshare-all`, `SOURCE_DATE_EPOCH 0`, pinned inputs with sha256, an
empty tier-1 budget, and a SEAL step that enforces the box contents against a
declared list. The remainder is bookkeeping — hash the inputs, hash the outputs,
write the pair down, key a cache on it. That is a few hundred lines against a
model already designed in `ARCHITECTURE.md` §5.

**Nix's format is still worth stealing**, specifically: content-addressed
outputs, a derivation as a pure function from hashed inputs, and the
store-path-as-identity idea. Take the model, not the dependency.

---

## Decision 3 — extract the build from YAML first

`stage0-stage4-complete.yml` is 3589 lines. The box assembly, the airlock
steps, the SEAL enforcement, the tarball repacking and the boot verification
all live in the workflow. Only `rungs.sh` runs inside the box.

So "the same script locally" does not exist yet. The first change is mechanical
and behaviour-preserving:

```
tools/veron            the entry point, runs anywhere
  build <stage>        one stage, or all
  verify               second run + diff
  why <file>           provenance query
  roots                every external input

.github/workflows/…    becomes: checkout, install airlock deps, `tools/veron build`
```

This is the same refactor `TRUST-BOUNDARY.md` already names as a prerequisite
for the `.s0` driver — "move the checking outside the box" — and it should be
one pass, not two.

**It also fixes a measured problem.** `shell-surface.sh` shows the in-box
scripts are roughly four to one reporting against building. Moving reporting
out of the box is what makes the driver tractable *and* what makes the
derivation boundaries visible, because what remains inside is exactly the pure
function being recorded.

---

## The schema

A derivation is a pure function from hashed inputs to an output. One record per
output, extending the fields `ledger/README.md` already names.

```json
{
  "name": "gcc",
  "version": "4.7.4",
  "stage": 4,
  "flavor": "glibc",
  "output_hash": "sha256:…",
  "short": "07184a9f2b6c",
  "inputs": {
    "sources": [
      { "url": "…/gcc-4.7.4.tar.bz2", "sha256": "…", "sig": "…", "spdx": "GPL-3.0-or-later" }
    ],
    "derivations": [ "sha256:…(binutils)", "sha256:…(musl)", "sha256:…(mc-tcc)" ],
    "patches":  [ { "path": "spikes/…/0001-….patch", "sha256": "…" } ],
    "recipe":   { "path": "stages/4/gcc.sh", "sha256": "…" },
    "env":      { "SOURCE_DATE_EPOCH": "0", "nproc": 4, "kernel": "…", "TZ": "UTC" }
  },
  "builder": "sha256:…(the compiler that ran)",
  "files":   "sha256:…(manifest of installed paths)",
  "repro":   [ { "run": "…", "output_hash": "sha256:…", "match": true } ],
  "deferred": []
}
```

Two fields beyond the existing list, both required for the graph:

- **`builder`** — the hash of the compiler that produced this output, not just
  the sources. This is what makes "which gcc built this" answerable, and it is
  the field that distinguishes the mc-tcc arm from the reference arm.
- **`files`** — a manifest of installed paths with per-file hashes, which is
  what turns a derivation graph into a *file* graph.
- **`short`** — the first twelve hex characters of `output_hash`, resolved by
  prefix the way git resolves a short commit: unambiguous or an error, never a
  guess. This is the node's name in every query, in the tree output, in
  `ledger/` filenames and in the cache key, so a hash read off a chart can be
  pasted straight into `veron show` without a lookup step.

### What counts as an input

Anything that can change the output. The ones that leak silently:

- **`nproc`** — already noted in the logs as an undeclared input. Parallelism
  changes link order and archive member order.
- **kernel version** — `uname` reaches configure scripts.
- **clock** — `SOURCE_DATE_EPOCH 0` covers most of it; `__DATE__`/`__TIME__`
  and `ar` mtimes need explicit handling.
- **locale and `TZ`** — sorting and date formatting.
- **the airlock's own compiler** — busybox is compiled by the runner's gcc.
  Indirect, but it is an input and the record should say so.

### What is allowed to differ

Declared, not discovered. The usual offenders:

- `ar` archive member timestamps — normalise with `D` (deterministic mode)
- ELF build IDs — pin or strip
- `__DATE__` / `__TIME__` — `SOURCE_DATE_EPOCH`
- embedded build paths — a fixed build prefix
- parallel-build ordering inside archives

Each one is either **normalised** or **recorded as an expected difference with
a reason**. A run that differs in a way not on the list is a failure.

---

## The provenance graph

The deliverable behind "every file traceable back to the Veron repo".

### Capturing file ownership

Each stage installs into the sysroot. Ownership is captured by manifesting the
sysroot before and after a stage and attributing the delta:

- new path → owned by this derivation
- modified path → owned by this derivation, previous owner kept in history
- unchanged → untouched

**The honest limit:** last-writer-wins is wrong for anything built twice — gcc
pass 1 then pass 2 both install `bin/gcc`. So the record keeps the full
sequence, and `why` reports the chain, not a single answer. That is more useful
anyway: "built by pass 2, which was built by pass 1, which was built by 4.7.4"
is the interesting shape.

### Command capture — the level below the graph

The derivation chain answers *which compiler built this*. The requirement is
stronger: expand any edge and see **the exact commands**, all the way down to
the seed. So a derivation records not just a recipe hash but the argv of every
command it executed.

**Two hooks already exist.** `rungs.sh` has eighteen `START JOE: THIS IS THE
COMMAND IM ABOUT TO DO` lines — a hand-rolled command log for the commands that
cost rounds. And `TRACE_APPLETS` already wraps every busybox applet in a script
that appends its own name to `/out/applets-used.txt`. Neither is complete, but
both prove the shape works inside the box.

**The driver is the right place to do it completely.** Everything in the box is
`execve`'d by the shell. A driver we write emits a structured record per exec
for free — no wrapper scripts, no `LD_PRELOAD`, no doubling the run the way
`TRACE_APPLETS` does. This is where the driver design and the provenance design
meet, and it is an argument for doing the driver before the ledger rather than
after.

Record per exec, appended to the derivation's command log:

```
seq  cwd  argv[]  exit  duration  outputs-touched
```

**Volume is tractable.** A gcc bootstrap is order 10⁴ compile commands; the
whole ladder is plausibly 10⁵–10⁶ execs. At ~200 bytes each that is tens to
hundreds of MB raw, and it compresses hard because argv is highly repetitive.
Store it per derivation, compressed, content-addressed like everything else.

**Honest limits, stated so they are not discovered:**

- **`make -j` ordering is not stable** across runs. The command *set* is
  deterministic; the sequence is not. So compare command logs as sets, not as
  sequences, or the reproducibility check fails on scheduling noise.
- **Commands inside `make` are `make`'s**, not the driver's — `make` forks its
  own children. Capturing those needs `make` to be run under the driver's
  tracing, or `make SHELL=` pointed at the driver. The latter is cheap and
  worth designing for, since almost every rung above 3.5 goes through `make`.
- **A command log is evidence, not proof.** It records what ran; the hashes
  record what came out. Both are needed and neither replaces the other.

### The queries

```
veron why /usr/bin/gcc

  /usr/bin/gcc                                          8f21c0d4e7a9
   └─ gcc 15.2.0        stage 5  glibc                  8f21c0d4e7a9
      ├─ builder: gcc 10.2.0                            c3d4a91b6e02
      │  └─ builder: gcc 4.7.4 pass 2                   e5f60b2c8d13
      │     └─ builder: gcc 4.7.4 pass 1                07184a9f2b6c
      │        └─ builder: mc-tcc                       29ab7c1e5f30
      │           └─ builder: micro-c                   3bcd8e0a4172
      │              └─ builder: stage2 pico-c          4def91a35b28
      │                 └─ builder: stage1 macro-as     5e012b46c839
      │                    └─ builder: stage0-as        6f123c57d94a
      │                       COMMITTED, round-trip verified
      ├─ source:  gcc-15.2.0.tar.xz                     6f12aa03b8e1
      │           GPL-3.0-or-later
      ├─ patches: none
      └─ inputs:  binutils 2.47      a71bc2d09e4f
                  glibc 2.44         b82cd3e10f50
                  gmp mpfr mpc       c93de4f21061
```

**Every node carries a short hash**, twelve hex characters of its output hash,
resolved by prefix the way git resolves a short commit — unambiguous or an
error, never a guess. That hash is the node's name everywhere: in the tree, in
`ledger/`, in the cache key, and as the argument to every other query.

### Expanding a node

Any line in that tree expands by its short hash. No need to name the
derivation, and no need to have run `why` first:

```
veron show 07184a9f2b6c

  gcc 4.7.4 pass 1                                      07184a9f2b6c
  stage 4  glibc   built by mc-tcc (29ab7c1e5f30)
  output   /work/out/gcc-4.7.4-pass1                    43,248,128 bytes
  source   gcc-4.7.4.tar.bz2                            1a2b3c4d5e6f
  patches  gcc47-aarch64-changed.patch                  7f8e9d0c1b2a
           gcc47-aarch64-newfiles.tar.gz                2c3b4a5968d7
  env      SOURCE_DATE_EPOCH=0  nproc=4  TZ=UTC
  commands 11,204                                       run `--commands`

veron show 07184a9f2b6c --commands

  [    1] cd /work/bld
  [    2] /work/src/gcc-4.7.4/configure --target=aarch64-unknown-linux-gnu \
            --prefix=/work/out --without-headers --with-newlib \
            CC=/work/mc-tcc                              rc=0    18.4s
  [   47] /work/mc-tcc -c -o libiberty/regex.o -I. -I../include \
            ../../src/gcc-4.7.4/libiberty/regex.c        rc=0     0.8s
  [   48] /work/mc-tcc -c -o libiberty/cplus-dem.o …     rc=0     0.4s
  …
  [11204] /work/mc-tcc -o gcc/xgcc gcc/gcc.o libbackend.a \
            libcommon.a ../libcpp/libcpp.a                rc=0     2.1s

veron show 07184a9f2b6c --commands --grep regex.c
  [   47] /work/mc-tcc -c -o libiberty/regex.o … regex.c  rc=0     0.8s

veron show 6f123c57d94a --commands
  stage0-as                                             6f123c57d94a
  COMMITTED ARTIFACT -- verified, not produced. No build commands.
  Attestation 2e7f04ba91c6 -- `veron attest stage0` for the nine steps,
  `--script` for a runnable copy of them.
```

The seed node terminates the walk, and it terminates it with an **attestation**
rather than with build commands — the correct answer for an artifact that was
verified rather than produced. That attestation is designed below.

### The seed attestation — the terminus, in one screen

The walk ends at `stage0-as` and `elf`, which were **verified rather than
produced**. That verification is the load-bearing claim of the project, so it
needs a form someone can read in one screen, check by hand, and reproduce.

**The chart shows our tools, not the host's.** The steady state is our
assembler and our disassembler doing the round trip, with nothing from binutils
or LLVM in it. Host decoders appear exactly once, historically, in the ROOT
AUDIT line — see below for why that line must stay and why it is not a
weakening.

```
veron attest stage0

  ARTIFACT   stage0-as                     6f123c57d94a    53,248 B
  SOURCE     stage0-as.s0                  a19f4b2c7e08     3,328 lines
  ARTIFACT   elf                           8c04e1d9f273    12,912 B
  SOURCE     elf.s0                        b57d20c8a4e6     1,104 lines
  ARTIFACT   disasm                        f30b6d24e5a1    21,504 B
  SOURCE     disasm.s0                     0e9a71c48b35     2,190 lines

  ROUND TRIP                    tools: stage0-as, elf, disasm  -- ours, all of them
   1  disasm     stage0-as      → asm     7a8b9c0d1e2f
   2  diff       stage0-as.s0     asm                          identical
   3  stage0-as  stage0-as.s0   → obj     3d5e7f9a1b0c
   4  elf        obj            → bin     6f123c57d94a         == ARTIFACT
   5  disasm     disasm         → asm'    5c1e8a03f6d2
   6  diff       disasm.s0        asm'                         identical
   7  stage0-as  disasm.s0      → bin'    f30b6d24e5a1         == ARTIFACT

  SELF-HOST
   8  stage0-as  stage0-as.s0   → gen1    91c7e0a3b5d2
   9  gen1       stage0-as.s0   → gen2    91c7e0a3b5d2         gen1 == gen2
  10  gen2       stage0-as.s0   → gen3    91c7e0a3b5d2         fixpoint
  11  gen1       stage1.s0      → stage1  c4a8f13e6072         == reference

  ROOT AUDIT   one-time, external, recorded              8b40e27fc1a5
  ATTESTATION                                            2e7f04ba91c6
```

Every hash on that chart is ours: our artifacts, our sources, our assembler,
our ELF writer, our disassembler. `BUDGET_PATH` is empty here in the same sense
it is empty for the ladder.

### Why the ROOT AUDIT line stays

Steps 1–11 are self-referential on purpose: our disassembler audits our
assembler, and our assembler built our disassembler. On its own that is a
Thompson circle.

`TRUST-BOUNDARY.md` explains what defuses it, and it is **the order**, not the
tools: two independent external decoders verified `stage0-as` and `elf` against
their source *first*, before anything of ours built anything. A subverted
assembler would have had to carry its subversion visibly in a disassembly that
was character-identical to the source under two decoders from different
vendors. It could not have passed that step while hiding anything, so a
disassembler it later builds is not subverted by construction.

So the root audit is **a recorded historical event, not a running dependency**:

```
veron attest stage0 --root

  ROOT AUDIT                                             8b40e27fc1a5
  performed once, against these exact artifacts:
    stage0-as                   6f123c57d94a
    elf                         8c04e1d9f273
  by two decoders sharing no code:
    binutils objdump   2.47     d4e5f6a70b19
    llvm-objdump      22.1.8    1b2c3d4e5f60
  asserting:
    both disassemblies identical to each other
    both identical to the committed source under plain diff
    the whole linked ELF reconstructed from disassembly, byte for byte
```

It is pinned to those artifact hashes. **If `stage0-as` or `elf` ever change,
the root audit no longer covers them and must be redone** — which is the
correct behaviour, and is why the line carries the artifact hashes rather than
just a date.

That is the honest structure: a one-time external audit at the root, our own
tools from there on. Presenting the chart without the root line would look
cleaner and would be a circle; presenting the host decoders as if they run
every time would understate what has been achieved. The chart shows both, with
the historical one clearly marked as historical.

### Reproducing it without trusting the tool

`--script` emits the exact commands with the artifact hashes inline, as a
runnable file depending on nothing here except the artifacts and sources it
names:

```
veron attest stage0 --script > verify-seed.sh
```

Steps 1–11 need only our three binaries, so a third party reproduces the live
chain with no toolchain at all. Redoing the ROOT AUDIT needs binutils and LLVM,
and that is the one place a reproducer supplies their own — which is the point
of it being external.

**A human never audits an encoding.** They read `stage0-as.s0`, judge whether
that program is correct, and let the steps carry the judgement to the bytes.
That is the only part of the job a human is good at; the attestation exists so
the rest is one command.

### The rest of the queries

```
veron why /usr/bin/gcc --expand=all --format=json
  every node, every command, machine-readable

veron roots
  every external input, with hash and license — the complete trust surface

veron diff <run-a> <run-b>
  the reproducibility check: first derivation whose output hash differs

veron deps 29ab7c1e5f30 --forward
  what breaks if mc-tcc changes
```

`veron why` terminating at a committed, round-trip-verified artifact is the
whole point. That is the sentence the project exists to be able to print.

### Presentation

- **Default: text tree**, as above. Readable in a terminal and in a log.
- **`--format=dot`** and **`--format=mermaid`** for rendering. Mermaid means it
  embeds directly in the README and in GitHub step summaries.
- **`--format=json`** so it is machine-readable and diffable.
- The ledger is plain files under `ledger/`, one per output hash, so the graph
  is greppable without the tool.

An HTML view is optional and last. The text tree is what gets used.

### It has to be verifiable, not merely recorded

Every hash in the graph is checkable against the artifact it names. `veron
verify --graph` re-hashes each node and each edge and reports mismatches. A
provenance graph nobody can check is the same failure mode as a committed
binary nobody can disassemble.

---

## Order of work

1. **Resolve the numbering.** Cheap, blocking, no code.
2. **Extract the build into `tools/veron`.** Behaviour-preserving; the workflow
   becomes a thin caller. Do the reporting-out-of-the-box move in the same pass.
3. **Hash inputs and outputs; write records.** Schema above, one file per
   output under `ledger/`.
4. **Capture file manifests and command logs** per stage — file manifests make
   the graph reach individual files, command logs make each edge expandable.
   The driver emits the command log natively, which is why it belongs before
   the ledger rather than after.
5. **`veron why` / `roots` / `deps`.** Queries over records that already exist.
6. **`veron verify`** — second run, diff, expected-difference list. This is
   cheap only because 2 made a second run one command.
7. **Cache keyed on input hash.** Last, because it is an optimisation and it is
   the step most likely to hide a reproducibility bug behind a cache hit.

Steps 5 and 6 are what turn the existing green run into an auditable one. Steps
1–4 are the work that makes them possible.

---

## What this does not do

It does not change the ladder, the fork, or the boot. It does not remove
`bubblewrap` or the airlock's compiler. It does not make the spike track's
suspended invariants apply retroactively — migrating that work into `stages/`
under the invariants is a separate phase, and this design is what it will
migrate *into*.
