# stages/2-pico-c — the C layer, bootstrapped from assembly — LIVE

Stage 2 merges the spike track's two coupled layers (design D1): the macro
assembler exists only to make pico-c writable, so they are one stage.

| artifact | source (committed) | built output (recorded, not committed) |
|---|---|---|
| `pico-c-assembler` | `pico-c-assembler-arm64.s` — two-pass numeric label resolver, written in the self-assembler's language (1 file) | `out/2/aarch64/pico-c-assembler` — sha/bytes pinned in `substages.toml` |
| `pico-c` | `pico-c-arm64.s` — THE C-subset compiler (1 file, ~75 KB) | `out/2/aarch64/pico-c` — pinned likewise |

Pipeline: `prog.c | pico-c | pico-c-assembler | self-assembler | elf-wrapper`.

**Redone from the spike sources with audited diffs**: the only code changes
are the renamed self-naming strings — 3 (+3 length words) in the assembler,
7 length-preserving in pico-c — everything else is comments. Proven
equivalent against the live spike as oracle: label resolution byte-identical,
compiler output on real C byte-identical, and the built pico-c differs from
the spike-chain build by **exactly 42 printable-ascii bytes** (7 × the 6
chars where `stage2` ≠ `pico-c`). The canon canary built through this chain
lands on **5,052 B `ba935364bb0532c0` — the same number the spike ladder job
prints** — and holds its fixpoint.

`verify.sh` (one script, both homes; the workflow is its caller) rebuilds
both artifacts through the committed Stage 1 pair, requires the recorded
hashes, and runs the canary + error-prefix probes. Records:
`substages.toml`, with `builder` edges into `1/1` and `1/2` — a Stage 1
re-baseline makes this gate go red until these records regenerate, which is
the chain doing its job. Companions (`m2libc-shim.c`, `corpus/`,
`selfhost/`) adopted verbatim.
