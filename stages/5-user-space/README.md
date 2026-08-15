# stages/5-user-space — the package set and the image

Redone from `spikes/stage5` under §7.0 by adopting its proven recipes and
driver logic at a pinned commit — the spike original stays live and is the
oracle: byte-identical output between the official stage-5 run and the live
spike run is the acceptance test. `packages/`, `packages-amd64/` (the
overlay model, unchanged), `boot/`, `guest/` land here; the repo-wide pins,
keyring and expected-differences move up to `/policy`; anything genuinely
stage-local stays beside the stage as `policy-local/`.

Consumes `4/latest-<arch>`; publishes `5/latest-<arch>`.

**Status: SCAFFOLD ONLY — adoption is §7 step 2.**
