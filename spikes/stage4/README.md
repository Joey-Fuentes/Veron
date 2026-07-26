# stage 4 — hermetic sysroots, and the ladder above gcc 4.7

**Status: two sysroots build and run; the ladder above 4.7 is untested.**

Stage 3 answered *can tcc build a gcc that targets aarch64* — yes, measured
three ways, with no miscompilation across 349 translation units. It answered it
while borrowing the host's binutils, libc, make and shell, which
`stage3/GCC-BACKPORT.md` records under "What the host supplies".

This directory is about removing that borrowing, and about what comes after 4.7.

## Why LFS and not live-bootstrap

They solve different problems and we need both halves.

- **LFS** builds a temporary toolchain *to isolate from a host*. Chapters 5–6
  build tools that are deliberately thrown away; chapter 7 enters an environment
  containing nothing else.
- **live-bootstrap** never has a host to isolate from. It starts at a 357-byte
  seed and every byte above it was produced by something below.

Veron's lower half is live-bootstrap-shaped and its upper half is LFS-shaped.
The seam is tcc: below it, provenance; above it, isolation.

The isolation is **not static linking** — three runs were lost to that before
the book was read properly. It is a triplet the host does not have
(`aarch64-veron-linux-gnu` against `aarch64-unknown-linux-gnu`), `--with-sysroot`,
and a libc cross-compiled into the sysroot so the tools find their loader
inside it.

## The ladder

```
tcc  →  gcc 4.7.4 + 4.8.5's aarch64 backend      last gcc written in C
     →  g++ 4.7                                  built FROM that C
     →  gcc 10.2.0                               C++98 ceiling is "prior to 10.5"
     →  gcc 15.2.0 / 16.1.0                      needs C++14, which 10.2 has
```

Three builds above 4.7, each backed by a book (`sources/lfs.toml`). Above rung 1
tcc is not involved at all, which is why the upper rungs are testable without it.

`10.2.0` rather than live-bootstrap's `10.4.0` for one reason: 10.2.0 has a book.
Both are inside the C++98 range; a tested surrounding set beats being at the top
of it.

## The boxes

| workflow | toolchain | libc | purpose |
|---|---|---|---|
| `hermetic-1-sandbox` | host | host | bwrap with `/usr` bound — enumerates what is borrowed |
| `hermetic-2-sysroot` | gcc 15.2.0 | glibc 2.43 | the baseline; builds a kernel and boots it |
| `hermetic-3-period` | gcc 4.8.2 | glibc 2.19 | where a 2013 compiler needs no workarounds |
| `hermetic-5-bleeding` | gcc 16.1.0 | glibc 2.43 | newest inputs, linux v7.2-rc4 from git |

## Status, 2026-07-26

### hermetic-2-sysroot (gcc 15.2.0, glibc 2.43) — a kernel, built in the box

The sysroot is complete and the box is self-sufficient. Every ladder rung
passes: shell, coreutils, sed/grep/awk, make 4.4.1, as and ld 2.46.0,
gcc 15.2.0, and **compile-and-run inside the box returns 42**.

It then builds software rather than merely running it. Inside, natively:

```
m4 1.4.21, bison 3.8.2, flex 2.6.4, perl 5.42.0    built and installed
linux 7.1.5                                        Image built
initramfs                                          626,575 bytes
```

**The image did not boot, and not for a reason in the image.** QEMU refused to
start:

```
qemu-system-aarch64: failed to find romfile "efi-virtio.rom"
```

That is the host's QEMU packaging — `qemu-system-arm` on this runner does not
pull in the option ROMs — so nothing was learned about the kernel. A kernel that
builds and is never loaded is a different open question from one that builds and
panics, and the log distinguishes them.

### hermetic-3-period (gcc 4.8.2, glibc 2.19) — g++ 4.7 exists

```
gcc 4.7.4 + 4.8.5's aarch64 backend, built inside the box:
  configure   rc=0
  cc1         65,938,829 bytes
  cc1plus     71,662,708 bytes
  g++         g++ (GCC) 4.7.4
```

**This is the rung the whole choice of 4.7 rests on**, and nothing had built it
before — every earlier result configured `--enable-languages=c`. All of gcc 4.7
is C, including its C++ front end, so a C compiler yields a C++98 compiler; that
was the load-bearing assumption of the leg and it now has a binary behind it.

`make` then stopped at fixincludes:

```
The directory that should contain system headers does not exist:
  /usr/include
Makefile:4204: recipe for target 'stmp-fixinc' failed
```

The period box puts everything under `/tools`; `/usr/lib` and `/usr/bin` are
symlinked into it and `/usr/include` is not. So **libgcc was never reached and
the `ucontext` prediction is still untested.** The premise did hold — the box
confirms `typedef struct ucontext` present in glibc 2.19 — but the question
itself remains open.

### hermetic-5-bleeding (gcc 16.1.0) — glibc stops it

binutils 2.46.1 and gcc 16.1.0 pass 1 both build, 1,003 kernel headers install
from linux 7.1.3, and glibc's configure selects the cross compiler correctly.
glibc 2.43 then fails:

```
make[2]: *** [sysd-rules:111: misc/umount.o]  Error 1
make[2]: *** [sysd-rules:111: misc/umount2.o] Error 1
```

Worth noting precisely because **the same glibc 2.43 builds cleanly in
hermetic-2**. Three things differ: `--enable-kernel=5.10` against 5.4, linux
7.1.3 headers against 6.18.10, and gcc 16.1 against 15.2. Which of the three is
responsible is not yet known.

The mpc substitution worked — 1.3.1 in place of the dev book's unmirrored 1.4.1.

### Where that leaves the ladder

| rung | state |
|---|---|
| tcc → gcc 4.7.4 + backend | proven in stage 3, host tools |
| gcc 4.7.4 → **g++ 4.7** | **built, in a period box** |
| g++ 4.7 → gcc 10.2.0 | never run — blocked on libgcc |
| gcc 10.2.0 → 15.2/16.1 | never run |

**Open, in the order they block things**

1. `/usr/include` absent in the period box, so fixincludes fails and libgcc is
   never built. Everything above rung 1 waits on this.
2. The `ucontext` prediction, still untested for the same reason.
3. glibc 2.43 under gcc 16.1 with 7.1.3 headers — three variables, unbisected.
4. QEMU's missing option ROMs on the runner — nothing to do with the image.

## What is still borrowed

The host gcc builds the cross toolchain, exactly as LFS chapter 5 does.
Removing that is leg 1 — seed → tcc — not this directory.

Two smaller ones, both recorded rather than hidden:

- **Kernel UAPI headers** are copied in as content.
- **The transplant needs python3**, which no bootstrap chain has until very
  late. `expand_int_iterators.py` and `port_gcc47_api.py` currently run outside
  the box. Freezing them into patch files removes the dependency *and* satisfies
  the reviewed-delta criterion, since nobody can review what a generator did
  without re-running it.

## Method notes worth keeping

Every one of these cost at least one run.

- **Take versions from a book, never from memory.** gcc 13.2 + glibc 2.39,
  BusyBox 1.36.1 under gcc 15, m4 1.4.20 — three runs, three composed sets.
- **A check that cannot fail is not a check.** A `grep -q "^CONFIG_TLS=y"` that
  finds nothing reports "off" whether the symbol is disabled or misspelled.
- **A flag silently ignored looks exactly like a flag that did not work.**
  BusyBox reads `CONFIG_EXTRA_CFLAGS`, not `EXTRA_CFLAGS` or `CFLAGS_EXTRA`;
  three runs produced an identical error before the compile line was checked.
- **Do not name a variable something a build system already owns.** `M4`,
  `BISON`, `FLEX`, `GMP` are autoconf's names for the *programs*; setting them
  to version strings broke the first build in the workflow.
- **`tail` on a `-j` log is not the error.** The failure is wherever it happened;
  the last lines are whatever finished last.
- **Configure first, then modify, then verify.** `oldconfig` re-derives symbols
  and silently undid the same edit three runs running.
