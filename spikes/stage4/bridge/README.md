# The bridge: from one tcc to gcc 4.7.4, in a box with busybox and nothing else

**Status.** `stage3-to-stage4-reference` **closes**. Eight rungs, from a static
tcc to a working gcc 4.7.4 with a C++ compiler, in a sandbox whose entire host
inventory is one busybox. `stage3-to-stage4-bridge` runs the same rungs with
mc-tcc and has not been attempted yet.

**Two more architectures now run the same rungs, and one of them is finished.**
`stage4-arch-spike-amd64` clears every rung, both phases, boots the kernel it
built, runs the compiler *inside* that kernel, and publishes to its own release
tag. `stage4-arch-spike-riscv64` is green through rung 7 and stops at rung 8 on
a stage-2 compiler that segfaults. Both are copies of the reference rather than
a matrix over it. See *Three architectures, and where each one stands* below.

**All three still start from a host-built tcc**, and amd64 publishes anyway.
`stage3-cross-tcc-probe` shows a native x86_64 tcc and a native riscv64 tcc can
be produced from the aarch64 side with no host compiler in their history;
whether they walk a ladder is unanswered. Until they do, the released x86_64
sysroot has Ubuntu in its ancestry, which is a fact about the artifact rather
than a caveat that can be argued away.

```
0    compiler runs, libtcc1.a             ok
1    freestanding compile+link            ok
2    musl, no make                        ok
3    hosted program, real libc            ok
3.5  GNU make 3.82                        ok
4    binutils 2.30                        ok
4.5  make 4.4, rebuilt with real binutils ok
5    gmp / mpfr / mpc                     ok
6    gcc 4.7.4 by tcc  -- stage 4 stage 1 ok
7    gmp/mpfr/mpc rebuilt by that gcc     new
8    gcc 4.7.4 again   -- stage 4 stage 2 new

xgcc     2,730,239        SEALED. 1 host binaries,
cc1     70,483,958        0 of them on the build path.
cc1plus 76,575,236          busybox  1914704  52151e7f322f926b
```

---

## What this is for, and what it is not

`stage4-complete` already goes from a tcc to a booting Linux in 61 minutes. The
only thing wrong with it is where its tcc comes from: `./configure --cc=gcc`,
[stage4-complete.yml:191]. Stage 3 exists to replace that one binary.

But stage 4's box also `--ro-bind /usr /usr` [chain/box.sh:85] and borrows
`binutils`, `make`, `perl`, `bison`, `flex`, `texinfo` and a libc from the host
[chain/env0.sh:34]. Its own accounting is blunt about it:

> the guarantee stage 4 currently makes is "no host compiler", not "no host
> dependencies".

This job removes the rest. It is **not** on the critical path to closing stage
3 -- `WHAT-STAGE-4-NEEDS.md` says the bar is "be substitutable for `$TCC` at the
bottom of `rung1.sh`", and that could be answered by swapping mc-tcc into stage
4's existing box in one variable. This is the separate, larger project that
document calls "unowned": removing host glibc, host binutils and host make.

**The reference arm proves the recipe, not the seed.** `ref-tcc` is built by the
host's compiler. "The seed reaches gcc 4.7.4" is only ever the bridge arm's
claim, and the BUDGET step says so in every log rather than leaving it to be
inferred.

---

## Why a reference arm at all

`spikes/stage3/README.md` argues it for tcc-two-ways and it held here exactly as
written:

> The control runs FIRST on purpose: if the harness is wrong, that is where it
> shows, on a compiler nobody doubts.

The first six runs of this job found six bugs, all in the harness: a dropped
`-z`, a `tr` that ate its own input, `od -j` returning a confident empty
reading, YAML parsing `2.30` as the float `2.3`. Every one would have been
charged to micro-c if the bridge arm had gone first.

Both arms run **one script**, `rungs.sh`, parameterised by `CC_BIN`. A second
copy would drift and the comparison would stop meaning anything.

---

## The order, and why it is not LFS's

LFS builds binutils first. LFS also has a host `make` from day one and never
bootstraps one. This box has neither, and the dependency runs the other way:

* **binutils cannot be built without make** -- recursive Makefiles across bfd,
  opcodes, libiberty, gas, ld, with generated sources.
* **make can be built without make** -- upstream ships `build.sh`, and
  live-bootstrap's `steps/make-3.82/pass1.kaem` does better: 27 literal `tcc -c`
  commands, an empty `config.h`, and every setting configure would have
  discovered passed as a `-D`.
* **tcc supplies its own linker and archiver**, so make needs no `ld` and no
  `ar`.

So: musl, then make, then binutils. See `spikes/livebootstrap/ORDER.md` for the
verified live-bootstrap ordering and the places ours diverges.

**musl before make is our inversion**, and it is forced. live-bootstrap builds
make first because they have mes-libc installed by then; our M2libc lives
*inside* mc-tcc rather than on disk and could not carry make anyway. So rung 2
hand-drives musl in busybox sh -- the same shape as their kaem scripts, in a
different shell.

**make is built twice.** 3.82 comes up first because it is the only one that
can, and it drives musl's install, binutils and the arithmetic libraries
without complaint. Then it took a `Bus error` building libgcc. live-bootstrap
rebuilds make for the same reason, in almost these words: *"GNU make is now
rebuilt properly using the build system and GCC, which means that it does not
randomly segfault."* Rung 4.5 is that rebuild, and it is the first rung where
the thing being built uses tools this box produced rather than tools it
borrowed.

---

## The substitution ledger

Everything the box does that is not "unpack and configure". Each is printed in
the log as it happens.

### Inputs

| what | why |
|---|---|
| **tarballs repacked as ustar** | GNU release tarballs are **V7 format** with no `ustar` magic at offset 257. busybox's `get_header_tar` requires it and refuses them; host GNU tar reads V7 so nothing outside the box ever noticed. musl's is PAX and worked, which is why exactly one archive in the set opened and six runs went into the one that did not. |
| **binutils 2.30, not stage 4's 2.46** | tcc has a ceiling. live-bootstrap's first binutils is 2.30; their older layout used 2.14 because "2.14 seems to be the limit for tcc"; a 2024 guix-devel report puts 2.43 past it. **Stage 4 never builds binutils** -- it borrows it -- so its version was never a tcc question. |
| **gcc 4.7.4 + two derived patches** | 4.7.4 has **no aarch64 backend**; aarch64 arrived in 4.8. `backport-aarch64.sh` transplants 4.8.5's. It needs python3 and rewrites source, so it is tier 1 and runs in the **airlock**; the box receives `gcc47-aarch64-newfiles.tar.gz` (37 files) and `gcc47-aarch64-changed.patch` (4 files) and applies them with busybox `tar` and `patch`. Commit those two artifacts and the derivation step can be deleted. |

### Tools the box has to invent

| what | why |
|---|---|
| **`cc-static`** | libtool does not pass `$CC`'s flags to the link -- it parses the compile command and builds its own link line. `-static` in `CC` was stripped; `-static` in `LDFLAGS` was stripped. binutils' `as` came out dynamic, wanting `ld-linux-aarch64.so.1`, and this box has no loader, so it failed to exec with "Permission denied". A two-line wrapper that appends `-static` is not strippable, because the flag is no longer in the argument list. |
| **`tcc-ar`** | Two faults. tcc `-ar` accepts `rcs` and prints usage for libtool's `cru`/`cq`/`cr`. And it **creates rather than appends** -- libtool builds a large archive in batches, so `libbfd.a` came out 823 KB with five members, valid header, valid index, and missing nearly all of itself. The shim translates the flags and keeps a sidecar member list so repeated calls accumulate. |
| **`tcc-ranlib`** | A no-op. `tcc -ar` writes the index as it goes; live-bootstrap's own configure logs show `checking for ranlib... :` for the same reason. |
| **`sys/cdefs.h`** | musl deliberately omits it. Old GNU source uses `__P`, `__ptr_t`, `__const` **without including anything**, because on glibc those arrive through headers that include `cdefs.h` for you. Writing the file was not enough -- nothing included it -- so `cc-static` force-includes it. |
| **target tooldir** | gcc asks for `-B$PFX/$target/bin/` and `-isystem .../sys-include` by construction, whether or not the target is the same machine. binutils here is native and put nothing there deliberately. This is the half of LFS's `--with-sysroot` layout that "the box IS the target" does not excuse. |

### Source substitutions

| where | what | why |
|---|---|---|
| musl | `src/complex/*.c` dropped | no `_Complex` |
| musl | **`dropped_asm` is now empty** | nine aarch64 `.s` files were listed as unassemblable. Measured: **all nine assemble.** And there is no portable C for `__set_thread_area` -- `msr tpidr_el0, x0` cannot be written in C -- so dropping it left the thread pointer unset and every static binary died on its first touch of `errno`. |
| musl | eight empty stub archives | `libm.a` and friends. musl's math is in `libc.a`; its own `make install` creates empty archives so `-lm` resolves. Rung 2 hand-drives the *compile*, so it had to learn the *install* too. |
| make 3.82 | ~45 `HAVE_*` defines | live-bootstrap passes four. Their short list describes **mes-libc**, not make. musl is a complete POSIX libc and answers yes to nearly all of them. |
| make 4.4 | *(none)* | 4.2.1 was live-bootstrap's pin and cost five substitutions in its bundled glob before hitting `gl_opendir`, a `glob_t` member from GNU's `GLOB_ALTDIRFUNC` that musl has no equivalent for. **4.3 dropped the bundled glob**; 4.4 keeps it dropped and uses gnulib. |
| gcc | `--disable-nls` | musl's gettext makes gcc build its own `intl/`, which does not compile |
| gcc | `--disable-libmudflap` | redeclares glibc's `__assert_fail` (`unsigned int` vs musl's `int`). Removed entirely in gcc 4.9. |

### Source substitutions the other two architectures need

Nothing below is aarch64's. Each was measured on its own arm, and the run that
found it is named so the claim can be checked.

| where | arch | what | why |
|---|---|---|---|
| musl | amd64 | `src/math/x86_64/*` dropped | 18 of 1349 objects failed, all in this directory: 8 × `unknown constraint 'x'` (SSE), 5 × `'t'` (x87 stack top), 2 × `invalid clobber register 'st'`. These are optimisations -- musl ships generic C for every one. |
| musl | amd64 | `@PLT` stripped from `sigsetjmp.s` | `sigsetjmp.s:14: end of line expected` on `call setjmp@PLT`. **Not** the forward label `jz 1f`, which was the obvious suspect and which tcc handles. A static link needs no procedure linkage table. `src/signal/sigsetjmp.c` is a zero-byte placeholder, so the file cannot be dropped. |
| musl | riscv64 | `src/fenv/riscv64/*` dropped | `fenv.S:52: ',' expected` on `fscsr t1`, plus `csrc`/`csrs`/`frflags`. `src/fenv/fenv.c` defines the same seven symbols -- checked, not assumed -- and musl's own comment calls it *"Dummy functions for archs lacking fenv implementation"*. |
| musl | riscv64 | `add`→`addi`, `sll`→`slli` in `tlsdesc.s` | GNU `as` accepts the register form with an immediate and silently assembles `addi`; tcc says so instead. A spelling fix, not a behaviour change. |
| libc.a | amd64 | `__fixxfdi`, `__floatundidf` added from `libtcc1.a` | see rung 4.6 above |
| libc.a | riscv64 | 19 soft-float binary128 helpers added | same rung; the comment predicted an empty overlap and was wrong |
| gcc 4.7.4 | amd64 | `--disable-decimal-float` | 4.7 defaults decimal float **on** for x86_64 and builds `libgcc/config/libbid`, which uses `FE_INEXACT` and friends. musl has them -- `arch/x86_64/bits/fenv.h` defines `FE_INEXACT` as 32 -- so this is a corner of gcc the early sysroot does not satisfy rather than a missing header. Needed on **both** 4.7.4 configures, rung 6 and rung 8. |
| gcc 4.7.4 | both | `--disable-libitm` | `libitm/config/linux/x86/tls.h:28: missing binary operator before token "("` -- a function-like macro in an `#if` that is never defined, here `__GLIBC_PREREQ`. It was the only target library not already on the disable list. |
| gcc 15 | amd64 | `t-linux64` `MULTILIB_OSDIRNAMES`, `../lib64`→`../lib` | the aarch64 equivalent is `t-aarch64-linux`'s `mabi.lp64=` line. A first version sed'd every `t-*` under `config/i386` mentioning lib64 and caught `t-gnu64` (Hurd) and `t-mingw-w32` -- targets this chain never builds. |
| gcc 15 | amd64 | `linux64.h` `GLIBC_DYNAMIC_LINKER64`, `/lib64/`→`/lib/` | **a different thing from the line above.** That one says where libraries go; this is the path baked into every executable gcc links. This sysroot has no `/lib64` deliberately -- the book: *"The LFS editors have deliberately decided not to use a /usr/lib64 directory ... If for any reason this directory appears it may break your system."* glibc here installs its loader to `/usr/lib` (`libc_cv_slibdir=/usr/lib`), so the loader is where the sysroot wants it and only gcc disagrees. Adding a `/lib64` symlink would also work and is what LFS does; it would have to survive into stage 5. |
| gcc 4.6.4 fork | riscv64 | `struct ucontext`→`ucontext_t`, headers only | glibc renamed it; 2012 gcc still says the old name. Restricted to `*.h`: a bare `grep -rl` matched `gcc/ChangeLog-2005`, a 2005 entry *describing this very rename*, and rewriting prose put a hunk in the derived patch that would not apply. |
| gcc 4.6.4 fork | riscv64 | `LIB_SPEC` override removed from `config/riscv/linux.h` | its own comment is a FIXME: RISC-V has only word-sized atomics, so it links libatomic by default, and that reference breaks the build before libatomic exists. |
| gcc 4.6.4 fork | riscv64 | `HOST_WIDE_INT_1` / `_1U` defined in `hwint.h` | see above -- the fallback branch tcc takes uses two macros the fork never defines. |
| gcc 4.6.4 fork | riscv64 | shipped **unpatched** beside a derived patch | the workflow clones the fork, applies three edits, `diff -ruN`s them out, and tars the PRISTINE tree. A first version tarred the patched one and the box applied the patch twice: `Hunk 1 FAILED 50/50` on a file already correct. |
| gcc 4.7.4 | amd64 | `--disable-libitm` | `libitm/config/linux/x86/tls.h:28: missing binary operator before token "("` -- a function-like macro in an `#if` that is never defined, here `__GLIBC_PREREQ`. musl does not have it. It was the only target library not already disabled. |
| gcc 4.7.4 | amd64 | `--disable-decimal-float` on **both** 4.7.4 configures | rung 8 builds the same gcc and hits the same `libbid`. Adding the flag only at rung 6 cleared rungs 6 and 7 and then walked back into ten `FE_*` errors at rung 8. Any flag that exists because of what 4.7.4 assumes about its libc belongs on every 4.7.4 configure. |
| gmp | riscv64 | `CC_FOR_BUILD` = the box's tcc | gmp compiles its table generators with `CC_FOR_BUILD` and no `CFLAGS`; the manual: *"It doesn't need to be in any particular ABI or mode, it merely needs to generate executables that can run."* The gcc under test still compiles the library. |
| gcc | riscv64 | `CC_FOR_BUILD` on the **make** line, not configure | gcc's configure sets `CC_FOR_BUILD='$(CC)'` when build == host and discards what it was given. A make command-line assignment cannot be overridden that way; verified against a two-line Makefile before it was used. |
| prerequisites | riscv64 | rung 7 reuses tcc's archives instead of rebuilding | mpfr's configure passes every check that INSPECTS the fork-built gmp -- versions, linking, limb geometry -- and fails the one that RUNS a program: `GMP library vs header correctness... no (exit 82)`. Rung 5's tcc-built gmp passes the same test. Same source, same flags; the compiler is the only variable. |
| sysroot | amd64 | zlib 1.3.2, pkgconf 3.0.5, elfutils 0.195 at rung B5.5 | objtool needs `gelf.h`. It is force-selected on x86_64 by `MITIGATION_RETPOLINE`, `MITIGATION_RETHUNK`, `X86_KERNEL_IBT` and `UNWINDER_ORC`, so turning it off means shipping an unmitigated kernel. Only `lib` and `libelf` are built -- `libcpu` wants m4 and objtool never touches it. |
| pkgconf | amd64 | `ln -s pkgconf /usr/bin/pkg-config` | pkgconf installs `pkgconf`; autoconf's `PKG_PROG_PKG_CONFIG` looks for `pkg-config`, unguarded at elfutils' `configure.ac:906`. Every distro shipping pkgconf provides this symlink. |
| kernel | amd64 | `ARCH=x86_64`, target `bzImage`, path `arch/x86/boot` | three per-architecture facts and only the first is obvious: the image name is not the ARCH string, and the directory is neither. |
| gcc | `CFLAGS/LDFLAGS_FOR_TARGET=-static` | target configures call `xgcc` directly, not through `cc-static`. Dynamic links get `--eh-frame-hdr` and failed with *".eh_frame_hdr refers to overlapping FDEs"*. |
| binutils / gcc 15 pass 1 | `-Wl,--no-eh-frame-hdr` | **The same error, and rung 10 finally located it.** Every object in that link was compiled by *gcc 10*; the linker was the *tcc-built binutils 2.30*. So the malformed section is not something tcc puts in an object -- it is something tcc's `ld` emits when it **merges** them. Two earlier guesses in this file were wrong: not musl's crt files, and not tcc's own `.eh_frame`. Rung 6 hid it by going static, which suppresses the section; rung 10's link is static too and still trips it, because gas carries enough CFI. Nothing in a static binary reads `.eh_frame_hdr` -- it exists so a dynamic unwinder can find FDEs quickly, and there is no loader here. **The real fix is upward:** chapter 5 builds a new binutils, and once `$LFS_TGT-ld` exists this stops mattering. The flag only has to carry the links that produce it. |
| gcc | libstdc++ `os/gnu-linux` → `os/generic` | `_IScntrl` and friends are glibc's *internal* ctype enum. gcc 4.7 predates musl -- support landed in 4.9 -- so there is no `linux-musl*` arm to fall into and no triple that would find one. |

**Eleven of these are one thing:** old GNU source treating "not glibc" as "barely
a libc". `alloca`, `strncasecmp`, `getlogin`, `__P`, `__ptr_t`, `__assert_fail`,
`_IScntrl`. musl is a complete POSIX libc without the badge, and every one of
those is a two-line fix once you stop reading it as a compiler defect.

---

## Where the harness lied

Kept because each cost a round and the shape recurs.

* **`tr -dc '[:print:]'`** -- busybox `tr` has no POSIX character classes. It
  deleted its input and reported the tar header as empty. A reading of "nothing
  is there" from a tool that always returns nothing.
* **`od -j`** -- same shape, one line later.
* **`patch -d`** -- GNU has it, busybox does not. busybox answers an unknown
  flag by printing usage and exiting 1, which reads as the *operation* failing.
* **`grep -c`** -- prints `0` and exits 1, so `|| echo 0` printed it twice.
* **`-I/usr/include` before `"$@"`** -- the sysroot outranked the project's own
  `-I.`, so gnulib read musl's `glob.h` while expecting its own. This was
  shadowing **every** project header, which produces a wrong build rather than a
  failed one.
* **`rung 4 = ok` meant the files existed**, not that they ran. It reported ok,
  and rung 5 after it, while `as` could not be executed at all.
* **A probe that skipped silently** -- the `xgcc` link check runs before `make`,
  so on a first pass xgcc does not exist. An absent probe reads exactly like a
  passing one.

* **A `sed` that matched nothing** -- `CONFIG_STATIC=y` was applied to
  `# CONFIG_STATIC is not set`, `oldconfig` had already written something else,
  and the rung reported `static: NO` for a busybox that was supposed to be
  static. `sed` succeeds either way. So does `rm -f` on a path that does not
  exist, which is how `src/complex/*.c` was "dropped" while every file stayed.
* **A fix applied to one of two places** -- `CONFIG_TC` was disabled in the
  airlock busybox and not the initramfs one; `-isystem` went to one of rung
  11.7's two configure lines. Both look identical to a fix that worked, until
  the untouched half runs.
* **`onedir` globs the whole of `/work/src`** -- by rung 16 that holds a dozen
  unpacked packages, so `onedir "make-4.4"` returned `busybox-1.36.1` and the
  log said "extracting make" while naming busybox. Every rung that unpacks a
  second copy now uses a private directory.
* **A comment inside a line continuation** -- a `#` line after `\` is not a
  comment; bwrap received the prose as arguments and printed its usage, with no
  error message at all.

The rule the job now follows: **a flag working on the runner says nothing about
the box**, and every check reports what it measured rather than a verdict.

And the rule that would have prevented most of the above: **read the line
before changing it.** Nearly every entry here is a ten-second check -- `grep`
for the variable, look at what `onedir` does, print the PATH -- skipped in
favour of an assumption about what the code did.

---

## Three architectures, and where each one stands

`stage4-arch-spike-amd64` and `stage4-arch-spike-riscv64` are **copies of this
job**, not a refactor of it. The reference is the arm that works; a matrix over
it would put every architecture's failures in one file and make the aarch64 arm
answerable for the other two. Each spike is the same 27 steps, the same box, the
same seal, driving its own `rungs-<arch>.sh`.

```
                              aarch64      amd64        riscv64
0    compiler runs, libtcc1.a    ok          ok           ok
1    freestanding                ok          ok           ok
2    musl, no make               ok          ok           ok
3    hosted program              ok          ok           ok
4    binutils                    ok          ok           ok
4.5  make rebuilt                ok          ok           ok
4.6  libc.a gets tcc's helpers   n/a         ok           ok
4.7  m4                          n/a         ok           ok
4.8  flex                        n/a         n/a          ok
5    gmp / mpfr / mpc            ok          ok           ok
6    the bottom gcc, by tcc      ok          ok           ok
7    prerequisites again         ok          ok           ok (reused)
8    the bottom gcc again        ok          ok           FAIL
9    gcc 10.2.0                  ok          ok           --
10   binutils pass 1             ok          ok           --
11   gcc 15 pass 1               ok          ok           --
12-16 headers, glibc, ch6        ok          ok           --
B0-B8 the sysroot, entered       ok          ok           --
BOOT  and it runs                ok          ok           --
```

**amd64 is finished.** Every rung, both phases, and the boot:

```
VERON-BOOT-OK Linux 7.1.5 x86_64
VERON-TESTS pass=8 fail=0
VERON-GCC-IN-GUEST ok compiled and ran, rc=42 (expect 42)
trimmed: 5264 MB -> 586 MB      sysroot.tar.zst 136M
VERON-STAGE4-PUBLISHED-AMD64
```

That third line is the ladder closing on itself: the compiler this chain built,
running inside the kernel it built, compiling and running a program. It
publishes to **`stage4/latest-amd64`** -- its own tag, so a botched run cannot
reach the aarch64 release. Separate tags rather than suffixed filenames on a
shared one: the isolation is structural rather than conventional.

### The declared hole, closed on x86_64

`stage0-stage4-complete-amd64` is the amd64 ladder with **no host compiler in
its history**. Three jobs, and the split is forced by architecture rather than
chosen:

| job | runner | what it does |
|---|---|---|
| `oracle` | arm | upstream's reference compiler, for GATE 1 |
| `seed` | arm | hand-written assembler → stage1 → stage2 → micro-c → mc-tcc, **then the cross** |
| `stage4` | x86 | twenty rungs and a boot, natively, on what the seed job handed it |

The first two are the jobs from `stage0-stage4-complete`, unchanged. Only the
seed job gains anything, and only at its end.

**What it closes.** `stage4-arch-spike-amd64` builds its tcc with the runner's
`musl-gcc` and says so — *"DOES NOT PROVE: anything about the seed. This tcc
was built by the host's compiler."* `stage4-complete.yml` calls it **"the one
declared hole"**, and `stage3-cross-tcc-probe` records that the arch spikes
*"inherited it: their tcc comes from the runner's gcc, so the x86_64 and
riscv64 ladders each begin with a compiler whose ancestry runs through
Ubuntu."*

**One binary crosses, and nothing else.** Cross-building the rungs *"would
make every rung above a cross build and trade one problem for a worse one"* —
the probe's words. So three steps sit between mc-tcc and the x86 runner:

```
mc-tcc          aarch64, from the seed
  -> x86_64-tcc      an AARCH64 binary that EMITS x86_64
  -> x86_64 musl + x86_64-libtcc1.a, built by that
  -> tcc-x86_64      an X86_64 binary, static, that emits x86_64
```

Every rung above it is native. The handoff carries a `PROVENANCE` file naming
each digest and the chain that produced it, and the `stage4` job checks the
binary is x86_64 **and** static before a single rung runs — a cross build that
silently emitted the wrong target would otherwise surface twenty rungs later,
on a different machine, an hour away.

**Why not emulate stages 0–3 on the x86 runner instead.** It would keep one
job and one unbroken chain, at the cost of running under TCG a chain that
already runs natively next door, and of mixing two architectures inside one
job. The artifact boundary here is the one stage 5 already accepts for the
sysroot.

**Run 85526581967 got as far as the cross and stopped on a bug in this file.**
Everything upstream worked: GATE 1 passed byte for byte —

```
ref-gen1.M1  (host gcc)      2947903  dc38e13e4ceaeecb
ours-gen1.M1 (our ladder)    2947903  dc38e13e4ceaeecb
```

— mc-tcc built its own libtcc1 (5 of 5 objects) and was handed forward at
1,651,925 bytes. Then:

```
AIRLOCK: musl source for the cross libc
  MUSL_MIRRORS: unbound variable
```

The step used `$MUSL_MIRRORS` as though it were a workflow env var. It is a
**shell local inside the stage4 job's fetch step**, three hundred lines away
and in another job. The mirror list is now written out where it is used, and
the tarball's digest is printed and checked. `set -eu` is what turned an
unbound name into a stop rather than an empty loop and a stranger failure two
steps later.

**Run 85528747783 reached `CROSS 1` and failed on a second bug in this file** —
not on the experiment:

```
VERON-XTCC-CROSS-FAIL  mc-tcc could not compile tcc for x86_64
  tcc: error: file 'crt1.o' not found
  tcc.h:28: error: include file 'stdarg.h' not found
```

That is not a code-generation failure, and the step's own marker read it as
one. **`x86_64-tcc` is an aarch64 binary that emits x86_64** — it runs on the
arm runner, links against that machine's libc and needs its headers and crt
files. `-DTCC_TARGET_X86_64` selects the code generator compiled in; it says
nothing about the platform the program runs on.

The probe did not make this mistake because it used `make x86_64-tcc`, and
tcc's Makefile knows a cross compiler is still a host program. The hand-rolled
invocation dropped all of that to keep the line short. `CROSS 1` now runs
`./configure --cc=mc-tcc` and `make x86_64-tcc CC=mc-tcc` — the probe's step
with one thing changed, which is what makes a failure attributable.

Two things the same reading turned up:

- **`config.h` is regenerated.** The tree comes from
  `tcc-5ec0e6f8-arm64-configured`, whose `config.h` has aarch64 paths baked
  in — right for mc-tcc, wrong for a cross build. `./configure` is a shell
  script, so re-running it costs nothing.
- **`CROSS 2` must *not* pass `CC`.** libtcc1 is the compiler's runtime and
  must be target code; the Makefile's `x86_64-libtcc1.a` rule already uses the
  cross compiler, and overriding `CC` would have built an aarch64 runtime that
  links cleanly and fails at run time.

**Run 85530802574 found the real gap, and it was not the cross.** `CROSS 1`
stopped compiling `conftest.c` — the Makefile's first, trivial host program:

```
tcc: error: file 'crt1.o' not found
/usr/include/stdio.h:28: error: include file 'bits/libc-header-start.h' not found
```

**mc-tcc cannot link a hosted program at all.** The runner's libc is glibc,
whose headers tcc does not parse, and the box has only ever asked mc-tcc for
`-c`. The seed job's own step B has been saying so all along:

```
step A: gen1 COMPILES tcc.c -- 873506 byte object
step B: gen2 will not link, rc=1
  undefined: 32 total -- 0 from tcc's own lib/, 32 from a libc
```

Compilation was never the gap. A libc was.

**And `stage3-cross-tcc-probe` never showed otherwise.** It installs `gcc` from
apt and runs `make x86_64-tcc` with no `CC=`, so the cross compiler it built
came from the *host's* gcc. Its header describes the mc-tcc substitution as the
question it is aimed at — *"can a compiler with no host gcc in its history emit
a working tcc for another architecture"* — not as something it performed.
Reading its success as evidence for that step cost two runs.

#### The libc rung, reused rather than rewritten

`rungs.sh` rung 2 already builds musl with a tcc, hand-driven, no make: the
include order, `-nostdinc -D_XOPEN_SOURCE=700`, the nine aarch64 `.s` files
that fall back to portable C, `-DCRT` for the crt objects, and a comment
warning not to delete arch assembly before it has actually refused. Every one
of those was earned by a failed run.

So the seed job now assembles a **second box** — same empty tier-1 budget,
separately sealed, because widening the first box after its SEAL would quietly
change what that SEAL certified — and runs `rungs.sh` in it with
`CC_BIN=/work/mc-tcc` and `STOP_AFTER=2`. That is tool-probe's invocation with
two things changed, and the file itself argues for the approach: tool-probe
*"runs THIS FILE with STOP_AFTER=5 rather than growing a second musl build that
would drift from this one."*

Out comes an aarch64 `libc.a` and crt files built by mc-tcc, and `CROSS 1` then
builds `x86_64-tcc` with `-nostdinc -nostdlib` against them — no host headers
anywhere in it. `CROSS 2` builds libtcc1 from the file list directly rather
than through the Makefile, for the same reason: the Makefile's first act is the
host `conftest.c` that has now failed twice.

**Rungs 0–2 with mc-tcc is itself the experiment.** They are called *"the most
proven part of this script"*, but always with a tcc the host's gcc built. If
rung 2 fails, it fails in a rung with its own name and its own error rather
than as a header error inside a Makefile — and the 32 undefined symbols say
which direction to look.

#### Run 85534907100: two firsts, and a fourth finding

```
libc.a  3162530 bytes   crt1.o 1641   crti.o 799   crtn.o 799   headers: 219
VERON-MCTCC-LIBC-OK  an aarch64 musl, built by mc-tcc

ELF 64-bit LSB executable, ARM aarch64, statically linked
VERON-XTCC-CROSS-OK  an aarch64 binary that emits x86_64
```

**Rungs 0–2 pass with mc-tcc as `CC_BIN`** — the substitution that had never
been made, on the rungs called *"the most proven part of this script"* but
always with a host-built tcc. And with a libc it can link against, **mc-tcc
built `x86_64-tcc`**: a cross compiler with no host gcc anywhere in its
history. Both are firsts.

`CROSS 2` then stopped:

```
lib/libtcc1.c:624: error: can't cross compile long double constants
```

**The size crossed with the compiler.** `x86_64-tcc` was built by mc-tcc, so
it inherited mc-tcc's `LDOUBLE_SIZE` of 8 — micro-c maps float, double and
long double to one word-sized type, and tcc-microc patch 0001 sets the size to
say so. x86_64's ABI says 16. tcc's guard fires when the target's long double
differs from the compiler's own, and here they genuinely do.

The switch already exists and this repository already explains it:
`stage0-stage4-complete` passes `-D TCC_USING_DOUBLE_FOR_LDOUBLE=1` against
the same error string and calls it *"honest rather than a workaround -- it
makes the build say what is true"*.

**Probed, not hardcoded**, which is rung 2's rule for this exact question. It
refuses to rewrite musl's `float.h` unconditionally because the same file also
runs under a host-built tcc whose long double really is binary128 — *"Rewriting
the header unconditionally fixes the second and BREAKS THE FIRST."* A
compile-only probe answers it and needs nothing linkable, so `CROSS 2` and
`CROSS 3` each ask their own compiler before deciding.

**One thing to expect.** `stage0-stage4-complete` records that this flag is
*not sufficient on its own* — more long-double constants follow at
`tccgen.c:2580`. If the next failure is the same string at a different line,
that is the real capability gap rather than a missing flag, and the step says
so in its own error path.

#### The probe asked the wrong question, and its answer showed that

Run 85537036642 probed for an eight-byte long double before setting
`TCC_USING_DOUBLE_FOR_LDOUBLE`, and reported:

```
long double is not 8 bytes -- no override needed
lib/libtcc1.c:624: error: can't cross compile long double constants
```

**`sizeof(long double)` compiled *by* `x86_64-tcc` is the target's — sixteen,
from `x86_64-gen.c`.** The size that matters is the one `x86_64-tcc` was itself
built with, which is mc-tcc's eight, and no probe compiled by that compiler can
observe it. The probe was right to decline the flag; the flag was never the fix.

`TCC_USING_DOUBLE_FOR_LDOUBLE` would not have helped either way. Patch 0001's
preamble already says so — *"It is defined for PE, macOS/arm64 and Win32 in
tcc.h and selects double-based branches in the float parser, but arm64-gen.c
sets LDOUBLE_SIZE unconditionally, so the guard above still fires."* The same is
true of `x86_64-gen.c`. Upstream tried exactly this for macOS/x86_64 in 2021 and
withdrew it as a mistake.

#### `0005`: the missing branch, not a changed ABI

`init_putv`'s guard has two branches and both are equality tests:

```c
if (sizeof(long double) == LDOUBLE_SIZE)   /* 8 == 16, no */
else if (sizeof(double) == LDOUBLE_SIZE)   /* 8 == 16, no */
else if (0 == memcmp(ptr, &vtop->c.ld, LDOUBLE_SIZE))  /* reads 16 from 8 */
else tcc_error("can't cross compile long double constants");
```

A host whose long double is **smaller** than the target slot has a correct
answer available and no branch that reaches it. `0005` adds one: store the
bytes the host actually has.

**`LDOUBLE_SIZE` is deliberately left at 16, and that is the difference from
patch 0001.** 0001 shrinks a type in a compiler that only ever builds the next
compiler, and states the cost plainly. Doing the same in `x86_64-gen.c` would
shrink it in the compiler that **builds musl** — and that musl is kept, as the
libc the whole x86_64 ladder links against. Its headers would claim
`LDBL_MANT_DIG 113` while every long double occupied eight bytes, which is the
exact mismatch `rungs.sh` rung 2 spends thirty lines diagnosing on the other
architecture. **A wrong ABI in a throwaway compiler is a declared limitation; a
wrong ABI in a retained libc is a defect.**

What is lost is precision in compile-time long-double *constants* — they carry
double precision rather than eighty bits. Nothing else narrows, and the upper
bytes are zero rather than garbage because `section_realloc` zeroes what it
adds (`tccelf.c:284`).

**Checked before shipping:** the patch applies to the pinned tree both by
`git apply` and by `patch -p1`, and stacks on 0001–0004. The branch logic was
run against six host/target size combinations — every case that worked before
takes the same branch, and only mc-tcc→x86_64 takes the new one.

#### Run 85544287752: the cross works

```
VERON-MCTCC-LIBC-OK   an aarch64 musl, built by mc-tcc
VERON-XTCC-CROSS-OK   an aarch64 binary that emits x86_64
VERON-XTCC-LIBC-OK    an x86_64 musl, built by the cross compiler
VERON-XTCC-GEN2-OK    x86_64, static, no host gcc in its history

tcc-x86_64  58aa13592867fc38...
mc-tcc      4213e5abb65f710b...
built-by    mc-tcc -> x86_64-tcc -> tcc-x86_64
```

**An x86_64 tcc exists whose ancestry contains no host compiler**: hand-written
assembler → stage1 → stage2 → micro-c → mc-tcc → x86_64-tcc → tcc-x86_64. Patch
0005 was what unblocked it — `x86_64-tcc` compiled `lib/libtcc1.c` (6 objects,
37 KB) where three runs had stopped.

The handoff crossed to the x86 runner, the substitution took, and the gate
confirmed static x86_64 before any rung ran. Then the stage4 job stopped in its
airlock:

```
M4_BOOT_VER: unbound variable
```

**A composition hazard, and the fourth of its kind in this file.** This
workflow's `env` came from `stage0-stage4-complete`, whose stage4 job is the
*aarch64* ladder; the stage4 job here is the *amd64* spike, and its rungs fetch
four things the aarch64 one does not — `M4_BOOT_VER`, `ELFUTILS_VER`,
`PKGCONF_VER`, `ZLIB_VER`. Taking a job body from one workflow and an env block
from another leaves exactly this gap. All four are copied verbatim from the
spike, and every key the two already shared was checked for disagreement —
there were none.

**So the class is now checked rather than discovered.** A sweep over all three
jobs looks for any `$NAME` a step reads that is neither assigned in that step,
nor in the workflow or job `env`, nor exported by an earlier step via
`$GITHUB_ENV`, nor `${NAME:-}`-guarded. It comes back clean, and removing
`M4_BOOT_VER` again makes it name the three steps that would fail — so it is a
check that can fail, not a rubber stamp.

The boot step's follow-on `BOX: unbound variable` was a consequence rather than
a second bug: `BOX` is written to `$GITHUB_ENV` by the box assembly, which
never ran. It is now `${BOX:-/nonexistent}` — an `always()` step that cannot
survive an empty environment turns every upstream failure into two errors, and
the one the reader should see is the first.

**The ladder itself has still never run on this compiler.** `stage3-cross-tcc-probe` established
that a cross tcc and a target-native tcc can be built — **with the host's
gcc**. Doing the same
with mc-tcc is the experiment. The probe named the likely failure before it
ran: *"linking a hosted program for the target needs the target's libc and crt
files."* That is why `CROSS 2` builds a musl with the cross compiler before
`CROSS 3` builds the native tcc, and why each step reports what it produced.
If mc-tcc cannot compile `tcc.c` for another target, `CROSS 1` says so in one
command rather than forty rungs later.

It publishes to **`stage4/hermetic-amd64`**, its own tag, so it cannot
overwrite the spike's release — the same argument the spike makes about the
aarch64 one.

**riscv64 stops at rung 8**, and the post-mortem there says exactly where.

```
stage 1 (built by tcc)       1,500,084 bytes
  --version -dumpversion -dumpmachine -print-search-dirs -dumpspecs   all ok
  -dumpspecs three times:  rc = 0 0 0
  cc1: compiled a trivial program (232 bytes of asm)

stage 2 (built by stage 1)   1,218,560 bytes
  --version -dumpversion -dumpmachine -print-search-dirs -dumpspecs   ALL SEGFAULT
  -dumpspecs three times:  rc = 139 139 139
  cc1: not present
```

**The tcc-built compiler is healthy.** Every driver call works, deterministically,
and its `cc1` compiles. What it *produces* does not: stage 2 segfaults on
`--version`, before argument parsing does anything, and does so three times out
of three -- so not uninitialised memory.

Two numbers narrow it. Stage 2 is **282 KB smaller** than stage 1 from the same
source and the same configure, a 19% shrink; and `cc1` was never reached,
because the build died at `specs` immediately after linking `xgcc`. A driver
that cannot survive `--version` looks more like a bad LINK -- crt files, libgcc,
static against dynamic -- than bad code generation, and the difference between
the two builds is what they were linked against rather than what compiled them.

#### What the post-mortem did NOT establish, and the cheaper question nobody asked

The post-mortem answers *which binary*, *which call* and *is it deterministic*.
It cannot answer *why*, because by the time it runs the only evidence left is a
1.2 MB binary that dies instantly. Reading the rungs for what has actually been
measured turns up something the log does not say out loud:

**this compiler has never been asked to optimise anything.**

Every `$GCC1` invocation in `rungs-riscv64.sh` -- preflight 1, the `-std`
ladder, preflight 2 -- passes no `-O` flag, so every program this chain has
compiled *and run* with the tcc-built gcc was built at `-O0`. Rung 7 then
**reuses tcc's archives** rather than rebuilding them, so nothing there
exercises it either. The first optimised code this compiler ever emits is
gcc's own build at rung 8:

```
/work/out/bin/gcc -static -g -O2 -DIN_GCC ... -o xgcc
/work/bld2/./gcc/xgcc -B/work/bld2/./gcc/ -dumpspecs > tmp-specs
make[2]: *** [Makefile:1868: specs] Segmentation fault
```

-- and the first binary out of it segfaults before it can print its version.
That is not proof the optimiser is at fault. It is the observation that the
one variable nobody has moved is the one that changes at exactly the rung
where things break, and that testing it costs two seconds where reaching rung
8 costs forty minutes.

So rung 7 gains two preflights, both **reporting rather than gating**:

- **Preflight 3** compiles and runs the existing `p1b` program at `-O0`,
  `-O1`, `-O2`, `-Os` and `-g -O2` -- the last a literal, because it is what
  rung 8 passes, and a ladder that tests everything except the failing
  combination is a near-miss this chain has paid for before. `p1b` announces
  each construct before running it and flushes, so a crash names the
  construct.
- **Preflight 4** tests the bad-link reading directly instead of letting
  preflight 3 stand in for it: `-print-libgcc-file-name`, the resolved path of
  each crt file and `libc.a`, and the actual `collect2` line from `-static -v`.
  Rung 4.6 merged nineteen soft-float helpers out of `libtcc1.a` **into**
  `libc.a`, so there are genuinely two sources for some symbols and whichever
  the linker reaches first wins -- that is visible here and nowhere else.

**Reporting, not gating, and that is a decision rather than caution.** Failing
rung 7 on a bad `-O2` would save the forty minutes rung 8 costs, but this probe
has never run, and a gate keyed on an outcome nobody has seen is a guess in a
measurement's clothes -- the same reasoning the cmake-log check in this chain
records. Reporting also keeps both the ladder *and* rung 8's post-mortem in one
log, and the correlation between them is worth more than either alone. It
becomes a gate once the answer is known.

#### The startup theory is dead, and so is the bad-link reading

Run 85330273671 added `size`, the `__global_pointer$` count and the first
instructions at `_start` for both binaries. They settle two questions at once:

```
stage 1 (tcc-built)     text 577272   data  4800   __global_pointer$: 1
  10498: auipc gp,0x8f
  1049c: addi  gp,gp,-232

stage 2 (gcc-built)     text 414416   data 11832   __global_pointer$: 1
  12268: auipc gp,0x68
  1226c: addi  gp,gp,-1832
```

**`gp` is set, identically in form, in both.** So the reading that crt1 fails
to initialise it is wrong, and the `.option norelax` line of enquiry is closed.

**And the size difference is not a link fault.** Stage 2 has 28% less text and
2.5× more data than stage 1 — which is what a real optimiser looks like beside
tcc, not a truncated binary. The earlier note that "a driver that cannot
survive `--version` looks more like a bad LINK" was reasonable and is now
disproven by the numbers it was inferred from.

#### What preflight 5 actually found

```
-O0        SEGFAULT (rc=139) after: global pointer to a literal...
-g -O2     ok (all six)
--no-relax ok (all six)
```

**The tcc-built gcc miscompiles global variable access at `-O0`.** That is a
root cause statement about the compiler, not a symptom of the binary, and it
comes with a forty-line reproducer. Not relaxation — `--no-relax` passes.
Backwards from the usual direction, too: wrong at `-O0`, right at `-O2`, which
points at the addressing sequence `-O0` emits for a global.

**It does not yet explain rung 8**, and saying so matters. `xgcc` is built at
`-g -O2`, where those six constructs pass. So either gcc's sources reach a
construct the six do not, or there is a second fault. What has changed is that
there is now a case small enough to answer in seconds instead of a run.

`crt1.o` reaches `__global_pointer$` through **`R_RISCV_GOT_HI20`** — a
GOT-based load, where GNU `as` with `.option norelax` emits the PC-relative
form. That is tcc's assembler output and it is a second thread pointing at the
same place.

#### The compiler now leaves the job

Five rounds have each cost a full ladder, because the only way to ask the
tcc-built gcc a question was to add a probe to `rungs-riscv64.sh` and dispatch
again — the binary under test is destroyed with the runner every time. Four
artifacts already left this job and **not one contained the compiler the
investigation is about**: `Collect the final toolchain` takes `box/work/lfs`,
which is the LFS sysroot from rung 10 onward, while the rung-6 compiler lives
in `box/work/out`.

`compiler-under-test-riscv64` is a slice of the box — `work/out`, both build
trees' `gcc` directories, `work/prefix` for binutils, `work/prereq2`, and
musl plus headers so it runs at all. Build trees are excluded: gigabytes of
objects that answer nothing.

With `qemu-user-static` and binfmt, riscv64 binaries run on any x86 machine,
so `-S`, `objdump -dr`, flag bisection and construct narrowing all happen
locally in seconds. **`STOP_AFTER` is now a dispatch input** as well — the
script has always read it, and `stop_after=6` reaches the compiler without
paying for rungs 7 and 8.

#### Both readings lost, on the same run

Run 85320231620 answered both at once:

```
--- preflight 3: does optimisation break what it emits? ---
  -O0 ok    -O1 ok    -O2 ok    -Os ok    -g -O2 ok

--- preflight 4: what its static link is made of ---
  libgcc:  /work/out/lib/gcc/riscv64-unknown-linux-gnu/4.6.4/libgcc.a
  crt1.o /lib/crt1.o    crti.o /lib/crti.o    crtn.o /lib/crtn.o
  crtbegin.o, crtend.o  from gcc's own directory
  -static -v rc=0 ... the linked binary ran: exit=0
  collect2: -melf64lriscv -static crt1.o crti.o crtbeginT.o
            --start-group -lgcc -lc --end-group crtend.o crtn.o
```

The optimiser is not at fault for those constructs, and the link resolves the
paths it should and produces a binary that runs. **Two readings, both
weakened by one run**, which is the useful kind of result: it leaves one thing.

#### What every test program in this chain has in common

```c
p1.c   int main(void){return 42;}
p4.c   int main(void){return 0;}
p1b.c  five `static` items -- mk, addp, fact, apply, dbl -- ALL FUNCTIONS
```

**Not one program this chain has compiled and run has a file-scope variable.**

On riscv64 that is not an academic gap. The ABI reserves `x3` as `gp`, and
small globals are addressed relative to it -- `lw a0,-12(gp)` rather than a
two-instruction absolute form -- with the linker *relaxing* the long form into
the short one when the datum falls within ±2 KB of `__global_pointer$`. `gp`
is set once, in crt1's startup:

```asm
.option push
.option norelax
la gp, __global_pointer$
.option pop
```

If `gp` is never set, or set wrong, **every gp-relative access reads from a
garbage base** -- and the symptom is exactly the one rung 8 reports. A program
with no globals never makes such an access and runs fine at every optimisation
level. A 1.2 MB compiler driver makes them constantly and dies before printing
its own version, deterministically.

The `.option norelax` is there because the instruction computing `gp` must not
itself be relaxed to be gp-relative. **And this box's crt1 came from a musl
that tcc assembled** -- the same tcc that rejected `fscsr`, `csrc`, `csrs` and
`frflags` in musl's fenv, and needed `add`→`addi` and `sll`→`slli` spelled out
in `tlsdesc.s` where GNU `as` accepted the register form. `.option
push/norelax/pop` is in that family: a directive tcc may accept, ignore, or
mis-handle without saying so.

**This is a hypothesis with a six-line reproducer, not a conclusion.**
Preflight 5 tests it directly: one initialised `int`, one `.sbss` int, a global
struct, a pointer to a literal, and a 16 KB array that sits *past* the gp
window so it must be addressed absolutely. Each is announced before it runs.
Preflight 6 relinks the same program with `-Wl,--no-relax`. And a static check
asks whether `crt1.o` references `__global_pointer$` at all -- which needs no
program run, and if the answer is no, nothing sets `gp` in any binary this
compiler links.

| preflight 5/6 says | what it means |
|---|---|
| small globals crash, 16 KB array fine | `gp` specifically -- crt1's startup, or tcc's handling of `.option` |
| crashes relaxed, runs `--no-relax` | linker relaxation; rung 8 needs one `LDFLAGS` entry |
| everything crashes including `-O0` | globals generally, not gp -- and rung 6 shipped a compiler rung 7 passed |
| everything runs | globals are fine; the difference from `xgcc` is something else again |

The rung-8 post-mortem also now prints `size`, the count of
`__global_pointer$` symbols, and the first fourteen instructions at `_start`
for **both** xgcc binaries. Stage 1 runs and stage 2 does not; if their startup
differs, one look settles it, and if it does not, that rules the whole
direction out without a debugger the box does not have.

### What the other two need that aarch64 does not

Every one of these was measured, and each cost a run to find:

| rung | amd64 | riscv64 | why aarch64 never sees it |
|---|---|---|---|
| 2 | drop `src/math/x86_64`, strip `@PLT` from `sigsetjmp.s` | drop `src/fenv/riscv64`, `add`→`addi` in `tlsdesc.s` | its arch files are plain C and portable asm |
| 4.6 | `__fixxfdi`, `__floatundidf` | 19 soft-float binary128 helpers | gcc's aarch64 libgcc ships the ones tcc calls |
| 4.7 | m4 1.4.7 | m4 1.4.7, and `--build=` because a 2006 `config.guess` predates RISC-V | gmp 6.3.0 asks for m4 on these targets, not on aarch64 |
| 4.8 | -- | flex 2.6.4, and a `gcc`/`cc` name on PATH for its second `AC_PROG_CC` | its bottom gcc is a git tree with no `gengtype-lex.c` |
| 6 | `--disable-decimal-float`, `--disable-libitm` | Ekaitz's gcc 4.6.4 fork + 3 patches | 4.7 defaults decimal float on for x86_64; 4.7 has no RISC-V port at all |
| 7 | -- | reuse tcc's archives; the fork's gmp computes wrong answers | the fork is not in that chain |
| 8, 9 | -- | `CC_FOR_BUILD` on the **make** line, not configure | nothing there miscompiles |
| 11, B4 | `t-linux64` multilib **and** `linux64.h` interpreter | -- | aarch64's interpreter is already `/lib/...` |
| B5.5 | zlib, pkgconf, elfutils | -- | objtool is an x86 tool; arm64 never builds it |
| B6 | `ARCH=x86_64`, `bzImage`, `arch/x86/boot` | -- | the image name is not the ARCH string |

**Rung 4.6 is the one worth reading.** musl's `libc.a` is compiled by tcc, and
tcc *calls* helpers where gcc emits instructions -- the x87 long-double
conversions on x86_64, the soft-float binary128 ones on RISC-V. Those live in
`libtcc1.a`, which every tcc link picks up silently, so rungs 3 through 5 never
notice. Rung 6 hands the same archive to xgcc and the symbol is gone. The rung
computes the overlap with `nm` rather than carrying a list, because a list goes
stale the moment musl or tcc moves: on riscv64 it found nineteen where the
comment predicted none.

### The bottom gcc is not the same program

aarch64 and amd64 both start from the gcc 4.7.4 release tarball -- aarch64 with
4.8.5's backend transplanted in, amd64 unmodified, because x86_64 is 4.7.4's
oldest target. RISC-V reached gcc upstream in **7.1**, five years after 4.7 and
well past what a C-only compiler can build, so there is nothing to transplant
into. That arm uses **Ekaitz Zarraga's NLnet-funded backport of RISC-V into a
C-only gcc 4.6.4**, at tag `working-compiler-c++`.

It arrives as a pristine tree plus one derived patch, for the reason this
project applies everywhere else: *a patched tarball hides the delta inside an
opaque blob and there is nothing left to review.* The workflow clones the fork,
applies three edits, diffs, and ships the **unpatched** tree beside the diff.

Two of the three edits are Ekaitz's own, published as shell commands rather than
carried in the fork. The third appears to be new:

```
gcc/hwint.h:291: error: 'HOST_WIDE_INT_1' undeclared
```

`sext_hwi` has a fast path guarded by `#if defined(__GNUC__)` and a fallback in
the `#else`. A modern gcc satisfies the guard and never compiles the fallback;
tcc takes it and finds two macros the fork uses and never defines. Nobody
upstream has hit it because nobody upstream builds this fork with tcc -- Ekaitz
builds it on Debian with build-essential.

---

## The seed, and the hole that is still declared

Every arm above starts from a tcc built by the host's compiler. `stage4-complete`
calls that **the one declared hole**, and the arch spikes inherited it: their
first compiler's ancestry runs through Ubuntu.

`stage3-cross-tcc-probe` asks whether it can be closed, and the answer is yes
for the parts it can test. On a native aarch64 runner:

```
VERON-XTCC-BUILD-OK    x86_64-tcc and riscv64-tcc built from one tree
VERON-XTCC-FILE-OK     each emits its own architecture
VERON-XTCC-MUSL-OK     a target musl for each, by those cross compilers
VERON-XTCC-NATIVE-OK   a NATIVE tcc for each: static, right architecture
```

The shape is not a cross build of the ladders -- that would make every rung
above a cross build and trade one problem for a worse one. It is **one binary**
crossed:

```
mc-tcc (aarch64, from the seed)
  -> x86_64-tcc, riscv64-tcc          cross compilers, on aarch64
  -> a target musl, built by each
  -> a NATIVE tcc for each target     an x86_64 binary emitting x86_64
  -> each runner walks its ladder natively, as it does now
```

The musl step needs the same four adjustments rung 2 already carries, which is
the useful part: nothing new had to be invented.

**What is not settled** is whether those binaries walk a ladder. qemu-user ran
the riscv64 one and could not load the x86_64 one at all, which says more about
emulating x86_64 on aarch64 than about the binary -- the same build performed on
an x86_64 machine produced a tcc that reports its version and compiles. The
authoritative test is the binary on its own hardware, and that is the next
experiment rather than this one.

**Nothing is integrated and nothing is published until both ladders are green
end to end AND running on a micro-c-descended tcc.** A stage-4 sysroot released
before then would have Ubuntu in its ancestry, and stage 5 would consume it.

---

## Where the ladder stands

```
0-9    tcc -> musl -> make -> binutils -> gcc 4.7.4 x2 -> gcc 10   ok
10     LFS 5.2 binutils pass 1                                     ok
11     LFS 5.3 gcc 15 pass 1                                       ok
11.5   perl                                                        ok
12     LFS 5.4 linux 7.1.5 API headers                             ok
11.7   gawk, m4, flex, bison, python  (glibc's prerequisites)      ok
13     LFS 5.5 glibc 2.44                                          ok
14     LFS 5.6 libstdc++                                           ok
16     LFS 6.x make, binutils pass 2, gcc pass 2                   in progress
15     busybox, BY gcc pass 2                                      never run in this order
17     m4/bc/bison/flex/openssl, in the sysroot                    never run
18     linux 7.1.5, natively in the sysroot                        never run
19-20  initramfs, and the Image handed out                         never run
```

**Chapter 5 is complete** -- a cross toolchain and a glibc sysroot, both built
from tcc. Rung 16 is the current wall: its three defects (a colliding make
tree, a missing build-side C++14 compiler, and `onedir` picking the wrong
directory) are fixed and unverified.

## Next

`stage4-complete`'s own diagram for the part above tcc:

```
tcc ──► gcc 4.7.4 (c,c++) ──► gcc 4.7.4 again ──► gcc 10.2.0
        stage 1               stage 2             stage 3
```

**4.7.4 is built twice, and the second one is not redundant.** The first carries
whatever tcc got wrong; the preflight above shows what that looks like in a
library. The second is built by the first and is what everything above depends
on. Each stage rebuilds gmp/mpfr/mpc with the compiler it just made before
building the next one -- stage 4 does this at every rung and the logs say so:
*"prerequisites, rebuilt by the tcc-built gcc"*, then *"rebuilt by the stage-2
gcc"*.

## Which book, and where we leave it

**Updated to `LFS-BOOK-r13_0-167`**, and the update was forced by a 404 rather
than chosen. `glibc-2.43-upstream_fixes-1.patch` stopped being served while
every other file came down from the same directory; the newer book explains it:
r13.0-167 moved to **glibc 2.44**, which needs no reconciliation with a 7.x
kernel, and dropped the patch from section 3.3 entirely.

```
                r13.0-156      r13.0-167
Glibc           2.43           2.44
Binutils        2.46.0         2.47
GCC             15.2.0         16.1.0
Linux           7.1.3          7.1.5   (headers AND image)
Perl            5.42.2         5.44.0
Python          3.14.6         3.14.6
glibc patches   fhs + upstream fhs only
```

**The 7.1.5 divergence is no longer a divergence.** It was carried as a stated
exception because `stage4-complete` boots that kernel; r13.0-167 now uses it
for both the API headers and the image, so `KHDR` and `KERNEL` agree with the
book and with each other.

**GCC 16.1.0 is not adopted.** The chain reaches gcc 15 through gcc 10 through
gcc 4.7, and each of those hops is a measured result. Moving the top of the
ladder is a separate experiment from moving the libc under it.



`spikes/stage4/books/LFS-BOOK-r13_0-156-systemd` -- the **development
snapshot**, not the stable 13.0 beside it. It specifies:

```
Linux 7.1.3    Perl 5.42.2    Glibc 2.43    Binutils 2.46.0    GCC 15.2.0
```

Two versions had drifted and were corrected: perl was 5.42.0, which is the
*stable* book's number, and the kernel was 7.1.5 from nowhere in particular.
Mixing books is how a pairing nobody tested becomes the thing being debugged --
glibc 2.43's `upstream_fixes` patch exists precisely to reconcile a libc with a
kernel it was not shipped against, and stage 4 calls it *"THE PRICE OF LINUX
7"*.

**One divergence is kept deliberately: `KERNEL 7.1.5` against `KHDR 7.1.3`.**
`stage4-complete` already builds and boots that exact pairing, so it is tested
rather than hoped for, and a kernel may always be newer than the headers its
libc was compiled against -- the syscall ABI is stable forward. The reverse is
what breaks. Keeping them as two variables makes that a property stated rather
than one obtained by accident, and it is the shape every later bump takes:
linux-next against a released glibc is the same question with a bigger gap.

When it does break it looks like `redefined [-Werror]` on a type both the
kernel headers and the libc declare. Rung 13 greps for that specifically,
because the message names a symbol rather than the pairing that caused it.

## What glibc actually requires, measured

`tool-probe` ran each package's own configure in a box with a controlled PATH.
glibc answered the question this document had been arguing from the book's
table of contents for several rounds:

```
glibc-2.43  configure: error:
  *** These critical programs are missing or too old: make gawk bison python
```

**Python is required at LFS chapter 5, not just chapter 8.** LFS never notices
because chapters 5 and 6 run on the host, which has one; its chapter 7 builds
Python for the *chroot*, before chapter 8's glibc. We have no host at either
point, so Python moves earlier -- for a reason the book does not have.

That also settles `gawk`, which the trap log flagged three times: busybox awk
handles everything m4 and bison use -- `ENVIRON`, `-f`, `gsub`, `printf`,
`match`, all measured -- so glibc naming it is a version check against
`gawk --version`, not a capability gap. A `gawk` wrapper around busybox awk is
in both boxes.

The rest of the set, and what each turned out to be:

| tool | verdict |
|---|---|
| **python3** | **real, and earlier than the book puts it** -- glibc 5.5 |
| **bison** | **real** -- glibc names it; and bison needs flex before it |
| **flex** | **real** -- both flex and bison stop at *"cannot find output from flex"*. bison's scanner ships pre-generated, but its *configure* checks anyway |
| **perl** | **real** -- rung 11.5, already built |
| **split, comm** | **real** -- not busybox applets at any configuration; written in C |
| makeinfo | texinfo; `MAKEINFO=true` disposes of it |
| pkg-config | optional for bc; for Python it is how openssl is found |
| gawk | false positive -- busybox awk suffices, wrapper supplied |

**perl configures cleanly** (`rc=0`) with a long list of headers it did not
find -- `db.h`, `gdbm.h`, `ndbm.h`, `bfd.h`. Those are optional modules, not
requirements, which is why the rc is 0. Worth knowing that a package can pass
configure while quietly building less than it would elsewhere.

**m4 fails at `config.status: Something went wrong bootstrapping makefile
fragments`**, which is autoconf's message for a substitution engine that could
not run -- and is what the gawk wrapper is expected to fix.

**bc returns 127**, meaning its configure script did not execute at all. Its
own shell requirement, and not yet diagnosed.

## Which compiler builds what, and why it matters

The ladder produces four compilers. Confusing them cost several runs, so this
is the table.

| compiler | where | built by | its job |
|---|---|---|---|
| tcc | `/work/tccsrc` | the airlock | build musl, make, binutils, gcc 4.7.4 |
| gcc 4.7.4 | `/work/out`, `/work/out2` | tcc, then itself | build gcc 10 |
| gcc 10.2.0 | `/work/out10` | g++ 4.7.4 | build binutils and gcc 15 pass 1 |
| **gcc 15 pass 1** | `$S/tools/bin/$LFS_TGT-*` | gcc 10 | build glibc, and everything in chapter 6 |
| **gcc 15 pass 2** | `$S/usr/bin/gcc` | pass 1 | **build everything that ships** |

**The rule: anything that ends up in the boot artefacts is built by pass 2.**
That is busybox in the initramfs, the kernel Image, and the prerequisites they
need. Pass 1 exists to build glibc and then to build pass 2; its output must
not ship, because it was configured `--without-headers --with-newlib` before a
libc existed.

Three rungs had this wrong and were moved or rewired:

* **rung 15 (busybox)** ran before rung 16 and used `$LFS_TGT-gcc`, i.e. pass
  1 -- and its output goes straight into the initramfs. It now runs *after*
  rung 16 and builds with pass 2. The rung order is
  `13 → 14 → 16 → 15 → 17 → 18`.
* **rung 17 (prerequisites)** built into `$PFX` with `chain-cc`, which is
  gcc 10 against **musl**. It now builds into the sysroot with pass 2.
* **rung 18 (the kernel)** cross-compiled with `CROSS_COMPILE=$LFS_TGT-`,
  again pass 1. It now runs natively in the sysroot with no `CROSS_COMPILE` at
  all, which is what LFS chapter 10 does.

**The build-side compiler in chapter 6 is pass 1, and that is correct.**
configure needs two compilers for a cross build: `--host` for the programs
being built, `--build` for the test programs and generators it runs during the
build. It finds `$LFS_TGT-gcc` for the host side by itself and falls back to
bare `gcc`/`g++` for the build side -- which in this box is **gcc 4.7.4** from
rung 6:

```
checking whether aarch64-veron-linux-gnu-g++ supports C++14 ... yes
checking whether g++ supports C++14 ... no
configure: error: A compiler with support for C++14 is required
```

So rung 16 passes `CC_FOR_BUILD`/`CXX_FOR_BUILD` explicitly, at pass 1 -- the
newest compiler that exists at that moment. `--build` is
`aarch64-unknown-linux-gnu` and `--host` is `aarch64-veron-linux-gnu`; they
differ only in the vendor field, so pass 1's output runs on the build machine.

**`stage4-complete` never hits this**, and the reason is worth recording: its
chapters 5 and 6 run on the bare GitHub runner, where `g++` is Ubuntu's gcc 13.
It enters a box only for the kernel and the boot. Ours is inside the box for
the whole ladder, so every compiler must come from the ladder. That is a place
where the reference job is stricter than stage 4 and stage 4's flags cannot be
copied.

---

## Where the box's tools differ from the sysroot's

Two sets of tools exist and they are not interchangeable.

**`$PFX/bin` -- the box's tools.** musl-linked, static, built by `chain-cc`
(gcc 10). make, binutils 2.30, gawk, m4, flex, bison, python, perl. These run
*during* the build and never ship. Rung 11.7 builds most of them because
glibc's configure names them:

```
*** These critical programs are missing or too old: make gawk bison python
```

**`$S/usr/bin` -- the sysroot's tools.** glibc-linked, built by pass 2. This is
LFS chapter 6's product: busybox, make, binutils pass 2, gcc pass 2, and rung
17's m4, bc, bison, flex and openssl.

**Rung 15 must run `busybox --install`.** Copying the binary gives the sysroot
one file called `busybox`; every other name is a symlink to it. Rung 17 runs
configure scripts inside the sysroot, and a configure script is a shell script
-- without `/usr/bin/sh` there is nothing to run it with.

**openssl is on rung 17's list because the kernel asks for it by name.** arm64
defconfig enables `CONFIG_MODULE_SIG`, the kernel then builds
`scripts/sign-file.c`, and that includes `<openssl/bio.h>`. Without it the
build stops partway through on a missing header that reads as a kernel problem.

---

## Above gcc 10: LFS chapters 5 and 6, and the traps in them

`stage4-complete` uses gcc 10 as the *host* compiler for a normal LFS build --
`CHAIN_CC=/work/out10/bin/gcc`. From there the order is the book's, and it is
not negotiable: **headers before glibc, glibc before libstdc++, libstdc++ before
pass 2.**

```
5.2 binutils pass 1   --target=$LFS_TGT --with-sysroot=$S --prefix=$S/tools
5.3 gcc pass 1        --without-headers --with-newlib --disable-libstdcxx
                      --enable-languages=c,c++   gmp/mpfr/mpc IN-TREE
5.4 linux API headers  headers_install from KHDR
5.5 glibc              + glibc-fhs-1.patch + glibc-2.43-upstream_fixes-1.patch
5.6 libstdc++          from the gcc 15 tree, against the glibc just built
ch6 binutils pass 2, gcc pass 2, and seventeen packages
```

`LFS_TGT=aarch64-veron-linux-gnu` -- a **deliberately distinct triple**, LFS's
own device, so the new toolchain cannot silently reach the host's libraries.
That also settles the `config.sub` question left open above: stage 4 already
carries a custom vendor through gcc 15, so a non-standard triple is not the
obstacle it looked like.

**This is where musl leaves the chain.** Chapter 5 builds glibc into a sysroot,
and everything above is glibc. musl was the bootstrap libc for exactly the
stretch where nothing else could be built, which is what `ORDER.md` argues and
this is where it comes true.

### The traps, from stage 4's own comments

**`t-aarch64-linux`, and it is not in the book.** LFS seds
`gcc/config/i386/t-linux64` for x86_64; the aarch64 file that does the same job
is `t-aarch64-linux` and *"nothing in the book covers aarch64, so this is OUR
delta"*. Without it glibc lands in `/usr/lib` and libstdc++ in `/usr/lib64`, a
directory the sysroot has no symlink to. **g++ still links.** The program then
dies at exec with `error while loading shared libraries: libstdc++.so.6` --
which reads as a broken C++ runtime rather than a misplaced file.

**`limits.h` has to be reassembled by hand after gcc pass 1.**
`--without-headers` installs a self-contained `limits.h` that knows nothing of
the system one, so `PATH_MAX` is simply absent. binutils pass 2 then dies on
`ld/ldmain.c:646: error: 'PATH_MAX' undeclared` -- *"which names a macro rather
than the include chain that lost it"*. The fix is to concatenate `limitx.h`,
`glimits.h` and `limity.h` from the gcc tree into the installed one, so it
`#include_next`s through to glibc's once that exists.

**Two kernels, not one.** `KHDR` (7.1.3) supplies the API headers at 5.4;
`KERNEL` (7.1.5) is the one that boots. And `ENABLE_KERNEL=5.4` is glibc's
minimum-kernel setting, unrelated to either.

**Two glibc patches.** `glibc-fhs-1.patch` is LFS's own; the upstream-fixes one
is *"THE PRICE OF LINUX 7"* -- a 2.43 glibc meeting a 7.x kernel.

**gmp/mpfr/mpc go IN-TREE** for gcc here, not into a separate prefix. That is
what the book does and it is more reliable than `--with-gmp=`.

### The rule worth stealing immediately

> **ASSERT THE ANCHOR.** A sed that matches nothing ships an unchanged file and
> looks exactly like a sed that worked.

Stage 4 checks the file exists, greps for the pattern, and *fails the step* if
either is missing, before editing. Every substitution in this job should do the
same -- several of ours currently report `removed 0` and carry on.

Then, to boot:

```
gcc 10 ──► gcc 15
   │
   └─► m4, bison, flex, bc, perl
             │
             └─► kernel ──► initramfs ──► boot
```

Perl is **not** live-bootstrap's four-version climb -- they build it before
binutils exists, with tcc and mes-libc. We would build it after gcc 15, where it
is an ordinary package that Alpine builds against musl routinely.

Known items:

* **The triple.** gcc 10 knows musl, but only through `linux-musl*`. Ours says
  `aarch64-unknown-linux-gnu`, so it will pick `os/gnu-linux` and hit `_IScntrl`
  again. Check whether the backported `config.sub` accepts `linux-musl` -- if it
  does, switching there is cleaner than another sed and fixes every gcc above.
* **`--disable-libsanitizer`** becomes mandatory at gcc 10+; it is glibc-specific.
* **busybox built in-box** for the initramfs, which is cheap once a libc and make
  exist -- and would let `BUDGET_DRIVER` finally reach empty.

Or hand off: the bridge proves *seed → 4.7.4*, stage 4 proves *4.7.4 → boot*
today. That is one continuous claim with one honest caveat, and it is one run
away.
