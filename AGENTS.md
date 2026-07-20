# AGENTS.md — Working in the Veron repository

This file is the operating guide for any AI agent (or human) working in this
repo. It states the **rules you must not break** and the **workflows you'll
use**. For deep design, read [`ARCHITECTURE.md`](./ARCHITECTURE.md) — it is
canonical. When this file and `ARCHITECTURE.md` disagree: `ARCHITECTURE.md`
wins on *design*, this file wins on *process*.

---

## 1. Orientation

Veron is a **bootstrap / spike operating system**. A hand-audited,
per-architecture assembly **seed** climbs a readable ladder — assembler →
C-subset compiler → self-hosting C → libc → GCC — to a traditional
**GNU/Linux** system. Its defining properties are **hermetic, reproducible,
and end-to-end auditable** builds. It is a proving ground, not a product.

Target architectures: `x86_64`, `aarch64`, `riscv64`.

**Current status — read before assuming a file exists.** The design (seed,
stages, build engine, flavors, ledger, all with invariants ON) under `seed/`,
`stages/`, `lib/`, etc. is *specified but not yet implemented*. What *does*
exist and run is the **feasibility-spike toolkit** under `spikes/` (invariants
SUSPENDED — see `spikes/PROGRESS.md`): a working ARM64 pipeline
`program.s | stage0-as | elf out` that turns assembly-with-labels into a running
executable, all hand-written and byte-verified against the real assembler.
`stage0-as` is **assembler-complete** (arithmetic, branches, single-char labels,
memory, data). This is a proving ground, not Veron proper; do not copy spike
code into `seed/`/`stages/` without re-applying the invariants. Do not assume
something exists because the design mentions it — check the filesystem.

---

## 2. Invariants — never violate these

1. **No committed binaries. Ever.** Every binary is *derived*. The seed binary
   is produced from its assembly source and verified by round-trip
   disassembly; it is never checked in. `.gitignore` blocks `seed/*/seed-as`.
   If you need a binary, produce it in a build/CI step — do not commit it, and
   do not commit `*.o`, `*.elf`, or build outputs.

2. **The stage-0 seed is bijective, readable assembly.** For seed sources only
   (`seed/**`): one real instruction per line, one pinned encoding each. **No**
   macros, **no** pseudo-instructions that expand, **no** branch relaxation,
   **no** optimization, **no** assembler-chosen encodings. The seed must
   round-trip: assemble → disassemble → diff back to source with no
   difference. The seed is per-architecture. The **RISC-V seed is RV64I base
   only** (no compressed extension); the OS *target* is RV64GC.
   **Spikes are exempt** — `spikes/**` may use full assembler conveniences.

3. **Nothing below stage 4 may reference libc** — not directly, not
   transitively. Stages 0–3 are the flavor-blind trunk; `libc` becomes a
   parameter only at stage 4. (To be enforced by `tools/check-fork-invariant`
   once implemented: any stage 0–3 derivation whose hash differs between
   flavors is a stop-the-line bug. Until that tool exists, uphold it manually.)

4. **Flavors are parameters, not copies.** `musl` and `glibc` are small
   parameter files under `flavors/`, both fed by one trunk. Never fork the
   tree per flavor.

5. **Respect the trust boundary.** The seed source (per arch) is the only
   hand-authored root. The **assembler is untrusted** — its output is
   round-trip-verified. The **Linux kernel and hardware are trusted, declared
   inputs**; the kernel is a normal reproducible package, not bootstrapped
   from the seed. State deferrals explicitly (see `TRUST-BOUNDARY.md`); never
   hide them.

6. **License discipline.** Veron's own code is **MIT** (`LICENSE`). Upstream
   software (GCC, glibc, Linux, coreutils, BusyBox, musl, …) keeps its own
   license, recorded per-node in the ledger as an SPDX id (audit criterion 7).
   Never relicense upstream. Never vendor/copy upstream source into the tree —
   fetch it by pinned hash via a `sources/` manifest.

7. **Veron is self-contained.** It references **no other project, product, or
   roadmap**. Do not add "relationship to X", "successor to Y", or "part of Z"
   notes to any file — not in code, comments, docs, or commit messages. Keep
   everything about Veron and its upstream dependencies only. If you find a
   stray reference to an unrelated project, **remove it**.

8. **Every build node must be auditable.** Any derivation you add must be able
   to emit an audit record covering the **seven criteria** (§5). If a step
   can't be made hermetic and reproducible, **stop and flag it** rather than
   merging it.

---

## 2a. When to STOP and escalate

Do **not** improvise past a boundary. Working around a rule you don't
understand, or silently reinterpreting one so the task can proceed, is how the
invariants erode one reasonable-seeming step at a time. In any of these cases,
**stop, do not commit, and surface the issue to a human** (in your response,
and if mid-task, as a clear note in the PR/branch):

- **A task conflicts with an invariant (§2).** Never resolve the conflict by
  weakening the invariant on your own. Stop and ask.
- **The documentation is ambiguous, silent, or self-contradictory** on
  something the task needs. Don't guess the design. Stop and ask.
- **`AGENTS.md` and `ARCHITECTURE.md` disagree** in a way that matters (beyond
  the design-vs-process split in the header). Stop and ask.
- **The task would drift the design** — change the ladder, move the fork line,
  alter the trust boundary, add a dependency, or set a precedent — that no
  recorded decision covers. Design changes are human decisions. Stop and ask.
- **You cannot make a build step hermetic and reproducible** (invariant #8).
  Stop; do not merge a non-reproducible step to "fix later."
- **Reality contradicts the docs** — the code does something the docs say it
  doesn't, or vice versa. Stop and flag the discrepancy; do not code around it.

When you stop, state plainly: what you were doing, which rule or doc is in the
way, and the options as you see them. A blocked task with a clear question is a
good outcome. A silently worked-around invariant is not.

## 2b. Keep the documentation honest

The docs are **living**, and they are the source of truth the *next* agent
inherits. Treat divergence between docs and reality as a bug.

- When a design decision is made or changed (by a human), **update
  `ARCHITECTURE.md`** so the decision is recorded, and update `AGENTS.md` if it
  changes a rule or workflow. Do this in the *same* change, not "later."
- When you add real capability that supersedes a "planned" note (e.g. the
  `check-fork-invariant` tool, the seed `roundtrip.sh`, a new stage), **update
  the status notes and the relevant sections** so they stop saying "planned."
- Never leave the docs describing a world that no longer exists. If you can't
  update them correctly, that itself is a reason to **stop and ask** (§2a).
- If a rule here turns out to be wrong or unworkable, **do not just ignore
  it** — flag it so it can be fixed. A wrong rule that everyone quietly routes
  around is worse than no rule.

---

## 3. Repository map

```
AGENTS.md            this file — agent operating guide
ARCHITECTURE.md      canonical design (ladder, criteria, fork, trust boundary)
AUDIT.md             audit-record format (summary; schema TBD)
TRUST-BOUNDARY.md    what is trusted and why (honest boundary statement)
LICENSE              MIT — Veron's own code only
README.md            human-facing overview

seed/                readable per-arch assembly trust root (NO binaries here)
  <arch>/            seed-as.S, seed-as.hash, roundtrip.sh, AUDIT.md
stages/              the ladder: 0-seed-as → 1-macro-as → 2-mini-c → 3-full-c
                     │ (FORK LINE) │ 4-libc → 4-binutils → 5-gcc-… → 5-kernel
flavors/             musl/ and glibc/ — parameter files, not copies
lib/                 build engine: derivations, sandbox, binary cache
sources/             pinned upstream manifests (url + hash + signature + SPDX)
ledger/              per-node audit records — the auditability deliverable
tools/               spike.sh (works now); diffoscope-wrap, check-fork-invariant (planned)
spikes/              rapid cross-arch proof-of-concepts (see spikes/README.md)
.github/workflows/   spike.yml (works now); trunk/flavor build workflows (planned)
ci/                  Dockerfile for a prebuilt fast-start CI image
```

---

## 4. The stage ladder (summary — full detail in `ARCHITECTURE.md` §2)

| Stage | Name | Written in | Audit regime |
|-------|------|-----------|--------------|
| 0 | `seed-as` | readable per-arch assembly | A — source read + round-trip disassembly |
| 1 | `macro-as` | stage-0 assembly | A — full source read |
| 2 | `mini-c` | stage-1 assembly | A — full source read |
| 3 | `full-c` | stage-2 C subset (self-hosts) | B — self-host + diverse double-compilation |
| — | **FORK LINE** | *nothing above references libc* | |
| 4 | `libc` + `binutils` | full C | C — reproduce + review delta + defer |
| 5 | GCC → userland → kernel | full C | C |

Stages 0–2 are per-arch (written 3×). From stage 3's portable C upward, source
is written once and the compiler targets all three arches — so keep the
assembly-language rungs few and small.

---

## 5. The audit ledger (summary — full detail in `ARCHITECTURE.md` §3)

Every derivation emits one audit record (`ledger/<output-hash>.json`),
flavor-tagged, carrying the **seven criteria**:

1. provenance (source hash + signature)
2. reproducibility (output hash + N byte-identical rebuild attestations)
3. hermeticity (full input graph)
4. reviewed delta (our patches / flags / recipe)
5. behavioral verification (tests + self-host / fixpoint + GCC 3-stage)
6. recorded deferral (verified vs. deferred, stated)
7. license & rights (SPDX id per source)

The ledger is what makes Veron end-to-end auditable, and doubles as an
always-current SBOM + GPL corresponding-source manifest.

---

## 6. Daily workflow — spikes

A **spike** is a tiny program you assemble and run under QEMU user-mode to
answer one question fast. Spikes are throwaway experiments and (unlike the
seed) **may use full assembler conveniences**.

**Naming convention** — one source per architecture, tagged in the filename:

```
spikes/<name>/<name>.x86_64.s
spikes/<name>/<name>.aarch64.s
spikes/<name>/<name>.riscv64.s
```

**Run locally** (the same script CI uses — local and CI can never drift):

```bash
tools/spike.sh aarch64 spikes/hello/hello.aarch64.s          # run + show output
tools/spike.sh riscv64 spikes/hello/hello.riscv64.s --dump   # also disassemble
```

Local prereqs: `qemu-user` + `binutils-x86-64-linux-gnu`,
`binutils-aarch64-linux-gnu`, `binutils-riscv64-linux-gnu` (see `ci/Dockerfile`).

**Run in CI:**
- Push anything under `spikes/**` or `tools/spike.sh` → all three arches run in
  parallel; results land in each job's summary.
- Or Actions tab → *spike* → *Run workflow*, optionally pointing at one file.

The harness is deliberately fast: logic lives in `tools/spike.sh`, the matrix
runs arches in parallel, and `fail-fast: false` shows all three results even if
one fails. For a faster start, build `ci/Dockerfile`, push to GHCR, and set
`container:` on the job (see comments in `.github/workflows/spike.yml`).

---

## 7. Before you commit — checklist

Run these from the repo root:

```bash
# 1. Relevant spikes still pass (run the ones you touched, all three arches)
tools/spike.sh x86_64  spikes/<name>/<name>.x86_64.s
tools/spike.sh aarch64 spikes/<name>/<name>.aarch64.s
tools/spike.sh riscv64 spikes/<name>/<name>.riscv64.s

# 2. No stray build artifacts or binaries staged
git status                       # expect no a.elf, *.o, seed-as, etc.

# 3. If you touched seed/**: the seed still round-trips (no diff)
#    (run seed/<arch>/roundtrip.sh once it exists)

# 4. Docs/code mention only Veron + its upstream deps (invariant #7)
```

---

## 8. How to add things

- **Add a spike:** create `spikes/<name>/<name>.<arch>.s` (one file per arch you
  want to test — you need not cover all three), run it locally, push.
- **Add a stage (later):** create `stages/<n>-<name>/` as a hermetic,
  content-addressed derivation. Uphold invariants #2 (if it's the seed), #3
  (fork line), #5 (trust boundary), #8 (auditable).
- **Add an upstream dependency:** add a pinned manifest under `sources/`
  (url + cryptographic hash + signature + SPDX license). Never vendor source.

---

## 9. Pointers

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — canonical design (start here for depth)
- [`TRUST-BOUNDARY.md`](./TRUST-BOUNDARY.md) — what is trusted and why
- [`AUDIT.md`](./AUDIT.md) — audit-record format
- [`spikes/README.md`](./spikes/README.md) — spike conventions
- [`spikes/PROGRESS.md`](./spikes/PROGRESS.md) — bootstrap-spike progress + toolkit state
- per-directory `README.md` files — what belongs in each directory
