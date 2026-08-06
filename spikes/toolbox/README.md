# spikes/toolbox — committed development tools

Two binaries that a sandbox cannot fetch for itself, committed so that stage-3
work can be done outside CI. Read the **What this is not** section before
assuming anything about them.

## What is here

| file | bytes | sha256 (first 16) |
|---|---|---|
| `qemu-aarch64-static` | 6,245,816 | `bfcd46c842441912` |
| `tcc-5ec0e6f8-arm64-configured.tar.gz` | 1,019,196 | `2e441f5c6b73cf01` |

`SHA256SUMS` carries the full digests. Verify with `sha256sum -c SHA256SUMS`.

---

## `qemu-aarch64-static`

**What it is.** QEMU's *user-mode* aarch64 emulator: it runs an aarch64 Linux
ELF on a non-aarch64 host by translating instructions and forwarding syscalls.
It is not a machine emulator and boots nothing.

```
qemu-aarch64 version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.17)
ELF 64-bit LSB pie executable, x86-64, static-pie linked, stripped
BuildID[sha1] 6c2f342fd4968ac4a578fc652864bb62693764bf
```

**Where it came from.** `apt-get install qemu-user-static` on `ubuntu-24.04`,
copied from `/usr/bin/qemu-aarch64-static` by
[`.github/workflows/local-toolbox.yml`](../../.github/workflows/local-toolbox.yml).
That workflow is the reproduction recipe: run it and you get this file again.

**It is an x86_64 binary on purpose.** A `qemu-aarch64-static` built *for*
aarch64 emulates aarch64 *on* aarch64, which is useless to an x86_64 host. The
workflow asserts `uname -m` is `x86_64` and fails otherwise, because that
mistake produces a file that looks correct and helps nobody.

**Why we need it.** Veron's target is aarch64. `stage0-as`, `elf`, `stage1`,
`stage2` and everything micro-c emits are aarch64 binaries, and a development
machine generally is not. Without an emulator the only way to *run* any of it
is a CI round of about three minutes; with it, locally, about a second.

The concrete difference: `05-struct-assign` sat red for the entire life of the
case suite and could not be reproduced locally at all. Under this emulator it
reproduced immediately, and the cause turned out to be three wrong instruction
encodings in M2libc's macro table — not a compiler bug.

**How to use it.** For stage-3 work you do not invoke it directly --
`spikes/stage3/tools/local-build.sh` and `local-tcc.sh` do, and they also
encode the four silent traps between a clean checkout and a working setup.
Start there.

To use it by hand, invoke it explicitly. No `binfmt_misc` registration, no
root:

```sh
spikes/toolbox/qemu-aarch64-static ./some-aarch64-binary
```

The whole spike ladder runs this way:

```sh
Q=spikes/toolbox/qemu-aarch64-static
$Q spikes/stage0-as/stage0-as < prog.s | $Q spikes/elf/elf a.out && $Q ./a.out
```

**Licence.** QEMU is GPLv2. This is an unmodified Debian/Ubuntu build; the
source is `qemu` `1:8.2.2+ds-0ubuntu1.17` from Ubuntu 24.04.

---

## `tcc-5ec0e6f8-arm64-configured.tar.gz`

**What it is.** tinycc at pin `5ec0e6f84b47ebd8c269b581712666313f5edaef`
(version `0.9.28rc`), with `spikes/stage3/patches/tcc-arm64-asm/` applied and
`./configure --cpu=arm64` already run. 546 files, `.git` removed.

**Why it is *configured* and not a plain checkout.** `tcc.h:27` includes
`config.h`, which does not exist in the repository — `./configure` writes it.
`tccdefs_.h` is generated from `include/tccdefs.h` by a `c2str` helper that has
to be compiled first. A raw clone has neither, and that is exactly what
`tcc-two-ways` tripped over on its first run. Both are present here:

```
config.h        present
tccdefs_.h      13,286 bytes
```

**Why we need it.** It is the input to the whole stage-3 exercise: micro-c
compiles `libtcc.c` from this tree. Without it the sandbox can build micro-c
but has nothing to point it at, so every question about how far tcc gets costs
a CI round.

**Why the pin.** See [`sources/tcc.toml`](../../sources/tcc.toml). `mob` is a
moving target and its own arm64 assembler rejects instructions musl needs;
`5ec0e6f8` is the tree the Feb-2026 assembler series was written against,
located by matching pre-image blob hashes in the patches rather than by date.

**Licence.** tinycc is LGPL-2.1-or-later.

---

## What this is not

- **Not on any build path.** Nothing in `stages/`, `seed/`, `lib/` or any
  hermetic workflow reads this directory. `BUDGET_PATH` is unaffected, the
  `SEAL` step in `stage3-hermetic-arm64` does not see it, and no byte of any
  artifact comes from here. These are tools for *looking at* the work.

- **Not a trust root, and not verified.** Everything under `seed/` and
  `spikes/stage0-as/` is committed *derived* and checked against its own
  source by round-trip disassembly under two independent decoders. **These two
  files get none of that.** `qemu-aarch64-static` is an opaque 6 MB binary from
  a distribution package and we have not disassembled it. That is a deliberate
  exception to "nothing opaque is committed", and it is acceptable only because
  of the point above: it cannot influence an output, only what we observe about
  one.

- **Not required.** Delete the directory and every workflow still passes. What
  you lose is the local loop.

- **Not a substitute for CI.** amd64 hides an entire class of bug — unaligned
  access faults on ARM and is tolerated on x86 — and four bugs in this work
  were invisible on amd64 and fatal on aarch64. The emulator narrows that gap
  but does not close it: qemu is not silicon, and `tcc-two-ways` still runs on
  a real `ubuntu-24.04-arm` runner. Local results are a filter, not a verdict.

## Refreshing them

Run `.github/workflows/local-toolbox.yml` (`workflow_dispatch`), download the
`veron-local-toolbox` artifact, replace these files, and update `SHA256SUMS`
and the table above. That workflow proves the emulator works before uploading
it — it cross-compiles a real aarch64 binary and runs it under the copy it is
about to ship, rather than asserting that a version string looks right.

## The third piece, already committed elsewhere

M2-Planet at pin `bd2fe4b` (tag `Release_1.13.1`) lives at
[`spikes/reference/m2-planet/`](../reference/m2-planet). micro-c is that tree
plus `spikes/stage3/patches/`. It sat 56 commits past the pin for weeks, which
meant the patch series would not apply and micro-c could not be built outside
CI at all — see that directory's README for the check that would have caught
it.

## qemu is built from pinned source now, and there are two of them

It used to be `apt-get install qemu-user-static` and a `cp` out of `/usr/bin`
-- an opaque host binary in an artifact this repository ships. That is below
the bar `TRUST-BOUNDARY.md` sets for tier 2, which busybox meets: *"the source
is ours to choose and PINNED; the compiler that turned it into a binary is the
runner's."* An apt package meets neither half, and the tool used to check that
this chain's output runs was the one thing here with no provenance.

`local-toolbox.yml` now fetches a pinned qemu tarball through the mirror and
builds both targets from the one tree:

| | what it is for |
|---|---|
| `qemu-system-aarch64` | boots a stage-4 `Image` -- **new**, and the reason for the change |
| `qemu-aarch64-static` | runs an aarch64 binary on x86-64, as before |

**Why the system emulator matters more than it sounds.** B5.5 -- `switch_root`,
dinit as PID 1, the writable overlay -- is the one piece of this project only
testable at the END of a full run. Iterating on it through CI is forty minutes
a cycle. With a local `qemu-system-aarch64` the same loop is seconds, against
the same `Image` the release publishes.

**The version has to be checked, not remembered.** The first attempt pinned
qemu 9.2.4 -- a version recalled rather than read from download.qemu.org, when
the current stable was 11.0.3. The digest for it was measured honestly and was
still the wrong pin, because *a correctly measured digest of the wrong tarball
is still wrong*. The `PENDING` mechanism catches an invented digest; it cannot
catch an invented version, and nothing else here can either.

**The digest starts as `PENDING` on purpose.** The first dispatch fetches the
tarball, prints the sha256 it measured, and refuses to build. Paste it in and
dispatch again. Two recipes in this repository already carry a comment about a
digest that was invented rather than read; a wrong one here would be a pinned
lie about the only tool that checks whether the chain's output runs.

**`--static` is attempted, not required**, and the fallback had to be moved
once. It originally triggered on `./configure --static` failing -- but static
configure *succeeded*, and the build died three thousand targets later:

```
/usr/bin/ld: cannot find -lmount
```

glib's static build pulls libmount, libblkid, libselinux, pcre2 and libffi,
and a missing `.a` for any of them surfaces at LINK time, not at configure
time. **A fallback that cannot see the failure it exists for is decoration.**
It now covers configure and build together, and the `-dev` packages those five
need are installed so the static path has a chance of succeeding rather than
merely being attempted. If it still fails, the job builds dynamically and
packs the shared libraries beside the binaries -- worse for portability, still
better than an apt binary.

**And it is a stage-5 recipe eventually.** qemu's build dependencies -- glib,
pixman, zlib, meson, ninja, python -- are *already* stage-5 packages, all six
built and tested. Once stage 5 boots well enough to host a build, qemu is
compiled by the compiler this chain produced, against libraries this chain
built, and the emulator traces back to stage 0 like everything else. At that
point the tier-2 caveat above disappears entirely.

## Static is the goal, and one of the two gets there today

**bwrap does.** Its only dependency is libcap, apt ships `libcap.a`, and the
result is one file that runs anywhere. It is built here from the same pinned
tarball `stage5-isolate` uses, and checked the same way -- `--overlay-src`
present, `--unshare-all` actually sandboxes -- because the copy people
download deserves the assertion the spike makes for itself.

**Until now it did not ship at all.** stage5-isolate built it, installed it
into the runner, and the runner was destroyed. The argument that convinced us
not to trust the host's bwrap -- that `--overlay-src` is a property of the
VERSION -- was never extended to anyone else, who still had to get bwrap from
whatever their distro packages.

**qemu does not get there yet, and the reason is not qemu.** Static linking
qemu means static linking glib, and glib's `Libs.private` pulls libmount,
libblkid, libselinux, pcre2 and libffi. Debian and Ubuntu stopped shipping
static archives for several of those, so `--static` fails at link time on a
`.a` that apt cannot provide -- which is why the job falls back to dynamic and
packs the libraries with a loader shim.

Two ways out, and the second is the one this project is already walking
toward:

- **Build glib and its chain from pinned source here**, statically, and link
  qemu against those. More pinned sources, all of which stage 5 already has
  recipes for.
- **Build qemu as a stage-5 package.** glib, pixman, zlib, meson, ninja and
  python are already in the set. At that point qemu is compiled by the
  compiler this chain produced, against libraries this chain built, and
  static linking is a flag rather than a fight with someone else's packaging.

The second answers portability and provenance at once, which is why it is
worth waiting for rather than working around.

## What the artifact is for

Two static-or-shimmed tools and a tcc tree, so somebody with neither qemu nor
bubblewrap can **run** a Veron image and **build** one, without their distro
having a say in either. That is the same reason the sources are mirrored: a
build that depends on what a host happened to install is not reproducible by
anyone who does not have that host.

## It is published, and here is the loop it enables

`toolbox/latest` carries the tarball. Two commands and a foreign host can run
Veron:

```sh
gh release download toolbox/latest -p veron-toolbox.tar.gz && tar xzf veron-toolbox.tar.gz
gh release download stage4/latest  -p Image -p initramfs.cpio.gz
./qemu-system-aarch64.sh -machine virt -cpu max -m 2048 -nographic \
  -no-reboot -nic none -device virtio-gpu-pci -device virtio-keyboard-pci \
  -kernel Image -initrd initramfs.cpio.gz \
  -append "console=ttyAMA0 rdinit=/init panic=1"
```

**This was used to verify the kernel change before any CI run.** A modified
initramfs was built, booted, and its output read in about a minute:

```
PROBE-DRM    card0
PROBE-EVDEV  event0 event1
PROBE-FS     ext4, overlay
```

That is the same probe that reported `VERON-DRM-ABSENT` from a stage-5 run,
answering. `/dev/dri/card0` exists, so wlroots has a device to open; `overlay`
is in `/proc/filesystems`, so B5.5's writable-layer design has its kernel
support.

**The loop matters more than the result.** B5.5 -- `switch_root`, dinit as
PID 1 -- is the one piece of this project only testable at the END of a full
run, and iterating on it through CI is forty minutes a cycle. With this it is
seconds, against the same Image the release publishes.

**One thing it cannot test yet:** `efi: UEFI not found`. `-machine virt` with
no `-bios` gives no UEFI firmware, so the EFI stub has nothing to attach to.
The symbols are in the kernel; exercising that path needs
`edk2-aarch64-code.fd`, which is already in the `pc-bios` directory this
artifact packs.
