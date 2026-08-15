# Stage 1 Self-Assembly — audit record

**Status: PENDING FIRST RE-BASELINE.** This file is completed by the
maintainer when `rebaseline.sh derive` produces the first official committed
binaries. Until then the spike pair and its audit remain authoritative for
the spike tree.

## Record (fill on re-baseline)

- **Sources read in full by:** _(name, date)_ — `self-assembler-arm64.s`
  (~1.3k lines), `elf-wrapper-arm64.s` (186 lines)
- **Committed binaries:** see `BASELINE.txt` (sha256 + byte size, written by
  `rebaseline.sh derive`)
- **Derivation:** gen1/elfgen1 of the self-host ladder; `as`+`ld` used only
  as the bounded-diff reference. Divergence from the reference bounded to
  the `.bss`-referencing `adr` words (ld page-aligns `.bss`; the wrapper
  writes one flat blob) — counted, named, and required to be only those.
- **Fixpoints:** gen1 == gen2 == gen3; elfgen1 == elfgen2 == elfgen3.
- **Regression:** gen1 builds the spike stage-1 source byte-identically to
  the reference pair (spikes as read-only oracle).
- **Deferral, stated:** the disassembler is the residual trust — mitigated
  by two independent decoders once the pinned two-disassembler gate is
  adopted from the spike workflow (extraction step). The kernel and hardware
  are declared trusted inputs (TRUST-BOUNDARY).
