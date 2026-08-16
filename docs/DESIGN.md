# Veron — The Official Structure

*The design for moving out of `spikes/`: one repo layout, one driver, one
artifact contract, one record schema, and the trace that the whole project
exists to make true.*

This document unifies what `ARCHITECTURE.md`, `DERIVATIONS.md`, `STAGE6.md`,
`AGENTS.md` and the skeleton READMEs already argue — and resolves the places
where they disagree. **`STAGE6.md` is canonical where they conflict.** Every
decision below names the documents it overrides.

---

## 0. The goal, stated as one testable sentence

> **`veron trace <any file in the image>` walks hash-verified edges and
> terminates at Stage 1 Self-Assembly, a file from a pinned revision of the
> Veron repo, or a declared root — and `veron build` produces that image,
> byte-identically, from the same command on a GitHub runner and on a
> bare-metal Veron machine with QEMU.**

Everything below is in service of that sentence. Two properties fall out of it
and both are load-bearing:

1. **The build system is the trace generator.** Substage records are not a report
   written after the fact; they are what the driver emits as it builds. A substage
   that cannot declare its inputs cannot run.
2. **CI is a caller, not a build system.** If the same command does not run on
   a laptop, the records are CI folklore, and the "stranger reproduces it"
   claim of STAGE6 §3 fails by construction.

---

## 1. Decisions — the five conflicts, resolved

### D1. Numbering: **1–6**, per STAGE6 §0. Counting starts at the beginning.

Canonical: `STAGE6.md` §0.
Overrides: `ARCHITECTURE.md` §2 (1–7), `AGENTS.md` §4 (0–5),
`DERIVATIONS.md` Decision 1 (recommended keeping 0–5), and the current
directory names.

The ladder is:

| stage | name | absorbs (spike directories) |
|---|---|---|
| **1** | **Self-Assembly** | `stage0-as`, `elf`, `seedas`, `stage0-arm64` — THE TRUST ROOT |
| **2** | **pico-c** | `stage1-as` + `stage2-pico-c` |
| **3** | **micro-c** | `stage3` — micro-c → tcc from Self-Assembly |
| **4** | **Toolchain and Kernel** | `stage4` — tcc → gcc 4.7 → 10 → 15 → linux → boot |
| **5** | **User Space** | `stage5` — the package set, the image, the working driver |
| **6** | **Verification and Distribution** | new — trace, kernel matrix, ISO, signing |

Why this is right, restated from STAGE6 so the reasoning travels with the
decision: a stage numbered zero reads as "before the beginning," and the
Self-Assembly stage is not before anything — **it is the first thing, and
everything else is defined in terms of it.** Counting from 1 also removes the
off-by-one that made every cross-reference between `ARCHITECTURE.md` and the
directories ambiguous. Stages 1 and 2 of the old scheme merge because
`stage1-as` exists only to make pico-c writable, has no other consumer, and
is never built alone — two substages that always run together with one purpose
are one substage with two files.

**The cost is paid once, first.** Every path, workflow name, document
cross-reference and release tag changes in a single mechanical pass, before
any substage record is written and before stage 6 adds more references to the
old names — DERIVATIONS is right that a content-addressed store keys on
stage identity, so the freeze precedes the first record; STAGE6 is right
about which scheme to freeze. The spike track's internal substage numbers
(0–16 plus 3.5/4.5, B0–B8) remain a local scheme inside stage 4, mapped in
`stages/4-toolchain-kernel/README.md`.

### D2. Vocabulary: it is **Stage 1 Self-Assembly**, never "the seed"

Overrides: `seed/README.md`, `ARCHITECTURE.md` §§1–4/7 phrasing ("seed",
"seed-as", "from-seed"), `AGENTS.md` §2, the `seed/` skeleton directory.

One name, everywhere: **Stage 1 Self-Assembly** (short form: Stage 1).
"Seed" implied something planted and left behind; Self-Assembly names what
the stage actually proves — **it assembles itself**: gen1 == gen2 == gen3,
and nothing built it but itself.

**The spike-era artifact names retire with the vocabulary.** `stage0-as`,
`stage1-as`, `stage2-pico-c` and friends were whatever the spikes happened to
be called; nothing depends on the names. The official artifacts, per stage:

```
stages/1-self-assembly/
  self-assembler-arm64.s     self-assembler-arm64   (the assembler — was stage0-as)
  elf-wrapper-arm64.s        elf-wrapper-arm64      (was elf — wraps raw code
                                                     bytes in a minimal runnable
                                                     static ELF; NOT a linker)
stages/2-pico-c/
  pico-c-assembler-arm64.s   (was stage1-as.s0 — the macro/label assembler,
                              written in the self-assembler's language; exists
                              only to make pico-c writable)
  pico-c-arm64.s             (was stage2-pico-c.s1 — the C-subset compiler,
                              ONE file, ~75 KB of stage-2 assembly)
  m2libc-shim.c  corpus/  selfhost/    (companions, names unchanged)

stages/3-micro-c/
  micro-c/                   THE EXACT micro-c SOURCE, committed in-tree,
                             already patched, exactly as the build needs it.
                             Veron source, not a pin — see below.
  tcc/                       tcc handled like any package: a pinned RELEASE
                             tarball (sources/ manifest) + ONE condensed
                             veron patch, applied normally by the build
                             system. tcc is stage 3's OUTPUT — the artifact
                             handed off to stage 4 (tcc-arm64 → x86_64-tcc +
                             musl in artifact.tar.zst).
```

The `-arm64` suffix marks sources written in per-architecture assembly
(stages 1–2 are written 3× by design); riscv64/x86_64 siblings take the same
names when written. The old `.s0`/`.s1` extensions encoded which *language
layer* a file is written in; that fact moves into the file's header comment —
the pipeline itself documents it:
`prog | pico-c-assembler | self-assembler | elf-wrapper`.

**Micro-c "done properly" means: it is Veron source.** Decided: micro-c is
NOT pin-plus-patches. `stages/3-micro-c/micro-c/` holds the **exact source,
committed in-tree, already patched, exactly as the build needs it** — one
canonical copy, no fetch, no patch step, no pin to drift against. The reason
is direction, not convenience: micro-c is slated for a **rewrite that
abandons M2-Planet** (and the rest of that lineage — M2libc, mescc-tools), so
it is adopted as first-party source now rather than maintained as a patch
series against an upstream the project is leaving. Consequences:

- **Trace:** every micro-c file is a `repo` root — *a file from a certain
  revision of the Veron repo* — the simplest root there is. No upstream
  edge, no pin record.
- **Honesty until the rewrite lands:** the directory carries a short
  `ORIGIN.md` (derived from M2-Planet `bd2fe4b` + the patch series,
  upstream's license recorded) so criterion 7 and attribution hold while any
  inherited lines remain. As the rewrite replaces them, `ORIGIN.md` shrinks;
  when nothing inherited is left, the directory is plain MIT Veron code.
- **AGENTS invariant 6 amends** from "never vendor upstream" to: *no
  undeclared copies.* Upstream is either pinned via `sources/` **or** adopted
  as a declared in-tree source with origin + license recorded — never both,
  never silently. tcc, musl, gcc and every stage-4/5 package stay pinned —
  tcc specifically as a pinned release plus **one condensed patch** applied
  at build like any other package; micro-c is the sole declared adoption.
- `spikes/reference/` (the stale vendor copy) and the patch-at-build
  plumbing retire; `stages/3-micro-c/micro-c/` is the only copy that exists.

The rename goes **all the way through, including the strings inside the
sources** (`.ascii "stage0-as: rejected: "` and its sibling become
`self-assembler:` messages; `elf: code exceeds CODEBUF_SZ` becomes
`elf-wrapper:`). Because those strings are bytes in the
committed binaries, this is a **deliberate re-baseline, in its own commit**:
the binaries are re-derived from the renamed source, re-committed, and the
verification machinery re-proves them automatically on the same push —
round-trip under two disassemblers, whole-ELF reconstruction, gen1 == gen2 ==
gen3. Every recorded hash and byte-count baseline (`LADDER-BASELINE.txt`,
handoff records, README claims) updates in that commit and nowhere else, so
the hash change is attributable to exactly the rename and nothing more. The
old names survive only inside `spikes/`, which is frozen history.

Consequences:

- The `seed/` skeleton directory is deleted, not relocated. Stage 1 **is**
  the trust root; a separate directory above the stages would imply Stage 1
  is built *with* the root rather than being it, and would put the trust
  root in two places (STAGE6 §1, kept verbatim).
- The per-arch plan `seed/README.md` designed (aarch64 reference, riscv64
  RV64I-only, x86_64 pinned encodings) survives as
  `stages/1-self-assembly/<arch>/` when those sources are written.
- Claims rephrase: "from-seed" → "self-assembled"; "the seed assembler" →
  "the Stage 1 assembler"; the trace root type is `self-assembly` (§6.1).
- A repo-wide grep for `seed` (outside `spikes/`, which is frozen history)
  is part of the rename pass and a lint rule after it.

### D3. The committed-binary invariant is rewritten, not violated

Overrides: `AGENTS.md` §2 invariant 1 ("No committed binaries. Ever.").
Confirms: `TRUST-BOUNDARY.md`, `README.md`, spike practice.

The repo's strongest result — `self-assembler-arm64` and `elf-wrapper-arm64`
(the spike's `stage0-as` and `elf`) as committed binaries,
re-derived from source on every push under **two independent disassemblers**
with the whole ELF reconstructed byte-for-byte — directly contradicts the
written invariant. The practice is stronger than the rule, so the rule
changes:

> **No unverified binaries.** A binary may be committed only if (a) it is a
> Stage 1 Self-Assembly artifact whose source round-trips under two
> independent disassemblers on every push, or (b) it is a declared toolbox
> exception (`toolbox/README.md`) that no build path may read — deleting it
> must leave every workflow green. Everything else is derived.

### D4. One record schema. `substages.toml` **is** the ledger.

Overrides: `ledger/README.md` (`<output-hash>.json`), the JSON schema in
`DERIVATIONS.md` — in *format* only; every field survives.

There are currently two competing record designs: DERIVATIONS' JSON
derivation record and STAGE6's TOML substage record. Two schemas for one fact is
how the numbering dispute happened. Decision: **one TOML record per substage**,
because STAGE6's requirement is the binding one — *"readable without the
tool: one fact per line, so `grep` and a shell loop can follow the chain."*
The audience for provenance is exactly the person who does not trust our
parser.

The unified record is STAGE6's substage record carrying DERIVATIONS' fields:

```toml
[[substage]]
id      = "4/11.4/gcc-15.2.0"
stage   = 4
arch    = "x86_64"                 # TARGET arch — what the output runs on
substage_arch = "x86_64"               # the ISA the substage's tools execute as
                                   # (stages 1–3 of a x86_64 target: "aarch64")
flavor  = "glibc"                  # trunk substages (stages 1–3): "trunk"
commit  = "<repo sha that built this>"   # ADVISORY — see below: identity
                                          # is content hashes, never the commit
host_arch = "x86_64"               # the machine that ran it
emulated  = false                  # true when substage_arch != host_arch (qemu-user)

[[substage.input]]
role   = "source"
name   = "gcc-15.2.0.tar.xz"
sha256 = "…"
bytes  = 90923412                  # exact size — a cheap second falsifier
url    = "…"                       # from sources/ manifest
spdx   = "GPL-3.0-or-later"

[[substage.input]]
role   = "builder"
ref    = "4/9/gcc-10.2.0"          # names another substage…
sha256 = "…"                       # …and repeats its output hash. Falsifiable.

[[substage.input]]
role   = "recipe"
path   = "stages/4-toolchain-kernel/substages/11.4-gcc-15.sh"
sha256 = "…"                       # a repo file at `commit` — a trace root

[[substage.input]]
role   = "patch"
path   = "stages/4-toolchain-kernel/patches/0001-….patch"
sha256 = "…"

[substage.env]
SOURCE_DATE_EPOCH = "0"
nproc = 4
TZ = "UTC"
kernel = "…"                       # the leaky inputs DERIVATIONS names

[[substage.output]]
path   = "usr/bin/gcc"
sha256 = "…"
bytes  = 2947903
mode   = "0755"

[[substage.step]]                  # THE RECIPE: literal argv, no shell.
name   = "configure"               # stdin/stdout are explicit fields when a
run    = ["../gcc-15.2.0/configure", "--prefix=/usr", "…"]   # pipeline needs
                                   # them; $W is the substage scratch dir.
[[substage.step]]
name   = "build"
run    = ["make", "-j$J"]
```

**Substages vs steps: one dial, not two ontologies.** A **substage** is the
smallest unit whose outputs are *contracts* — hashed, recorded, cacheable,
consumable by another substage, a cutoff point, a trace node, replayable. A
**step** is one argv *inside* a substage, sharing its scratch, producing
intermediates that are nobody's contract. The schema deliberately lets the
dial turn all the way: a substage may have one step, and any step whose
output deserves a contract is **promoted** to a substage of its own. What
keeps steps from dissolving entirely is economics, not ontology: zlib's
unpack/configure/build steps share one scratch tree, and hashing a half-built
tree between them buys nothing — no consumer, no cache reuse, no cutoff
(configure changed means build reruns anyway). Where an intermediate IS
meaningful — stage 1's mechanical translation, say — promote it and it gets
a record. The rule in one line: *substage boundaries exist exactly where
hashing pays; steps exist where it doesn't.*

**Every substage records its recipe as `[[substage.step]]` — the literal
argv that turn the inputs into the outputs**, executed in order with no
shell, stdin/stdout as explicit fields ($W = scratch). This is the
plan-is-the-contract rule as ledger data: `veron plan` prints exactly these
steps before running, `veron build` executes exactly them, and the record is
the executed plan — so `veron show <substage>` answers "what command made
this byte" for any node, and a record can be **replayed**: run its argv,
require its shas. Stage 1's record states the project's founding loop as
data: the binary with sha `e97e2969…` runs the recorded command whose
output is the binary with sha `e97e2969…` — replay-verified.

**Every input and output records `sha256`, exact `bytes`, and `mode`.** Size
is a cheap second falsifier a human can check with `ls -l`; mode is part of
the artifact contract, not decoration — and nowhere more than at Stage 1,
where the committed binaries run on checkout only because git preserves
0755, and the elf-wrapper *emits* 0755 by construction. Records are TOML
**array-of-tables** (`[[substage]]` with nested `[[substage.input]]` /
`[[substage.output]]`), because repeating a plain `[substage]` table is
invalid TOML — caught by parsing the first real record, not by review.

The seven audit criteria map onto this record: provenance and license = the
`source` inputs; hermeticity = the complete input list plus the SEAL result;
reviewed delta = `recipe` + `patch` inputs (repo files, diffable by commit);
reproducibility = a `repro/` sidecar of second-run attestations; behavioral
verification and recorded deferral come from the recipe's `[declared]` block,
which stage 5's `recipe.toml` already carries. `ledger/` stops being a
hand-shaped directory: it is **generated** — the concatenation of every
stage's `substages.toml` plus attestations — and stage 6 signs it. The
`ledger/README.md` seven-criteria spec moves to `docs/AUDIT.md` as the
*mapping*, not a second format.

**Content-addressed first, commit-annotated second.** A repo-file input's
identity is its `sha256`, not the commit: any revision containing that blob
satisfies the record, `trace --verify` walks pure hashes and never touches
git (which is also why the live image can verify itself with no repo
present), and derivation identity / cache keys are functions of input hashes
only — so unrelated commits invalidate nothing, and a rebuild happens exactly
when an input's bytes actually change. The `commit` field is kept as a
one-line *human* pointer: it names a checkout guaranteed to contain every
input at its recorded hash, making reproduction `git checkout <commit> &&
veron build` instead of assembling files hash-by-hash. It is checkable but
nothing verifies through it. And because rarely-changing is not
never-changing, the per-file hashes are recorded on every run regardless —
when a "stable" file does change, the records say so byte-precisely.

`short` (twelve-hex prefix naming) and `veron why`/`veron show` from
DERIVATIONS survive unchanged as driver features over these records.

### D5. `lib/` dissolves into the driver

Overrides: `lib/README.md` as a directory plan.
Confirms: its own decision text ("implement the model, not Nix").

`lib/` was designed when the engine was hypothetical. The engine now exists —
it is the `veron` driver, and DERIVATIONS Decision 2 already ruled out
adopting Nix. derivation/sandbox/cache are driver modules, not a sibling
directory. The Nix cross-consumption note (`veron export --nix`, Nix runs
alongside, never underneath) moves to `docs/DERIVATIONS.md`.

---

## 2. The repository, official form

Per STAGE6 §1, extended with what STAGE6 left implicit (sources, flavors,
the local store, the generated ledger):

```
veron/
├── README.md                      # status + claims, pointing into docs/
├── LICENSE
├── AGENTS.md                      # process rules, updated invariants (D3)
│
├── stages/
│   ├── 1-self-assembly/           # THE TRUST ROOT
│   │   ├── self-assembler-arm64.s # + committed verified binary. Nothing
│   │   ├── elf-wrapper-arm64.s     # above exists without these; nothing
│   │   │                          # built them but themselves.
│   │   ├── roundtrip.sh           # assemble → 2× disassemble → diff → rebuild
│   │   └── AUDIT.md               # (riscv64/x86_64 siblings when written)
│   ├── 2-pico-c/
│   │   ├── pico-c-assembler-arm64.s   # macro/label assembler (1 file)
│   │   ├── pico-c-arm64.s             # the C-subset compiler (1 file, ~75 KB)
│   │   └── m2libc-shim.c  corpus/  selfhost/
│   ├── 3-micro-c/
│   │   ├── micro-c/               # THE exact source, in-tree, already patched
│   │   │                          # (Veron source; ORIGIN.md until the rewrite)
│   │   └── tcc/                   # pinned release + ONE condensed veron patch,
│   │                              # applied normally; tcc is the stage-3 OUTPUT,
│   │                              # incl. the cross to a native x86_64 tcc
│   ├── 4-toolchain-kernel/
│   │   ├── substages/             # one script per substage, extracted from YAML
│   │   ├── patches/
│   │   └── README.md              # substage map incl. the spike-era numbering
│   ├── 5-user-space/              # ← redone from spikes/stage5 (§7.0)
│   │   ├── packages/  packages-amd64/   (overlay model unchanged)
│   │   ├── policy-local/  boot/  guest/
│   │   └── README.md
│   └── 6-verification-distribution/
│       ├── kernels/               # minimal-qemu / reference-laptop / generic
│       └── installer/
│
├── tools/
│   ├── veron                      # THE driver — stages 1..6, not just 5.
│   │                              # `veron build --stage N --arch A` is the
│   │                              # whole interface, CI and laptop alike.
│   ├── trace/                     # veron-trace, C, ships in the image
│   └── …                          # small helpers (mirror.py, lint-workflows)
│
├── policy/                        # repo-wide: pins, mirrors, keyring, budget,
│                                  # expected-differences (stage 5's move up)
├── sources/                       # pinned upstream manifests (unchanged role)
├── flavors/                       # musl.toml / glibc.toml — parameters, not copies
│
├── in/                            # UNTRACKED. fetched pinned sources — the
│                                  # only directory the network ever touches.
│                                  # Content-verified against sources/ on
│                                  # every use, shared across stages & arches.
├── build/                         # UNTRACKED. scratch — where the sealed
│   └── <stage>/<arch>/            # boxes actually run. Disposable; `veron
│                                  # clean` removes it without loss.
├── out/                           # UNTRACKED. local artifact store — the
│   └── <stage>/<arch>/            # laptop's equivalent of a GH release
│
├── ledger/                        # GENERATED (D4): concatenated substage records
│                                  # + repro attestations; signed at stage 6
│
├── docs/
│   ├── ARCHITECTURE.md            # rewritten to D1–D5
│   ├── TRUST-BOUNDARY.md  DERIVATIONS.md  AUDIT.md
│   ├── stages/                    # STAGE5.md, STAGE6.md, roadmaps
│   └── experiments/               # findings from retired probe workflows
│
├── spikes/                        # LIVE during migration (§7.0) — untouched,
│                                  # its workflows running as today. Freezes
│                                  # only after per-stage cutover completes.
│
└── .github/workflows/             # thin callers — see §5
```

(`in/`, `build/` and `out/` are gitignored as a set — the working tree's
derived state lives only in those three, so `git status` staying clean after
a full ladder build is itself a check that nothing leaked into the repo.)

What each official component is redone from, in one line each — spikes are
the proof and the oracle (§7.0), never edited; adopted content is taken at a
pinned commit:

- **`spikes/stage5` → `stages/5-user-space`** — STAGE6 §1's argument stands:
  144 pinned packages, a plan gate and a published image are not a spike.
- **`spikes/stage0-as` + `spikes/elf` (+ `seedas`, `stage0-arm64`) →
  `stages/1-self-assembly`** as `self-assembler-arm64` + `elf-wrapper-arm64`
  (D2) — the trust root is the first stage, not an experiment beside the
  ladder.
- **`spikes/stage1-as` + `spikes/stage2-pico-c` → `stages/2-pico-c`** as
  `pico-c-assembler-arm64.s` + `pico-c-arm64.s` — the D1 merge, physically.
- **`spikes/stage3` → `stages/3-micro-c`** as `micro-c/` (the exact patched
  source, adopted in-tree) and `tcc/`, with `spikes/reference/` and the
  patch-at-build plumbing retired (D2).
- **the driver → `tools/veron`, stage-generic** — every stage needs it;
  recipes, plans, manifests and substage records are how the project records
  what it did, not a stage-5 idea (STAGE6 §1).
- **stage-5 `policy/` → repo `policy/`** — pins, keyring and expected
  differences are project facts, not stage-5 facts. (Anything genuinely
  stage-local stays beside the stage as `policy-local/`.)
- **`seed/`, `lib/`, `ledger/`-as-authored, `stages/0-*` skeletons** —
  deleted or regenerated per D2/D4/D5.
- **`spikes/` stays, live and untouched** (§7.0) — actively used during the
  whole migration; it freezes per-stage cutover, and even then stays in
  place: history is valuable and moving it breaks every link in PROGRESS.md.

---

## 3. The driver: one program, six stages, two homes

The driver's own header is the design: *"ONE SCRIPT, TWO ENVIRONMENTS… THE
PLAN IS THE CONTRACT."* The work is generalizing what stage 5 proved.

### 3.1 Interface

```
veron plan   --stage N --arch A          # literal argv, printed before run
veron fetch  --stage N                   # pinned sources into in/, verified
veron build  --stage N --arch A          # execute the plan in the sealed box
veron build  --from 1 --to 6 --arch A    # the whole ladder
veron verify --stage N --arch A          # second run + byte diff → repro/
veron trace  <path-in-image> | --forward <substage> | --verify
veron why    <file>                      # provenance query over records
veron doctor [--stage N --arch A]        # host contract check (see 3.3/3.4)
veron selftest / sources / installs …    # stage-5 verbs, now stage-scoped
```

### 3.2 Stage backends, not stage drivers

The driver grows a small backend per stage; the plan/execute/record spine is
shared. Stage 5's backend is the existing recipe walker, unchanged. Stages
1–4's backends are thin: their plans are the substage scripts extracted from YAML
(§4), in order, inside the box. **Extract, do not rewrite** — each substage script
runs exactly the commands the YAML runs today, proven by a before/after CI
run compared byte for byte (STAGE6 §3's rule, kept verbatim).

Everything the driver runs *inside* the box is a pure function; everything
that reports, checks, fetches, seals and records runs *outside*. This is
DERIVATIONS Decision 3's measured point — the in-box scripts are four-to-one
reporting against building — applied as the extraction rule: what stays
inside is exactly the function being recorded.

### 3.3 The two homes

**GitHub runner.** The workflow is: checkout → airlock deps → `veron build`.
`lint-workflows.py` grows one rule: any `run:` step in a stage workflow other
than checkout / airlock / driver invocation / upload fails lint. That is the
regression guard the driver's header asks for, made mechanical.

**Bare-metal Veron + QEMU.** Same command. The differences are inputs, not
code paths, and `veron doctor` checks them before anything runs:

```
python3 ≥3.11, git, bubblewrap (unprivileged userns ON), busybox-static,
qemu-user-static     (only when a substage's arch ≠ host arch — see 3.4),
qemu-system-<arch>   (boot verification), e2fsprogs, ~40 GB disk
```

**The local working tree is three untracked directories, one per phase of
the derivation lifecycle** — and CI uses the identical layout on the runner:

```
in/      FETCH.   `veron fetch` resolves sources/ manifests (or the mirror in
         policy/) and downloads here. The ONLY networked phase. Files are
         named and verified by their pinned sha256 — a file in in/ is never
         trusted by path, only by hash re-checked at use, which is what makes
         the cache safe to share across stages, arches and flavors, and safe
         to pre-seed by hand for a fully offline build.

build/   BUILD.   `veron build` assembles the sealed box here: in/ inputs and
         the previous stage's artifact mounted read-only by hash, no network,
         scratch writable inside. build/<stage>/<arch>/ is disposable by
         definition — nothing in it is a product, and `veron clean` deletes
         it. If removing build/ loses anything, that thing was written to the
         wrong directory and it is a bug.

out/     PUBLISH. only after SEAL passes and the manifest is written does the
         driver pack artifact.tar.zst + ARTIFACT-SHA256 + substages.toml into
         out/<stage>/<arch>/. out/ holds contracts, never intermediates.
```

fetch is separated from build precisely so hermeticity is structural: the box
never has the network because everything it needs already sits in in/,
verified. A populated in/ is also the offline story — STAGE6 §3's "network
for the pinned sources" is the *only* network the whole ladder uses.

Where CI downloads `4/latest-<arch>` from a release, the laptop reads
`out/4/<arch>/`; where CI uploads, the laptop writes there. One resolver:
*local store first, then release, verify `ARTIFACT-SHA256` either way.* And
emulation is recorded: a substage built under qemu-user carries `emulated = true`
in its record, because native-vs-emulated is exactly the kind of silently
differing input the reproducibility comparisons must be able to see.

Self-hosting closes the loop later: a Veron image carries python3 as
`build_only` today, so "Veron builds Veron" is a stage-6-era milestone the
structure permits but does not gate on.

### 3.4 The architecture model

Three arch facts, kept separate because conflating them is where per-arch
designs rot:

- **`arch`** — the TARGET: what the artifact runs on. This is the namespace
  everything is keyed by: `out/<stage>/<arch>/`, releases `<N>/latest-<arch>`,
  cache keys, substage ids. Stage 3's x86_64 artifact is *produced by* aarch64
  substages but it IS an x86_64 artifact — it lives under `3/x86_64`.
- **`substage_arch`** — the ISA the substage's tools execute as. Today, stages 1–3
  are aarch64 substages for **every** target, because the only self-assembler is
  ARM64; the target arch takes over at the cross.
- **`host_arch`** — the machine that actually ran it. When
  `substage_arch != host_arch` the driver runs the substage under `qemu-user` and
  records `emulated = true`. Emulation is a *declared input*, never a hidden
  one — the repo has already measured that native and emulated execution can
  disagree (tcc-arm64 once ran under qemu and segfaulted natively), so repro
  attestations compare native-vs-emulated runs as an explicit pair, not as
  interchangeable.

**Each target arch declares its origin — how its ladder reaches Stage 1:**

```
policy/arches.toml
[aarch64]  origin = "native"               # stages 1–3 native from self-assembler-arm64
[x86_64]   origin = "cross-from-aarch64"   # aarch64 substages 1–3, cross at 3/2:
                                           # tcc-arm64 → x86_64-tcc → native tcc + musl
[riscv64]  origin = "cross-from-aarch64"   # same shape, riscv64 cross substage
```

The origin decides which substages exist for that target and what the trace
prints at the bottom — the cross NOTE (STAGE6 §2.1) is generated from this
declaration, never hand-written. **Writing `self-assembler-x86_64.s` or
`self-assembler-riscv64.s` later is a one-line origin flip** — `origin =
"native"` — which swaps the cross substages for native stage 1–3 substages. It is a
new lineage, not an edit: artifacts under the new origin have different substage
graphs and different roots (their trace terminates in the new arch's own
self-assembler), so the flip is a declared, versioned event in the ledger,
and both lineages can coexist while the new one is proven against the old
(same tcc bytes out is the acceptance test).

**Input resolution is target-keyed and host-blind.** `veron build --stage N
--arch A` needs stage N−1's artifact *for target A*, and resolves it the
same way everywhere: `out/<N-1>/<A>/` first, then the `<N-1>/latest-<A>`
release, verifying `ARTIFACT-SHA256` either way. Only if neither exists does
building stage N−1 locally come into play — and only *that* is where the
host's QEMU needs appear.

Worked example — **amd64 laptop, stage 4**:

```
$ veron build --stage 4 --arch x86_64
  needs 3/x86_64 → found out/3/x86_64/ (or downloads 3/latest-x86_64, verified)
  every stage-4 substage: substage_arch = x86_64 = host_arch → NATIVE, no qemu-user
  boot verification: qemu-system-x86_64 (always virtualized in CI; optional
  native boot on matching bare metal, recorded as such)
```

No emulation anywhere on the build path — stage 4 for x86_64 is native on
amd64 by construction. Only if `3/x86_64` cannot be resolved does the driver
offer `veron build --from 1 --to 3 --arch x86_64`, and `veron doctor --stage
1-3 --arch x86_64` then requires `qemu-user-static`, because those substages are
aarch64 until the x86_64 origin flips to native. The same laptop building
**target aarch64** stage 4 is the mirror image: every substage emulated,
possible but slow, honestly recorded — which is why CI keeps an arm64 runner
and why bare-metal aarch64 hardware stays the reference for that target.

---

## 4. Hooking stage 5 to stages 1–4: the artifact contract

Stage 4 → 5 already works — the `stage4/latest` release with
`sysroot.tar.zst` + `SYSROOT-SHA256` + `PROVENANCE`, verified on download.
**The design is: that seam, at every seam.** Each stage publishes,
identically (STAGE6's contract, adopted whole):

```
releases/<N>/latest-<arch>/          — and locally: out/<N>/<arch>/
  artifact.tar.zst        what stage N+1 consumes
  ARTIFACT-SHA256
  substages.toml              every substage record this stage produced (D4 schema)
```

- The tarball is deterministically packed (sorted, mtime 0, uid/gid 0, no
  compression timestamp) — the treatment `sysroot.tar.zst` already gets.
- `substages.toml` travels **with** the artifact so the trace never needs to
  correlate a tarball with a record published elsewhere.
- STAGE6's open question — chain vs. individual dispatch — resolves to:
  **the contract is load-bearing; every green workflow run publishes at its
  output boundary,** chained or not. Publishing is seconds against hours of
  build, it is what lets stage 5 re-run against yesterday's stage 4 (how the
  work actually proceeds), and an unpublished consumed artifact is a hole in
  the ledger. Stages 1–3 share one boundary and one release (§5);
  `chain-<arch>.yml` is *only* a convenience caller with zero logic of its
  own.
- The stage-3 handoff facts (`built-by tcc-arm64 -> x86_64-tcc -> tcc-x86_64`,
  the musl line) stop being log output and become substage records in stage 3's
  `substages.toml` — STAGE6 §2.1 already observed the content is correct and
  only the destination is wrong.

### 4.1 Invalidation: the cascade, and the early cutoff

Every substage has a **plan key**, computed before anything builds: the hash
of its declared inputs — source hashes, recipe hash, patch hashes, env, and
its **builder's output hash**. That last term is what makes staleness
structural rather than policed, in both directions:

- **Never stale.** Change stage 2's source → its key changes → it rebuilds →
  if pico-c's bytes change, stage 3's builder input changed → its key
  changes → and so on to the image. The cascade cannot be skipped, because
  downstream keys are *functions of* upstream outputs, and the resolver
  matches artifacts by key, never by "latest." If stage 2 changed, everything
  after it that depends on the change rebuilds, absolutely.
- **Never wasteful — the early cutoff.** If the stage-2 change produces a
  byte-identical pico-c (a comment, a rename that assembles to the same
  bytes), stage 3's inputs are unchanged, its key matches, and **the cascade
  stops with proof**. Most build systems cannot claim this honestly because
  their builds are not deterministic; Veron's reproducibility is what makes
  the cutoff sound instead of hopeful. The precise rule: *rebuild what
  changed, and everything downstream exactly as far as the bytes actually
  changed* — which degrades to "everything after" whenever the change is
  real.

**The cutoff works through the trunk, at both granularities.** Inside the
sealed box it is per-substage: a self-assembler change rebuilds pico-c, but
if pico-c's output bytes are identical, micro-c's inputs match and the
cascade stops there — or ripples on and converges later. At the consumption
boundary it is the tcc hash: stage 4 keys on tcc's bytes, not on "the trunk
ran," so a stage-1 change that re-runs the whole trunk yet converges to a
byte-identical tcc rebuilds **nothing** in stages 4–6. Two rules keep this
honest:

- **The trunk always runs to tcc when anything in 1–3 changed** — the bytes
  to compare must be produced before anything can be skipped. The release
  then updates `substages.toml` (the new stage-1 hashes are real and belong
  in the ledger) while the artifact hash stays the same, so downstream keys
  still match.
- **Cutoff skips rebuilds, never verification.** Identical tcc bytes prove
  downstream needn't rebuild; they do not prove the change was *good* — the
  repo's own finding, "a fixpoint proves a compiler is stable, not correct."
  The trunk's gates (round-trip, gen1 == gen2 == gen3, the case suites) run
  on every trunk build regardless.

This is not a new mechanism: proving things by byte convergence is already
the project's signature move (gen2 == gen3 == gen4, landing on upstream's
bytes, the origin-flip acceptance test). Early cutoff is the same fact put
to work as scheduling.

`veron plan` is the status view of this: compare desired keys against `out/`
and the releases, print the stale frontier and **which input hash moved**,
and `veron build` executes exactly that frontier. `chain-<arch>.yml` uses
the same comparison to reuse `3/latest-<arch>` untouched when the trunk's
keys still match — stage 5's per-package checkpoint system already behaves
this way, and this generalizes it to the whole ladder.

---

## 5. Workflows: the list is the ladder

Names per STAGE6's rule — what they build, for what, so an alphabetical list
of runs reads as the ladder — with the constraint STAGE6 names: stages 1–3
are coupled, fast, and must run on aarch64, so they share one job.

```
.github/workflows/
  1-self-assembly-verify.yml      trust-root gate, every push, fast: the
                                  committed binaries re-derived and round-
                                  tripped under two independent disassemblers
                                  (today's stage0-selfhost). Verifies, never
                                  publishes — stage 1's artifacts are IN the
                                  repo; the repo is their release.
  1-3-trunk-<arch>.yml            ONE sealed box, aarch64: self-assembly →
                                  pico-c → micro-c → tcc (→ the cross for
                                  non-aarch64 targets). Publishes ONE release:
                                  3/latest-<arch>.
  4-toolchain-kernel-<arch>.yml   native: twenty substages, three kernels
                                  → 4/latest-<arch>
  5-user-space-<arch>.yml         native: the package set, the image
                                  → 5/latest-<arch>
  6-release-<arch>.yml            native: trace --verify, ISOs, signing
                                  → the signed release
  chain-<arch>.yml                calls trunk → 4 → 5 → 6 in order, no logic
  lint.yml
```

### Publish at consumption boundaries, not stage boundaries

Stages 1–3 do NOT publish separately, and this is a rule, not an
optimization: **a release exists where something outside the box consumes
it.** Nothing external ever consumes a bare pico-c binary or a stage-2
intermediate — the trunk's stages hand off to each other inside one sealed
box, and the first externally-consumed output is tcc. So the trunk is one
job and one release, `3/latest-<arch>`, whose artifact is exactly what stage
4 needs: tcc — plus musl for cross targets, since the non-aarch64 handoff is
`tcc-arm64 → <arch>-tcc → tcc + musl`. **The whole trunk exists to yield one
thing: a tcc built by no host tool other than the bootstrap system itself.**
The release should look like that fact.

Splitting 1/2/3 into separate releases would force one of two bad shapes:
three separately-sealed boxes (which `lib/README.md` already rejects as "a
different build" from the sealed-once box), or intermediate tarballs nothing
downloads, padding the release list with noise.

**Traceability loses nothing**, because record granularity and release
granularity were only ever coupled by accident: the single
`substages.toml` in `3/latest-<arch>` carries every internal record — stage
1's self-assembly proof, every pico-c and micro-c substage, every builder
edge down to `self-assembler [1]`. Records travel per substage; tarballs
travel per consumer.

This refines §4's contract rule to its correct form: **every workflow
publishes at its output boundary.** Stage boundaries inside one box are
record boundaries, not release boundaries — and the resolver stays uniform
because the trunk's release is stage-keyed (`3/latest-<arch>`), so "stage 4
needs 3/<arch>" works identically whether stage 3 was published by a
dedicated job or by the trunk.

("Trunk" is already project vocabulary — the flavor-blind stages before the
libc fork — and it is exactly what the 1–3 job builds.)

### Substages are units of the ledger, not of the YAML

**Substages do NOT need to correspond to distinct workflow steps — and mostly
must not.** A substage is defined by the *record*: one set of declared
inputs, one builder edge, one output set, evaluated hermetically and written
as one `[substage]` entry. Workflow steps are an orchestration detail of one
of the driver's two homes; the laptop has no "steps" at all, so tying
substage identity to GitHub's step granularity would hang the ledger's
structure on the UI of one runner. The dependency points the other way: the
driver defines the substages, and workflows merely call the driver.

Two concrete reasons the granularities must be free to differ:

- **Stages 1–3 run in one sealed box in one job** — dozens of substages,
  one workflow step. Splitting the job to match would add artifact
  round-trips for minutes of work *and* turn the sealed-once box into many
  separately-sealed boxes, which the project has already rejected as "a
  different build" (`lib/README.md`'s argument against per-derivation
  sandbox entries).
- **One substage often spans several YAML steps** — fetch, build, verify,
  report. The reporting steps are not substages; only the pure function in
  the middle is, and the record marks exactly it.

What alignment IS worth having: workflow **jobs** align with **stages**
(that is the artifact-contract boundary), and long stages may group
substages into a few named steps purely for log legibility (`veron build
--stage 4 --sub 1..9`, `--sub 10..16`), including to split around the
6-hour hosted-runner cap. Grouping changes where logs land and nothing
else: the driver emits one record per substage regardless of how the steps
are cut, and re-cutting the steps must never change a single byte of
`substages.toml` — that invariance is itself a CI check.

Every stage workflow is both `workflow_call` and `workflow_dispatch`;
dispatched alone it resolves inputs from the previous stage's release, called
from `chain` it takes them in-run — same script, different input source.

**The other ~54 workflows retire.** Each probe/watchpoint that proved
something gets its finding written into `docs/experiments/<name>.md` (what
was asked, what was learned, link to the last run), then the file moves to
`.github/workflows-archive/`. `spike`, `probe`, `complete` and `watchpoint`
all leave the live names — they described a moment in the project's history,
not what the job does.

---

## 6. `veron trace` — total traceability, specified

### 6.1 The four roots

Every file in the image must terminate, over hash-verified edges, at exactly
one of:

| root | terminates as | example |
|---|---|---|
| **`self-assembly`** | Stage 1: source + committed verified binary at repo `commit` | `self-assembler-arm64.s` — 3,720 bytes, assembles itself, gen1 == gen2 == gen3 |
| **`repo`** | a repo file identified by sha256 (`commit` = advisory pointer) | micro-c's source, a recipe, a patch, `veron-boot.c`, a wallpaper |
| **`upstream`** | url + sha256 + signature, named by a `sources/` manifest that is itself a repo file at `commit` | `gcc-15.2.0.tar.xz` |
| **`opaque`** | declared, pinned, licensed, **excluded from the built-from-source claim** | firmware blobs in the generic kernel |

This is the goal made checkable: *"Stage 1 Self-Assembly, or some file from a
certain revision of the Veron repo"* — with the two honest extensions the
project already lives with. `upstream` is a repo root once removed (the pin
is a repo file; the bytes are not), and `opaque` is TRUST-BOUNDARY
discipline: the generic kernel's firmware is the one place the claim cannot
hold, so the trace says so instead of hiding it — the same posture as
printing the aarch64→x86_64 cross rather than omitting it.

### 6.2 Edges and verification

Two edge kinds, both already in the D4 record:

- **built-from**: output file → the substage whose `[[substage.output]]` lists its hash →
  that substage's `source`/`recipe`/`patch` inputs (roots or repo files).
- **built-by**: substage → the `builder` substage, whose recorded hash must be
  byte-identical to what that substage actually produced. The duplication is the
  falsifiable claim; `veron trace --verify` walks **every** edge in the
  ledger and fails on any mismatch, and runs in stage 6's workflow so the
  release gate *is* the trace check.

The chain a user sees is STAGE6 §2.1's, under the canonical numbers:

```
gcc 15.2.0   [4/11.4]  built with gcc 10.2.0 →
gcc 10.2.0   [4/9]     built with gcc 4.7.4  →
gcc 4.7.4    [4/7]     built with tcc        →
tcc          [3/2]     built with micro-c    →
micro-c      [3/1]     built with pico-c     →
pico-c       [2/2]     assembled with pico-c-assembler →
pico-c-assembler [2/1] assembled with self-assembler →
self-assembler   [1/1] assembles itself: gen1 == gen2 == gen3
  source  self-assembler-arm64.s  sha256 3e2ba52c…  48,563 bytes  mode 0644
  binary  self-assembler-arm64    sha256 e97e2969…   3,730 bytes  mode 0755
ROOT REACHED — every edge hash-verified, sizes and modes checked.
NOTE: this x86_64 chain crosses architectures at 3/2.
      (generated from the arch's declared origin — printed, never hidden)
```

`veron trace --forward <substage>` inverts the graph — "1,412 files descend from
this compiler" — which is the post-CVE question and costs nothing extra once
records exist.

### 6.3 The ledger ships in the image — the live system traces itself

How the proofs travel and where they land, end to end:

1. **Each release carries only its own records.** `3/latest-<arch>`'s
   `substages.toml` is the bottom of the graph: the self-assembly proof
   (round-trip attestations of the committed binaries at repo `commit`,
   gen1 == gen2 == gen3), every pico-c and micro-c substage, tcc's output
   hashes, and the cross edge for non-aarch64 targets.
2. **Stages chain by falsifiable reference, not inclusion.** Stage 4's first
   substage names `builder = 3/…/tcc` and repeats tcc's hash — which must be
   byte-identical to what stage 3's records published. Same at every seam.
   The chain IS the hashes agreeing.
3. **Stage 6 merges and seals.** It concatenates the `substages.toml` of
   1–3, 4 and 5 into the ledger, runs `trace --verify` over every edge (the
   release gate), signs it — and **bakes the signed ledger into the image**.
4. **Therefore the booted system traces itself, offline.** `veron-trace
   <file>` on the live machine walks from the file's hash through the
   on-device ledger down to `self-assembler [1]` with no network, no GitHub,
   no Python. Releases are how the proofs travel during the build; the image
   is where they live.

### 6.4 Two implementations, deliberately

The Python driver builds and queries the trace. The **small C tracer**
(`tools/trace/`, a few hundred lines against libgcrypt) ships in the image,
because python is `build_only` and the device must verify itself. The records
being greppable TOML is what makes a few hundred lines enough — and is the
third, tool-free implementation: a stranger with `grep` and `sha256sum` can
follow any chain by hand.

---

**Logging law (see AGENTS.md invariant 9): CI never truncates logs; diagnostics show everything; long steps stream live; runaway output is a producer bug, not a suppression target.**

## 7. Order of work (each step leaves the repo green)

### 7.0 The prime directive: redo properly; spikes stay live and untouched

`spikes/` and its workflows are under active use and development — and the
official tree is not a relocation of them anyway. **Spikes were the proof,
built with invariants suspended; the official tree is the same system redone
properly, with the invariants ON** — which is exactly what the repo's own
rule always required ("do not copy spike code into `stages/` without
re-applying the invariants"). The split of what "redo" means:

- **Structure is redone**: names, numbering, layout, the record schema, the
  driver's stage-generality, the workflows — all built fresh to this design.
- **Proven build content is adopted deliberately**: the exact substage
  command sequences, pins, patches, micro-c's exact source, stage 5's
  recipes and driver logic. These are adopted at a pinned commit because
  they are *proven* — rewriting working bootstrap commands for beauty is how
  a chain that boots stops booting — and every adoption is verified against
  the live spike as oracle.

Until per-stage cutover:

- **Nothing in `spikes/**` is renamed, moved, or edited** — not sources, not
  committed binaries, not READMEs, not PROGRESS.md links. The spike originals
  stay live and authoritative for the spike track.
- **CI is path-partitioned.** Existing workflows keep their `spikes/**`
  triggers and run exactly as today; new workflows trigger on `stages/**`
  (and `tools/`, `policy/`) only. Neither tree can fire the other's jobs.
- **Release namespaces are disjoint.** Spike workflows keep publishing
  `stage4/latest` and friends; the official system publishes
  `3/latest-<arch>`, `4/latest-<arch>`, … No tag is shared.
- **The re-baseline is official-tree-only.** `stages/1-self-assembly/` gets
  renamed sources, its own re-derived committed binaries and its own verify
  workflow; `spikes/stage0-as` and its selfhost workflow are untouched. Two
  verified binary pairs coexist, each guarding its own tree.
- **Spikes are the oracle.** "Extracted, proven byte-identical" means the
  official stage-N workflow's output is diffed against the *live spike
  workflow's* output — read-only use of spikes as the reference
  implementation, a stronger proof than before/after on one mutated tree.
- **The driver is the one real coupling point.** `tools/veron` starts as a
  copy of `spikes/stage5/tools/veron` at a pinned commit; while the spike
  copy keeps evolving, an informational CI check diffs the two and reports
  drift, and changes port spike → official until cutover.
- **Cutover is per stage and maintainer-decided.** A spike workflow archives
  (findings to `docs/experiments/`) only when its official counterpart is
  proven *and* work in that spike has stopped. `spikes/` freezes at the end
  of the migration, not the start.

STAGE6 §4's order, with the design decisions slotted in — every step below
builds the official tree under §7.0, spikes untouched:

1. **Establish the official tree — the vocabulary pass, first** (D1, D2).
   Create `stages/1..5` under the canonical names and numbering, Stage 1
   redone with its official artifact names and the re-baseline commit (D2),
   docs rewritten (ARCHITECTURE §2/§4, AGENTS invariant 1 per D3), workflow
   names per §5, the `seed/` and `lib/` skeletons retired into `docs/`.
   First, so no record or reference is ever written under a disputed name.
2. **Redo stage 5 officially** (`stages/5-user-space`, `tools/veron` as the
   stage-generic driver), adopting its proven recipes and driver logic at a
   pinned commit, `policy/` established repo-wide — spike originals
   untouched and still live. Byte-identical output between the official
   stage-5 run and the live spike run is the acceptance test.
3. **Extract stages 1–4 from YAML into `stages/<N>/substages/` scripts** behind
   driver backends. Mechanical, substage by substage, each verified by
   byte-identical CI comparison. (~4,500 lines of inline shell; the single
   largest item — and the gate for everything below, because a substage that
   only exists as YAML cannot declare its inputs.)
4. **The artifact contract at every seam** (§4) — generalize the existing
   stage-4 release pattern; add the local `out/` resolver and `veron
   doctor`. *First bare-metal end-to-end run happens here.*
5. **Substage records + `veron trace`/`why`/`--verify`** — the driver emits D4
   records as it builds; backfill stage 5 by generating records from its
   recipes and manifests (the data already exists in `recipe.toml` +
   `installs`).
6. **Workflow consolidation** (§5) + `docs/experiments/` for retired probes.
7. **Stage 6 proper**, in STAGE6's own order: kernel matrix, EFI stub +
   reproducible baked initramfs, e2fsprogs + installer, image formats,
   distribution, signed ledger — with `trace --verify` as the release gate.
8. **Then the other architectures** — the shape is proven on one before it
   is paid for three times.

---

## 8. What this design refuses

- **No rewrite of working substages.** Extraction is verified byte-identical; a
  bootstrap that boots is not improved by being made prettier.
- **No second schema, ever again.** One record format (D4). Any new fact is
  a field in it, not a new file kind.
- **No build logic in YAML.** Enforced by lint, not by intention.
- **No silent roots.** A file whose trace terminates nowhere is a release
  blocker, not a TODO — that is what "total" means.
- **No "seed."** The trust root is Stage 1 Self-Assembly, in every document,
  workflow, record and query — enforced by the same lint pass that guards
  the workflows.
- **No third flavor by drift, no unverified committed binary, no reference
  to other projects** — the standing AGENTS invariants, unchanged except D3.
