# lib/ — the build engine

- **derivation** — content-addressed derivations: pure functions from hashed
  inputs (including `libc`) to a hash-determined output.
- **sandbox** — hermeticity enforcement: no network, no ambient state, inputs
  mounted read-only by hash.
- **cache** — binary-cache client keyed by input hash; independent rebuilders
  diff their outputs against it (reproducibility as a distributed property).

**Open decision:** build *on* Nix/Guix (inherit the derivation engine, store,
and sandbox) vs. implement the model here. This choice affects only this
directory; the ladder, fork, and ledger are engine-agnostic.

See `ARCHITECTURE.md` §5.
