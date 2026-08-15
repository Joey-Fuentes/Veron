# stages/3-micro-c — micro-c, and the tcc it hands to stage 4

Two components, deliberately in the only two postures amended invariant 6
allows (design doc D2):

- **`micro-c/` — Veron source, adopted in-tree.** The exact micro-c source,
  already patched, exactly as the build needs it. Not a pin: no fetch, no
  patch step, no upstream copy to drift against. Slated for a rewrite that
  abandons the M2-Planet lineage; until inherited lines are gone, `ORIGIN.md`
  records the fork point and upstream license (criterion 7). Every file here
  is a `repo` trace root.
- **`tcc/` — a pinned package.** A pinned RELEASE tarball (named in
  `sources/`) plus **ONE condensed veron patch**, applied normally by the
  build system like any stage-4/5 package. tcc is stage 3's OUTPUT — the
  artifact handed to stage 4 (`mc-tcc → <arch>-tcc → tcc + musl` for cross
  targets) inside `3/latest-<arch>`.

**Status: NOT YET ADOPTED.** Adoption = copy the exact micro-c tree from
`spikes/stage3` at a pinned commit + write `ORIGIN.md` + condense the tcc
patch series into one patch and pin the tcc release in `sources/`. The stale
vendor copy at `spikes/reference/` retires only at cutover; spikes stay
untouched until then (§7.0).
