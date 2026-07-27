# CI / orchestration

GitHub Actions is the **orchestrator and one independent rebuilder** — not the
build system itself (the derivations are). It walks the graph, fans builds out
to stay under the **6-hour hosted-runner job cap**, populates the binary cache,
and contributes byte-identical rebuild attestations toward criterion 2.

## End-to-end vs localised

Most workflows here answer **one** question and start from a host-built base on
purpose, so a failure localises — `hermetic-gcc10`, `-gcc15`, `-gcc16` each say
so in their own headers, and none triggers another.

`stage4-complete` is the exception and exists because of what that costs: two
green chains that never touched. It walks **tcc → gcc 4.7.4 → gcc 10.2.0 → gcc
15.2.0 → linux 7.1.5 → QEMU boot** in a single job, 61.4 minutes, no cache. 28
of its 34 steps are copied byte-for-byte from `tcc-builds-gcc-arm64` and
`hermetic-gcc15` with step names unchanged, so each diffs against its source.
See `spikes/stage4/README-complete.md`.

It does not replace the localised boxes and should not grow to. They stay
useful *because* they start from a host base.

## Native ARM64, and the host budget

Every workflow that builds the seed ladder runs on `ubuntu-latest` (x86_64)
under `qemu-aarch64`, with the seed cross-assembled. Two do not:

- **`stage3-hermetic-arm64`** — the same climb on `ubuntu-24.04-arm`, no
  emulator, inside `bubblewrap` with `--unshare-all`. Its host budget is
  declared in two tiers and enforced: `as` and `ld` on the build path, one
  static `busybox` as the driver. The SEAL step enumerates every executable in
  the sandbox and fails if anything else is there. Gates on our seed-built
  M2-Planet producing output byte-identical to upstream's reference compiler,
  behind 426 conformance programs and the `canon` fixpoint.
- **`stage0-selfhost`** — asks whether `stage0-as` can assemble its own source,
  which is what would let `as` and `ld` come out of that budget. Measurement
  only: it probes each instruction form against BOTH the real assembler and GNU
  `as` and byte-compares, and it guards the ladder against its own changes with
  `spikes/stage0-as/LADDER-BASELINE.txt` — artifact hashes plus a behavioural
  fingerprint of what stage 2 emits, so an encoding change that moves binaries
  without moving meaning is distinguishable from one that does not.

Workflows to add once `lib/` exists:
- `trunk.yml`        — build + attest stages 0–3 (shared, audited once)
- `flavor-musl.yml`  — instantiate stages 4+ with `libc=musl`
- `flavor-glibc.yml` — instantiate stages 4+ with `libc=glibc`

See `ARCHITECTURE.md` §8.
