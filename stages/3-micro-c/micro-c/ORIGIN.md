# ORIGIN — micro-c is Veron source, adopted from a declared fork point

This directory holds THE exact micro-c source, in-tree, already patched,
exactly as the build needs it (design D2: adopted source, not pin+patches).
It is slated for a rewrite that abandons the M2-Planet lineage; until
inherited lines are gone, this file records the fork point so attribution
and license provenance (criterion 7) hold.

- **Forked from:** M2-Planet `bd2fe4b0659fd0ad3f476a5ad0ef801bd134665d`
  (tag Release_1.13.1, 2025-08-17), https://github.com/oriansj/M2-Planet.git
- **Plus:** the 77-patch series (4 in `spikes/stage3/patches/m2-planet/`,
  73 EXPERIMENT patches in `spikes/stage3/patches/micro-c-experiments/`),
  applied in lexical order with `git apply --ignore-whitespace` — the exact
  procedure of `spikes/stage3/tools/local-build.sh`. Combined series
  sha256: `e0c3a675bbec0f7cacc2bfd20ba7daf18a6a45e82f366350818abfea4dd57334`
- **Plus:** `bootstrappable.c` from M2libc
  `ca023d8dc855171fd0618951add5817e0e568fca` (the one M2libc file micro-c
  links; adopted here so nothing official builds from spikes/).
- **Upstream license:** GPL-3.0-or-later (see `LICENSE`, unmodified). This
  directory is therefore GPL-3.0-or-later, not MIT, until the rewrite
  replaces the inherited lines — recorded per amended invariant 6: adopted
  in-tree source with origin + license declared, never silent.
- **Verified at adoption:** micro-c rebuilt from this exact tree is
  byte-identical to the tree materialized by the spike's own script.

- **Removed at adoption (git metadata, not source):** `.gitmodules` and the
  empty `M2libc/` submodule mountpoint it declared — the vendored form has
  no external submodule; `bootstrappable.c` is adopted at top level and the
  handoff libc lives in `../micro-c-libc/`. Upstream's `.gitignore` files
  are KEPT: they ignore only scratch/output paths (verified against the
  tree: nothing they name exists in it), and they stop local test runs from
  dirtying the official tree.

The spike copies (`spikes/reference/m2-planet`, the patch dirs) stay live
and untouched per §7.0 until cutover; THIS tree is the official source.
