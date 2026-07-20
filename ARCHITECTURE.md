# Veron — Architecture & Repository Skeleton

*A hermetic, reproducible, end-to-end auditable OS bootstrapped from a tiny hand-audited per-architecture assembly seed.*

---

> ## Scope — read first
>
> **This is a bootstrap/spike OS: a proving ground, not a product.**
>
> Its purpose is exploratory — to prove out one specific path (a hand-audited per-arch assembly seed climbing a readable ladder to a **traditional GNU/Linux** system) and to learn what is actually buildable end to end. It commits to nothing beyond that. It is self-contained and depends on no other project.

---

## 1. What this project is

A traditional GNU/Linux operating system whose defining property is not *what it runs* but *how it is built*: from a tiny **readable-assembly seed** — hand-written per CPU architecture, mapping 1:1 to its binary and verified by round-trip disassembly — upward through a readable ladder of stages, to a full desktop system, with every build decision pinned, sandboxed, reproducible, and recorded.

The system ships in **two flavors** (musl/BusyBox and glibc/GNU) that share one trunk and fork exactly once, at the libc stage.

### Design priorities, in order

1. **End-to-end readability and auditability.** Every build *decision* is transparent, even where package internals are not.
2. **Hermeticity.** Every build is a pure function from hashed inputs to output; no network, no ambient state.
3. **Reproducibility.** Bit-for-bit identical outputs, so anyone can rebuild and diff rather than trust.
4. **A minimal, *readable* trust root.** The committed root is the seed's **assembly source** (one per CPU architecture — x86-64, ARM64, RISC-V), not an opaque blob. Its binary is derived by an *untrusted* assembler and confirmed to match the source by round-trip disassembly, so reading the source and vouching for the binary are one act.

### What is deliberately *not* claimed

This is not a defense against a maliciously backdoored global ecosystem, and it does not bootstrap below the kernel. See **§7, Trust Boundary** — stated honestly rather than papered over.

---

## 2. The stage ladder

The governing rule: **add exactly one new abstraction per stage, and write each stage in the language the stage below just produced.** Readability climbs monotonically; the only cryptic layer is the first one, which is also the smallest.

| Stage | Name | Written in | Adds | Audit regime |
|-------|------|-----------|------|--------------|
| 0 | `seed-as` | **readable per-arch assembly** (x86-64 / ARM64 / RV64I) | line-oriented assembly → static ELF; labels, `.byte`/`.ascii` | **A** — source read + round-trip disassembly (assembler untrusted) |
| 1 | `macro-as` | stage-0 assembly | macros, named constants, integer expressions, `.include` | **A** — full source read |
| 2 | `mini-c` | stage-1 assembly | C subset: functions, int/char/ptr, if/while, arrays, globals | **A** — full source read |
| 3 | `full-c` | stage-2 C subset | preprocessor, structs/unions, switch, full types; **self-hosts** | **B** — self-host + diverse double-compilation |
| — | **← FORK LINE** | | *nothing above this line may reference libc* | |
| 4 | `libc` + `binutils` | full C | musl **or** glibc; real assembler/linker | **C** — reproduce + review delta + defer |
| 5 | GCC → userland → kernel | full C | bootstrappable GCC → modern GCC → coreutils/BusyBox → Linux → desktop | **C** |

### Two structural facts the seed forces

**Bijective encoding is a discipline, not a freebie.** For the round-trip (assemble → disassemble → compare) to hold, the seed assembly must forbid everything that makes assembly ambiguous: no macros, no pseudo-instructions that expand, no branch relaxation, no optimization, no assembler-chosen encodings. Every line is one real instruction with one encoding *you* pinned. The three targets are not equal at this: **ARM64** (fixed 4-byte instructions) is cleanest; **RISC-V** is clean if the *seed* is restricted to the **RV64I base** — fixed 32-bit width, whereas the compressed (`C`) extension introduces 16-bit instructions and breaks the bijection; **x86-64** is the hard one — variable length with multiple valid encodings per operation, so you must pin one canonical encoding per instruction and keep the instruction subset small. ARM64 is the natural reference arch.

> **RV64I constrains the seed only, not the OS.** General-purpose RISC-V PCs run **RV64GC** (integer + mul/div + atomics + float + compressed), and that is the *target* for stage 5 and up — the kernel and userland are RV64GC, emitted by full-c/GCC like any normal distro. The seed is written in bare RV64I purely so it round-trip-audits; because RV64GC is a strict superset of RV64I, that seed runs natively on any general-purpose RISC-V machine. Each rung targets what it needs; only the *seed* is restricted, and only because it must be hand-auditable. (Likewise ARM64 and x86-64: the seed uses a pinned subset, the OS uses the full ISA.)

**The lower stages are written 3×; race to portable C.** Stage 0's assembly is arch-specific by nature, and so is anything written *in* it (stages 1–2). The convergence point is `full-c`: from stage 3 up, sources are **portable C written once**, and the compiler targets all three arches. So the design pressure is to keep the assembly-language rungs *few and small* — every rung below the C line costs triple.

### The three audit regimes

- **Regime A — read the whole thing (stages 0–3).** Each stage is small enough (hundreds of bytes to low thousands of lines) that "we read all of it" is *literally true*. Stage 0's audit is a read of its commented assembly source, with the produced binary confirmed to match by round-trip disassembly; stages 1–3 are complete source review plus reproducible rebuild.
- **Regime B — the fixpoint (stage 3).** When `full-c` compiles `full-c` to a byte-identical fixed point, self-hosting proves the C subset was sufficient, and **diverse double-compilation** unlocks: rebuild upper stages with independent existing compilers and diff. Divergence is an automatic flag.
- **Regime C — reproduce, review the delta, defer the rest (stages 4–5).** Packages now exceed what anyone reads end to end. "Audited" means: pinned provenance + reproducible build + review of *our* patches/flags only + upstream test suites + an explicit recorded deferral of the internals.

Stage 0 is the only node with no stage beneath it to diverse-*compile* against — but its round-trip check *can* be run with independent disassemblers (a fixed-width clean encoding disassembles by near-lookup-table), so the seed still gets a diversity check of its own. This is precisely why it must be tiny and its encoding clean.

---

## 3. The seven audit criteria (per-node audit record)

Every derivation — from the seed to GCC — emits one audit record. The collection of these records **is** the OS's audit ledger, and is itself readable end to end even though the packages are not.

1. **Provenance** — source pinned by cryptographic hash (git commit / tarball digest) + upstream signature verified.
2. **Reproducibility** — output hash + N independent byte-identical rebuild attestations.
3. **Hermeticity** — the complete input graph, enumerated; sandboxed, no network, no ambient state.
4. **Reviewed delta** — the diff *we* introduced: patches, configure flags, build recipe.
5. **Behavioral verification** — test suites + self-host / fixpoint checks + GCC's three-stage self-rebuild-and-compare.
6. **Recorded deferral** — an explicit statement of what was verified vs. deferred upstream. Marking the boundary is itself part of the audit.
7. **License & rights provenance** — the upstream license (SPDX identifier) of every source, recorded per node alongside its hash. This is the rights-companion to criterion 1: provenance says *where the bytes came from*; this says *what may be done with them*.

The honest one-liner this produces, for any node: *"Built from source X under license L, by a fully-declared hermetic build, reproducibly, with our patches and flags reviewed, passing suite T, deferring to upstream for the internals."* Every clause is checkable by a stranger.

**License tracking → automatic compliance.** Because every node already records provenance, patches, and now license, the ledger *is* an always-current SBOM and GPL corresponding-source manifest across the whole graph — generated, never hand-maintained. This matters at **distribution, not building**: shipping recipes that fetch-and-build GPL software (GCC, glibc, Linux, coreutils) carries no obligation beyond the pinned sources already in `sources/`; the obligation attaches only when a *built image* is conveyed, at which point GPLv2/v3 require offering corresponding source + our patches to the recipient — which the ledger already provides. Veron's own code is **MIT** (see `LICENSE`); upstream licenses are tracked, never relicensed, and never touch Veron's terms. A transparently-sourced, publicly-hashed tree is the compliance ideal, not a lawsuit target. (Note: the **musl/BusyBox flavor** carries a smaller, more permissive dependency surface — musl is MIT — than glibc + full GNU coreutils; a second reason it is the "clean core.")

> **Seam to keep honest:** reproducibility proves build-purity, not source-goodness. A reproducible build of bad source is reproducibly bad. Keep "this is the compiled form of exactly this source" separate from "this source deserves trust."

---

## 4. Repository skeleton

```
os/
├── README.md
├── ARCHITECTURE.md              # this document
├── AUDIT.md                     # the seven criteria + ledger record format spec
├── TRUST-BOUNDARY.md            # honest statement of what is trusted and why (§7)
│
├── seed/                        # ── THE READABLE TRUST ROOT (source, per-arch) ──
│   ├── README.md                #    the entire trust root: readable assembly, one per arch
│   ├── aarch64/                 #    reference arch — fixed 4-byte encoding, cleanest round-trip
│   │   ├── seed-as.S            #    the seed: readable, commented assembly (THE committed root)
│   │   ├── seed-as.hash         #    pinned digest of the derived binary (for reproducibility)
│   │   ├── roundtrip.sh         #    assemble → disassemble → diff against seed-as.S
│   │   └── AUDIT.md             #    source-read + round-trip audit record, human-signed
│   ├── riscv64/                 #    seed in RV64I base only; OS target is RV64GC
│   └── x86_64/                  #    same shape; canonical encodings pinned (variable-length)
│
├── stages/                      # ── THE LADDER (derivations) ──
│   ├── 0-seed-as/               #    trunk begins — flavor-blind
│   ├── 1-macro-as/
│   ├── 2-mini-c/
│   ├── 3-full-c/
│   │   └── FIXPOINT.md          #    self-host proof + DDC procedure (Regime B)
│   │   ══════════════════════   #    ═══ FORK LINE ═══
│   ├── 4-libc/                  #    parameterized: libc ∈ {musl, glibc}
│   ├── 4-binutils/
│   ├── 5-gcc-bootstrap/         #    old bootstrappable GCC, buildable by full-c/tcc
│   ├── 5-gcc/                   #    modern GCC, built by 5-gcc-bootstrap
│   ├── 5-userland/              #    coreutils|busybox, shell, init
│   └── 5-kernel/                #    Linux — a normal package, built by stage 5
│
├── flavors/                     # ── INSTANTIATIONS, NOT COPIES ──
│   ├── musl/
│   │   └── flavor.toml          #    libc=musl, tools=busybox, browser=chromium …
│   └── glibc/
│       └── flavor.toml          #    libc=glibc, tools=coreutils, proprietary-ok=true
│
├── lib/                         # ── THE BUILD ENGINE ──
│   ├── derivation.*             #    content-addressed derivation model
│   ├── sandbox.*                #    hermeticity enforcement (no net, no ambient state)
│   └── cache.*                  #    binary-cache client (keyed by input hash)
│
├── sources/                     # pinned upstream manifests: url + hash + signature
│   └── *.lock
│
├── ledger/                      # ── THE AUDIT DELIVERABLE ──
│   └── <output-hash>.json       #    one seven-criteria record per derivation, flavor-tagged
│
├── tools/
│   ├── diffoscope-wrap          #    reproducibility microscope when two builds disagree
│   └── check-fork-invariant     #    CI: no trunk derivation hash may differ across flavors
│
└── .github/workflows/
    ├── trunk.yml                #    build + attest stages 0–3 (shared, audited once)
    ├── flavor-musl.yml          #    instantiate stages 4+ with libc=musl
    └── flavor-glibc.yml         #    instantiate stages 4+ with libc=glibc
```

### What the tree physically encodes

- **`seed/` holds the trust root as readable assembly *source*, per architecture** — no committed binaries anywhere in the repo. Every binary, including the seed's, is *derived*; the seed's is confirmed against its source by round-trip disassembly. If a committed binary appears anywhere, that's a bug.
- **The fork line is visible in the tree**, between `3-full-c/` and `4-libc/`. Everything above it is one flavor-blind trunk.
- **`flavors/` holds instantiations, not parallel source trees.** A flavor is a small parameter file, not a fork of the repo.
- **`ledger/` is a first-class output**, not a byproduct. It is the readable-end-to-end artifact.

---

## 5. The build engine

Every stage is a **content-addressed derivation**: a pure function whose inputs (including `libc`) are hashed, producing an output whose hash is determined by them. This is the mechanism behind the structural criteria (provenance, reproducibility, hermeticity, recorded deferral) at once; license is recorded in the same manifest.

- **Sandbox** enforces hermeticity — no network at build time, no ambient state, inputs mounted read-only by hash.
- **Binary cache**, keyed by input hash, means you never rebuild the world — only what changed and its dependents. Independent rebuilders (including CI on different arches/hosts) diff their outputs against the cache, turning reproducibility into a *distributed* property rather than one person's say-so.
- **`diffoscope`** localizes any divergence when two builds of the "same" derivation disagree.

> **Build-tool decision (open):** you can either build *on* Nix/Guix — inheriting the derivation engine, store, and sandbox for free — or implement the derivation model yourself. Building on Nix reaches a working system far faster; a custom engine serves the "from scratch" ideology more fully. This choice affects `lib/` only; the ladder, fork, and ledger above are engine-agnostic.

---

## 6. Flavor mechanics: one trunk, one fork

The fork is **a parameter, not a copy.** Stages 0–3 are one set of derivations both flavors consume unchanged. `libc` becomes a real choice only from stage 4 up.

**Invariant:** *nothing below stage 4 may reference libc, even transitively.*
**Enforcement:** `tools/check-fork-invariant` runs in CI and fails if any trunk (stage 0–3) derivation produces a different hash between the musl and glibc builds. The fork line cannot move without a human deciding it should.

**Audit records carry a flavor tag** from the first divergent node. Trunk records are written once and inherited by both.

### The two flavors have distinct identities

| | **musl / BusyBox** | **glibc / GNU** |
|---|---|---|
| Purpose | minimal, maximally auditable, from-source | compatibility; runs proprietary glibc blobs |
| Trusted surface | smaller | larger |
| Browser | Chromium (native) | official Chrome (native) |
| GPU / CUDA | CPU + Vulkan | CUDA / proprietary drivers native |
| Existence proof | Alpine Linux | every mainstream distro |

This framing resolves the recurring "but will it run X?" question cleanly: proprietary glibc-only software (official Chrome, CUDA, Steam) *is what the glibc flavor is for*, rather than a compromise bolted onto a single system.

### Two guardrails

- **Sequencing is free.** Because it's one parameterized graph, you can build and prove the **musl flavor first** and light up the glibc instantiation later at the *same* stage-4 seam — no retrofit. The repo is shaped for both whether or not both yet exist.
- **Don't let "hybrid" become a silent third tree.** The musl-base-plus-glibc-runtime option (for CUDA/Chrome via Flatpak-style bundling) must be either a first-class third flavor with its own audit records or explicitly out of scope. Unstated is what bites.

---

## 7. Trust boundary (stated, not hidden — this *is* criterion 6 for the whole system)

The bootstrap collapses the **userland** trust root to one tiny, hand-read block of assembly *source* per architecture. It does not reach below that:

- **The assembler is not trusted; the disassembler is the residual check.** Any assembler may produce the seed binary, because its output is verified against the source by round-trip disassembly. That shifts a sliver of trust onto the *disassembler* — but for a fixed-width clean encoding that's a near-lookup-table you can hand-write and run in independent implementations, a far better position than trusting a compiler. Record it in the seed's audit rather than hiding it.
- **The seed is per-architecture.** A new CPU means writing a new small assembly seed (and pinning its encodings) and reusing everything above it. Launch set: x86-64, ARM64, RISC-V.
- **The kernel and hardware are trusted inputs.** The seed needs a running kernel to execute; the Linux kernel is, by a wide margin, the largest thing being trusted — it dwarfs GCC. It is built reproducibly as a normal package, but it is not bootstrapped from the seed.
- **"From nothing" honestly means** "from a few small blocks of hand-read assembly (one per arch), plus a declared, recorded trust in kernel and silicon." That is the smallest *true* version of the claim.

Pushing the boundary below the kernel (seL4-style verified-microkernel research) is a much larger undertaking and a separate field of its own. For a traditional GNU/Linux OS, trusting the kernel is the normal, defensible line — recorded here rather than left implicit.

---

## 8. CI / orchestration model

GitHub Actions is the **orchestrator and one of the independent rebuilders**, not the build system itself (the derivations are).

- Actions walks the derivation graph and **fans builds out to stay under the 6-hour hosted-runner job cap**; long serial steps are split into chained jobs.
- It **populates the binary cache** and its own byte-identical result becomes an attestation toward criterion 2.
- The **seed's assembly source (per arch) is the only thing a reviewer vouches for by hand**; CI derives the seed binary and runs the round-trip check (assemble → disassemble → diff), ideally with more than one disassembler, as an attestation. Everything else is derived.
- Watch hosted-runner disk limits for large stage-5 builds; split or use larger/self-hosted runners where a single node genuinely exceeds the cap (recording any weaker-independence tradeoff in the ledger).

---

## 9. First milestone

The **Regime A boundary** on the reference arch (ARM64): write `seed-as` in readable ARM64 assembly, prove the round-trip (assemble → disassemble → diff), and get `macro-as` building reproducibly on top of it. That is the entire thesis in miniature — hand-read source, a mechanically-verified binary, then readable source all the way up, with the audit record attached from the very first node. Port the seed to RISC-V and x86-64 after the shape is proven once.

Concrete next artifact: the **stage-0 specification** — `seed-as`'s minimal instruction subset and pinned encodings (per arch), its directives (`.byte`, `.ascii`, labels), its input grammar, and the Linux syscall ABI it targets — plus the round-trip audit procedure and the exact form of the commented listing that serves as the committed root.
