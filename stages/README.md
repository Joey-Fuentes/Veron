# stages/ — the official ladder (design: docs/DESIGN.md)

| stage | name | state |
|---|---|---|
| 1 | Self-Assembly | **live** — committed verified binaries + two gates |
| 2 | pico-c | scaffold; adoption plan in its README |
| 3 | micro-c (+ tcc, the handoff) | scaffold |
| 4 | Toolchain and Kernel | scaffold; extraction plan |
| 5 | User Space | scaffold; adoption plan |
| 6 | Verification and Distribution | scaffold |

Redone from the spike track under docs/DESIGN.md §7.0: spikes stay live and
untouched; each stage here is proven against the live spike as oracle. One
sealed trunk job builds 1–3 and publishes one release, `3/latest-<arch>` —
tcc, the artifact everything below the trunk exists to yield.
