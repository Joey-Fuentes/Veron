# stages/3-micro-c/tcc — the handoff compiler: a pin plus ONE patch

Design D2: tcc stays **upstream at a pinned commit plus one condensed,
reviewable veron patch**, applied normally — unlike micro-c, which is
adopted as in-tree source, tcc's delta is small enough that "read the diff"
is the right audit shape.

- **Pin:** `sources/tcc.toml` is the single source of truth (commit
  `5ec0e6f8…`, 0.9.28rc, LGPL-2.1-or-later, repo.or.cz canonical). This
  directory deliberately does NOT repeat it.
- **The delta today:** two series the spike workflows apply in order —
  `spikes/stage3/patches/tcc-arm64-asm/` then `spikes/stage3/patches/tcc-microc/`.
- **`tcc-veron.patch`:** the two series folded into one patch, generated and
  PROVEN by `condense.sh` (pristine + one patch must reproduce pristine +
  the full series, byte for byte). It is absent until `condense.sh` has run
  once on a machine with network — never commit an artifact that was never
  verified. The toolbox tcc tarball cannot serve as the base: it is a
  mid-series dev snapshot, measured, not pristine.
- **At cutover:** `sources/tcc.toml`'s `[patches]` section repoints from the
  spike series dirs to this one file; the spike dirs stay live and untouched
  until then (§7.0).

Run once, commit the output:

    sh stages/3-micro-c/tcc/condense.sh
    git add stages/3-micro-c/tcc/tcc-veron.patch
