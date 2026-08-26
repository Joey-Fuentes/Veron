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

## Running it (2026-08-26: extracted from the workflow into `build.sh`)

    sh stages/5-user-space/build.sh in      # selftest, plan, sysroot + kernel (out/4 first, else attested releases), sources, checkpoint (gh)
    sh stages/5-user-space/build.sh chain   # VERON-SEAL + every package in the sysroot box; the gates
    sh stages/5-user-space/build.sh merge   # the system
    sh stages/5-user-space/build.sh image   # the image, repro probe, initramfs
    sh stages/5-user-space/build.sh boot    # its own tests under the qemu it built; BOOT_SYSTEM=1 / NET_TEST=1 for more
    sh stages/5-user-space/build.sh strip   # strip, rebuild, re-verify
    sh stages/5-user-space/build.sh pack    # out/5

Same text on a GitHub runner, a Veron laptop, or any Linux with bubblewrap.
Knobs are environment variables (STOP_AFTER, USE_CHECKPOINT, ADOPT_CHECKPOINT,
SEED_INSTALLS, SELFREBUILD, BOOT_SYSTEM, NET_TEST, SKIP_BOOT). Working tree
is `spikes/stage5/{sysroot,dl,build,dest,out,logs}` (gitignored), state
across phases in `box5/env.sh`. A cold build (no checkpoint) is most of a
day on a laptop; disk to be measured.
