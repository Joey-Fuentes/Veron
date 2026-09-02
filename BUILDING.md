# Building Veron locally, stage 1 through stage 6

This is the sequence that produces the flashable image on a machine you own,
and the comparison that proves it is the same image GitHub Actions publishes.

**Verified 2026-09-01.** A Veron laptop and a GitHub Actions runner on the
same commit produced byte-identical artifacts at every stage, 1 through 6, ending in the same `veron-x86_64-<sha7>.img` and the same
`.img.zst`. Stages 1 through 3 were compared against their published
releases in an earlier session; stages 4 through 6 in the session that
closed the last differences. The digests for 4 through 6 are recorded in the
last section, with the exact comparison commands. Anyone on that commit who
follows this document should reproduce them. If you do not, that is a
finding, and the tools in `tools/` are how to locate it.

## What you need

- A Linux host with `bwrap` (bubblewrap), `python3`, `curl`, `git`, `tar`.
  A Veron machine has all of these. An Ubuntu machine needs
  `apt-get install bubblewrap`; the rest are usually present.
- Network for the `in` phases, which download pinned sources and verify
  them. Every other phase runs inside a box with no network.
- Disk: roughly 40 GB free for a full stage-5 build. `/tmp` must not be a
  small tmpfs; stage 5 uses it for image work.
- Memory: 8 GB minimum. Stage 5 builds wpewebkit with LTO and will be killed
  under memory pressure with no swap.
- On a Veron host, `SSL_CERT_FILE` handling is built into stages 5 and 6.
  On other hosts python's default trust store is used.

The tools bundle is fetched first and used by every stage:

```sh
cd ~/Veron
sh tools/fetch-tools.sh
```

It unpacks `veron-tools/`: this project's own static `zstd`, `debugfs`,
`mke2fs`, `busybox`, `qemu`, and OVMF, verified against a published
`TOOLS-SHA256`. Stages 4 and 5 prefer the binaries they build themselves
(`dest/…`) and fall back to this bundle; stage 6 has no `dest/` and uses the
bundle directly. `PACKED-BY` in each stage's output names which one packed
each archive.

## Clean start

To build from nothing:

```sh
cd ~/Veron
git status --short          # commit or stash anything you want to keep
git clean -fxd              # removes box*/, out/, in/, dl/, veron-tools/ and every checkpoint
sh tools/fetch-tools.sh
```

`git clean -fxd` deletes every untracked file. That includes downloaded
sources under `dl/`, which will be fetched again by the `in` phases.

## Stage 1 — self-assembly

The stage-1 binaries are committed. This stage verifies them; it builds
nothing new.

```sh
sh stages/1-self-assembly/roundtrip.sh
```

See `stages/1-self-assembly/README.md`.

## Stage 2 — pico-c

```sh
sh stages/2-pico-c/verify.sh
```

Produces `out/2/aarch64/pico-c` and `out/2/aarch64/pico-c-assembler`, which
stage 3 reads. Stages 2 and 3 execute aarch64 binaries: on an aarch64 host
they run natively; on x86_64 they run under `qemu-aarch64-static`, which the
tools bundle provides.

## Stage 3 — micro-c and tcc

```sh
sh stages/3-micro-c/build.sh in
sh stages/3-micro-c/build.sh chain
```

Produces `out/3/x86_64/tcc-amd64`, the compiler stage 4 starts from. Its
digest must match the committed record in
`stages/3-micro-c/substages-amd64.toml`; the chain fails if it does not.

If `out/3` is absent, stage 4's `in` fetches the same `tcc-amd64` from the
`3/latest-x86_64` release and checks it against the same record. Either
route yields identical bytes or stage 4 refuses to start.

## Stage 4 — toolchain and kernel

```sh
sh stages/4-toolchain-kernel/build.sh in
sh stages/4-toolchain-kernel/build.sh chain
sh stages/4-toolchain-kernel/build.sh collect
sh stages/4-toolchain-kernel/build.sh boot
sh stages/4-toolchain-kernel/build.sh pack
```

`chain` is the long one: tcc → gcc 4.7.4 → gcc 10.2.0 → gcc 15.2.0 → glibc
→ the full sysroot, in a box holding busybox and tcc and nothing else.
Several hours.

`pack` writes `out/4/rel/`: `sysroot.tar.zst`, `SYSROOT-SHA256`, `Image`,
`initramfs.cpio.gz`, `PROVENANCE`, `PACKED-BY`, `manifest.tsv`, `BUDGET`.

Then the generic kernel, which stage 6 puts on the disk:

```sh
sh stages/4-toolchain-kernel/generic.sh in
sh stages/4-toolchain-kernel/generic.sh config
sh stages/4-toolchain-kernel/generic.sh build
sh stages/4-toolchain-kernel/generic.sh boot
sh stages/4-toolchain-kernel/generic.sh efi
sh stages/4-toolchain-kernel/generic.sh loader
sh stages/4-toolchain-kernel/generic.sh pack
```

`pack` writes `out/4-generic/rel/`: `vmlinuz-generic`, `config-generic`,
`veron-boot.efi`, `modules-<ver>-generic.tar.zst`, `KERNEL-GENERIC-SHA256`,
`PROVENANCE`, `PACKED-BY`.

## Stage 5 — user space

```sh
sh stages/5-user-space/build.sh in
sh stages/5-user-space/build.sh chain
sh stages/5-user-space/build.sh merge
sh stages/5-user-space/build.sh image
sh stages/5-user-space/build.sh boot
sh stages/5-user-space/build.sh strip
sh stages/5-user-space/build.sh pack
```

`in` takes the sysroot from `out/4/lfs` and the generic kernel from
`out/4-generic/rel` when they exist, otherwise from the `4/latest-x86_64` and
`4/kernel-x86_64` releases, digest-checked either way.

`chain` builds 172 packages against that sysroot. Several hours. Every
package's DESTDIR lands in `spikes/stage5/dest/<name>/`, and a checkpoint
marker keyed to the sysroot digest is written beside them.

**Re-running after the first build.** `chain` starts with `build --clean`,
which wipes `dest/` and rebuilds everything. To resume from what is already
built:

```sh
USE_CHECKPOINT=1 sh stages/5-user-space/build.sh chain
```

This restores every package whose key still matches and builds only what
changed. Then continue from `merge`.

`boot` must run before `strip` on the first pass: it resolves the generic
kernel into `boot-generic/`, which the trace records read. The phases are
meant to be run in the order above.

`pack` writes `out/5/`: `rootfs.img`, `rootfs.img.tar.zst`,
`rootfs-full.img.tar.zst`, `IMAGE-SHA256`, `PACKED-BY`, `files.tsv`,
`initramfs.cpio.gz`, `Image`.

## Stage 6 — release image

```sh
sh stages/6-release/build.sh in
sh stages/6-release/build.sh unpack
sh stages/6-release/build.sh fw
sh stages/6-release/build.sh image
sh stages/6-release/build.sh boot
sh stages/6-release/build.sh pack
```

`in` takes `out/5/rootfs.img` and `out/4-generic/rel/` when present,
otherwise the releases. `boot` runs the assembled disk under OVMF on both
attachments and refuses to pack if the consumer path does not reach init.

`pack` writes `out/6/`: `veron-x86_64-<sha7>.img`, its `.zst`,
`SHA256SUMS`, `INPUTS`, `PACKED-BY`, `BUDGET`.

## Comparing against CI

Each stage's release carries the same record files the local build writes.
The comparison is the same shape at every stage: fetch the release's small
records, `diff` them, and only if a digest differs go into the payload.

### Stage 4

```sh
cd ~/Veron
rm -rf /tmp/ci4 && mkdir -p /tmp/ci4
B=https://github.com/Joey-Fuentes/Veron/releases/download/4/latest-x86_64
for f in $(ls out/4/rel); do curl -fsSL -o "/tmp/ci4/$f" "$B/$f" || rm -f "/tmp/ci4/$f"; done
for f in $(ls /tmp/ci4); do
  cmp -s "/tmp/ci4/$f" "out/4/rel/$f" && printf '%-26s same\n' "$f" || printf '%-26s DIFFER\n' "$f"
done
```

`SYSROOT-SHA256`, `PROVENANCE`, `Image`, `initramfs.cpio.gz`,
`sysroot.tar.zst` are the ones that must match. `BUILD-RUN` is CI-only by
design. `trim.txt` and `manifest-b8.tsv` are known to differ in ways that
do not reach the sysroot (an unsorted `find` in the trim log; phase-A
intermediates that are trimmed before packing).

The same loop against `4/kernel-x86_64` and `out/4-generic/rel` for the
generic kernel; every file must match.

### Stage 5

```sh
cd ~/Veron
rm -rf /tmp/ci5 && mkdir -p /tmp/ci5
B=https://github.com/Joey-Fuentes/Veron/releases/download/5/latest-x86_64
for f in IMAGE-SHA256 PACKED-BY; do curl -fsSL -o "/tmp/ci5/$f" "$B/$f"; done
diff /tmp/ci5/IMAGE-SHA256 out/5/IMAGE-SHA256 && echo "image identical"
diff /tmp/ci5/PACKED-BY   out/5/PACKED-BY   && echo "archives identical"
```

`IMAGE-SHA256` is the digest of `rootfs.img`. `PACKED-BY` records, for
each `.zst`, the digest of the `tar` and `zstd` binaries that made it and
the digest of the result; identical `PACKED-BY` means identical tarballs
without downloading them.

If `IMAGE-SHA256` differs, the image is an ext4 filesystem and the
comparison goes inside it:

```sh
curl -fsSL -o /tmp/ci5/rootfs.img.tar.zst "$B/rootfs.img.tar.zst"
veron-tools/zstd -dc /tmp/ci5/rootfs.img.tar.zst | tar -xf - -C /tmp/ci5
python3 tools/img-compare.py /tmp/ci5/rootfs.img out/5/rootfs.img
```

`img-compare.py` walks both filesystems with `debugfs` and compares every
entry -- content hash, mode, size, symlink target, hardlink group -- and
prints every difference grouped by location. `tools/img-diff-files.py`
shows the diff of a named file across the two images. If `img-compare`
reports identical and the digests still differ, the container layout
differs while the contents do not; `cmp -l` for the differing blocks and
`debugfs icheck` to name their inodes is the next step.

### Stage 6

```sh
cd ~/Veron
TAG=$(gh release list --limit 20 | awk '/^release\//{print $1; exit}')   # or the tag from the CI log
rm -rf /tmp/ci6 && mkdir -p /tmp/ci6
B=https://github.com/Joey-Fuentes/Veron/releases/download/$TAG
for f in SHA256SUMS INPUTS PACKED-BY; do curl -fsSL -o "/tmp/ci6/$f" "$B/$f"; done
diff /tmp/ci6/INPUTS    out/6/INPUTS    && echo "inputs identical"
diff /tmp/ci6/SHA256SUMS out/6/SHA256SUMS && echo "image and archive identical"
```

`INPUTS` first: if the rootfs and kernel digests it records differ, the two
legs assembled different inputs and nothing downstream is comparable.

## What was verified, exactly

On 2026-09-01 a Veron laptop (`veron`, uid 1000, after `git clean -fxd`) and
GitHub Actions (`ubuntu-latest`, uid 1001), on the same commit, produced the
same bytes at every stage.

Stages 1 through 3 were verified against `3/latest-x86_64` and its
committed records in `stages/3-micro-c/substages-amd64.toml`; stage 4's `in`
re-checks that same `tcc-amd64` digest on every run, so the trunk's output
is confirmed each time stage 4 starts. Stages 4 through 6:

| stage | artifact | sha256 |
|---|---|---|
| 4 | `sysroot.tar.zst` | `3eed834c7b076d8ef65020d49a1d47d2633c2b2d01d8e3b45f7f82a6c7a3c195` |
| 4 | `PROVENANCE` | identical (`diff` empty) |
| 4-generic | every file in `rel/` | identical (`cmp` on each) |
| 5 | `rootfs.img` | `11f4d7928728f78e203e5996d258b9f14de196ce934061b7cb723ab79e16e5eb` |
| 5 | `rootfs.img.tar.zst` | `fb7ec30dbf7c4047bcdb868d0dad1e693e3f764b29a576050e986d7e479d49f9` |
| 5 | `rootfs-full.img.tar.zst` | `805546b4c7e4ee2b6fd3516e8cfb28b3008b653a07c3ab7fe50c8b12098b0ed0` |
| 6 | `veron-x86_64-c6ee72c.img` | `c6ee72c6f6052270d360ab0c030a7b9c2029dffa2f1a4a389b89e600a1e6774a` |
| 6 | `veron-x86_64-c6ee72c.img.zst` | `9aade9c15bc89de94e9fefe5dc4fae4f0755bb5ff1204881156c073c778c3511` |

The stage-5 comparison was made with `img-compare.py` over all 31,962
entries and 27,916 file contents before the digests were compared, so the
match is known to be content-for-content and not only container-for-
container. The stage-5 CI leg restored all 172 packages from its checkpoint;
the local leg built all 172 from source. That they agree is also a proof
that the checkpoint holds what a fresh build produces.

Things that had to be true for this to hold, each found by a difference and
fixed:

- the image is laid out by the `mke2fs` this build made, on both legs, not
  the host's (`build_img` in stage 5; `PACKED-BY` names it);
- the built `debugfs` runs inside the sysroot box, because a static glibc
  binary that `dlopen`s borrows the host's loader, and Ubuntu's refused it;
- every archive is compressed by the `zstd` this build made, on both legs
  (`pack-in-box.sh`; `PACKED-BY` names it);
- the strip runs inside the box on the sysroot's own tools, since busybox
  and coreutils disagree on `chmod --reference`;
- the ledger and every install listing classify symlinks with `lstat`, so
  a link whose absolute target happens to exist on one host and not the
  other is recorded the same on both;
- checkpoint restores preserve modes (`tar -p`), `__pycache__` never ships,
  perl pins `osvers` and `cf_time`, libtool pins `max_cmd_len`, and the
  provenance records inside the image pin artifacts by digest rather than
  carrying documents whose wording could differ.

If a future comparison differs, the record files -- `PACKED-BY`, `INPUTS`,
`CHAIN`, `PROVENANCE` -- are designed to name which tool or input moved
before any payload has to be inspected.
