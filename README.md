# Veron

A hermetic, reproducible, end-to-end auditable operating system — bootstrapped from a tiny, hand-audited, per-architecture **assembly seed** up a readable ladder to a traditional **GNU/Linux** desktop.

**Status:** Design phase. No build code yet. The founding design is in [`ARCHITECTURE.md`](./ARCHITECTURE.md); the first artifact to write is the stage-0 seed specification (ARM64 reference).

**License:** [MIT](./LICENSE) for Veron's own code. Upstream dependencies keep their own licenses, tracked per-node in the ledger.

---

## What Veron is

- **From-seed.** A few hundred lines of readable, bijectively-encoded, per-arch assembly (ARM64, RISC-V RV64I, x86-64) climb one rung at a time: assembler → C-subset compiler → self-hosting C → libc → GCC → GNU/Linux. The seed binary is *derived* and verified against its source by round-trip disassembly — nothing opaque is committed.
- **Hermetic + reproducible.** Every build is a pure function from hashed inputs to output, sandboxed with no network. Anyone can rebuild and diff rather than trust.
- **End-to-end auditable.** Every build *decision* — provenance, patches, flags, license — is pinned and recorded in an audit ledger. The ledger, not the package internals, is what makes the whole system auditable.
- **Two flavors, one trunk.** The tree forks exactly once, at libc: **musl/BusyBox** (minimal, maximally auditable, permissive dependency surface) and **glibc/GNU** (compatibility — official Chrome, CUDA, prebuilt blobs).

## What Veron is *not*

Veron is an independent exploration / proving-ground OS — a place to test what's buildable from a seed, not a finished product. It is self-contained and references no other project. Full scope note at the top of [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Layout

```
seed/       readable per-arch assembly trust root (the only hand-authored root)
stages/     the ladder: 0-seed-as → 1-macro-as → 2-mini-c → 3-full-c │ 4-libc → 5-…
flavors/    musl / glibc instantiations (parameter files, not copies)
lib/        the build engine: derivations, sandbox, binary cache
sources/    pinned upstream manifests (url + hash + signature + license)
ledger/     per-node audit records — the auditability deliverable
tools/      diffoscope wrapper, fork-invariant CI check
.github/    CI orchestration (fan-out under the 6h runner cap, cache, attest)
```

## First milestone

Write the **stage-0 spec** for the ARM64 reference seed: the minimal instruction subset and pinned encodings, the directives (`.byte`, `.ascii`, labels), the input grammar, the Linux syscall ABI, and the round-trip audit procedure. Prove the round-trip, then bring up `macro-as` on top. Port to RISC-V and x86-64 after the shape holds once.
