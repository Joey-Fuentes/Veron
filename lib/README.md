# lib/ — the build engine

- **derivation** — content-addressed derivations: pure functions from hashed
  inputs (including `libc`) to a hash-determined output.
- **sandbox** — hermeticity enforcement: no network, no ambient state, inputs
  mounted read-only by hash.
- **cache** — binary-cache client keyed by input hash; independent rebuilders
  diff their outputs against it (reproducibility as a distributed property).

**Decision: implement the model here**, taking Nix's *format* -- content-addressed
outputs, a derivation as a pure function from hashed inputs -- without the
dependency. The reasoning is in [`DERIVATIONS.md`](../DERIVATIONS.md): the hard
parts (sandbox, pinned inputs, `SOURCE_DATE_EPOCH`, an enforced budget) are
already done, what remains is bookkeeping, and a tracing engine nobody in this
project audited sits badly under a claim that every file is traceable.

The structural reason: a Nix derivation is a black box, so the ladder becomes
either one node -- discarding the whole provenance graph -- or twenty separate
sandbox entries, which is a different build from the sealed-once box the SEAL
step enforces. `veron export --nix` gives the interop without the dependency.

**This decision covers stages 0-4 only.** Stage 5 is a wide DAG of hundreds of
mostly independent packages with a flavor fork, where black-box derivations are
the *correct* abstraction and a store, garbage collection, profiles and
rollback are most of the product. **Decided: cross-consumption.** Nix runs alongside rather than underneath --
it does not build on our toolchain and we do not evaluate its recipes. Nix
packages use nixpkgs' own glibc from its own store, so their binary cache
works and no Nix package links against a Veron artifact. Everything Veron
installs traces to the seed; everything Nix installs does not, and `veron why`
and `veron status` say which is which rather than blurring them. See
`DERIVATIONS.md`.

See `ARCHITECTURE.md` §5.
