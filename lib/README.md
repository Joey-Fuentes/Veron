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

See `ARCHITECTURE.md` §5.
