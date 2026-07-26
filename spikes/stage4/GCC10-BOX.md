# hermetic-gcc10 — a gcc 10.2.0 box builds gcc 15.2.0 and gcc 16.1.0

**PROVEN 2026-07-26**, run `81886082847`, `.github/workflows/hermetic-gcc10.yml`.

An LFS 10.0 sysroot whose newest compiler is **gcc 10.2.0** builds **gcc
15.2.0** and **gcc 16.1.0** inside a `bwrap` box with no network, no host
toolchain on `PATH`, and nothing bound in from the runner. Both new compilers
install, report their own version, and compile and run a program.

```
sysroot built              yes
box compiles+runs C        yes
box runs C++     <- decides yes
gcc 15.2.0 built           yes
gcc 16.1.0 built           yes
```

This is rung 2. `tcc-builds-gcc-arm64` owns everything below it — tcc → gcc
4.7.4 → gcc 4.7.4 → gcc 10.2.0. This box starts from a host-built cross
toolchain **on purpose**, so that a failure here is gcc 10's and not 4.7's. The
two halves have not yet been joined end to end.

## What the evidence is

Not the summary rows — those are derived. The load-bearing lines:

| claim | the line that carries it |
|---|---|
| the box is self-sufficient | 11 ladder rungs OK: shell, coreutils, sed/grep/awk, make 4.3, as/ld 2.35, gcc 10.2.0, ar, ranlib, m4 1.4.18, bison 3.7.1 |
| C works inside | `ran: exit=42 (expect 42)` |
| C++ works inside | `ran: exit=42 (expect 42)` — **compiled and executed**, not merely linked |
| gcc 15 built | `configure rc=0`, `make (all) rc=0`, `install rc=0`, `gcc (GCC) 15.2.0` |
| gcc 15 works | `smoke: exit=42 (expect 42)`, from a program compiled by the gcc it just built |
| gcc 16 built | same four lines, `gcc (GCC) 16.1.0` |
| gcc 16 works | `smoke: exit=42 (expect 42)` |

## What it does not show

- **Nothing was bootstrapped.** `MODE: all` is `--disable-bootstrap`. Nothing
  was compiled twice and nothing was compared. The fixpoint gate is still open,
  and it is now known to be **cheap** — see the timings below.
- **No kernel.** This box ends at a compiler. `hermetic-gcc15` and
  `hermetic-gcc16` own the boot.
- **No testsuite.** No DejaGnu, no `make check`.
- **The chain is not joined.** gcc 10 arrives here from a host-built cross
  toolchain, not from the tcc-built 4.7.

## Timings, measured

44 minutes wall clock, against `timeout-minutes: 360`.

| stage | minutes |
|---|---|
| gcc 10.2.0 pass 1 (cross) | 6.1 |
| glibc 2.32 | 2.6 |
| chapter 6 (BusyBox, make, binutils 2, gcc 2) | 8.0 |
| chapter 7 (libstdc++ 2, bison) | 1.2 |
| **ATTEMPT 1 — gcc 15.2.0** | **11.0** |
| **ATTEMPT 2 — gcc 16.1.0** | **12.0** |

An earlier estimate in review put chapters 5–7 at "roughly 2–2.5h" and
concluded that `bootstrap: yes` could never fit inside the cap. That was wrong
by about seven times. A 3-stage bootstrap is roughly 35 minutes per compiler,
so the whole job with both compilers bootstrapped is around two hours —
comfortably inside 360 minutes, and reachable with a `workflow_dispatch` input
that already exists. **No code change is needed to run the fixpoint gate.**

## The five failures it took, and the mechanism of each

Each was one run. The value is in the mechanisms, not the fixes.

### 1. Chapter 7 failed and the step went green — run `81866138350`

The in-box script is piped into `sed` for indentation, and **a pipeline exits
with its last command's status**. That status was `sed`'s: 0. bison failed
inside the box, the step succeeded, `.sysroot-complete` was written anyway, and
both gcc attempts then spent an hour dying on the tool that was never
installed. `set -o pipefail`.

This is the same rule the tree already had written down twice. It is not enough
to know a trap; the place it bites is the place with no assertion.

### 2. `cp -r` destroyed the timestamps upstream shipped — run `81866138350`

```
make: *** [Makefile:3515: Makefile.in] Error 1
make: *** [Makefile:3542: configure] Error 127
```

`cp -r` stamps every copied file with the time of the copy, in whatever order
the filesystem hands them over, so `configure.ac` can land newer than
`configure`. automake's maintainer rules then fire and try to re-run autoconf,
which this box does not have and is not meant to have. A tarball ships its
generated files newer than their sources; `tar` preserves that and `cp -a`
preserves `tar`'s. **`cp -r` was the whole bug**, in three places.

### 3. libstdc++ linked but could not run — run `81866138350`

```
/work/tpp: error while loading shared libraries: libstdc++.so.6:
cannot open shared object file
```

libstdc++-v3 installs into `toolexeclibdir` rather than `libdir` when configure
decides the build is a cross — and it does decide that, because `--host` is
`aarch64-veron-linux-gnu` while `config.guess` inside the box answers
`aarch64-unknown-linux-gnu`. gcc's driver searches that directory at **link**
time; the dynamic loader does not search it at **run** time.

The book never notices, and that is not an oversight in it: every remaining
LFS 10.0 chapter 7 package — gettext, bison, perl, Python, texinfo, util-linux
— is C. This box has to *run* C++, because gcc 15 and 16 compile and then
execute their own generator programs. `ldconfig` appears in chapter 8 and
nowhere in chapter 7. So the fix is a **declared deviation**: `/etc/ld.so.conf`
plus `ldconfig`, and symlinks into `/lib` as the mechanism that cannot fail,
since every binary in the box already resolves `libc.so.6` from there.

The predicted directory was `/usr/$LFS_TGT/lib`. The actual one was
**`/usr/lib64`** — gcc's aarch64 config sets `MULTILIB_OSDIRNAMES` to
`../lib64`, and LFS seds only the x86_64 equivalent because the book is x86
only. The code searched instead of hardcoding the prediction, so it adapted.
**That is the only reason this took one run instead of two.**

### 4. The gate was killed by its own success value — run `81869421157`

```
=== C++ gate ===
##[error]Process completed with exit code 42.
```

The payload runs under `set -e`, and the gate program returns **42 to mean it
passed**. `cmd; rc=$?` lets errexit fire on the "failing" command before the
assignment happens. A command whose status is being captured must sit in an OR
list, where POSIX suppresses errexit: `rc=0; cmd || rc=$?`.

An exit code used as a success sentinel is a trap the shell cannot distinguish
from failure. The convention is kept for consistency with the ladder; the idiom
around it is now correct.

### 5. Two doc rules, and one self-inflicted wound — runs `81876774003`, `81882416333`

```
GEN      doc/bison.info.bak
/bin/sh: -pi.bak: not found
```

`-pi.bak` is `perl -p -i.bak`. bison's configure does not route perl through
the `missing` wrapper — it leaves `$(PERL)` **empty**, so the first word of the
recipe vanishes and the shell tries to execute the flags. LFS installs perl at
7.10, one section *after* bison, so the book has no perl there either.
`PERL=true` swallows the arguments and returns 0, which is the right answer for
a doc target in a box that ships no documentation.

Then:

```
/work/bison/build-aux/missing: line 81: autoheader: not found
make[2]: *** [Makefile:3555: lib/config.in.h] Error 127
```

**This one was caused by the fix for failure 2.** Alongside `cp -a` a "belt and
braces" loop had been added, stamping every file matching a fixed list of names
— `aclocal.m4`, `configure`, `Makefile.in`, `config.h.in` — to the present.
bison ships its gnulib header template as **`lib/config.in.h`**, which matches
none of them. So `aclocal.m4` jumped to now while the template kept its 2020
date, and automake correctly concluded the template was stale.

A name list can never be complete, and **every name it misses becomes a file
that is now older than its own dependencies**. The loop was removed. The safety
net moved to the other end, where it does not need to know what anything is
called: `AUTOHEADER=true AUTOCONF=true AUTOMAKE=true ACLOCAL=true` on the make
lines. A command-line assignment overrides the
`AUTOHEADER = ${SHELL} .../missing autoheader` automake writes, so `missing` is
bypassed rather than asked to apologise for a tool that is deliberately absent.

## Two predictions that were wrong

Recorded because the reasoning was plausible and the outcome was not.

- **BusyBox `awk` was expected to break gcc's build.** gcc runs its own awk
  scripts — `opt-gather.awk`, `optc-gen.awk` — and BusyBox awk is not GNU awk.
  It handled them. No gawk is needed in this box.
- **The 6-hour cap was expected to be the binding constraint.** It is not
  close: 44 minutes.

## Reporting changes that made these findings cheap

- `die()` prints compiler diagnostics **with make's `*** [target] Error 1`
  lines filtered out**, then make's summary separately, then a 20-line tail.
  The previous one-liner grepped `Error [0-9]`, which matches make's own
  summary lines — make prints several per real failure, so a `head` limit
  filled with them and the actual `error:` never appeared.
- Every `--build=$(… config.guess)` goes through a `cg()` helper that dies
  naming the script when it is missing, fails, or prints nothing. Its
  diagnostics go to **stderr**, because it is always called inside `$( )` and
  an `echo` would be captured into the variable instead of reaching the log.
- The summary keys on `.ran` markers, not on whether a binary exists. Run 1
  printed `box compiles C++  yes` next to a loader error.
- The attempts stop after a failed `configure` and dump `config.log`, rather
  than running `make` on a tree configure rejected and burying the first
  failure under a second.
- The artifact collects m4's, BusyBox's, chapter 7's and bison's logs, every
  `i.log`, every `config.log`, `.sysroot-complete` and `/etc/ld.so.conf`. None
  of those were being uploaded.

## What is still open in this box

- `bootstrap: yes` has never been run. It is now known to be affordable.
- The cache key omits `M4_VER`, `BISON_VER`, `MAKE_VER`, `BUSYBOX` and the
  file's own hash, and no step is gated on `.sysroot-complete`, so the cache
  cannot skip any work — it only imports state. Left alone deliberately: the
  full build is 20 minutes and every run starting clean is worth more than the
  saving.
- LFS 10.0 chapter 7 is installed in part: libstdc++ pass 2 and bison only, not
  gettext, perl, Python, texinfo or util-linux. `--disable-nls` covers gettext
  for the attempts. Anything that later needs a real perl should get 7.10, not
  a wider flag.
- libstdc++ lives in `/usr/lib64` and is reached by symlink. The LFS-style fix
  is a sed on `gcc/config/aarch64/t-aarch64-linux` in both gcc passes, which
  moves every library in the box — worth doing on its own, not while chasing a
  green run.
