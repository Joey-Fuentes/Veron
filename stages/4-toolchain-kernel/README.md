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

## Running it (2026-08-25: extracted from the workflow into `build.sh`)

    sh stages/4-toolchain-kernel/build.sh in        # airlock: 3->4 contract (out/3 first, else the release, attested), pins, repack
    sh stages/4-toolchain-kernel/build.sh chain     # the box: ref-tcc -> musl -> make -> binutils -> gcc -> the final system
    sh stages/4-toolchain-kernel/build.sh collect   # out/4/{boot,toolchain,manifest}, BUDGET
    sh stages/4-toolchain-kernel/build.sh boot      # the kernel under qemu -- ours when the host has it
    sh stages/4-toolchain-kernel/build.sh pack      # trim + tar -> out/4/rel (the release payload); out/4/lfs where GNU tar is absent

Same text on a GitHub runner, a Veron laptop, or any Linux with bubblewrap.
The pins are `pins.env`, one place. The busybox the box uses is resolved
the way `stages/box.sh` resolves it (bundle, airlock-built from the pin,
or the system's) and recorded by hash in `out/4/BUDGET`.

Disk, measured on bare-metal Veron 2026-08-26, nothing deleted as it goes
(the build tree is the build tree; what leaves it is the deliverable):
stages 1-3 0.25 GB; the stage-4 airlock ~2 GB; the chain through `pack`
**40 GB**. `box4/` is the box and is one `rm -rf` when you are done.

## The generic kernel (`generic.sh`)

    sh stages/4-toolchain-kernel/generic.sh in|config|build|boot|efi|loader|pack|all

Extracted 2026-08-26 from 4-generic-kernel-amd64.yml. Consumes `out/4/lfs`
when a local stage-4 run made one, else `4/latest-x86_64` (attested).
Scratch is `box4g/`, outputs `out/4-generic/rel`. The squashfs gate needs
`mksquashfs` (CI has it; the image does not, and says so); the EFI gate uses
the host's OVMF (`/usr/share/qemu/OVMF.fd` on the image).

## Diagnostics (`tools/diag/`)

    sh tools/diag/kernel-diff.sh    # this checkout's generic kernel vs the published one: digests, ELF extraction, strings diff

For the case where the kernel differs between two hosts on the same
commit; the output names the input that differed, or says it is code
layout. `extract-vmlinux.py` is the kernel's `scripts/extract-vmlinux`
without its GNU-grep and mktemp assumptions, so it runs on the image.
