# The bridge: from one tcc to gcc 4.7.4, in a box with busybox and nothing else

**Status.** `stage3-to-stage4-reference` **closes**. Eight rungs, from a static
tcc to a working gcc 4.7.4 with a C++ compiler, in a sandbox whose entire host
inventory is one busybox. `stage3-to-stage4-bridge` runs the same rungs with
mc-tcc and has not been attempted yet.

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

The rule the job now follows: **a flag working on the runner says nothing about
the box**, and every check reports what it measured rather than a verdict.

---

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
