# Stage 4 — tcc to a booting Linux

**Scope: everything above tcc.** Stage 3 owns reaching tcc from M2-Planet
(`spikes/stage3/README.md`); this stage owns what tcc is then used to build —
gcc, a userland, a kernel, and a QEMU boot. It also owns removing the host
borrowing that stage 3's results were allowed to keep.

**Read this file first.** The forward plan is `ROADMAP.md`; the two finished
results have their own full records in `GCC-BACKPORT.md` and `TCC-USERLAND.md`.

---

## The jobs, and where each stands

Each triggers on its own file only; none starts another. The first four are the
gcc leg; the `hermetic-*` boxes are the climb above it.

| job | question it owns | state |
|---|---|---|
| `gcc47-aarch64-backport` | can 4.8.5's aarch64 backend live in 4.7.4? | **ANSWERED** — full build, libgcc, xgcc runs |
| `gcc47-libgcc-ice` | why did libgcc never build? | **ANSWERED** — one missing `#include` |
| `tcc-builds-gcc-arm64` | can *our tcc* reach a modern gcc, with no host compiler? | **ANSWERED** — tcc → gcc 4.7.4 → gcc 4.7.4 → **gcc 10.2.0**, boxed |
| `tcc-gcc-miscompile-check` | did tcc miscompile the gcc it built? | **ANSWERED** — 349 of 349 TUs identical |
| `tcc-userland-arm64` | can a tcc-built userland boot? | **ANSWERED** — PID 1 under a gcc-built kernel |
| `hermetic-gcc47` | rung 1 in an LFS 10.0 box, then gcc 10 | in progress |
| `hermetic-gcc10` | a gcc 10.2.0 box, and can it reach 15 and 16? | **ANSWERED** — builds **gcc 15.2.0 and 16.1.0**, both run |
| `hermetic-gcc15` | a gcc 15.2.0 system that boots | **ANSWERED** — boots linux 7.1.5; gcc runs inside the guest |
| `hermetic-gcc16` | a gcc 16.1.0 system that boots | **ANSWERED** — boots linux v7.2-rc4, 142 checks green |
| `hermetic-enumerate-host` | what does the host still supply? | not a rung; enumeration only |
| `stage4-complete` | does the *whole* ladder run, tcc to a boot, in one process? | **ANSWERED** — tcc → 4.7.4 → 4.7.4 → 10.2.0 → 15.2.0 → linux 7.1.5, booted, 61.4 min |

---

## THE JOIN, CLOSED

**A gcc 15.2.0 whose entire ancestry was built in the same process — starting
from tcc — built linux 7.1.5, booted it, and compiled a program inside it.**

```
VERON-BOOT-OK        Linux 7.1.5 aarch64
VERON-COMPILER       Linux version 7.1.5 (gcc (GCC) 15.2.0, GNU ld ...)
VERON-TESTS          pass=8 fail=0
VERON-GCC-IN-GUEST   ok compiled and ran, rc=42 (expect 42)
GCC-EXERCISE         pass=10 fail=0
```

`stage4-complete` first ran green on 2026-07-27, run 81944089602, 61.4 minutes.

Why this is different from the `hermetic-*` boxes: those each start from a
host-built cross toolchain *on purpose*, so a failure localises to one question.
That is the right shape for them and they keep it. But it means the gcc that
booted in `hermetic-gcc15` was built by the runner's gcc, and the gcc 10 that
`tcc-builds-gcc-arm64` reached was consumed by nothing. Two green chains that
never touched.

`stage4-complete` walks the whole thing in one job. The join is a single
substitution: LFS chapters 5.2 and 5.3 build binutils and gcc pass 1 with
whatever `gcc` is on `PATH`, and everything above them is already built by the
cross toolchain those two steps produce — so pointing just those two at the
tcc-built gcc 10 moves the entire sysroot, kernel and boot onto tcc's line.

28 of its 34 steps are copied byte-for-byte from `tcc-builds-gcc-arm64` and
`hermetic-gcc15`, step names unchanged so each diffs against its source. The
four that are not: `Install` (union of both), `5.2` and `5.3` (four-line guard
exporting `CC`), and `SEED` (the join itself).

**What it does not claim.** tcc is host-built here, outside the box — the
declared hole, and stage 3's open rung. One run, so nothing about
reproducibility. No 3-stage bootstrap, no DejaGnu. gcc 16 is not in this chain;
`hermetic-gcc16` answers that alone.

**No cache, deliberately.** A restored sysroot was seeded by some earlier run's
compiler, and booting one would claim a tcc ancestry it did not have. An hour of
compute is cheaper than a false claim.

---

## THE RESULT THIS STAGE TURNED ON

**A gcc 16.1.0 built in a box with no host filesystem built linux v7.2-rc4, and
the glibc 2.43 that box built ran as PID 1 under it.**

```
VERON-BOOT-OK   Linux 7.2.0-rc4 aarch64
VERON-KERNEL    Linux version 7.2.0-rc4 (gcc (GCC) 16.1.0, GNU ld (GNU Binutils) 2.46.1)
VERON-LIBC      ld.so (GNU libc) stable release version 2.43.
VERON-RESULT    PASS 59 passed, 0 failed
```

`hermetic-gcc16` first booted on 2026-07-26 and is now gated by three suites
that must all pass before the run goes green:

| suite | where | checks |
|---|---|---|
| compiler acceptance | in the box | 39 |
| userland acceptance | in the box | 44 (1 skipped) |
| userland acceptance + system tests | in the guest | 59 |

The whole run, with a warm cache, is **13 minutes** — of which 11 are the kernel.
See [how the box is tested](#how-the-box-is-tested), below.

**And it is not a single instance.** `hermetic-gcc15` reached the same result
independently on the same day, from the *stable* book rather than the
development one — gcc 15.2.0, LFS 13.0, booting **linux 7.1.5**, the latest
stable kernel. Two boxes, two toolchains, two kernels, two different sets of
faults on the way. It also carries the claim one step further:

```
VERON-GCC-IN-GUEST ok compiled and ran, rc=42 (expect 42)
```

QEMU hands the guest the sysroot over 9p and the guest **chroots in and runs the
compiler** — so the gcc this box built compiles and runs a program inside the
kernel that same gcc built. That was TODO item 3, *"the strongest claim
available"*.

---

## THE OTHER RESULT THIS STAGE TURNED ON

**The ICE that blocked the gcc leg since it opened was one missing `#include`.**

`gcc47-libgcc-ice` found it on 2026-07-26 after four runs, three of which were
lost to faults in the harness rather than the thing under test.

```
4.7.4   get_hard_reg_initial_val declared in gcc/integrate.h:21
4.8.5   ...declared in gcc/function.h:770
```

The aarch64 backend was written for 4.8, so `aarch64.c` includes `function.h`
and not `integrate.h`. Transplanted into 4.7 nothing declares it, and C89 then
assumes an `int` return:

```
aarch64.c:3941: warning: implicit declaration of function
  'get_hard_reg_initial_val' [-Wimplicit-function-declaration]
```

— the **only** implicit declaration in the entire compiler build. On LP64 the
returned `rtx` is truncated to 32 bits and sign extended back:

```
tem    = 0xfffffffff6b46500     <- low half preserved, high half sign bits
fndecl = 0x0000fffff78b6800     <- a valid pointer in the same frame
```

Non-null, so it passed `if (tem == NULL)` at `builtins.c:4568`, and `REG_P(tem)`
dereferenced it at 4581. That is the SIGSEGV, a hundred objects into libgcc,
with nothing on its face connecting it to a header.

**It is a warning, not an error.** The build reported *"0 errors, 471 warnings"*
and nobody read them. With the include added, `libgcc.a` built at 992,532 bytes.

The fix graduated to `tools/port_gcc47_api.py` as a **fourth rule kind**,
`include`, alongside drop / add / rename. It is the most dangerous of the four
because it does not fail at compile time.

### How that answer was reached, and what it cost

Worth recording, because the shape recurs:

- **The suspect named at the start was wrong.** The workflow hypothesised
  `__builtin_init_dwarf_reg_size_table` and `DWARF_FRAME_REGISTERS`. The
  backtrace put the fault in `expand_builtin_frame_address` — a different
  builtin on a different path. The *shape* of the guess was right (a 4.8 backend
  meeting a 4.7 middle-end at the frame surface); the target was not.
- **The ucontext theory was falsified, not merely dropped.** It predicted the
  ICE was environmental, so `hermetic-gcc47` was built on LFS 7.5 with glibc
  2.19 to test it. The box verified its own premise — `typedef struct ucontext`
  present — and the compiler died anyway, same file, same line, same column.
  A libc where the theory cannot apply.
- **The control was read at last**, and the two arms fail *differently*:
  vanilla 4.8.5 gives a clean `field 'uc' has incomplete type` at 129 objects;
  the transplant takes SIGSEGV at 104. Two different faults, so the control's
  failure never explained the transplant's.

---

## THE THIRD RESULT: tcc reaches gcc 10.2.0, with no host compiler in the box

**A tcc built the last gcc written in C; that gcc rebuilt itself with a C++
front end; and the g++ that yielded built gcc 10.2.0. All of it inside a sandbox
where every host C and C++ compiler is masked out.** `tcc-builds-gcc-arm64`,
2026-07-26, about 14 minutes end to end:

```
stage 1 configure rc : 0     tcc      -> gcc 4.7.4 (c,c++)   -> /work/out
stage 1 build     rc : 0     libgcc TF symbols missing of 8 : 0
stage 2           rc : 0     gcc 4.7  -> gcc 4.7.4 (c,c++)   -> /work/out2
stage 3           rc : 0     g++ 4.7  -> gcc 10.2.0          -> /work/out10
gcc 10 version : gcc (GCC) 10.2.0        implicit declarations : 0
```

This closes the question the choice of 4.7 was *for*. The old note read: *"an
ISO C++98 compiler is a floor, not a compatibility guarantee across thirteen
years."* It was a fair worry — the expectation was that gcc 10's source would
reach for C++11 *library* headers that 4.7's libstdc++ only partly has. It
didn't. gcc 10.2.0 built under g++ 4.7 with no intervention at all.

### The box, and why it changes what the earlier results mean

Every gcc result before this one was produced on a runner where `/usr/bin/gcc`
sat on `PATH` throughout. Nothing in those runs could distinguish *"tcc built
this"* from *"something quietly fell back to the host compiler"* — and
`/usr/bin/ld` appearing in a link error is what that looks like from outside.

The build now runs under bwrap with **the host compilers removed**. Each driver
name is resolved to the real binary behind it and bind-mounted to `/dev/null`,
and `/usr/libexec/gcc` — where `cc1` and `cc1plus` live — is replaced by an
empty tmpfs. The masking is structural rather than argued, and the run proves it
before spending anything on a build:

```
host cc : masked -- nothing in /usr/bin can compile a C file
/repo   : read-only        network : unreachable
tcc     : compiled, linked and ran, exit=6
```

**Resolve the binary, never the name.** The first attempt masked all fourteen
driver names directly and bwrap refused it:

```
bwrap: Can't create file at /usr/bin/c++: No such file or directory
```

Twelve of the fourteen are symlinks, and `c++` leaves `/usr/bin` on the way to
its target — `c++ → /etc/alternatives/c++ → /usr/bin/g++ → g++-13 →
aarch64-linux-gnu-g++-13`. All of them terminate at a handful of real files, so
resolving first and deduping masks exactly as much with no symlink for bwrap to
traverse.

**Scan, do not enumerate.** The mask is built by scanning `/usr/bin`, which
earned its keep immediately: the arm64 runner carries gcc 12, 13 **and** 14 plus
clang 16, 17 and 18 — 34 names resolving to 12 real binaries. A hand-written
list would have missed half.

### Each rung is exercised, not asserted

A compiler that exists is not a compiler that works, and this file already
records why `--version` proves nothing. Every rung runs its own output:

| rung | what is run | result |
|---|---|---|
| gcc 4.7 `cc1` | emits aarch64, assembled, **linked by our own gcc**, run | exit 55 |
| g++ 4.7 (tcc-built) | `std::vector` + `std::string`, compiled, linked, run | exit 47 |
| g++ 4.7 (gcc-built) | the same | exit 47 |
| gcc 10 `gcc` | `fib(10)` compiled, linked, run | exit 55 |
| gcc 10 `gcc` | **gmp 6.2.1 rebuilt — 515 objects — then linked and RUN** | 2^100 correct |
| gcc 10 `g++` | C++14 return-type deduction, run | exit 47 |
| control | the same file through g++ 4.7 at `-std=c++11` | rejected on the **language** |

The gmp check is the one that carries weight: 515 objects of limb arithmetic
compiled by gcc 10 and then asked for a value with a known decimal expansion.
Compiling is not computing, and the earlier version of this gate built those 515
objects and executed none of them.

The control is there because *"gcc 10 compiled C++14"* means nothing unless 4.7
could not. It has to fail for the right reason: run at `-std=c++14` it answered
`unrecognized command line option`, which shows 4.7 does not know the **flag**,
not that it cannot compile the **code**. At `-std=c++11` — the newest standard
4.7 accepts — it rejects the language, and the gate now fails if it ever sees
the flag error instead.

### What is still borrowed here, named

tcc itself is built **outside** the box by the host gcc, and that cannot be
closed at this rung: invariant #1 forbids a committed binary, so a tcc must be
derived, and today the only thing that can derive one is the host gcc. Reaching
it from the seed is stage 3's open rung. Until then this job's claim is about
**capability, not provenance**.

Also bound and declared: binutils (`as`, `ld`, `ar`, `ranlib` — gcc cannot be
built without them and binutils is not known to be tcc-buildable), glibc and its
headers, and make/perl/m4/bison/flex/sh/coreutils/python3.

### What it does not show

- **No testsuite.** DejaGnu has never run against any of these compilers.
- **Nothing rebuilt twice.** No byte-identical rebuild of any rung.
- **No bootstrap.** All three stages are `--disable-bootstrap`, so gcc's own
  stage2/stage3 byte-identical comparison — the self-validating gate this stage
  keeps naming — has never run here either. See the deferral section below.
- **gcc 10 is not self-contained.** Its binaries were linked by g++ 4.7 against
  `out2`'s `libstdc++.so.6.0.17` and need it on `LD_LIBRARY_PATH` to run.

---

## What is proven

**The gcc entry point, completely.** `gcc47-aarch64-backport`, host tools:

```
configure rc=0    build rc=0    (full make, through libgcc)
cc1        BUILT
libgcc.a   648,788 bytes
xgcc       BUILT   ->  fib(10) compiled, linked, ran, exit 55
implicit declarations in the whole build: 0
```

Until 2026-07-26 this arm ran `make all-gcc`, which stops before the runtime —
not a choice but a consequence of the ICE. The full build is new, and so is the
gate that **fails the arm on any implicit declaration in the backend**, because
that is now known to be a truncated pointer rather than a style complaint.

**tcc builds that compiler too — including its C++ front end, and the g++ it
yields has built gcc 10.2.0.** `tcc-builds-gcc-arm64`, and see the section
below for the whole chain:

```
stage 1  tcc      -> gcc 4.7.4 (c,c++)   libgcc.a 1,290,110   cc1plus BUILT
stage 2  that gcc -> gcc 4.7.4 (c,c++)   g++ links, runs, exit 47
stage 3  g++ 4.7  -> gcc 10.2.0          gcc, g++, cpp installed
implicit declarations: 0     libgcc soft-float binary128 routines: 8 of 8
```

**The userland half of the Linux leg.** A musl + BusyBox userland compiled
entirely by tcc boots as PID 1 under a GCC-built arm64 kernel. Gated by
`tcc-userland-arm64`; full record in [`TCC-USERLAND.md`](./TCC-USERLAND.md).
The one real compiler gap it found: **tcc has no dead-code elimination**, so
BusyBox's `if (ENABLE_FEATURE_X)` idiom leaves references to functions never
defined. The kernel uses the same idiom via `IS_ENABLED()`.

---

## Why LFS and not live-bootstrap

They solve different problems and both halves are needed.

- **LFS** builds a temporary toolchain *to isolate from a host*. Chapters 5–6
  build tools that are deliberately thrown away; chapter 7 enters an environment
  containing nothing else.
- **live-bootstrap** never has a host to isolate from. It starts at a 357-byte
  seed and every byte above it was produced by something below.

Veron's lower half is live-bootstrap-shaped and its upper half is LFS-shaped.
**The seam is tcc, and it is also the stage 3 / stage 4 boundary**: below it,
provenance; above it, isolation.

The isolation is **not static linking** — three runs were lost to that before
the book was read properly. It is a triplet the host does not have,
`--with-sysroot`, and a libc cross-compiled into the sysroot so the tools find
their loader inside it.

## The triplets, and which one the system wears

**DECIDED, NOT YET IMPLEMENTED.** The names below are what the chain should
produce; what it produces today is at the bottom of this section. Nothing in
this repository recorded the intent before now, which is why the current state
drifted into being backwards without anyone noticing.

| role | triplet |
|---|---|
| the cross toolchain that builds the system | `aarch64-toolchain-linux-gnu` |
| the string that forces autoconf into cross mode | `aarch64-toolchain-linux-musl` |
| **the system itself** | **`aarch64-veron-linux-gnu`** |

**The scaffolding must be visibly scaffolding.** A cross toolchain exists to be
thrown away — it is the thing LFS chapter 5 builds and chapter 8 replaces. It
should not wear the project's name, because a compiler in `/tools` called
`aarch64-veron-linux-gnu-gcc` reads as *the* Veron compiler and is precisely
the one that is not.

**The system must say what it is.** `gcc -dumpmachine` on the built system is
the shortest answer to "what am I running", and it is currently
`aarch64-unknown-linux-gnu` — a system that does not know its own name. Every
path under `/usr/lib/gcc/<triplet>/`, `/usr/include/c++/<version>/<triplet>/`
and `/usr/lib/<triplet>/` carries the same string, so this is not cosmetic: it
is several hundred paths in `manifest.tsv` and in stage 5's `files.tsv`.

**`-musl` on the middle one is not decoration either.** Its whole job is to
differ from `--build` as a *string*, because autoconf decides a build is native
by string comparison and then runs target binaries it cannot run. The libc
suffix has to be truthful for the configure scripts that key on it, so this
name is only correct while the half it configures is musl — see the open
question below.

### What the chain does today

| variable | value | where |
|---|---|---|
| `LFS_TGT` | `aarch64-veron-linux-gnu` | the hermetic boxes' cross toolchain |
| `HOSTTRIP` | `aarch64-veron-linux-musl` | phase B's autoconf cross trick |
| `BUILDTRIP` | `aarch64-unknown-linux-gnu` | phase B's `--build` |
| the built system | `aarch64-unknown-linux-gnu` | measured: 678 occurrences in a stage-5 diagnostic bundle, and no other triplet |

So **`veron` names the scaffolding twice and the system not at all.** The
native path wins for most of phase B — `cfg_try` attempts native-plus-`-static`
first — which is why `HOSTTRIP` does not appear in the output despite being
passed on every `configure` line.

### What the rename costs

Every triplet-bearing path moves, so the run-to-run manifest comparison breaks
**once, deliberately**. That is an argument for doing it before stage 5's
install digests are pinned harder, not after — and for doing it in the same
chain rerun as the kernel's DRM symbols, since neither is worth a full rebuild
alone.

### Which half is which, since the `-musl` looked wrong and is not

`HOSTTRIP`'s comment says `-musl` is *"honest about the libc, which several
configure scripts key on"*, and `policy/defaults.toml` records
`flavor = "glibc"` — which reads like a contradiction. It is not:

- **`HOSTTRIP` lives in `rungs.sh`, and `rungs.sh` is PHASE A.** Phase A is the
  musl half — it hand-builds musl and carries the chain to gcc 15.
- **Phase B runs `rungs-sysroot.sh`, which never mentions `HOSTTRIP`** — zero
  occurrences — and is the glibc half.

So the `-musl` is truthful about the half that uses it, and `flavor = "glibc"`
is truthful about the system that comes out. Two different halves, two correct
statements, and the appearance of conflict came from reading one variable
without checking which script owns it.

`aarch64-toolchain-linux-musl` is therefore the right name for it: it keeps the
libc truthful for the configure scripts that key on it, and stops the vendor
field claiming the scaffolding is Veron.

**And it never reaches the output.** A full-chain log contains 22 occurrences
of `aarch64-veron-linux-gnu`, 13 of `aarch64-unknown-linux-gnu`, and **none of
`aarch64-veron-linux-musl`** — because `cfg_try` attempts native-plus-`-static`
first and that path wins for everything phase A builds. The triplet exists for
the fallback, which is exactly when a package cannot be measured natively.

## The ladder, and the box that owns each rung

```
tcc  →  gcc 4.7.4 + 4.8.5's aarch64 backend      last gcc written in C     ]
     →  g++ 4.7                                  built FROM that C        ]  all three
     →  gcc 10.2.0                               C++98 ceiling            ]  PROVEN, boxed
     →  gcc 15.2.0 / 16.1.0                      needs C++14, which 10.2 has
     →  kernel + userland + QEMU boot
```

The first three rungs are carried end to end by `tcc-builds-gcc-arm64` in a
single box with no host compiler in it. The `hermetic-*` boxes below own the
rungs above, and reach rung 1 by a different route — an LFS-style cross
toolchain built by the host gcc, which is scaffolding that tcc replaces.

| box | book | builds | then attempts | boots? |
|---|---|---|---|---|
| `hermetic-gcc47` | LFS 10.0 | gcc 4.7.4 + backend, libgcc, libstdc++ | gcc 10.2.0 | no |
| `hermetic-gcc10` | LFS 10.0 | gcc 10.2.0 | gcc 15.2.0 **and** 16.1.0 | no |
| `hermetic-gcc15` | LFS 13.0 | gcc 15.2.0 + userland | — | **YES — linux 7.1.5, 2026-07-26** |
| `hermetic-gcc16` | LFS dev r13.0-156 | gcc 16.1.0 + userland | — | **YES — linux v7.2-rc4, 2026-07-26** |

Only gcc15 and gcc16 build a kernel. The lower two are about reaching the next
compiler.

**These boxes are LFS-shaped scaffolding, and that is temporary.** In the end
state tcc builds rung 1 and there is no host compiler anywhere. What carries
over is the *sysroot discipline* — no `/usr`, every input declared — not the
cross-triplet trick, which exists only because there is a host to isolate from
today.

**`hermetic-gcc47` used to be a period box** (LFS 7.5, gcc 4.8.2, glibc 2.19),
built solely to test the ucontext prediction. That prediction is falsified, so
the period environment buys nothing and the whole 4.8.2 cross toolchain is
deleted. It now shares the LFS 10.0 base with `hermetic-gcc10`, which means
every fix one earns, the other inherits.

---

## The boxes in flight

### hermetic-gcc10 (gcc 10.2.0, glibc 2.32) — ANSWERED 2026-07-26

**A box whose newest compiler is gcc 10.2.0 builds gcc 15.2.0 and gcc
16.1.0**, run `81886082847`. Both install, report their own version, and
compile and run a program. 44 minutes wall clock against a 360-minute cap.
Five runs, five distinct mechanisms — full record in `GCC10-BOX.md`.

The one doing the most work, and the newest file. It is the only box that must
support **C++ inside the box**, because its job is to build another compiler:
LFS chapter 7, libstdc++ pass 2, and bison. gcc15 and gcc16 have no chapter 7 —
their job ends at a kernel, and a kernel is C.

It is also **2020 software on a 2026 host** (gcc 10.2.0, glibc 2.32, binutils
2.35) where gcc15/16 are contemporary-on-contemporary, so it meets every era
bug the others cannot: `_IO_ftrylockfile` removed in glibc 2.28, `MB_LEN_MAX`
against a freestanding `limits.h`, `config.guess` moved into `build-aux/`. And
**LFS 10.0 has no `/usr` merge**, so every path assumption inherited from the
13.0-derived code was subtly wrong.

What it cost to get there, one mechanism per run:

- **the cache was poisoning itself.** `actions/cache` saves on failure, so a run
  that died half way published a half-built sysroot under the same key and the
  next run built on top. Three consecutive failures were plausibly the same
  poisoned tree presenting differently. A `.sysroot-complete` marker is now
  written as the last act of chapter 7; without it the restored tree and all
  `b-*` directories are deleted and the run starts clean. It caught a 4.8 GB
  unmarked sysroot on its first outing.
- **m4 was built in the wrong chapter.** LFS 10.0 lists it **first** in chapter
  6; this workflow had it in chapter 7, after gcc pass 2. Moved.
- **the full `limits.h` went to one directory of three.** The book writes
  `install-tools/include`, which is what fixincludes reads — correct, and not
  sufficient, because the pass-1 compiler cross-builds chapter 6 packages before
  anything regenerates `include-fixed`. Hence
  `bits/stdlib.h:91: "Assumed value of MB_LEN_MAX wrong"`. Now all three.
- **make keeps `config.guess` in `build-aux/`**, as the book says. The top-level
  path failed silently and configure ran with an empty `--build=`.

- **the m4 block left the shell inside `m4-1.4.18/`** when it moved, and the
  next command could not find its tarball. Contained in a subshell.
- **chapter 7 failed and the step went green.** The in-box script is piped into
  `sed`, and a pipeline exits with its *last* command's status — `sed`'s, which
  is 0. bison failed, `.sysroot-complete` was written anyway, and both attempts
  spent an hour dying on the tool that was never installed. `set -o pipefail`.
- **`cp -r` destroyed the timestamps upstream shipped**, in three places. It
  stamps every file with the time of the copy in filesystem order, so
  `configure.ac` can land newer than `configure`; automake's maintainer rules
  then fire and want an autoconf this box does not have. `cp -a` preserves
  what `tar` preserved.
- **a "belt and braces" `touch` loop then caused a failure of its own** by
  stamping a fixed list of names — `aclocal.m4`, `configure`, `Makefile.in`,
  `config.h.in` — while bison ships its template as `lib/config.in.h`, which
  matches none of them. A name list can never be complete, and every name it
  misses becomes a file older than its own dependencies. Removed; the net moved
  to `AUTOHEADER=true AUTOCONF=true AUTOMAKE=true ACLOCAL=true` on the make
  lines, which needs to know no filenames at all.
- **C++ linked but could not run.** libstdc++-v3 installs into
  `toolexeclibdir`, not `libdir`, when configure sees `--host` differ from
  `config.guess` — so it landed in `/usr/lib64`, which gcc searches at link
  time and the loader does not at run time. The book never notices because
  every remaining chapter 7 package is C; this box has to *run* C++, since gcc
  15 and 16 execute their own generators. A declared deviation: `ld.so.conf` +
  `ldconfig`, plus symlinks into `/lib`. `ldconfig` appears in LFS chapter 8
  and nowhere in chapter 7.
- **bison's doc rules wanted perl** — `$(PERL)` is left *empty* rather than
  routed through `missing`, so `/bin/sh: -pi.bak: not found`. `PERL=true`.
- **the C++ gate was killed by its own success value.** It returns 42 to mean
  pass, under `set -e`, via `cmd; rc=$?` — errexit fires before the assignment.
  A captured status must sit in an OR list: `rc=0; cmd || rc=$?`.

Two predictions recorded here were wrong, and are worth keeping: BusyBox `awk`
was expected to break gcc's `opt-gather.awk`/`optc-gen.awk` and did not, and
the 6-hour cap was expected to bind and is not close.

### hermetic-gcc15 (gcc 15.2.0, glibc 2.43) — BOOTS

Reached in six runs on 2026-07-26. It boots **linux 7.1.5** — the latest stable
kernel, deliberately not the 6.18.10 its book pins — and then, over a 9p share,
**runs its own compiler inside the guest**.

```
[    1.13] Run /init as init process
VERON-BOOT-OK      Linux 7.1.5 aarch64
VERON-COMPILER     Linux version 7.1.5 (gcc (GCC) 15.2.0,
                   GNU ld (GNU Binutils) 2.46.0.20260210)
VERON-LIBC         ld.so (GNU libc) stable release version 2.43.
GCC-EXERCISE       pass=10 fail=0
VERON-TESTS        pass=8  fail=0
VERON-GCC-IN-GUEST ok compiled and ran, rc=42 (expect 42)
Kernel panic 0 · BUG: 0 · WARNING: 0 · Call trace 0 · Oops 0 · segfault 0
[    8.39] reboot: Power down                                     qemu rc=0
```

Five things stood between this box and a boot, and **none was visible from where
the previous one failed** — each had to be removed before the next could be
seen. That is the shape worth recording, more than any individual fault.

- **It was building a kernel from no book.** `KVER` was 7.1.5 while `KERNEL`
  was 6.18.10 for the API headers. LFS 13.0's `wget-list` pins
  `linux-6.18.10.tar.xz` and its chapter 10.3 is titled *Linux-6.18.10*;
  `sources/lfs.toml` records the same against the entry whose `role` names this
  workflow by filename. 7.1.5 was in neither book — 7.1.x is the *development*
  book's series, which pins 7.1.3 — and the comment above the fetch still
  described the dev book's pin, an inherited line above a version it did not
  describe. This is the defect `lfs.toml` already records once against gcc10:
  *"an earlier workflow built 10.4.0 while this manifest said 10.2.0"*. It was
  collapsed to the book's single kernel, and 7.1.5 came back later **as a
  decision** rather than as drift — see below.

- **`BC_VER` was declared and never used.** The kernel generates
  `kernel/time/timeconst.h` by piping `CONFIG_HZ` through `bc`, so what had been
  answering to `bc` was BusyBox's applet, which `defconfig` enables. The build
  worked; nothing had declared what it was using. LFS 13.0 builds bc at 8.15 and
  so does this box now, from the book's own URL.

  Removing the applet first is not tidiness. `/usr/bin/bc` was a symlink to
  busybox, and **installing over a symlink follows it** — a tool writing its
  output to `/usr/bin/bc` writes *through* the link onto `/usr/bin/busybox`,
  which is the shell, `ls`, `sed`, `grep` and `tar` this box is made of.

- **openssl, and a misread of the book's silence.** The kernel died at
  `certs/extract-cert.c:21: fatal error: openssl/bio.h`. This file had recorded
  that `extract-cert`, `MODULE_SIG` and `TRUSTED_KEYRING` appear **zero times**
  in all eleven chapters, and concluded that LFS never touches the certs
  machinery. The count was right and the conclusion was wrong: LFS builds
  **OpenSSL 3.6.1 at 8.49**, twenty-odd packages before the chapter 10 kernel,
  so by the time it runs `defconfig` the header is simply there and there is
  nothing to say. *A book is silent about what it has already solved.* The fix
  was a missing package, not a wrong config — so the seven-symbol disable list
  and the selector hunt stayed deleted. `hermetic-gcc16` reached the same
  conclusion by fighting kconfig to a standstill first.

- **The initramfs contained no C library and could never have booted** —
  the same fault `hermetic-gcc16` hit, found here independently. `readelf`
  reported `PT_INTERP: /lib/ld-linux-aarch64.so.1`, which was not in the
  archive. **The 626,575-byte size was the tell**: that is a busybox and nothing
  else. It is now 6.4 MB and carries the loader and every `NEEDED` library.

- **And it would have printed nothing even if it had booted.** bwrap is
  unprivileged, so `mknod` cannot put `/dev/console` in the image; without it
  `init` starts with no stdio and its `echo` goes nowhere. `CONFIG_DEVTMPFS` and
  `CONFIG_DEVTMPFS_MOUNT` are the second and third items on the same book list
  whose first item is `WERROR`, and none of the three was set. **A kernel that
  booted perfectly would have produced an empty console** and been read as one
  that never reached userspace.

- **The romfile failure was ours** — `-nic none`, for the reasons recorded under
  gcc16. Three runs here were attributed to the runner's packaging.

Then the kernel decision was revisited on purpose. **7.1.5 is the latest stable
kernel and this box is the modern baseline, so it should run it**; the book's
6.18.10 had already proved the toolchain-to-QEMU path. Building glibc 2.43
against 7.1.5 headers then failed:

```
sys/mount.h:268: error: 'OPEN_TREE_CLONE' redefined [-Werror]
linux/mount.h:64:  note: this is the location of the previous definition
```

glibc defines it as `1`, the Linux 7 UAPI header as `(1 << 0)`. Different
bodies, so cpp warns, and glibc builds itself with `-Werror`. The development
book's answer is `glibc-2.43-upstream_fixes-1.patch`, whose own text reads *"Now
fix glibc to build against Linux 7"* — but it pairs that patch with **7.1.3**,
and **no book anywhere pairs glibc 2.43 with 7.1.5**. Rather than bet that a
point release changed nothing, this box took the split `hermetic-gcc16` already
boots with: **API headers from 7.1.3, image built and booted at 7.1.5.** A
kernel is always free to be newer than the headers its libc was compiled
against — that is what the UAPI guarantee is for. Both glibc patches now go on,
including LFS 13.0's own `glibc-fhs-1.patch`, which chapter 5 prescribes and
this workflow had simply never applied.

**libstdc++ was installing to `/usr/lib64`**, exactly as in gcc16 and for the
same missing aarch64 translation of the book's x86_64 step. Worth recording
separately only because of *how it presented*: `t_cxx` **failed in the box and
passed in the guest**, because the guest runs the static build. g++ links fine —
gcc knows its own lib64 path — and the program dies at exec with
`error while loading shared libraries: libstdc++.so.6`, which reads as a broken
C++ runtime rather than a misplaced file. This box has no `ld.so.cache` by
design, so anything outside `/lib` and `/usr/lib` is invisible at exec.

**Three checks in this file could never fail, and one of them poisoned a
cache.** All three were `ls … | head -1 || echo MISSING` or the same shape: the
`||` reads the last pipeline element, not `ls`.

- The libstdc++ check printed an **empty string** on the very run where the
  library was in the wrong directory — not "MISSING", nothing at all.
- The libc check never showed, because libc really is in `/usr/lib`. *An
  unsound check pointed at something that works is still unsound.*
- The GCC exercise gate was `if box.sh … | sed; then`, which asks sed whether
  the tests passed. The run printed `GCC-EXERCISE pass=9 fail=1`, then *"the
  compiler in this box is exercised and sound"*, **marked the sysroot complete
  and cached it.** A check that cannot fail does not merely fail to catch
  things; it can hand the broken tree to every run that follows.

Three box invocations still ended in `| sed` with no status check — the reason
the certs failure produced no `Image` and the *boot* step, several steps later,
was what finally said so. They now read `${PIPESTATUS[0]}`, which is the fix
gcc16 arrived at after a blanket `pipefail` broke the box in six seconds.

**The sysroot is cached** behind `$S/etc/.sysroot-complete`, written only after
the compiler suite passes — "chapter 6 finished" is not the claim worth caching.
Restore by prefix, save under a run-unique key, and `SYSROOT_EPOCH` as the salt
to bump when chapter 5 or 6 changes. It has now been exercised in both
directions: a failed run saved nothing, and the epoch bump retired a tree that
had been marked complete while `t_cxx` was failing. Cold, the job is 45 minutes;
the cache is 1.33 GB.

#### How this box is tested

Smaller than gcc16's 142 checks — that suite is the model — but it covers the
same shape, and one thing gcc16 does not yet do.

- **In the box, 10 checks, gated.** libm; pthreads across four threads and
  400,000 mutex operations; `fork`/`waitpid`; a 1 MiB `mmap` round trip;
  `clock_gettime` through the vDSO; long double formatting; libstdc++ with
  `sort`, `map`, `string`, exceptions and lambdas; **the same source at `-O0`,
  `-O1`, `-O2`, `-O3` and `-Os` producing one 64-bit answer** — a disagreement
  there is a miscompile; and a **negative test**, that an implicit declaration
  is still *rejected*. That last one is the fault class that cost the gcc 4.7
  leg weeks, and a compiler that has stopped diagnosing it looks exactly like a
  working compiler until something segfaults a hundred objects in.
- **In the guest, the same programs again**, built static and staged into the
  initramfs, so the binaries this box compiled run under the kernel it built.
  Gated on `fail=0`.
- **An inventory the guest prints about itself**: kernel identity and cmdline,
  CPU count and features, memory, supported filesystems, mounts, every device
  node devtmpfs created, the busybox applet table, libraries in `/lib`, live
  pipeline/arithmetic/file-io probes, and a **dmesg hygiene scan** counting
  panics, `BUG:`, `WARNING:`, call traces, oopses and segfaults.
- **The compiler, inside the kernel it built.** QEMU offers the whole sysroot
  over 9p read-only; the guest mounts it, mounts a tmpfs over its `/tmp` so
  there is somewhere to write, `chroot`s in and runs gcc. This is TODO item 3
  below — *"the strongest claim available"* — and it is answered here:
  `VERON-GCC-IN-GUEST ok compiled and ran, rc=42`. It is **reported, never
  gated**: a kernel that boots and runs its userland is a good result whether or
  not the optional share was available.

One defect survived into a green boot and is worth keeping as an example. The
initramfs applet symlinks were a hand-written list, `head` was not on it, and
the one line intended to prove the box's own glibc was running printed empty:

```
/init: line 11: head: not found
VERON-LIBC
```

A missing applet does not stop init; it silently blanks whichever line needed
it. The list now comes from `busybox --list`, with the `busybox` entry skipped —
it **is** in its own applet table, and `ln -sf busybox busybox` in that
directory replaces the binary with a symlink to itself.

### hermetic-gcc16 (gcc 16.1.0) — BOOTS

Reached in eight runs on 2026-07-26. The glibc patches the dev book requires
were the last recipe error; everything after them was a fault in this repo's own
scaffolding, and every one of those failed **silently in the direction of
looking successful**. Recorded in the order they were found, because the shape
recurs and three of them were new instances of traps already written down in the
method notes below.

- **`| sed` ate the kernel step's failure.** The step ends in a pipe, and a
  pipeline exits with its LAST command's status. The build ran `exit 1` — it
  printed *"That is a finding, not something to retry."* — `sed` exited 0, and
  the job went green having produced no kernel. QEMU was then handed an `Image`
  that had never been written. **The upload step is the tell:** *"there will be
  2 files uploaded"*, not 3.

- **`set -o pipefail` was the wrong fix and broke the box in a new way inside
  six seconds.** Under pipefail, `yes '' | make oldconfig > /dev/null 2>&1`
  fails: make closes the pipe, `yes` takes SIGPIPE and exits 141, and pipefail
  promotes that to the pipeline's status. Every stream was redirected, so the
  step died having printed **nothing at all**. It would also have turned every
  `grep … | head | sed` diagnostic into a step abort whenever the grep matched
  nothing — killing the error report exactly when it is wanted. The fix is
  `${PIPESTATUS[0]}` on the three box invocations, and nothing global.

- **`scripts/config` has never worked in any box.** It is `#!/bin/bash`, and
  these boxes have BusyBox ash and no bash. Every call failed silently and the
  `sed` after the `|| true` was doing all the work — a fallback that was really
  the implementation. `--set-str` therefore never ran once, and an `--enable`
  fallback that only rewrote `# CONFIG_X is not set` did nothing at all for a
  symbol absent from the file. Rewriting the line (delete both forms, append the
  one wanted; kconfig takes the last assignment) needs nothing but sed.

- **The certs fight was unwinnable and unnecessary.** `SYSTEM_TRUSTED_KEYRING`
  is reached by `select`, so `olddefconfig` restores it every time and no
  disable list can be long enough. A mechanical selector hunt was built, and it
  worked — it named `SYSTEM_DATA_VERIFICATION` — but that symbol was *already*
  on the list, i.e. it too was selected. **The right answer was to stop
  fighting: put openssl in the box.** LFS builds it at 8.49 and its kernel
  chapter is 10; this box stopped at chapter 6, so it was missing a package the
  book's own kernel step assumes. With openssl present, `MODULES=y` and
  `SYSTEM_TRUSTED_KEYRING=y` are simply left alone and `certs/extract-cert`
  builds the way it does on any normal system. **The kernel config is now three
  settings**: `WERROR` off, `DEVTMPFS`, `DEVTMPFS_MOUNT`.

- **libstdc++ was installing to `/usr/lib64`.** The book's x86_64 step
  `sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64` has an aarch64
  counterpart — `gcc/config/aarch64/t-aarch64-linux`, holding
  `MULTILIB_OSDIRNAMES = mabi.lp64=../lib64` — and nothing in the book covers
  aarch64, so it was never applied. glibc went to `/usr/lib` (forced by
  `libc_cv_slibdir`) and libstdc++ went where nothing searches. **The check said
  it was fine**, because `ls … | sed … || echo "NO libstdc++"` can never fire
  its fallback — the `||` reads sed's status — and the `find` beneath it ran
  unconditionally. The lib64 paths in that log were the *fallback diagnostic
  printing*, which reads exactly like the check passing.

- **bc 7.0.3 does not build under gcc 16** without the book's
  `CC='gcc -std=c99'`. gcc 15 changed the default dialect to `-std=gnu23`, where
  `true` and `false` are keywords rather than `<stdbool.h>` macros; bc writes
  `BC_PARSE_EXPR_ENTRY(false, …)`, whose expansion pastes each argument through
  `UINTMAX_C()` — `c ## UL` — so `false` pastes literally and `falseUL` is not
  a thing. Checked across all eleven chapters: **bc is the only package the book
  overrides the standard for.**

- **The initramfs contained no C library and could never have booted.** It held
  one dynamically linked, PIE busybox plus symlinks. Its `PT_INTERP` names
  `/lib/ld-linux-aarch64.so.1`, which was not in the archive, so the kernel
  could not exec `/init`:
  ```
  Run /init as init process
  Failed to execute /init (error -2)
  Kernel panic - not syncing: No working init found.
  ```
  `-2` is `ENOENT` and nothing in that message mentions a library — it reads as
  a broken init *script*. **The 624,847-byte archive was the tell:** that is the
  size of a busybox and nothing else. The image now reads `PT_INTERP` and
  `NEEDED` out of the binaries with `readelf` and copies what they name.
  Carrying the sysroot's own loader is also the stronger claim: a static busybox
  would boot, but only proves the compiler works; this proves **the glibc this
  box built runs as PID 1 under the kernel this box built**, outside bwrap.

- **The romfile failure was ours, not the runner's.** `-M virt` instantiates a
  default `virtio-net-pci`, that device wants an option ROM, the ROM ships in
  `ipxe-qemu`, and `ipxe-qemu` is a *recommends* — which
  `--no-install-recommends` drops. A boot test needs no network card:
  `-nic none`. Four runs were attributed to QEMU packaging.

- **A curated applet list is the wrong direction.** The boot image shipped a
  hand-written list of busybox applets, verified against busybox — but nothing
  verified the *scripts* against the list. `cp` and `ip` were missing, so the
  harness reported a tmpfs fault and a downed loopback: two wrong conclusions
  from one absent symlink. Every applet is now installed, and the assertion runs
  the other way, from what the scripts invoke to what exists.

- **And the reporting threw the evidence away.** The guest *did* print
  `cp: not found`. It fell between a `head -30` and a `tail -40` while a
  `grep 'VERON-'` dropped it. The boot step now prints the **entire** userspace
  session, which is bounded and is the whole point of the test.

**The sysroot is cached behind a completeness marker**, because the first runs
spent 36 minutes reaching a kernel step that failed in 5 seconds. Restore and
save are split: restore by prefix, save under a run-unique key, and only once
both `THE LADDER` has proved compile-and-run returns 42 and the box tools have
been rebuilt. A tree with no marker is deleted rather than trusted.
`SYSROOT_EPOCH` is the salt to bump when chapter 5 or 6 changes — a key tracking
the file hash would invalidate on every comment, and a key tracking nothing
would serve a stale recipe forever. Warm, the whole run is 13 minutes.

Six book steps went in along the way, all of them about hermeticity or
cross-compilation correctness: `CXX=$LFS_TGT-gcc` for libstdc++ (the book warns
its configure misbehaves without it), the two `.la` removals the book calls
*"harmful for cross compilation"*, binutils' `ltmain.sh` workaround against
linking to host-distro libraries, `target_configargs=gcc_cv_target_thread_file=posix`,
and the `ldd` `RTLDLIST` fix.

---

## How the box is tested

Reaching userspace proves the kernel loads and the loader resolves. It proves
nothing about whether the system **works**, and until 2026-07-26 nothing here
tested more than that: the boot step passed on a single grep for a marker that
`init` printed before doing anything.

**The reference way to test a gcc built from source** is GCC's own DejaGnu suite
(`make -k check`, ~100k tests — LFS builds Tcl, Expect and DejaGnu at 8.30–8.32
for exactly this) and gcc's **3-stage bootstrap comparison**, where stage2 and
stage3 must come out byte-identical. Neither runs here yet; both are in the TODO
below. What runs instead is the tier that catches a broken toolchain in one
minute rather than in eleven minutes of kernel build ending a long way from its
cause.

### The compiler, in the box — 39 checks

- **LFS's own toolchain sanity check, all six parts.** This box was doing one of
  six. Start files from `/usr/lib`, the include chain reaching `/usr/include`,
  the linker's `SEARCH_DIR`, `libc.so.6` from the sysroot, the dynamic linker
  resolved.
- The driver can resolve `cc1`, `cc1plus`, `collect2`, `crt{1,i,n}.o`,
  `crtbegin.o`, `libc.so`, `libgcc.a` — and each exists.
- **The same answer at eight optimisation settings** — `-O0 -O1 -O2 -O3 -Os`,
  `-flto`, `-fno-inline`, `-funroll-loops` — on a deliberately UB-free corpus
  (struct-by-value, bitfields, varargs, `setjmp`, VLA, `qsort`, long double,
  `__builtin_popcountll`). **A disagreement here is a miscompile**, which is the
  failure a bootstrap most needs to catch and the one a smoke test never will.
  The corpus is portable enough that gcc 13.3 on x86-64 and gcc 16.1 on aarch64
  produce the identical checksum, so agreement is the optimiser and not luck.
- **pthreads + C11 atomics**, which is what proves
  `target_configargs=gcc_cv_target_thread_file=posix` is doing its job; without
  it the target libgcc and libstdc++ inherit pass 1's `--disable-threads`.
- **A C++ exception thrown in a `.so` and caught in `main`** — the check a
  libgcc without unwinding cannot pass, and the same question the gcc 4.7 leg is
  still carrying: `cc1plus` existing is not g++ being able to link and unwind.
- Static linking, shared libraries, `dlopen`/`dlsym`, `-std=c++17/20/23`,
  `-static-libstdc++`, fully static C++.
- **Determinism**: the same TU compiled twice must be byte-identical. Criterion
  2 in miniature, and nearly free.

### The userland, in the box and again in the guest — 44 and 45 checks

The box's entire userland is one busybox and ~400 applets. Every configure
script, every Makefile and the initramfs builder itself run on them, and none
had ever been exercised — `THE LADDER` checked five things and stopped.

**The suite prints an actual shell session**: every command echoed with a
prompt, its real output beneath, and a verdict where there is a known-correct
answer. A transcript a person can read is worth more than a column of PASS
lines, and the one time a command was missing the reporting is what failed.

```
  $ printf abc | sha256sum | cut -d' ' -f1
    ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
VERON-TEST PASS sha256sum, known vector
```

Covered: identity and hardware, `ls -la /`, mounts, `df`, the busybox banner and
applet table, file operations, sed/grep/awk/sort/uniq/cut/tr/wc, shell
arithmetic and here-docs and functions, tar/gzip/**cpio** round-trips, md5sum
and sha256sum against known vectors, `ps`, signals, and the loopback stack. The
**same script** runs under bwrap and under QEMU, so the two transcripts are
directly comparable: one userland, two kernels. Checks that cannot apply — the
box is bwrap with `--proc` and no `/sys` at all — **skip visibly** rather than
fail, because a suite that reports failure for an environment it was never meant
to run in teaches people to ignore failures.

### The system, in the guest — the rest of the 59

`/proc`, `/sys` and devtmpfs populated; `/dev/{null,zero,console,urandom}`
behaving; a 4 MiB tmpfs write-copy-read round trip; monotonic time; and a
**dmesg hygiene check** — a kernel can boot and still be unwell, and
`BUG:`/`Oops`/`Call trace:` sails straight past a "did it boot" test.

The centrepiece: the compiler step stages three binaries it built, and the guest
runs them. The dynamic C binary **recomputes the corpus checksum and it must
match the value computed inside the box** — the same program, the same answer,
inside bwrap and on the real kernel. Plus the C++ binary (STL, RTTI, exceptions)
and a static one.

`VERON-RESULT` distinguishes *init ran and failed* from *init hung*, which a
grep for a marker cannot.

---

## The verification we are deferring, on purpose

Every box builds each compiler in **one pass**, with `--disable-bootstrap`. That
is a **deferral, recorded as one** — the `deferral` field of the audit record
exists for this — and not a judgement that the checks are unnecessary. There is
nothing to fixpoint until a single pass completes, and the gate costs ~3x. Both
lower boxes take `bootstrap: yes` as a dispatch input.

**`tcc-builds-gcc-arm64` defers it too, and there the deferral now costs the
most.** That job is the only one whose whole chain — tcc → 4.7 → 4.7 → 10.2.0 —
is built by compilers this tree made, so it is where a stage2/stage3 comparison
would say the most and where a consistently miscompiling compiler would be
hardest to notice. It has no `bootstrap` input yet.

1. **Fixpoint, per builder.** `make bootstrap` requires stage2 and stage3 to
   compare **byte-identical**. `ROADMAP.md` already calls this out: *"gcc insists
   on exactly the property we would want to prove, using its own machinery.
   Free, and strong."* Nothing in this tree has ever run it.
2. **Builder-independence.** The same source built by our tcc and by the LFS gcc
   will **not** produce identical generation-1 binaries and never can:
   `genconditions` folds insn conditions only when the compiler building it is
   GCC, so a tcc-built tree keeps 2,082 patterns where a gcc-built one keeps
   2,078. Measured, understood, benign. The claim that *is* available: both legs
   reach a fixpoint and the fixpoints **agree on behaviour** — compile a fixed
   corpus with each stage3 and diff the emitted assembly.
3. **Safety of each handoff is not a separate experiment.** If our 4.7
   miscompiles gcc 10's stage1 in any way that survives, gcc 10's own
   stage2/stage3 comparison fails. A green bootstrapped build **is** the proof.

Neither 1 nor 2 is worth much alone — a consistently miscompiling compiler is a
perfectly stable fixpoint, which is the whole shape of the Thompson attack. It
is the conjunction that carries the argument.

**Only 4.7 needs two builder arms.** tcc enters the chain there; above it both
legs have converged and a single bootstrapped build per rung suffices. That is
what makes this affordable.

---

## Open, in the order they block things

1. ~~**Does the tcc-built g++ 4.7 link?**~~ **ANSWERED 2026-07-26.** It does —
   compiled, linked and ran, exit 47, and so does the one stage 2 builds. The
   old failure was the gate looking for C++ headers in an *uninstalled* build
   tree, where `-B` does not add them; against an installed prefix the answer
   means something.
2. ~~**`hermetic-gcc10` through chapter 7**~~ **ANSWERED 2026-07-26** —
   chapter 7 completes and the box builds **gcc 15.2.0 and gcc 16.1.0**, both
   of which then compile and run a program. `GCC10-BOX.md`. What is still not
   done in that box is `bootstrap: yes`, which is now measured rather than
   guessed at: see item 5.
3. **`hermetic-gcc47` on the LFS 10.0 base** — it inherits gcc10's fixes and is
   the rung that hands off to gcc 10 in the real chain.
4. ~~**g++ 4.7 → gcc 10.2.0 has never been attempted**~~ **ANSWERED
   2026-07-26** — `gcc (GCC) 10.2.0`, built by the g++ 4.7 that tcc produced,
   in a box with no host compiler. The worry was reasonable and did not
   materialise: the floor held, and gcc 10's source needed nothing from 4.7's
   libstdc++ that it did not have. gcc 10 → gcc 15/16 is now answered as well
   (`GCC10-BOX.md`) — but from a host-built cross toolchain, not from *this*
   4.7. The two halves have never been joined end to end, and that join is the
   remaining gap in the chain.
5. **Nothing has been rebuilt twice.** No box has been shown byte-identical
   across two runs — cheap, and the natural gate for a project whose thesis is
   "rebuild and diff rather than trust". `hermetic-gcc10` now has a measurement
   to put behind the word *cheap*: its whole job, both compilers included, is
   **44 minutes against a 360-minute cap**. A 3-stage bootstrap is roughly 35
   minutes per compiler, so the bootstrapped job is about two hours — and the
   `bootstrap` input already exists, so it costs a `workflow_dispatch` and no
   code change at all.
6. **The kernel is still borrowed** in `tcc-userland-arm64`, which boots
   Ubuntu's kernel. Correct for the ABI claim, but a distro artifact.
7. **QEMU's missing option ROMs** — CLOSED. Not a runner problem: `-M virt`
   adds a default NIC whose ROM is in a *recommended* package. `hermetic-gcc16`
   drops the NIC with `-nic none` and installs `ipxe-qemu` as well; the other
   boxes have not been touched.

---

## TODO

Ordered by what each buys, not by effort. Nothing here is blocking
`hermetic-gcc16` — it boots and its three suites are green — so these are the
next things worth a run, and the small tidying that came out of reading the
first clean transcript.

### Testing that is not yet here, and should be

1. **GCC's DejaGnu testsuite.** This is *the* reference way to test a gcc built
   from source, and this tree has never run it. It needs Tcl, Expect and
   DejaGnu in the box — LFS builds all three at 8.30–8.32 for precisely this
   reason — after which `make -k check` and `contrib/test_summary` are the
   standard invocation. The full suite is hours, so the first cut should scope
   it with `RUNTESTFLAGS`. One ~15-minute run gets the three packages into the
   cached sysroot, and every run after that is cheap.
2. **`make bootstrap` — gcc's own 3-stage comparison.** Every box builds each
   compiler in one pass with `--disable-bootstrap`, which is a recorded
   deferral and not a judgement (see the section above). `ROADMAP.md` already
   states the case: *"gcc insists on exactly the property we would want to
   prove, using its own machinery. Free, and strong."* It costs roughly 3x a
   gcc build. Both lower boxes already accept `bootstrap: yes` as a dispatch
   input; nothing has ever used it.
3. ~~**Compile inside QEMU.**~~ **ANSWERED 2026-07-26, in `hermetic-gcc15`.**
   QEMU offers the sysroot over 9p read-only, the guest mounts a tmpfs over its
   `/tmp` so there is somewhere to write, `chroot`s in and runs the compiler:
   `VERON-GCC-IN-GUEST ok compiled and ran, rc=42`. Two details worth carrying
   over: the VFS allows a tmpfs mount *inside* a read-only mount, which is what
   makes the read-only share usable; and `msize=262144` matters, because gcc
   opens several hundred files and the default transfer unit makes that look
   like a hang under TCG. **`hermetic-gcc16` has not had this applied**, and it
   is the box with the fuller test suite, so it is the better home for it.
4. **Rebuild twice and diff.** Item 5 above, applied to this box specifically.
   The compiler suite already proves one TU compiles byte-identically twice;
   the box has never been shown byte-identical across two runs, which is the
   natural gate for a project whose thesis is rebuild-and-diff.
5. **A libstdc++ testsuite pass**, once DejaGnu is in. `check-target-libstdc++-v3`
   is a much smaller run than `check-gcc` and covers the library the C++ checks
   here only sample.

### Cleanups

6. **The initramfs is owned by uid 1001.** `cpio` records the builder's uid, so
   `ls -la /` in the guest shows `1001` where a real image shows `root`.
   Harmless — `id` reports uid=0 and root ignores the bits — but it is not what
   a real system looks like. An owner override on the cpio fixes it.
7. **No hostname is set**, so `uname -a` reads `Linux (none) 7.2.0-rc4`. One
   line in `init`.
8. **The other boxes still carry the traps this one has had removed.**
   `scripts/config` cannot run in any of them. `hermetic-gcc15` is now clear:
   its three `| sed` box invocations read `${PIPESTATUS[0]}`, and the three
   `ls … | head || echo MISSING` checks test the file instead. `hermetic-gcc10`
   sets `pipefail`, which cost a full run to find out mattered — and is the
   blunter instrument of the two, for the reasons in the method notes.
   `hermetic-gcc47` has not been looked at. None of this is urgent and none of
   it should change without a run to confirm, but it is written down here so
   the next person does not rediscover it.
9. **`sources/` has no manifest for the packages this box fetches.** Invariant
   #6 says upstream comes in by pinned hash via a `sources/` manifest; these
   boxes fetch by URL with the version pinned in `env:` and no hash. That gap
   predates this work and is worth closing before any of it graduates out of
   `spikes/`.

## What is still borrowed

**In the `hermetic-*` boxes**, the host gcc builds the cross toolchain, exactly
as LFS chapter 5 does. Removing that is stage 3's job — seed → tcc — not this
directory's.

**In `tcc-builds-gcc-arm64` it no longer does.** That box masks every host C and
C++ compiler, so the only compiler above tcc is one this tree produced. What is
left there is tcc itself, built outside by the host gcc — which is step 5 of the
hermetic ladder in `GCC-BACKPORT.md` and is blocked on seed → tcc, not on
anything here.

- **Kernel UAPI headers** are copied in as content.
- **The transplant needs python3**, which no bootstrap chain has until very
  late. `expand_int_iterators.py` and `port_gcc47_api.py` run outside the box.
  `gcc47-libgcc-ice` emits `transplant-4.7.4.patch` as an artifact — the frozen
  form that removes the dependency and satisfies the reviewed-delta criterion.
- **binutils and make are not known to be tcc-buildable.** gmp/mpfr/mpc are
  (`tcc-builds-gcc-arm64`); `as` and `ld` are what gcc actually needs and every
  box borrows them.

---

## Method notes worth keeping

Every one of these cost at least one run, and most were faults in the harness
rather than in the thing under test. The recurring shape is worth naming:
**each failed silently in the direction of looking successful.**

### Shell and CI

- **A reporting step needs `set +e`.** GitHub runs `run:` blocks with
  `bash -e {0}`, so the first non-zero command kills the step. The C++ gate
  printed its header and the step died with `exit 1` and nothing else — the
  driver was found and invoked, the compile failed, and errexit deleted the one
  diagnostic the run existed to produce.
- **Any `if:` drops the implicit `success()`.** A failed kernel config still ran
  the initramfs and boot steps, against a kernel that did not exist.
- **A pipeline exits with its LAST command's status.** `grep … | head || echo
  "none"` never fires the fallback, so an absent symbol prints nothing at all
  and looks like a broken grep. Hit three times — and then a fourth, where the
  pipeline was `box.sh … | sed 's/^/    /'` around the whole kernel build. The
  step's `exit 1` became sed's `0`, the job went green, and QEMU was handed a
  kernel that had never been written. **Read `${PIPESTATUS[0]}` on the pipeline
  that matters** — not a blanket `pipefail`, for the reasons two notes below.

  Then `hermetic-gcc15` found **three more in one file**, and they are worth
  recording separately because of what each taught:
  - one printed an **empty string** where it should have said MISSING, on the
    very run where the library really was missing;
  - one had never shown, because it happened to be pointed at something that
    works — *an unsound check aimed at a healthy target is still unsound*, and
    it will be believed the day the target stops being healthy;
  - and one was the gate on a **compiler test suite**. It reported
    `pass=9 fail=1`, declared the box sound, marked the sysroot complete and
    **saved it to the cache**. A check that cannot fail does not merely fail to
    catch things — it can hand the broken tree to every run that follows.
  **Grep the tree for the pattern whenever one turns up.** All three of these
  were in a file that had already had the trap written down.
- **Installing over a symlink writes through it to the target.**
  `busybox --install -s` leaves `/usr/bin/bc` pointing at busybox; a real bc
  installing itself to that path lands on the shell, `ls`, `sed`, `grep` and
  `tar` the whole box is made of. Unlink before installing. The same table has
  a second edge: `busybox` is itself in `busybox --list`, so linking every name
  in that list replaces the binary with a symlink to itself.
- **An unprivileged builder cannot create a device node**, so `mknod` fails
  under bwrap and no image built there can contain `/dev/console`. Without it
  `init` starts with no stdio and everything it prints goes nowhere:
  **a kernel that booted perfectly is indistinguishable from one that never
  reached userspace.** `CONFIG_DEVTMPFS_MOUNT` is what closes that, and it is
  on the book's required list next to `WERROR`.
- **`set -e` does not fire on the left of `&&`.** `make && make install` with no
  `|| exit 1` swallows a failed `make` completely — verified: `set -e; false &&
  true; echo hi` prints `hi`. That is how a failing `bc` would have surfaced an
  hour later as an unrelated kernel error.
- **A `while` returns its body's last status, so `set -e` can kill a loop that
  merely found nothing.** `set -e; printf a | while read x; do false && echo hi;
  done; echo REACHED` never prints REACHED. In an evidence dump this truncates
  the report at the first empty result, which reads as "the search found
  nothing".
- **`grep -c` prints the count AND exits 1 on zero matches.** `$(grep -c … ||
  echo 0)` yields `"0\n0"` and the next comparison is a syntax error.
- **A blanket `set -o pipefail` is not the fix for a swallowed pipeline, and it
  breaks other things.** `yes '' | make oldconfig > /dev/null 2>&1` fails under
  pipefail — make closes the pipe, `yes` takes SIGPIPE and exits 141 — and with
  every stream redirected the step dies having printed nothing at all. It also
  turns every `grep … | head | sed` diagnostic into a step abort whenever the
  grep matches nothing. Read `${PIPESTATUS[0]}` on the one pipeline that
  matters instead. Verified: `set -euo pipefail; yes | head -1 >/dev/null`
  exits 141; the same line under `set -eu` exits 0.
- **`scripts/config` is `#!/bin/bash` and no box has bash.** Every call to it
  has always failed silently, with the `sed` after the `|| true` doing the real
  work — which means `--set-str` never ran once, anywhere. To set a kconfig
  symbol, delete both forms of its line and append the one you want: kconfig
  takes the last assignment it reads.
- **Disabling a symbol something else `select`s can never work.** olddefconfig
  re-derives it every time. Either remove the consumer, or supply what the
  symbol needs and stop fighting.
- **A curated list of applets is verified in the wrong direction.** Checking
  each name against busybox does not check that the *scripts* only use names on
  the list. Install everything and assert from what the scripts invoke to what
  exists. And never `ln -sf busybox busybox`.
- **`--include` is a GNU grep extension.** The box runs BusyBox, whose grep does
  not implement it — so a Kconfig search that had "never found a selector" had
  in fact never run. Every grep in the same block that used `--include` came
  back blank; the one that did not, worked. That was the tell. **This was written
  down and then hit again**, in `hermetic-gcc16`, in the same search, against
  the same symbol. Writing a trap down does not remove it from the files that
  already contain it — grep the tree for the pattern, not just the lesson.
- **A moved block inherits the cwd assumptions of where it lands.** m4 ended
  with `cd m4-1.4.18`; harmless as the last thing in a step, fatal at the head
  of the next one. Wrap in a subshell.
- **Check where an insertion landed, not just that it applied.** An awk-writer
  intended for a step went inside the `box15.sh` heredoc and ran on every box
  invocation.
- **A string replacement that silently matches nothing ships an unchanged
  file.** Assert the anchor exists. One zip went out with none of its changes in
  it because the indentation was off by two spaces.
- **Verify the artifact, not the working tree.** Same reason.
- **`actions/cache` saves on failure.** A build tree is only meaningful
  complete; mark it, and discard an unmarked one.

### Sandboxes

- **Mask the resolved binary, not the name.** Almost every compiler driver on an
  Ubuntu image is a symlink, and `c++` leaves `/usr/bin` on its way to a target
  — `c++ → /etc/alternatives/c++ → g++ → g++-13 → <triplet>-g++-13`. Binding
  over the names gets `bwrap: Can't create file at /usr/bin/c++`. Fourteen names
  resolved to three real files.
- **Scan for what to mask; do not list it.** The arm64 runner carries gcc 12, 13
  and 14 *and* clang 16, 17 and 18. A hand-written list is a list that silently
  stops being complete the day the runner image moves.
- **Mask the compiler proper, not just the drivers.** `cc1` and `cc1plus` live
  in `/usr/libexec/gcc`, not `/usr/lib/gcc`; the latter holds `crt*.o` and
  `libstdc++.a`. Both are worth masking and only one of them is load-bearing.
  The runtime `libgcc_s.so.1` is in neither — it is in `/usr/lib/<triplet>/` —
  so masking those directories does not stop dynamically linked binaries running.
- **Prove the box before spending an hour in it**, and make the proof the thing
  the box is *for*: compile a C file with every driver and fail if any succeeds.
  A sandbox that still contains a compiler makes every claim above it vacuous.
- **A read-only bind is a mount property, not a permission.** `test -w` answers
  the wrong question; try the write.

### Diagnostics

- **Prefer the compiler's message over make's.** make prints several
  `*** [target] Error 1` lines per real failure, so a `head` limit fills with
  summary lines and the actual `error:` never appears.
- **Do not discard stderr on a step that can fail.** `2>/dev/null` on a `diff`
  made three runs unable to say why a patch came out empty.
- **Classify on the whole output, not `head -1`.** The first line of a gcc
  failure is `In function 'foo':`; six ICEs read as six unknowns.
- **A check that cannot fail is not a check**, and a summary must distinguish
  *never ran* from *ran and failed*. A step called `STAGE 3 GATE` printed
  `expect exit 55` next to the real value and exited 0 regardless, so a compiler
  answering 99 would have gone green. Printing an expectation is not asserting
  it.
- **A control has to fail for the right reason.** The C++14 gate ran its control
  at `-std=c++14`, and g++ 4.7 answered `unrecognized command line option` —
  which shows it does not know the flag, not that it cannot compile the code.
  Run at the newest standard it *does* accept, it rejects the language. The gate
  now fails if it ever sees the flag error instead, because that outcome
  supports nothing.
- **Glob where the files are.** A report globbed `out/lib/.../libgcc.a` and
  tested `work/$lg`, so the pattern expanded against a directory that had no
  `out/`, stayed literal, and every iteration hit `continue`. It printed
  nothing at all, which is worse than the ambiguous number it replaced —
  silence cannot be told apart from a step that never ran. A fetch failure once printed three
  confident "no"s about experiments that never started.
- **A `head`/`tail` window is not a log.** The one run where a command was
  missing from the boot image, the guest printed `cp: not found` and the line
  fell between a `head -30` and a `tail -40` while a `grep 'VERON-'` dropped
  it — so the run reported a tmpfs fault and a downed loopback, two wrong
  conclusions from evidence the reporting had thrown away. If the interesting
  region is bounded, print all of it.
- **Reaching a marker is not a result.** A boot step that greps for a string
  `init` prints before doing anything cannot tell a working system from a
  kernel that merely got as far as `exec`. Have the guest report per-check and
  require every one, and distinguish *ran and failed* from *never finished*.
- **Test what the thing does, not whether a file exists.** `command -v bc` in a
  busybox userland finds the applet symlink and proves nothing about the bc
  that was just installed; running the kernel's own `timeconst.bc` proves it.
  Likewise for openssl: compile and link exactly what `certs/extract-cert.c`
  compiles.
- **Name the failing input.** `get()` echoed a basename *before* fetching, so
  the reader had to infer which URL was in flight when curl died.

### Upstream and books

- **Take versions from a book, never from memory.** Four runs, four composed
  sets — and the fourth was a *kernel*, easy to miss because the version sat in
  a second variable that looked like it belonged to a different box. When two
  workflows are siblings, a variable copied between them arrives with its old
  comment attached and reads as deliberate.
- **And take the *steps* from the book too.** The gcc16 glibc failure was not a
  bad version pairing — the pins were exactly the dev book's. Two required
  patches were simply never applied.
- **Read what the book does not say — then check what it has already built.**
  `certs`, `MODULE_SIG` and `TRUSTED_KEYRING` appear zero times in all of LFS
  13.0, and the conclusion drawn from that was that LFS never touches the certs
  machinery. **The count was right and the inference was wrong.** It builds
  OpenSSL at 8.49 and so has nothing left to say by chapter 10. A book is
  silent about what it has already solved, and a box that substitutes packages
  away inherits the problem without inheriting the sentence describing it. Both
  gcc15 and gcc16 spent runs on this, from opposite directions.
- **A patch directory can be a moving target, and pinning its digest is not
  automatically right.** `/patches/lfs/development/` tracks whatever the
  development book currently is — a revision series whose patches are revised
  in place. Pin a digest from one revision and a legitimate upstream update
  becomes a red build; pin nothing and a substitution goes through unseen.
  Record what arrived, compare it to the vendored book, say plainly when they
  differ — and let the real gate be whether `patch` applies, which a corrupt or
  substituted file will not.
- **A libc and a kernel are a *pair*, and the books pair them explicitly.**
  glibc 2.43 against linux 7.1.5 headers dies on `OPEN_TREE_CLONE redefined`;
  the development book pairs that glibc with 7.1.3 and a patch whose text is
  *"Now fix glibc to build against Linux 7"*. Where no book has run the pairing
  you want, take the **headers** from one that has and run the newer kernel on
  top: a kernel may always be newer than the headers its libc was built
  against.
- **The book only covers one architecture, so some of its steps have to be
  translated.** `sed -e '/m64=/s/lib64/lib/' gcc/config/i386/t-linux64` has an
  aarch64 counterpart in `t-aarch64-linux` that no book mentions. Skipping it
  put glibc in `/usr/lib` and libstdc++ in `/usr/lib64`.
- **The box compiler is dialects ahead of what it is asked to build.** gcc 15
  changed the default to `-std=gnu23`, where `true` and `false` are keywords
  rather than macros. bc 7.0.3 pastes them through `UINTMAX_C()` and dies on
  `falseUL`. The book already knows: it is the only package for which it
  overrides `CC` with a standard.
- **The box is a chapter-6 system being asked to do chapter-10 work.** The
  kernel chapter assumes packages LFS built in chapter 8. openssl was the one
  that bit; expect others as more of the book is attempted.
- **Layout details are not portable between books.** LFS 10.0 has no `/usr`
  merge and keeps headers in `/usr/include` while 7.5 keeps everything under
  `/tools`. Carrying `--with-native-system-header-dir` across recreated the
  identical failure with the directories swapped.
- **A flag silently ignored looks exactly like a flag that did not work.**
  BusyBox reads `CONFIG_EXTRA_CFLAGS`, not `EXTRA_CFLAGS`.
- **Do not name a variable something a build system already owns.** `M4`,
  `BISON`, `FLEX`, `GMP` are autoconf's names for the *programs*.
- **`tail` on a `-j` log is not the error.** The last lines are whatever
  finished last.
- **Configure first, then modify, then verify.** `oldconfig` re-derives symbols
  and silently undid the same edit three runs running.

### And one about hypotheses

- **A well-reasoned mechanism is still a guess until something prints a frame.**
  The ICE suspect was named confidently at the start, repeated for weeks, and
  was the wrong builtin on the wrong path. The backtrace took four runs to
  obtain because three separate harness faults stood between the workflow and
  its own payload — and each of those was found only by testing the harness
  rather than reasoning about it.

---

## Where things live

```
spikes/stage4/                  this folder -- everything above tcc
spikes/stage4/ROADMAP.md        legs 2 and 3: gcc, and real Linux
spikes/stage4/GCC-BACKPORT.md   the gcc 4.7 + 4.8-aarch64 result, in full
spikes/stage4/TCC-USERLAND.md   the tcc userland result, in full
spikes/stage4/probes/           the transplant, the CC shim, the C probes, PID 1
spikes/stage4/books/            the vendored LFS books the ladder is drawn from
spikes/stage3/                  M2-Planet, and reaching tcc -- BELOW this stage
sources/{gcc,musl,busybox,lfs}.toml   url + hash + license + declared substitutions
tools/port_gcc47_api.py         the transplant's rule table -- four kinds now
tools/fetch-pinned.sh           pinned fetch, shared with stage 3
.github/workflows/hermetic-*    one box per rung; each triggers on itself only
```
