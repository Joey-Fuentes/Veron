# Stage 6 -- the consumer release

    sh stages/6-release/build.sh in       # rootfs (stage 5), kernel + loader + modules (stage 4), firmware pins
    sh stages/6-release/build.sh unpack   # rootfs.img -> box6/rootfs, with this project's debugfs
    sh stages/6-release/build.sh fw       # the firmware tree, made in the box
    sh stages/6-release/build.sh image    # the A/B GPT image, made in the box, twice, compared
    sh stages/6-release/build.sh boot     # the consumer path (ahci, usb) under the system's own OVMF
    sh stages/6-release/build.sh pack     # out/6: named image, .zst by our zstd, SHA256SUMS, PACKED-BY, BUDGET

Inputs come from this checkout's own `out/5` and `out/4-generic` when they
exist, else from the releases (digest-checked; attestation-checked with `gh`).

The box is the released system itself (`box6/rootfs`), with bubblewrap
mapping the invoking user to uid 0: python 3.14, e2fsprogs, make, zstd and
busybox in there make every byte of the image, and every file in it is
root's. The host supplies a kernel, bubblewrap, curl, and -- for the unpack
and the gate -- debugfs and qemu from the stage-5 tools bundle or, on Veron,
from `/usr/sbin` and `/usr/bin`; `box6/BUDGET` names each by sha256.

`out/6/SHA256SUMS` is what the website shows. A bare-metal Veron on the same
commit produces the same lines, or the ledger says which file did not.
