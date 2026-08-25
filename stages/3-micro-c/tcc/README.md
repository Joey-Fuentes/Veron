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
- **Cutover done (2026-08-25):** `build.sh`'s in/ phase now takes the
  pristine pin (clone_pinned from `sources/tcc.toml`) + `tcc-veron.patch`
  by strict `git apply` + the written `config.h` beside this file. The
  toolbox tarball and the two spike series are no longer on the official
  build path; the spike workflows still use them and stay untouched.
  Forced by the ladder's first run ON VERON: the image's busybox patch has
  neither `-d` nor fuzz, and the old path had leaned on both.
- **`tccdefs_.h`:** the predefs the compiler bakes in, generated from
  `include/tccdefs.h` by `tools/c2str.py` -- tinycc's `conftest.c -DC2STR`
  ported line for line, proven byte-identical to the gcc-built reference
  -- and regenerated + compared on every `in` run.
- **`config.h`:** written, not generated -- only the values that reach the
  compiler, each a decision, with the grep that justifies every omission.

Run once, commit the output:

    sh stages/3-micro-c/tcc/condense.sh
    git add stages/3-micro-c/tcc/tcc-veron.patch
