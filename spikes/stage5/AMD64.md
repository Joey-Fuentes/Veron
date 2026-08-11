# stage 5 on x86_64 — the arm, and what it is expected to find

`.github/workflows/stage5-spike-amd64.yml` is stage 5's second architecture.
It is a **copy** of `stage5-spike.yml` rather than a matrix over it, for the
reason stage 4's arch spikes give about their own copies: a failure on one
architecture must not make the working arm answerable for it. `stage5-spike`
is what currently produces the published image, and a red X on it would read
as a stage-5 regression when it is an architecture nobody has ported yet.

**All 122 packages build on x86_64, the image reproduces byte-for-byte, and it
boots.** Run `85313812045` went the whole way: `VERON-IMAGE-REPRO-OK`, ext4
mounted over virtio-blk, dinit up, labwc and foot running, `VERON-DHCP-OK`
across two VMs, and the image published to `stage5/latest-amd64`. **156 guest
tests pass and one fails**, and that one is the most interesting result the
arm has produced. See *What the runs found*.

---

## What the arm shares, and what it changes

**Shared:** one driver (`tools/veron`), one policy, one `guest/`, one
initramfs builder, and 115 of the 122 recipes. A second copy of any of those
would drift and the comparison would stop meaning anything.

**Untouched by this arm:** `packages/`, `PLAN.txt` and
`.github/workflows/stage5-spike.yml`. Nothing the amd64 arm does can change
what the aarch64 arm builds — the seven recipes that differ live in a separate
directory the aarch64 arm never loads, and its plan gate diffs against its own
`PLAN.txt` exactly as before.

`tools/veron` and `guest/init` are both edited, and both edits are additive:
`--overlay`/`--plan` default to today's values, and the loader diagnostic in
`guest/init` was hardcoded to `ld-linux-aarch64.so.1` and would have told a
healthy x86_64 image its loader was missing. It now finds the loader instead
of naming it. The check itself — shell rc 126/127 — was already
architecture-neutral; only the explanation was not.

**Changed, and this is the whole list:**

| | aarch64 arm | amd64 arm |
|---|---|---|
| runner | `ubuntu-24.04-arm` | `ubuntu-24.04` |
| emulator package | `qemu-system-arm` | `qemu-system-x86` |
| sysroot | `stage4/latest` | `stage4/latest-amd64` |
| kernel | `veron-boot` artifact of the latest green `stage0-stage4-complete` | `Image` **from the same release as the sysroot** |
| qemu | `qemu-system-aarch64 -M virt -cpu cortex-a57` | `qemu-system-x86_64`, no `-M`, no `-cpu` |
| console | `ttyAMA0` | `ttyS0` |
| checkpoint | `ckpt/latest` | `ckpt/latest-amd64` |
| image | `stage5/latest` | `stage5/latest-amd64` |
| recipes | `packages/` | `packages/` + `packages-amd64/` overlay |
| plan | `PLAN.txt` | `PLAN-amd64.txt` |
| `VERON-INSTALLS` | `--mode fail` | `--mode warn` |
| partial builds | — | `stop_after`, which publishes nothing |
| artifacts | `veron-stage5-*` | `veron-stage5-*-amd64` |

Every other step name is byte-identical to its source, so each one diffs
against the step it was copied from.

### Three of those deserve their reasoning here rather than only in the file

**The kernel comes from the release.** The aarch64 arm asks the API for the
most recent successful `stage0-stage4-complete` run and downloads that run's
artifact. Artifacts expire at 30 days; a quiet month means `VERON-BOOT-SKIP`
after the build has already been paid for — the same failure shape that moved
the sysroot from a cache to a release in the first place.
`stage4-arch-spike-amd64` publishes `Image` and `initramfs.cpio.gz` into
`stage4/latest-amd64` beside the sysroot, and its `PROVENANCE` records the
sha256 of all three. So this arm takes both from one object, verifies the
kernel against that digest, and knows the two are from one run rather than
assuming it. **The aarch64 arm is deliberately not changed to match**: it
works, and moving it is a separate change that owes its own green run.

**Separate tags are structural, not cosmetic.** Every upload here uses
`--clobber` and every filename is unqualified — `rootfs.img.tar.zst`,
`IMAGE-SHA256`, `Image`, `files.tsv`. A shared tag would let the first run on
a new architecture destroy a working release. Stage 4 made this argument
already and it is the same argument.

**`--mode warn` on `VERON-INSTALLS` is not a lowered standard.**
`[installs].digest` is a per-file sha256 listing, and every digest in the tree
was measured on aarch64. The same source at the same pin produces different
machine code on x86_64, so all 122 packages would report
`INSTALL-SET-CHANGED` for the one reason that is not a fault — and a gate that
fires on correct code gets switched off. That is this project's own recorded
lesson about this very check. **The half that transfers is still enforced:**
the prefix check is architecture-independent, and a package installing
somewhere its recipe does not declare still shows up here. Read the file-set
diffs anyway — contents differing is expected, but a package installing a
*different set of paths* on x86_64 is a real finding about the recipe.

---

## The thirteen recipes that differ, and where they live

Thirteen recipes need to say something different on x86_64 — seven predicted
from reading, four found by the runs, and two found by booting the image on a
laptop. They are **not edited in place** — `packages/` is the aarch64 arm's tree and stays exactly as it is.
Each has a replacement in **`packages-amd64/`**, which only
`stage5-spike-amd64` loads, via `veron --overlay packages-amd64`.

| # in plan | package | base | amd64 overlay | cost |
|---|---|---|---|---|
| 27 | `gmp` | `--build/--host=aarch64-veron-linux-gnu` | `x86_64-veron-linux-gnu` | none |
| 37 | `libvpx` | (assembler auto-detected) | `--target=generic-gnu` | **large** — scalar C, no runtime CPU detection |
| 52 | `nettle` | `--enable-arm-neon` | removed | portable C, no SIMD |
| 70 | `dav1d` | `-Denable_asm=true` | `false` | **large** — the AV1 decoder without asm |
| 81 | `orc` | `-Dorc-target=neon` | `-Dorc-target=all` | library size; `sse` alone does not link |
| 90 | `ffmpeg` | (probes for nasm) | `--disable-x86asm` | large |
| 98 | `llvm` | `LLVM_TARGETS_TO_BUILD=AArch64;AMDGPU` | `X86;AMDGPU` | none |
| 46 | `freetype-bootstrap` | (bzip2 autodetected) | `--without-bzip2` | none — see *What the first run found* |
| 105 | `freetype` | (bzip2 autodetected) | `--without-bzip2` | none |
| 1 | `bzip2` | stages only `libbz2.a` | `install-shared` step | none — three packages can finally link it |
| 33 | `libffi` | `--with-gcc-arch=native` | `x86-64` | none — it is the baseline the image already uses |
| 104 | `mesa` | `gallium-drivers` without `radeonsi` | `+radeonsi` | none — GL stops being software |
| 121 | `veron-system` | console on `ttyAMA0` | `ttyS0` | none — it is the tty this arm already boots on |

**Four of the seven are one fact and one missing tool.** libvpx, dav1d and
ffmpeg all need `nasm` on x86 where aarch64 needs nothing — its `.S` files go
through the C compiler. nasm is not in the package set and is not pinned, so
each declines its assembly rather than failing at configure. `orc` is the
instructive contrast: it is a JIT, its backends are code generators inside
`liborc`, so the x86 target costs nothing and is taken.

**The declined assembly is a declared cost, not an oversight.** An x86_64
image built this way decodes AV1 and VP9 in scalar C. Pinning nasm is one
tarball, two mirror routes and one recipe, and turning these back on is the
first thing to do once it exists. Recorded here rather than discovered later
from a slow video.

**`libcap` needed nothing**, and had already predicted why: it derives its
libdir by running `ldd` and taking the second path component — `lib` on
aarch64, `lib64` on a typical x86-64 host — and pins `lib=lib` explicitly,
naming the x86 case in its own notes.

---

## What the runs found

**The entry contract answered first**, which is what that step exists for:

```
arch     x86_64      triplet  x86_64-veron-linux-gnu
sysroot  7bf01bc5…   kernel verified against PROVENANCE  37fa5549…
loader   lib/ld-linux-x86-64.so.2
gcc      gcc, g++, x86_64-veron-linux-gnu-gcc, x86_64-veron-linux-gnu-g++
libdir   usr/lib/gcc/x86_64-veron-linux-gnu/
VERON-ENTRY-OK
```

The triple matches what the gmp overlay names, so the port's central
assumption was confirmed before a single package was compiled. Taking the
kernel from the same release as the sysroot worked, and it was verified
against `PROVENANCE` rather than merely downloaded.

**45 packages built, through `curl`.** All seven overlay recipes that got
their turn were correct: `gmp` configured `--build/--host=x86_64-veron-linux-gnu`,
`libvpx` built in 186s with `--target=generic-gnu`. No predicted fault fired.

### The first stop: a declaration that was never true, on either architecture

```
[46/122] freetype-bootstrap 2.14.1
  ld: /usr/lib/libbz2.a(bzlib.o): relocation R_X86_64_PC32 against symbol
      `stderr@@GLIBC_2.2.5' can not be used when making a shared object;
      recompile with -fPIC
  ld: final link failed: bad value
VERON-BUILD-FAIL  freetype-bootstrap: step 'build' rc=2
```

Read as a linker error this is an x86_64 quirk. It is not.

`freetype-bootstrap`'s `[deps].optional_off` has listed **`bzip2`** since the
recipe was written — the package declares bzip2 declined. **That was never
told to the build system.** The configure line passes `--without-harfbuzz` and
`--without-brotli` and says nothing about bzip2, and freetype's
`--with-bzip2` defaults to **auto**. bzip2 is package 1 and is staged into the
build root forty-five rungs earlier, so configure found `bzlib.h` and
`libbz2.a` and linked `-lbz2`. **The recipe said off and the build was on.**

**On aarch64 that link succeeds**, and has been succeeding all along. So the
published aarch64 image ships a `libfreetype.so` with bzip2's code compiled
into it, under a recipe that says bzip2 is declined.

### Why three detectors could not see it, and an architecture could

bzip2 is the **only package in the set that ships a static archive and no
shared library** — swept across all 122 committed `installs.txt` listings:

| package | static | shared |
|---|---|---|
| **bzip2** | `libbz2.a` | **none** |
| elfutils, libcap, libudev-zero, llvm, ncurses, zlib, zstd | some `.a` | also `.so` |
| tzdb | `libtz.a` | none, and nothing links it |

A static archive leaves **no `DT_NEEDED` entry**. `veron linked` reads exactly
that field — it is the detector that exists to catch "a library picked up from
the sysroot by a configure script nobody told to look" — and it is structurally
blind to a dependency that got absorbed rather than linked. The static scan
reads intent and the recipe's intent was correct. The distro comparison reads
someone else's intent. All three were right and the build was wrong.

x86_64's linker refuses non-PIC objects in a shared object where aarch64
accepts them, so **the architecture is what surfaced it** — which is the case
for a second arm stated more sharply than it could have been stated in advance.

### The second stop: the same defect from the other side

```
[48/122] libarchive 3.8.5
  ld: /usr/lib/libbz2.a(bzlib.o): relocation R_X86_64_PC32 against symbol
      `BZ2_crc32Table' can not be used when making a shared object
VERON-BUILD-FAIL  libarchive: step 'build' rc=2
```

Same archive, same relocation, opposite declaration. freetype declared bzip2
**off** and silently got it. libarchive declares bzip2 **on** — `deps.build`,
`deps.link` and `deps.runtime` all name it — and cannot have it, because
**bzip2 ships no shared library to link.**

**bzip2's own recipe predicted this in writing.** Its `build-shared` step
carries the comment:

> bzip2 builds its shared library from a separate makefile. Skipping this
> leaves only `libbz2.a`, and every consumer that expects `libbz2.so.1` fails
> much later with a link error that does not mention bzip2.

The step was added. The library it produces was never staged: `make install`
runs from the *static* makefile, `Makefile-libbz2_so` has no install target,
and `libbz2.so.1.0.8` sat in the build directory and was deleted with it. So
the protection was written, documented, and not delivered — and the comment
describing it has been false of the shipped result all along. The failure it
predicted arrived twice, in the exact words it used.

**Three packages declare bzip2 as a link dependency** — `libarchive`, `python`
and `cmake` — and none of them can have it. libarchive and python build shared
objects, so x86_64 refuses. cmake links executables, where a non-PIC static
archive is legal: it would have passed and shipped bzip2 absorbed into a
binary instead. **On aarch64 all three link**, which is the worse outcome
rather than the lucky one: `libarchive.so` and python's `_bz2` module carry
bzip2's code inside them, with no `DT_NEEDED` naming it, under recipes that
declare the dependency the ELF cannot corroborate.

### The two fixes, and why both are needed

`packages-amd64/bzip2` adds an **`install-shared`** step staging
`libbz2.so.1.0.8` and its two symlinks. It refuses rather than skips if the
file is absent, so a future bzip2 that renames it fails *there*, naming bzip2,
rather than forty packages later against a symbol nobody recognises — which is
the whole shape of the bug. The soname is `libbz2.so.1.0`, not `libbz2.so.1`,
so that symlink is load-bearing. `libbz2.a` is kept: `ld` prefers a shared
library when both are present, so the archive stops being reached without
being removed, and removing it would be a second decision riding on a fix.

`packages-amd64/freetype-bootstrap` and `packages-amd64/freetype` keep
**`--without-bzip2`**, and this is the part that looks redundant and is not.
With `libbz2.so` present, freetype's configure would find bzip2, link it
cleanly, and the declaration gap would go **silent again on both
architectures**. `optional_off` says freetype declines bzip2; the flag is what
makes that true. Fixing bzip2 alone would have re-hidden the first finding.

The alternative for freetype — letting it keep bzip2 now that the shared
library exists — was rejected: when a recipe has already decided, the fix is
to make the build obey it, not to satisfy the linker.

**The base recipes are deliberately not changed.** Same gaps, same fixes, and
applying them on aarch64 moves `libfreetype.so`, `libarchive.so`, python's
`_bz2` and every install digest downstream. That is a dispatch and a
re-seeding run of its own, and it belongs to whoever owns that arm. Three
things for them:

1. `--without-bzip2` on `packages/freetype-bootstrap` and `packages/freetype`.
2. The `install-shared` step on `packages/bzip2`, or delete `build-shared` and
   its comment — building a library and discarding it is the worst of the
   three options.
3. A licence edge: `bzip2-1.0.6` code sitting inside `libfreetype.so`,
   `libarchive.so` and `_bz2` under nodes whose ledger records do not mention
   it.

**77 recipes name something in `optional_off` without passing a corresponding
flag**, so this shape is not rare and a gate over it would fire on 77 correct
recipes — most are genuinely default-off. The narrow, checkable version — *a
name in `optional_off` that the build system defaults to auto* — needs
per-package knowledge no sweep has.

### The third stop: my own overlay value, wrong

```
[81/122] orc 0.4.41
  ld: orcx86insn.c.o: in function `orc_x86_output_insns':
      undefined reference to `orc_x86_get_regname_mmx'
meson summary:  SSE : YES    MMX : NO
```

The overlay set `-Dorc-target=sse`, reasoning from the base recipe: name the
one backend this machine can execute. That reasoning is correct on aarch64 and
does not survive contact with orc's x86 sources. **`orcx86insn.c` is compiled
whenever any x86 backend is on and calls the MMX register-name helper
unconditionally**, so SSE is not separable from MMX. aarch64 has no equivalent
because NEON is the only ARM backend — nothing there depends on a second one
being present.

The overlay now passes **`-Dorc-target=all`**. The narrower `sse,mmx` says
exactly what is meant, and whether meson accepts it depends on whether
`orc-target` is an array option or a combo — a combo rejects it at setup.
`meson_options.txt` answers that in one line and was not read. `all` is orc's
documented default, is what every distribution ships on x86_64, and cannot be
rejected under either type.

It costs what the base recipe declines it for: code generators for mips,
altivec and c64x compiled in. They are **pure C emitters** — they generate
bytes for another architecture rather than executing them — so the cost is
library size, not correctness. Narrowing to `sse,mmx` is a follow-up that
needs one look at a file, not another run.

**This is worth being blunt about.** The seven predicted faults were derived
from reading recipes; six were right. This one identified the right package
and the right option and got the value wrong, and it cost a run of eighty
packages to find out. Reading a recipe tells you what a flag *means*; it does
not tell you whether upstream's source can honour it.

### What the bzip2 fix actually did

Confirmed in run three, and it is the cleanest possible evidence:

```
[48/122] libarchive   links    bzip2 xz zlib zstd
[60/122] python       links    bzip2 expat libffi ncurses readline sqlite ...
```

`links` is read from `DT_NEEDED`. Before the fix those packages declared bzip2
and the ELF could not corroborate it, because the archive had been absorbed
rather than linked. **The dependency is now visible to the detector written to
see it.** cmake, the third declarer, links executables and had been quietly
absorbing bzip2 all along without failing anywhere.

### The fourth finding: a library built for the machine that built it

Run `85313812045` built all 122 and booted. One guest test failed:

```
traps: python3[188] trap invalid opcode ip:7f272ffa7580
       in libffi.so.8.2.0[3580,7f272ffa6000+8000]
Illegal instruction
FAIL  python: import zlib,bz2,lzma,ctypes,sqlite3
VERON-STAGE5-TESTS pass=156 fail=1 none=2
```

**The recipe named this in advance and filed it under the wrong heading.**
`libffi`'s deferral note says `--with-gcc-arch=native` is *"a reproducibility
risk worth naming: it lets the compiler tune for the machine doing the build,
so two builders with different CPUs could produce different bytes... if G3 ever
disagrees across machines, this flag is the first thing to remove."*

The mechanism is exactly right and the consequence is larger than the heading.
`-march=native` does not only make the bytes **depend on** the build machine —
it makes them **require** it. The GitHub x86_64 runner is a recent Xeon;
`qemu-system-x86_64`'s default CPU model is `qemu64`, deliberately
conservative. libffi was compiled for the builder and then asked to run
somewhere else.

**One package, one test, and it is the only one of the 122 that does this** —
swept across every recipe, `libffi` is the sole `-march`/`-mtune`/`native`
user. Nothing in `policy/defaults.toml` sets `-march`, so every other package
compiles at gcc's baseline. ctypes is simply the first thing to `dlopen` it,
which is why one test failed rather than forty.

The overlay pins `--with-gcc-arch=x86-64`. That is not lowering libffi to meet
the emulator — it is lowering it to meet **its own image**, which is built at
that baseline throughout. Stated explicitly rather than by dropping the flag,
because relying on what libffi's configure defaults to is the kind of
assumption this project pins by hand everywhere else.

**The aarch64 arm carries the same flag and has not failed on it.** It builds
on a Neoverse runner and boots on `-cpu cortex-a57`, which is ARMv8.0, so the
same gap exists there and nothing has yet executed an instruction that proves
it. Latent, not absent — and it is also a live G3 hazard on both arms the day
two runners differ.

#### The emulated CPU is now named, and deliberately not raised

`-cpu max` would have made this test pass. It was not used. Raising the
emulated CPU until the image runs produces a green marker over a real defect in
the artifact — an image that only boots on hardware as new as whatever built
it — which is the failure mode this project treats as worse than a red run.

Instead all five qemu invocations now pass `-cpu qemu64` **at the value they
already had by default**. Nothing about the test changes; what changes is that
the baseline the image is certified against appears in the log, and raising it
becomes a decision somebody writes down rather than a default nobody chose.

### The fifth finding: 157 tests pass and nobody can type into it

Booting the published image by hand, with `-cpu host` so libffi runs, gives
`pass=157 fail=0` and then a console that does this forever:

```
dinit: Service console process terminated with exit code 1
[STOPPD] console
[  OK  ] console
dinit: Service console process terminated with exit code 1
...
```

`veron-system`'s console service ends:

```
command = /bin/busybox getty -n -l .../console-shell 115200 ttyAMA0
restart = true
```

**`ttyAMA0` is the ARM PL011 UART and does not exist on x86.** This arm passes
`console=ttyS0` on every kernel command line it writes, and then ships a
service that opens `ttyAMA0`. getty exits 1 immediately, `restart = true` does
exactly what it was asked, and the loop is the correct behaviour of a service
given a wrong device name.

**It reads as the documented absence of a login, and it is not that.**
`STAGE5.md` records that there is no login — `getty -n`, and an `/etc/passwd`
naming a `/etc/shadow` that does not exist — and that is a deliberate state.
This is a getty that cannot open a tty. The two look identical from across the
room and the difference is the exit code.

**Nothing in the run could have caught it.** The package tests run from init,
before dinit exists, and all 157 pass. The console service starts afterwards,
and no gate asserts that a getty stayed up. **A boot can report 157 passes and
hand back a machine nobody can type into** — which is the exact shape of green
marker this project treats as worse than a red one, and it survived four runs
of an arm that was otherwise finding a defect per run.

It was found by a person booting the image by hand on a laptop. That is worth
recording on its own: every other finding here came out of CI, and this one
could not have.

The overlay states `ttyS0`. **The base is not changed, though it should be** —
the honest fix is for the service to take its tty from `console=` on
`/proc/cmdline` rather than naming one, which makes the file arch-neutral and
correct on both arms. That moves `veron-system`'s bytes and every digest
downstream, so it needs its own dispatch.

**A gate is missing and is not added here.** Something should assert that the
console service is still running some seconds after dinit comes up — the boot
already greps the log for markers, so this is within reach. It is not written
yet because the right assertion is not obvious: `restart = true` means the
service is always about to be "up" again, so counting restarts is closer to
the truth than checking liveness once.

### Booting the published image on your own machine

```sh
gh release download stage5/latest-amd64 -R Joey-Fuentes/Veron \
  --pattern 'rootfs.img.tar.zst' --pattern 'IMAGE-SHA256' \
  --pattern 'Image' --pattern 'initramfs.cpio.gz'
tar --zstd -xf rootfs.img.tar.zst && sha256sum -c IMAGE-SHA256

qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 4 -m 4096 \
  -display gtk -serial mon:stdio \
  -drive file=rootfs.img,format=raw,if=virtio \
  -device virtio-gpu-pci -device virtio-keyboard-pci -device virtio-mouse-pci \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -kernel Image -initrd initramfs.cpio.gz \
  -append "console=ttyS0 rdinit=/init panic=1 loglevel=4 veron.boot=system"
```

**`veron.boot=system` is not optional.** `switch_root` into dinit is at line
383 of `guest/init` and the package test suite is at 477, so in system mode the
tests never run and the machine stays up; without the flag `BOOTMODE` defaults
to `test` and init runs the suite and calls `poweroff -f`. A boot ending in
`VERON-STAGE5-GUEST-DONE` and `reboot: Power down` was told to do that.

Then `sh /etc/dinit.d/scripts/labwc-session` in the terminal you launched from;
the compositor is deliberately not in `boot.d`. `Ctrl-A` then `X` quits. Drop
`-enable-kvm -cpu host` for `-cpu qemu64` if KVM is unavailable. Full notes are
in `STAGE5.md` under *Running the x86_64 image*.

**An image published before the `ttyS0` fix has no shell to start labwc from.**
Patch a copy rather than waiting for a rebuild:

```sh
cp rootfs.img rootfs-patched.img
sudo mount -o loop rootfs-patched.img /mnt/veron
sudo sed -i 's/115200 ttyAMA0/115200 ttyS0/' /mnt/veron/etc/dinit.d/console
sudo umount /mnt/veron
```

The patched copy no longer matches `IMAGE-SHA256`, which is the point of the
copy: the published image stays verifiable and the local one is plainly local.

**Swapping `-cpu host` for `-cpu qemu64` reproduces the libffi fault in two
minutes** — `qemu64` traps, `host` very likely does not — which is the local
version of the finding above and the clearest demonstration of why the fix was
to pin libffi rather than raise the emulated CPU.

### The sixth finding: it boots on a laptop, and the kernel was never built for one

The published image was written to an NVMe partition on an HP Laptop 14 and
booted through the machine's own GRUB. It got this far:

```
VERON-STAGE5-INIT
VERON-IMAGE-MOUNT-SKIP  no ext4 block device
VERON-STAGE5-GUEST-FAIL  no root to test: neither disk nor 9p
# cat /proc/partitions
major minor  #blocks  name
                                   <- nothing. not one block device.
```

**Not "no NVMe" — no block devices of any kind.** The only storage driver in
this kernel is virtio-blk. And booted with its own `Image` rather than a
borrowed one, the screen printed nothing at all: GRUB's framebuffer stayed on
screen because `DRM_VIRTIO_GPU` is the only display driver and it does not
attach to an AMD APU. The kernel was alive throughout — Caps Lock toggled.

**Neither Ubuntu's kernel nor ours can boot this image today, for opposite
reasons.** Ubuntu's has the drivers as modules, and this initramfs has two
files in it and no modprobe. Ours has no modules at all and never had the
drivers. `=m` and `=n` are the same thing in this system.

#### What the hardware actually is

Measured with `lspci -k`, which names the driver the running system chose,
rather than guessed from the model number:

| device | driver |
|---|---|
| Micron 2550 NVMe SSD | `nvme` |
| AMD Lucienne `[1002:164c]` | `amdgpu` |
| AMD Renoir/Cezanne USB 3.1 | `xhci_hcd` |
| Realtek RTL8852AE WiFi 6 | `rtw89_8852ae` |

**No ethernet controller at all**, which is why wireless is not a luxury on
this machine.

`sysroot-amd64.sh` now sets storage (NVMe, AHCI, SCSI disk, USB storage),
input (xHCI, USB HID, i8042 for the built-in keyboard, i2c-hid plus
`PINCTRL_AMD` for the touchpad's interrupt), display in two layers, wireless,
and compressed firmware loading. It errs generously on purpose: **stage 4 has
no checkpoint**, so a driver nobody needs costs bytes in the bzImage and a
driver somebody needs costs a full chain rerun.

#### Two layers of display, and the floor is the important one

`SYSFB_SIMPLEFB` + `DRM_SIMPLEDRM` + `FRAMEBUFFER_CONSOLE` adopt the linear
framebuffer UEFI already handed to GRUB. No blobs, no ASIC knowledge, works on
any UEFI machine. `DRM_AMDGPU` takes over when it probes, and if its firmware
is absent it fails back to that floor rather than to darkness.

That distinction is the difference between a kernel that can **say** what went
wrong and one that cannot, and the laptop demonstrated the second at length.

#### Firmware goes in the initramfs, not the rootfs

The non-obvious part, and the one that would otherwise have cost another
rebuild. These drivers are **built in**, so they probe during kernel init —
before `/dev/nvme0n1p5` is mounted and long before anything in the image is
reachable. The kernel populates the initramfs before driver initcalls run, so
`/lib/firmware` **inside the initramfs** is the only place a built-in driver
can find a blob at probe time.

Exact files, from that machine's own dmesg:

```
rtw89_8852ae: loaded firmware rtw89/rtw8852a_fw.bin
amdgpu: ATOM BIOS: 113-LUCIENNE-019          [1002:164c]
```

amdgpu maps `0x1636` and `0x164c` to `AMD_APU_IS_RENOIR`, so Lucienne wants
the `renoir_*` blobs rather than `green_sardine_*`. And every one of them is
**zstd-compressed** in a modern distribution, which is why
`FW_LOADER_COMPRESS_ZSTD` is set: a blob the loader cannot decompress fails
identically to one that is not there.

**None of this ships.** Firmware is redistributable binary nobody in this
chain can build, which is the one thing every other byte here is arranged to
avoid — see `TRUST-BOUNDARY.md`. The kernel is made *ready* for a blob the
operator supplies, which is a smaller and different claim than shipping one.
`STAGE5.md` has the copy commands.

#### And a report, because olddefconfig does not have to honour set_cfg

A symbol whose dependencies are unmet is dropped silently, and the resulting
`.config` looks exactly like one where the line was never written. The failure
then surfaces as a laptop booting to nothing, and costs a full chain rerun.
The build now prints every real-hardware symbol and whether it survived, ending
in `VERON-KCONFIG-OK` or `VERON-KCONFIG-DROPPED` with the list. Reporting, not
failing: which symbols matter depends on the machine, and a kernel missing
`R8169` is still worth publishing.

#### The two repository fixes this boot justified

- **`guest/init` now accepts `veron.root=`**, tried before the existing
  `/dev/vda`, `/dev/sda`, `/dev/vdb` list, which no NVMe partition can ever
  match. Every qemu boot passes no such argument and behaves exactly as
  before. It also prints `/proc/partitions` when a named device fails, so
  "wrong name" and "no driver" stop looking identical.
- **The console service reads `console=` from `/proc/cmdline`** instead of
  naming a tty. `ttyAMA0` on aarch64, `ttyS0` on x86_64 under qemu, `tty1` on
  a laptop — one wrapper is correct on all three, and it cannot drift from the
  kernel's own idea of where the console is because it is reading it.

### The seventh finding, and the first working laptop

The kernel with the hardware block booted. On an HP Laptop 14 with an AMD
Lucienne APU, from an NVMe partition, through the machine's own GRUB:

| | |
|---|---|
| storage | `/dev/nvme0n1p5` mounted, root over ext4 |
| display | `amdgpu` with `renoir_*` firmware from the initramfs, labwc on it |
| wireless | `rtw89_8852ae`, firmware loaded, associated, DHCP, `ping 1.1.1.1` at 15 ms |
| browser | WPE MiniBrowser playing YouTube |
| keyboard | i8042 |

Every one of those is a first. The firmware-in-the-initramfs reasoning held:
`rtw89_8852ae: loaded firmware rtw89/rtw8852a_fw.bin`, and the earlier
`fw-1.bin failed with error -2` is the driver trying a newer file first and
falling back, not a fault.

**Six things did not work, and every one was measured rather than guessed.**

#### `PINCTRL_AMD` was dropped, and the report is why we knew

`VERON-KCONFIG-DROPPED -- PINCTRL_AMD` on its first run, alone out of 24
symbols. `PINCTRL` is a **menuconfig**, the AMD driver lives inside its
`if PINCTRL ... endif` block, and `x86_64_defconfig` sets no `PINCTRL` line at
all — so the child was unsatisfiable and `olddefconfig` discarded it in
silence. The gate turned a dead touchpad into a named line before the boot.

**The fix came from the machine, not from reasoning.**
`/boot/config-6.8.0-51-generic` — a kernel where that touchpad works — has
`CONFIG_PINCTRL=y`, `CONFIG_PINCTRL_AMD=y`, `CONFIG_GPIOLIB=y`,
`CONFIG_GPIOLIB_IRQCHIP=y`. One `grep` against a working config beat a chain of
Kconfig inference, and it cost a command instead of a ladder run. That is worth
generalising: **when a distribution already runs on the target, its `.config`
is evidence and everything else is argument.**

`HID_MULTITOUCH` was missing too — never set, and a touchpad without it is a
bare pointer.

#### No sound card at all

```
# ls /dev/snd
seq   timer
```

ALSA core, no card: no audio driver was ever enabled. YouTube played silently.

**HDA, not SOF, and that is a measurement.** `lsmod` on the machine shows both
stacks — `snd_sof_amd_renoir` beside `snd_hda_codec_realtek` — so the obvious
reading is that it needs both. It does not: `/usr/lib/firmware/amd/` on that
machine holds only SEV blobs, **no `sof/` and no `sof-tplg/`**. SOF firmware
was never installed, so that driver loaded and never bound. Enabling SOF would
add a driver that cannot work and blobs nobody has.

#### Everything rendered on the CPU

`/usr/lib/dri/` does not exist, no `*_dri.so` anywhere, and
`libgallium-26.1.6.so` is the single library mesa 26 links its drivers into.
The recipe settles it: `-Dgallium-drivers=llvmpipe,softpipe,virgl` — **no
`radeonsi`**. A Ryzen APU with a working `amdgpu` was software-rasterising a
video site.

`packages-amd64/mesa` adds it. `libdrm` is already `-Damdgpu=enabled` and
`llvm` already builds the AMDGPU backend on both arms, so it is one flag.
**It does not buy hardware video decode** — that needs `gallium-va`,
`video-codecs` and libva, none of which are here.

#### Hotplugged devices come up unreadable

A USB mouse plugged in after boot enumerated correctly and the desktop ignored
it:

```
crw-rw----  root input   event0..event3    (boot)
crw-------  root root    event4            (hotplug)
```

`devtmpfs` creates the node with default ownership and **nothing fixes it up**,
because that fixup is a udev daemon's job and `libudev-zero` is a library with
no daemon. `chown root:input` plus `chmod 660` made the mouse work
immediately.

Two distinct gaps behind one symptom: **no permission rule for hotplugged
nodes**, and **no hotplug at all** — libinput learns about devices by scanning
at startup, so anything added later is invisible even when readable. busybox
has `mdev`, which does both jobs and needs no new package.

#### And no mixer

`ls /usr/bin/a*` finds `aserver` and no `amixer` or `alsamixer`. Once the HDA
drivers land, a card whose master comes up muted has nothing to unmute it with.
`alsa-utils` is a **new package** rather than a flag, and it goes in the base
tree, which touches the aarch64 arm — so it is deliberately not in this change.
It also needs a pinned tarball and a verified sha256, which is work of its own.
The next boot says whether it is needed: if sound works without it, it is a
convenience; if the card is silent, it is a blocker.

### The eighth finding: a gate that was silent about the symbols that mattered

The hardware kernel booted the laptop and reported `VERON-KCONFIG-OK`. Sound
arrived — two cards, HDMI through amdgpu and an ALC236 codec with its HP fixup
picked for SSID `103c:887c`. The keyboard, the display, wireless and storage
all held.

**The touchpad still did not work, and the reason is that its bus never
existed:**

```
# dmesg | grep -iE "i2c|designware|AMDI"
[  0.074697] AMD-Vi: ivrs, add hid:AMDI0020 ...
                                     <- and nothing else. No AMDI0010 bind.
```

`I2C_DESIGNWARE_PLATFORM` reads `depends on (ACPI && COMMON_CLK) || !ACPI`, and
`x86_64_defconfig` sets **no `COMMON_CLK` line at all**. ACPI is on, so the
first arm applies, is unmet, and `olddefconfig` discarded the symbol in
silence. `PINCTRL_AMD` may have been perfectly fine — it had no bus to route an
interrupt to. `/boot/config-6.8.0-51-generic` on that machine has
`CONFIG_COMMON_CLK=y`, which settles it.

**Exactly the `PINCTRL` lesson, one layer down.** A parent symbol nobody set,
a child silently dropped, and a working distribution config that answers it in
one `grep`.

#### The gate reported OK about symbols it was not checking

This is the part worth keeping. The `VERON-KCONFIG` report exists so a dropped
symbol is named before a boot rather than after — and it printed `OK` while
being silent about the two symbols that had been dropped, because
`I2C_DESIGNWARE_CORE` and `I2C_DESIGNWARE_PLATFORM` were **set in the config
block and never added to the list the report iterates**.

A gate that checks a subset of what it appears to check is worse than no gate:
it converts "we did not look" into "we looked and it was fine."

So the correspondence is now mechanical rather than remembered. Every
`set_cfg` in the real-hardware block is in the report list — checked by
extracting both sets and diffing them, which turned up **seven more** symbols
that had been set and never reported (`DRM_AMD_DC`, `FB`, `VT`, `VT_CONSOLE`,
`FRAMEBUFFER_CONSOLE_DETECT_PRIMARY`, `USB_EHCI_PCI`, `USB_OHCI_HCD`). 63
symbols set, 63 reported.

Run against a config with two symbols missing, the extended report prints what
the last run should have:

```
COMMON_CLK                   on
I2C_DESIGNWARE_PLATFORM      NOT SET
PINCTRL_AMD                  NOT SET
VERON-KCONFIG-DROPPED -- I2C_DESIGNWARE_PLATFORM PINCTRL_AMD
```

### What is still unknown

The image boots on a laptop and does most of what a laptop should. What has
not been shown: sound producing a sound, the touchpad reporting, hardware GL
after the mesa change, and whether anything needs a mixer. All four are
answered by the next boot and none of them need a stage-5 run.

Beyond this machine, **nothing**. One laptop is one data point, and the kernel
block was written against its `lspci` output. An Intel machine would exercise
`DRM_I915` and `E1000E`, both enabled and both untested; a SATA machine would
exercise `SATA_AHCI`, likewise. The generic-kernel design in the architecture
note is what replaces "we guessed well for one machine" with something that
works on machines nobody has.

### Every run rebuilt from package 1 — `stop_after` is the way out

`Restore a build checkpoint` reported **"no checkpoint published yet — building
everything"** on all three runs, and left alone it always would: the checkpoint
is published only when the build SUCCEEDS, and on a new architecture the build
is exactly what does not succeed yet. Each iteration paid eighty packages of
CPU to reach one new fact, and the price rises as the port gets further.

**The fix is to stop deliberately at the last package known to work**, which
makes that run a success, which publishes a checkpoint:

```
gh workflow run stage5-spike-amd64.yml \
   -f stop_after=orc -f save_checkpoint=true
```

Then every later run dispatches with `use_checkpoint=true` and resumes.

**Why the keys survive the rest of the set being restored.** Checkpoint keys
are per-package and position-independent —
`key(p) = sha256(base + policy + recipe_sha(p) + each dep's key)`. That
replaced a prefix hash precisely because a prefix hash conflated position with
dependency and threw away a 55-package checkpoint when seven packages were
inserted at rung 10. So banking 81 and then restoring all 122 keeps all 81,
and changing one recipe invalidates that package and its dependents and
nothing else.

**`--upto` is a prefix of the order, not a selection from it**, and that
distinction is load-bearing. `veron build foo bar` already filters to named
packages; a list is free to omit something in the middle, which would build a
package against a dependency that is not there and then blame the package.
Everything a package declares is earlier in the order, so **every prefix is
closed under the declared dependencies** and a prefix cannot make that mistake.

**This is a sounder checkpoint than one taken from a failed run**, which was
the other route and the one proposed before this. `veron build` returns as
soon as a step fails and does not remove `dest/<pkg>`, so a package failing
during INSTALL leaves a partial staged tree that `veron checkpoint` would
record as complete — and the next run would skip it. Under `--upto`, every
package in `dest/` ran every step. The idea is better than the fix it
replaced, and no driver failure-path change is needed.

**A partial run cannot publish anything, and that is structural.** `stop_after`
sets a job-level `PARTIAL` flag, and ten steps — manifest, ledger, merge,
`VERON-STAGE5-OK`, the image, the initramfs, the boot, the screenshot and its
upload, and the DHCP test — are gated on it. `Publish the image` carries its
own explicit check on top, because it is the step that writes to a release
under names claiming to be the x86_64 stage-5 system and it must never do that
for 81 packages of 122. One flag decides, in one place: the alternative is
repeating the condition fourteen times, and the one that gets missed is
whichever publishes, because it is last.

The build still prints what it did:

```
VERON-BUILD-UPTO  stopping after orc -- 81 of 122 package(s), NOT a complete system
```

`--upto` refuses a package not in the plan, and refuses to be combined with a
package list — both shown failing.

## How the two trees stay separate without becoming two projects

`--overlay <dir>` **replaces** recipes by name and can do nothing else.

- **It cannot introduce a package.** A directory whose name has no base in
  `packages/` is refused, because the only way to write one is a typo — and a
  typo would otherwise add a package while silently leaving the one it meant
  to override unchanged.
- **It cannot reach the base tree.** With no `--overlay` the value is `""` and
  every path is the one it was before. The aarch64 arm passes no such flag.
- **It is a whole recipe, not a diff.** `ROADMAP.md`'s first rule is that a
  reader of one recipe can see everything strange about that package; a merge
  would put the thing that runs in neither file. `patches/` and `files/`
  resolve from the recipe's own directory, so an overlay recipe carries its
  own.

Three shapes were possible and two were rejected: **a second `packages/`
tree** duplicates 122 recipes so 7 can differ, and **a second driver**
duplicates 4,900 lines for the same 7. Both are the drift argument stage 4's
two arms make about `rungs.sh`.

### The gate that makes the duplication safe

An overlay recipe restates the version, the url and the sha256 — and the
failure mode of every copied pin in history is that one copy gets bumped and
the other does not. Two architectures would then build **different upstream
source under one package name**, and every comparison between them would be
measuring the wrong thing while looking green.

So `veron --overlay ... selftest` compares `version` and every `[source]` key
against the base recipe and fails if they disagree. Flags, steps, patches and
`[installs]` are exactly what an overlay exists to change and are deliberately
not compared.

**Shown to fail, not merely to pass** — per `AGENTS.md` §2c, each of these was
broken on purpose and confirmed red:

```
FAIL  overlay pin drift -- gmp: version '6.3.0' base vs '6.3.1' overlay
FAIL  overlay pin drift -- gmp: source.sha256 differs between packages/ and the overlay
veron: overlay recipe 'gmp2' has no base in packages/ -- an overlay
       replaces, it does not introduce. Misspelling?
```

The check runs **only when an overlay is in use**, so the aarch64 arm's
selftest is unchanged: an arm must not go red for a fault in an architecture
it does not build.

### Its own plan

`PLAN-amd64.txt` is committed beside `PLAN.txt` and checked by
`veron --overlay packages-amd64 --plan PLAN-amd64.txt plan --check`. The two
files differ in **49 lines: ten `argv` lines, twelve `recipe-sha` lines and one
whole added step** — which is both the proof that the overlay changes only
what it claims to and the cheapest available review of what this architecture
does differently.

```
diff PLAN.txt PLAN-amd64.txt | grep -c '^[<>]'
49
```

---

## What was measured before each dispatch

Run locally against the tree at this commit, with the symlinks under
`packages/veron-system/files/` restored (a zip round-trip flattens them, which
makes `plan --check` stale for a reason that is not a fault):

| | |
|---|---|
| `veron selftest` — no overlay | `VERON-SELFTEST-OK`, output identical to the unmodified driver except three counts that moved because a new workflow file exists |
| `veron plan --check` — no overlay | `VERON-PLAN-OK`, `plan-sha256 7799c291…` |
| `veron --overlay packages-amd64 selftest` | `VERON-SELFTEST-OK`, `13 overlay recipe(s) pin the same source as their base` |
| `veron --overlay … --plan PLAN-amd64.txt plan --check` | `VERON-PLAN-OK`, `plan-sha256 59898d1a…` |
| `build --upto orc` | truncates the plan to `[1/81]` and says so; refuses an unknown name and refuses to be combined with a package list |
| the `PARTIAL` interlock | all ten system-producing steps gated, verified by parsing the rendered conditions |
| the three new gates | broken on purpose, each confirmed red |
| the workflow | parses as YAML; every `run:` block passes `sh -n` |

**The CLI-surface check does the rest.** `selftest` already parses every
`veron …` invocation in every workflow file with the real parser — it exists
because `veron merge --dest dest` died on a global option in the wrong
position. It now checks 47 invocations rather than 29, so the aarch64 arm's
own selftest validates this workflow's command lines on every run, without
running its overlay check.

**What this establishes and what it does not.** The gates check that the tools
agree with the recipes; run 85280166724 checked that 45 packages compile. The
remaining 77 are unmeasured, and so is everything after the build: the merge,
the image, the boot, the DHCP test and the screenshot have never run on this
architecture.

---

## Still open

- **`nasm` is not pinned.** Four recipes decline assembly because of it.
- **`[installs].digest` cannot hold across architectures.** The overlay
  recipes drop `files`/`digest` and keep `prefixes`, which is
  architecture-independent and still enforced; the other 115 packages keep
  aarch64 digests, which is why this arm runs `--mode warn`. A per-arch digest
  is a recipe-format change and is not made here.
- **`VIRTIO_BLK` and `EXT4_FS` are not asserted** in `sysroot-amd64.sh` — they
  come from `x86_64_defconfig`, and stage 4's amd64 boot never exercises them
  because it boots with 9p and no `-drive`. Stage 5 boots an ext4 image over
  virtio-blk. If the guest panics unable to mount root, that is the first
  place to look, and the fix belongs beside the symbols already asserted there.
- **KVM is off.** Some hosted x86 runners expose `/dev/kvm`. qemu is a
  verifier and contributes no artifact byte, so it cannot change what is
  built — but it can change what a hang looks like, and a first run should not
  vary two things at once.
- **The base recipes still carry both bzip2 defects.** One flag on each
  freetype and one step on bzip2, plus the re-seeding run on aarch64 they
  imply. See *The two fixes, and why both are needed*.
- **`libffi` still says `native` in the base tree**, on both arms. It is a
  live G3 hazard the day two runners differ, and an unproven portability
  hazard on aarch64.
- **`alsa-utils` is not in the package set**, so there is no `amixer`. A new
  base package, which touches the aarch64 arm, and a pin to verify.
- **Nothing manages device nodes.** Hotplugged input devices come up
  `root:root 600` and libinput never learns they exist. busybox `mdev` does
  both jobs; adding it is a stage-5 decision, not a kernel one.
- **`veron-system` names a tty instead of reading `console=`.** Arch-neutral
  is one small script change and is correct on both arms.
- **No gate asserts the console survives dinit.** 157 passes and an unusable
  machine is currently a green run.
- **The image published despite a failing guest test.** `Publish the image` is
  `if: always()` and guards only on the image existing — inherited from the
  aarch64 arm, not introduced here. Whether `VERON-STAGE5-PUBLISHED-AMD64`
  should be reachable from a run whose own tests failed is a question for both
  arms.
- **`orc-target=all` should be narrowed to `sse,mmx`** once someone reads
  whether the option is an array or a combo.
- **The base tree still cannot bank a checkpoint from a failed run.**
  `stop_after` makes that unnecessary here; the aarch64 arm has green runs and
  does not need it. The partial-`dest/` hazard in `veron build`'s failure path
  is still real and still unfixed.
