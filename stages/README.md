# stages/ — the official ladder (design: docs/DESIGN.md)

| stage | name | state |
|---|---|---|
| 1 | Self-Assembly | **live** — committed verified binaries + two gates |
| 2 | pico-c | **live** — `verify.sh` |
| 3 | micro-c (+ tcc, the handoff) | **live** — `build.sh in` / `chain`; publishes `3/latest-<arch>` |
| 4 | Toolchain and Kernel | **live** — `build.sh` + `generic.sh`; publishes `4/latest-x86_64`, `4/kernel-x86_64` |
| 5 | User Space | **live** — `build.sh`; publishes `5/latest-x86_64` |
| 6 | Release | **live** — `build.sh`; publishes `release/<sha7>-<inputs7>` |

Every stage, 1 through 6, is verified byte-identical between a laptop and
CI as of 2026-09-01; see `BUILDING.md` for the sequence and the digests.

Redone from the spike track under docs/DESIGN.md §7.0: spikes stay live and
untouched; each stage here is proven against the live spike as oracle. One
sealed trunk job builds 1–3 and publishes one release, `3/latest-<arch>` —
tcc, the artifact everything below the trunk exists to yield.
