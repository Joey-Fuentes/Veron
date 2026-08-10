# stage 5 on x86_64 — the arm, and what it is expected to find

`.github/workflows/stage5-spike-amd64.yml` is stage 5's second architecture.
It is a **copy** of `stage5-spike.yml` rather than a matrix over it, for the
reason stage 4's arch spikes give about their own copies: a failure on one
architecture must not make the working arm answerable for it. `stage5-spike`
is what currently produces the published image, and a red X on it would read
as a stage-5 regression when it is an architecture nobody has ported yet.

**It has run once.** Run `85280166724` built **45 of 122 packages** on x86_64
and stopped at 46, `freetype-bootstrap`. Every one of the seven predicted
architecture faults was correct and none of them fired — gmp configured with
the right triple, libvpx built without an assembler. What stopped it was not
on the list, and is the more interesting finding: see *What the first run
found* below.

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

## The nine recipes that differ, and where they live

Nine recipes need to say something different on x86_64 — seven predicted from
reading, two found by the first run. They are **not edited in place** — `packages/` is the aarch64 arm's tree and stays exactly as it is.
Each has a replacement in **`packages-amd64/`**, which only
`stage5-spike-amd64` loads, via `veron --overlay packages-amd64`.

| # in plan | package | base | amd64 overlay | cost |
|---|---|---|---|---|
| 27 | `gmp` | `--build/--host=aarch64-veron-linux-gnu` | `x86_64-veron-linux-gnu` | none |
| 37 | `libvpx` | (assembler auto-detected) | `--target=generic-gnu` | **large** — scalar C, no runtime CPU detection |
| 52 | `nettle` | `--enable-arm-neon` | removed | portable C, no SIMD |
| 70 | `dav1d` | `-Denable_asm=true` | `false` | **large** — the AV1 decoder without asm |
| 81 | `orc` | `-Dorc-target=neon` | `-Dorc-target=sse` | none |
| 90 | `ffmpeg` | (probes for nasm) | `--disable-x86asm` | large |
| 98 | `llvm` | `LLVM_TARGETS_TO_BUILD=AArch64;AMDGPU` | `X86;AMDGPU` | none |
| 46 | `freetype-bootstrap` | (bzip2 autodetected) | `--without-bzip2` | none — see *What the first run found* |
| 105 | `freetype` | (bzip2 autodetected) | `--without-bzip2` | none |

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

## What the first run found

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

### The stop: a declaration that was never true, on either architecture

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

### The fix, and the one that was rejected

`packages-amd64/freetype-bootstrap` and `packages-amd64/freetype` add
**`--without-bzip2`**. That is not a workaround for the linker; it makes the
recipe true.

The alternative was to install `libbz2.so` — which bzip2's recipe **already
builds**, at its `build-shared` step, and then never stages. That would also
make the link succeed and would give freetype a real runtime dependency on
bzip2. It was rejected: it contradicts `optional_off`. When a recipe has
already decided, the fix is to make the build obey it, not to satisfy the
linker.

**The base recipes are deliberately not changed.** Same gap, same one-flag fix
— but applying it on aarch64 moves `libfreetype.so`'s bytes and every install
digest downstream of it, so it needs its own dispatch and a re-seeding run.
Three things for whoever takes it:

1. `--without-bzip2` on `packages/freetype-bootstrap` and `packages/freetype`.
2. `bzip2` builds a shared library and throws it away. Either stage it or stop
   building it; a package that silently offers only a static archive hands the
   next consumer a static link nobody decided on.
3. There is a licence edge here too — `bzip2-1.0.6` code sitting inside
   `libfreetype.so` under a node whose ledger record does not mention it.

**77 recipes name something in `optional_off` without passing any
corresponding flag**, so this shape is not rare and a gate over it would fire
on 77 correct recipes. Most are genuinely default-off. The narrow, checkable
version — *a name in `optional_off` that the build system defaults to auto* —
needs per-package knowledge no sweep has.

### What is still unknown

The run stopped at 46 of 122. **Nothing beyond `curl` has been compiled for
x86_64**, so the second half of the set — glib, mesa, llvm, wlroots, the
compositor, wpewebkit — is entirely unmeasured, as are the image, the boot,
the DHCP test and the screenshot. Expect more findings of exactly this kind.

---

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
files differ in **36 lines: nine `argv` lines and nine `recipe-sha` lines,
and nothing else** — which is both the proof that the overlay changes only
what it claims to and the cheapest available review of what this architecture
does differently.

```
diff PLAN.txt PLAN-amd64.txt | grep -c '^[<>]'
36
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
| `veron --overlay packages-amd64 selftest` | `VERON-SELFTEST-OK`, `9 overlay recipe(s) pin the same source as their base` |
| `veron --overlay … --plan PLAN-amd64.txt plan --check` | `VERON-PLAN-OK`, `plan-sha256 d652603b…` |
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
- **The base freetype recipes still declare bzip2 off while building it on.**
  One flag, and a re-seeding run on aarch64 to go with it. See *The fix, and
  the one that was rejected*.
- **bzip2 builds a shared library and stages only the static one.** Either
  ship it or stop building it.
- **Packages 47–122 are unbuilt on x86_64**, and so is every step after the
  build.
