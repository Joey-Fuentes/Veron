# stages/3-micro-c — micro-c, and the handoff to tcc — SOURCE ADOPTED

Stage 3 is where the ladder leaves its own dialects: pico-c builds micro-c,
micro-c builds tcc, and tcc is the first stone of stage 4.

| piece | status |
|---|---|
| `micro-c/` | **adopted in-tree source** (design D2): the exact patched tree the build needs — M2-Planet `bd2fe4b` (Release_1.13.1) + the 77-patch series, materialized by the spike's own procedure, plus `bootstrappable.c` so nothing official builds from `spikes/`. Provenance, license (GPL-3.0-or-later) and the fork-point declaration live in `micro-c/ORIGIN.md`. **Verified at adoption: micro-c rebuilt from this exact tree is byte-identical to the spike-materialized build.** Slated for a rewrite that retires the inherited lineage; ORIGIN.md holds until then. |
| `micro-c-libc/` | the freestanding libc micro-c hands to tcc, adopted verbatim from the spike. |
| `tcc/` | pin + ONE condensed patch (see `tcc/README.md`); `condense.sh` generates and proves `tcc-veron.patch` on a networked machine. |

**Substage records are deliberately absent here for now.** The ledger's
builder edges must name the artifact that actually built each output, and in
the trunk that is pico-c-built micro-c — not a host-gcc dev build. Records
for 3/x land with the trunk extraction (§7 step 3), produced by the real
chain, never faked from a convenience build. The dev build's only role is
verification, and its byte-identity check lives in ORIGIN.md.
