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
| `hermetic-gcc15` | a gcc 15.2.0 system that boots | kernel config rewritten, awaiting a run |
| `hermetic-gcc16` | a gcc 16.1.0 system that boots | **ANSWERED** — boots linux v7.2-rc4, 142 checks green |
| `hermetic-enumerate-host` | what does the host still supply? | not a rung; enumeration only |

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
the book was read properly. It is a triplet the host does not have
(`aarch64-veron-linux-gnu`), `--with-sysroot`, and a libc cross-compiled into
the sysroot so the tools find their loader inside it.

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
| `hermetic-gcc15` | LFS 13.0 | gcc 15.2.0 + userland | — | **yes**, linux 7.1.5 |
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

### hermetic-gcc15 (gcc 15.2.0, glibc 2.43) — kernel config rewritten

The sysroot is complete and self-sufficient: shell, coreutils, sed/grep/awk,
make 4.4.1, as and ld 2.46.0, gcc 15.2.0, and **compile-and-run inside the box
returns 42**. It builds m4, bison, flex and perl natively, then linux 7.1.5 and
a 626,575-byte initramfs.

**The kernel config was rewritten to what the book actually says**, after
several runs spent fighting `CONFIG_SYSTEM_TRUSTED_KEYRING`:

> *"A good starting place for setting up the kernel configuration is to run
> `make defconfig`."* … *"Be sure to enable/disable/set the following features
> or the system might not work correctly or boot at all:
> `[ ] Compile the kernel with warnings as errors [WERROR]`"*

That is the **first** item on the book's list and this workflow never did it.
`CONFIG_WERROR` defaults to `y`, so any warning from a toolchain the kernel was
not tested against becomes a hard error.

And what the book never says, searched across all eleven chapters:

```
extract-cert       0 occurrences
TRUSTED_KEYRING    0
MODULE_SIG         0
certs              0
```

LFS builds this kernel from `defconfig` and never touches the certs machinery.
The openssl justification was inherited from a comment, not from the book, and
several runs went into satisfying it — a seven-symbol disable list, a four-round
hunt for whichever symbol selected `SYSTEM_TRUSTED_KEYRING`, an evidence dump
when the hunt found nothing. **All of it is deleted.** The step is now
`defconfig`, `WERROR` off, verify, build. If `extract-cert` genuinely needs
openssl here, the build will say so, and that is worth one run.

**QEMU has never loaded an image from this box.** Every attempt failed on
`failed to find romfile "efi-virtio.rom"` — the runner's QEMU packaging, not the
image. And on one run the kernel step failed while the initramfs and boot steps
ran anyway, because **any `if:` drops GitHub's implicit `success()`** — so QEMU
was handed a nonexistent kernel and the log read "DID NOT REACH USERSPACE",
which sounds like a kernel that boots badly rather than one never built. Both
fixed.

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
3. **Compile inside QEMU.** The strongest claim available and it needs no disk
   image: the boot log shows `9pnet: Installing 9P2000 support`, so arm64
   `defconfig` already has virtio-9p. Pass the whole sysroot through with
   `-virtfs`, mount it in the guest, and have the system build a program with
   its own gcc under its own kernel. Today the guest runs binaries the box
   compiled; this would have the guest do the compiling.
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
   `scripts/config` cannot run in any of them; `hermetic-gcc15` still has the
   `| sed` swallowing pattern on its box invocations and does not check the
   real status. `hermetic-gcc10` no longer does — it sets `pipefail` — and it
   cost a full run to find out that it mattered. None of that is urgent, and none of it should be
   changed without a run to confirm, but it is written down here so the next
   person does not rediscover it.
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
  kernel that had never been written. **Set `pipefail` on any step that pipes a
  build into a formatter.**
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

- **Take versions from a book, never from memory.** Three runs, three composed
  sets.
- **And take the *steps* from the book too.** The gcc16 glibc failure was not a
  bad version pairing — the pins were exactly the dev book's. Two required
  patches were simply never applied.
- **Read what the book does not say.** `certs`, `MODULE_SIG` and
  `TRUSTED_KEYRING` appear zero times in all of LFS 13.0. Several runs went into
  a problem the book does not have.
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
