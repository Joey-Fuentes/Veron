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

## The eleven recipes that differ, and where they live

Eleven recipes need to say something different on x86_64 — seven predicted
from reading, four found by the runs. They are **not edited in place** — `packages/` is the aarch64 arm's tree and stays exactly as it is.
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

### What is still unknown

Everything now builds and boots. What remains open is one guest test, whether
the libffi fix closes it, and whether the aarch64 arm is carrying the same
latent flag. Four runs, four findings, **none of them on the predicted list** —
the predictions were right about the seven they named and told us nothing about
the four that actually cost runs.

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
files differ in **47 lines: ten `argv` lines, eleven `recipe-sha` lines and one
whole added step** — which is both the proof that the overlay changes only
what it claims to and the cheapest available review of what this architecture
does differently.

```
diff PLAN.txt PLAN-amd64.txt | grep -c '^[<>]'
47
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
| `veron --overlay packages-amd64 selftest` | `VERON-SELFTEST-OK`, `11 overlay recipe(s) pin the same source as their base` |
| `veron --overlay … --plan PLAN-amd64.txt plan --check` | `VERON-PLAN-OK`, `plan-sha256 be351f2a…` |
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
