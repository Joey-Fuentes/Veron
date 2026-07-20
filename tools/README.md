# tools/

- `diffoscope-wrap`     — localize divergence when two builds of one derivation disagree.
- `check-fork-invariant` — CI gate: fail if any trunk (stage 0–3) derivation
  hash differs between the musl and glibc flavors. The fork line cannot move
  without a human deciding it should.
