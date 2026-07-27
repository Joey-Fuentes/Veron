# Veron

A hermetic, reproducible, end-to-end auditable operating system — bootstrapped from a tiny, hand-audited, per-architecture **assembly seed** up a readable ladder to a traditional **GNU/Linux** desktop.

**Status:** The ladder runs natively and hermetically, **with no host tool on the build path.** `stage3-hermetic-arm64` climbs seed → stage 1 → stage 2 → 426 conformance programs → M2-Planet on real ARM64 hardware inside a `bubblewrap` sandbox with no network, and M2-Planet's self-compilation output is **byte-identical to upstream's own reference compiler** (`dc38e13e4ceaeecb`, 2,947,903 bytes). The seed assembler and ELF writer are committed binaries, verified on every push: each is disassembled and compared to its own source by **two independent disassemblers**, and the whole linked ELF is reconstructed from that disassembly and compared byte for byte. `BUDGET_PATH` is empty.

**License:** [MIT](./LICENSE) for Veron's own code. Upstream dependencies keep their own licenses, tracked per-node in the ledger.

---

## What Veron is

- **From-seed.** A few hundred lines of readable, bijectively-encoded, per-arch assembly (ARM64, RISC-V RV64I, x86-64) climb one rung at a time: assembler → C-subset compiler → self-hosting C → libc → GCC → GNU/Linux. The seed binary is *derived* and verified against its source by round-trip disassembly — nothing opaque is committed.
- **Hermetic + reproducible.** Every build is a pure function from hashed inputs to output, sandboxed with no network. Anyone can rebuild and diff rather than trust.
- **End-to-end auditable.** Every build *decision* — provenance, patches, flags, license — is pinned and recorded in an audit ledger. The ledger, not the package internals, is what makes the whole system auditable.
- **Two flavors, one trunk.** The tree forks exactly once, at libc: **musl/BusyBox** (minimal, maximally auditable, permissive dependency surface) and **glibc/GNU** (compatibility — official Chrome, CUDA, prebuilt blobs).

## What Veron is *not*

Veron is an independent exploration / proving-ground OS — a place to test what's buildable from a seed, not a finished product. It is self-contained and references no other project. Full scope note at the top of [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Where the ladder stands

Everything below lives under [`spikes/`](./spikes) and is a **feasibility tracer**, not Veron proper. Spikes deliberately suspend the invariants — bijective encoding, reproducibility, hermeticity, the round-trip audit, no-committed-binaries — to answer one question cheaply: *can the ladder be built at all on this setup?* Nothing here should be copied into `seed/` or `stages/` without re-applying them. Stage numbering below is the spike track's own.

| rung | what it is | state |
|---|---|---|
| `stage0-as` | two-pass mnemonic assembler, hand-written ARM64 assembly. The last tool written in raw assembly. | **committed and verified** — the binary is in the repo and re-checked on every push: disassembly diffs clean against the source under two independent decoders, and the whole ELF reconstructs byte for byte |
| `stage1-as` | two-pass numeric label resolver, written in *stage 0's own language* | **works** — gives the ladder unbounded multi-character labels |
| `stage2-mini-c` | C-subset compiler, written in *stage 1's language* | **works** — 220 KB of upstream C in, 81,893 instructions out |
| `stage3` | M2-Planet, compiled by stage 2. There is no separately-written stage 3 — M2-Planet *is* stage 3. | **hand-off proven** — our build reproduces upstream's M2-Planet **byte for byte**, stable over five generations |
| `stage4` | everything tcc is used to build: gcc, a userland, a kernel, a boot | **works** — `tcc → 4.7.4 → 10.2.0 → 15.2.0 → linux 7.1.5 → boot`, 61 min, one job |

The stage-2 → stage-3 hand-off is the sharpest single result:

```
refM2P (upstream tooling)   643257  d80317fc92ff4889
G1     (our ladder)         643257  d80317fc92ff4889
G2..G5 identical            -- stable fixpoint
```

`G0` is built from lightly patched source; every generation after it is built from upstream's **unpatched** sources, so the patch leaves the chain immediately. That G1 lands exactly on upstream's bytes is the proof.

And at the top, stage 4's end-to-end run — a gcc whose entire ancestry was built in the same process, from tcc:

```
VERON-BOOT-OK        Linux 7.1.5 aarch64
VERON-COMPILER       Linux version 7.1.5 (gcc (GCC) 15.2.0, GNU ld ...)
VERON-TESTS          pass=8 fail=0
VERON-GCC-IN-GUEST   ok compiled and ran, rc=42 (expect 42)
```

A separate box, `hermetic-gcc16`, carries the same recipe to **gcc 16.1.0 and linux v7.2-rc4**, booting with its own glibc 2.43 as PID 1.

---

## What remains for the rough draft

Two proven segments, one gap between them, and one dependency at the floor. Neither is a research question; both are measured work.

### 1. Stage 0 — stand on our own assembler

`stage0-as` and `elf` are committed as **verified binaries** (`spikes/stage0-as/stage0-as`, `spikes/elf/elf`). Git preserves the executable bit, so they run on checkout with no tool at all — `as` and `ld` have left `BUDGET_PATH`, and the `SEAL` step in `stage3-hermetic-arm64` fails the run if anything reappears. They are not trusted: `stage0-selfhost` verifies the committed artifacts on every push, against pinned binutils 2.47 **and** LLVM 22.1.8, checking that the disassembly matches the source as a plain `diff` and that the whole ELF reconstructs byte for byte. What remains at the floor is `busybox`, which drives the build and touches no artifact byte, and the real hand-encoded seed — see [`TRUST-BOUNDARY.md`](./TRUST-BOUNDARY.md) for the verification chain and why its ordering matters.

Closing this replaces `as` with the seed at the bottom of the ladder. See [`TRUST-BOUNDARY.md`](./TRUST-BOUNDARY.md) — the assembler is *untrusted* by design; the work is making that literal.

### 2. Stage 3 — reach tcc from M2-Planet

Stage 4 already **has** a tcc — pinned, patched, and used. What stage 3 owes is a tcc reached *from the seed*. Two routes are open and not in competition:

| route | state |
|---|---|
| M2-Planet → Mes → tcc | Mes rung in progress, three rungs out |
| **enhanced M2-Planet → tcc directly** | gap measured against tcc's source; no enhanced M2-Planet written yet |

The direct route is the shorter one: extend M2-Planet's C subset far enough to compile real tcc, skipping the intermediate rungs entirely. The thesis behind it is that much of what the bootstrap ecosystem carries is *incidental* complexity — build plumbing, script-calling-script — rather than real capability gaps, and that the two can be separated by measuring instead of estimating. See [`spikes/stage3/ROADMAP.md`](./spikes/stage3/ROADMAP.md).

**Close those two and the chain is continuous from hand-read assembly to a booting GNU/Linux.** What stands between here and a rough-draft OS is that, plus re-applying the invariants — the spike track suspends every one of them.

---

## Layout

```
seed/       readable per-arch assembly trust root (the only hand-authored root)   [empty]
stages/     the ladder: 0-seed-as → 1-macro-as → 2-mini-c → 3-full-c │ 4-libc → 5-…  [empty]
flavors/    musl / glibc instantiations (parameter files, not copies)             [empty]
lib/        the build engine: derivations, sandbox, binary cache                  [empty]
sources/    pinned upstream manifests (url + hash + signature + license)
ledger/     per-node audit records — the auditability deliverable                 [empty]
tools/      spike driver, backtrace, source-porting scripts
spikes/     the feasibility track — everything that currently runs (invariants OFF)
.github/    CI orchestration (fan-out under the 6h runner cap, cache, attest)
```

The empty directories are Veron proper and are written against the invariants. `spikes/` is the proving ground; the two are deliberately separate.

> **Note:** the `stages/` line above reflects [`AGENTS.md`](./AGENTS.md) §4, which numbers the ladder 0–5 with the flavor fork between 3 and 4. [`ARCHITECTURE.md`](./ARCHITECTURE.md) §2 currently numbers it 1–7 with no fork line. The two disagree and the disagreement is unresolved — treat neither as canonical until it is.

## Where to start reading

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the founding design: ladder, fork, audit criteria, trust boundary
- [`AGENTS.md`](./AGENTS.md) — invariants and working rules, if you are contributing
- [`spikes/README.md`](./spikes/README.md) — the live pipeline, and what each spike answered
- [`spikes/stage3/README.md`](./spikes/stage3/README.md) — the open rung
- [`spikes/stage4/README.md`](./spikes/stage4/README.md) — everything above tcc, including the end-to-end run
- `.github/workflows/stage3-hermetic-arm64.yml` — the native, sandboxed climb and its host budget
- `.github/workflows/stage0-selfhost.yml` — can stage0-as assemble its own source? the measured answer
- [`spikes/PROGRESS.md`](./spikes/PROGRESS.md) — 150 KB of stage 0–2 history; reference only, do not load for context
