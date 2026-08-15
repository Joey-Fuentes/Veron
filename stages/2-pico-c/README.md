# stages/2-pico-c — the C layer, bootstrapped from assembly

Stage 2 merges the spike track's `stage1-as` and `stage2-pico-c` (design doc
D1): two layers that always run together with one purpose — making C
writable — are one stage with two files.

| official artifact | redone from | what it is |
|---|---|---|
| `pico-c-assembler-arm64.s` | `spikes/stage1-as/stage1-as.s0` | two-pass macro/label assembler, written in the self-assembler's own input language; exists only to make pico-c writable (1 file, ~7 KB) |
| `pico-c-arm64.s` | `spikes/stage2-pico-c/stage2-pico-c.s1` | THE C-subset compiler (1 file, ~75 KB of stage-2 assembly) |
| `m2libc-shim.c`, `corpus/`, `selfhost/` | same names in the spike | companions: the single M2libc substitution, the 426-program conformance list, the self-host harness |

The old `.s0`/`.s1` extensions encoded the language layer; that fact moves
into each file's header comment — the pipeline documents itself:
`prog | pico-c-assembler | self-assembler | elf-wrapper`.

**Status: NOT YET ADOPTED.** Adoption happens after Stage 1's first
re-baseline (its substages are assembled by the official Stage 1 binaries),
proven by the oracle test: the official pair must build these sources to
bytes identical to what the live spike workflow produces. Spike originals
untouched per §7.0.
