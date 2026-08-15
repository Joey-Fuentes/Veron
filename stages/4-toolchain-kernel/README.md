# stages/4-toolchain-kernel — tcc → gcc → linux → boot

Redone from `spikes/stage4` under §7.0. The build logic currently lives as
~4,500 lines of inline workflow shell; the extraction step (design doc §7
step 3) adopts it here as one script per substage in `substages/`, each
running EXACTLY the commands the spike workflow runs today, proven by
byte-identical output against the live spike workflow as oracle. Patches in
`patches/`. This directory's `README` also carries the substage map,
including the spike-era numbering (0–16 + 3.5/4.5, B0–B8) as the local
scheme it remains.

Consumes `3/latest-<arch>`; publishes `4/latest-<arch>` (sysroot + the
kernel matrix). Substage records per design doc D4.

**Status: SCAFFOLD ONLY — extraction not begun.**
