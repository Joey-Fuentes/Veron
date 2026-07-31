# live-bootstrap's build order, and what it settles for us

**Why this file exists.** The ordering of `make` and `binutils` was argued three
times from memory while designing `stage3-to-stage4-bridge`, and memory is not a
source. This records what was checked, against which artefacts, so the next
round starts from a fact. Where something was inferred rather than read, it says
so.

---

## The answer

**make first, binutils much later.** In `steps/manifest` — the machine-read
build order, tracked in prose by `parts.rst` — GNU **make 3.82 is step #25** and
**binutils 2.30 is step #81**. Fifty-six steps apart, with musl and the entire
autotools chain in between.

The ordering has never been the other way round in any layout of the project.

---

## Why it is forced, which matters more than the precedent

The dependency is asymmetric and local to the two packages:

* **binutils cannot be built without make.** Recursive Makefiles across `bfd`,
  `opcodes`, `libiberty`, `gas` and `ld`, with generated sources. There is no
  shell-script fallback.
* **make can be built without make.** Upstream ships `build.sh`, whose own
  header calls it "a Shell script to build GNU Make in the absence of any
  'make' program". live-bootstrap does the equivalent through
  `steps/make-3.82/pass1.kaem` — a flat kaem command list driving tcc.
* **tcc supplies its own linker and archiver**, so make needs no `ld` and no
  `ar`. live-bootstrap says as much when binutils finally arrives at #81: it
  means "we can now use full featured ar instead of tcc -ar, the GNU linker ld
  … and the GNU assembler as."

So the rule holds for us whatever upstream did. LFS builds binutils first
because **LFS has a host make from day one**; it never bootstraps one. A box
with no make cannot follow LFS's order.

Independent corroboration: GNU Guix's Reduced-Source Bootstrap orders
`gnu-make-mesboot0 (3.80)` before `binutils-mesboot (2.20.1a)` — same topology,
different project.

---

## The segment that concerns us

```
kaem ──► tcc 0.9.26 ──► tcc 0.9.27 ──► make 3.82  (#25, kaem-driven)
      ──► patch, gzip, tar, sed, bzip2, coreutils, bash
      ──► musl 1.1.24
      ──► m4, flex, bison, diffutils, gawk, perl
      ──► autoconf / automake / libtool chain
      ──► binutils 2.30  (#81)
      ──► gcc 4.0.4  (C frontend only)
      ──► … gcc 4.7.4 ──► binutils 2.41 ──► gcc 10.5.0 ──► gcc 15.2.0
```

Later rebuilds: make 3.82 again at #92 (the first one "randomly segfaults while
building the Linux kernel"), then make 4.2.1 at #115; binutils 2.41, then 2.41
pass 2 with the full autogen top level.

**The libc at the binutils and gcc rungs is musl**, never glibc. mes-libc covers
only the earliest rungs, up to and including the first make, coreutils and bash.

**A host `make` is never used at any point.** The chain starts from two ~350-byte
seeds plus kaem.

---

## What this changed in our jobs

**binutils 2.30, not 2.46.** `stage3-to-stage4-{bridge,reference}.yml` had
copied stage 4's `BINUTILS: 2.46.0` on the assumption that matching versions
made the overlap real. It does not — the overlap is at gcc 4.7.4, and binutils
below that is an implementation detail each side satisfies its own way. **Stage
4 never builds binutils at all**; it is in `chain/env0.sh`'s `BORROWED` list, so
its version had never been a tcc question. These jobs are the first thing in the
tree that asks a tcc to compile it, and tcc has a ceiling:

| evidence | says |
|---|---|
| live-bootstrap's old `sysa/` layout | binutils **2.14** — "seems to be the limit for tcc" |
| live-bootstrap master, first binutils | **2.30** |
| guix-devel, 2024 | binutils **2.43** "does not link the object files from TCC" |

2.46 was past every one of those. It would have failed rung 4 and read as a
compiler defect.

**WE BUILD musl BEFORE make. live-bootstrap DOES THE OPPOSITE, AND THE REASON
IS NOT PREFERENCE.** An earlier version of this file claimed our order matched
theirs while printing a diagram three paragraphs above showing that it does not.
Both cannot be true. What is true:

| | libc available when make is built |
|---|---|
| live-bootstrap | **mes-libc**, already installed at `/usr/lib/mes` and `/usr/include/mes` |
| us | **nothing** |

live-bootstrap builds make at #25 against mes-libc, which mes and tcc 0.9.26
have already put on disk as headers and libraries. musl comes later, at which
point there is a real make to drive it. That is a perfectly good order **when
you have an intermediate libc**.

Our box has none. mc-tcc is linked against M2libc, but M2libc is *inside*
mc-tcc -- statically linked into the binary, not installed as headers and
libraries something else could compile against. Even if it were installed it
would not carry make: M2libc has no `FILE`, no stdio layer, and a small
fraction of what mes-libc provides. There is no rung at which we could build
make and no musl yet.

So the order is forced the other way, and hand-driving musl is what it costs.
That is why rung 2 is a shell loop rather than a `make` invocation: not a
stylistic choice, and not an attempt to be clever, but the direct consequence
of having no libc before musl. It works -- 1348 of 1349 sources compile -- so
the cost is paid once and is small.

**AND IT HAS ALREADY COST ONE DEFINE.** live-bootstrap builds make 3.82 from a
flat command list -- `steps/make-3.82/pass1.kaem`, 27 compiles, an empty
`config.h`, no configure, no patches -- and every HAVE_* arrives as a `-D`.
Transcribed unchanged, 22 of the 27 fail here:

```
make.h:40: error: incompatible types for redefinition of 'alloca'
```

make.h declares `char *alloca ();` itself unless `HAVE_ALLOCA_H` is set. Their
libc at that rung is mes-libc, which does not declare it; ours is musl, which
does. One added define -- `-DHAVE_ALLOCA_H` -- and make.h includes musl's
`<alloca.h>` instead. That is the whole delta so far, and it exists **because
of the ordering difference above**, not in spite of it.

**The alternative, if hand-driving musl ever becomes untenable:** grow a
mes-libc-equivalent -- enough libc to carry make, installed as headers and
libraries -- and then follow live-bootstrap's order exactly. That is strictly
more work than the shell loop unless musl's build starts fighting us, and it is
recorded here so it is a choice rather than a thing nobody thought of.

**A second place we knowingly differ.** live-bootstrap builds musl **1.1.24** at the
tcc rung and only reaches 1.2.5 later, under gcc. We build **1.2.5** directly
with tcc, which is untested upstream at that position — and it works: the
reference arm compiles 1348 of 1349 sources. Recorded because it is a
divergence, not because it is a problem. If musl ever becomes the suspect, 1.1.24
is the fallback with precedent behind it.

**One place we skip a rung.** live-bootstrap builds gcc **4.0.4** (C frontend
only) before 4.7.4. We go straight to 4.7.4, which `stage4-complete` already
proves a tcc can do.

---

## Their constraints are not ours, and I imported three of them anyway

The ordering above is theirs and it is checked. The **reasons behind it** are
theirs too, and three times a reason was carried over without asking whether the
constraint still applied. Recorded because the mistake has a shape.

**make before musl.** Theirs, because mes-libc is installed by then. Ours
inverts, because M2libc lives *inside* mc-tcc rather than on disk and could not
carry make anyway. Cost: rung 2 hand-drives musl in shell. Already covered
above, and it is the one where the divergence was noticed early.

**make 3.82, then 4.2.1.** Theirs is a real pin with a real recipe, and 3.82
built here exactly as their `pass1.kaem` says. But 4.2.1 does not survive musl:
its **bundled glob** cost five substitutions — `getlogin`, `getlogin_r`, `__P`,
`__ptr_t` — before hitting `gl_opendir`, a `glob_t` member from GNU's
`GLOB_ALTDIRFUNC` that musl has no equivalent for. **make 4.3 dropped the
bundled glob entirely**; 4.4 keeps it dropped and uses gnulib, and it builds.
Their reason for avoiding 4.4 is stated in `parts.rst` — *"the use of automake
1.16 which we do not have yet"* — and it is an autotools reason, not a musl one.
We do not regenerate, so it never applied to us.

**perl in four versions.** 5.000 → 5.003 → 5.005_03 → 5.6.2, because they build
perl *before binutils and gcc*, with tcc and mes-libc. Modern perl will not
build in that environment. We would build it **after gcc 15**, where it is an
ordinary package that Alpine builds against musl as a matter of course. Reading
their four-stage climb as a cost we would also pay inflated the remaining work
from roughly eight rungs to twenty-plus.

**The rule.** live-bootstrap's ordering is evidence about *dependencies*. Their
version pins are evidence about *their environment*: kaem, mes-libc, no
autotools, x86. Ours is busybox, musl, a full binutils by rung 4, aarch64. Take
the ordering; re-derive the pins.

## Sources, and how firm each is

**Primary, read directly:** live-bootstrap's `parts.rst` (prose tracking of
`steps/manifest`), `README.rst`, `DEVEL.md`, and `steps/tcc-0.9.26/pass1.kaem`.
`DEVEL.md` supplies the naming convention that makes the kaem/make transition
legible: "Scripts run in kaem era should be denoted as such in their filename;
pass1.kaem, for example."

**Not read:** the raw `steps/manifest` line by line, and the literal contents of
`steps/make-3.82/pass1.kaem`. The conclusion does not rest on them — the step
numbers come from `parts.rst`, and the `.kaem` extension plus `parts.rst`'s own
statement that make is what frees the project from "complex kaem scripts" is
what establishes the mechanism. If the exact recipe is ever wanted, clone and
read that file.

**Secondary:** GNU Mes reference manual and Guix `commencement.scm`, the
bootstrappable wikis, guix-devel mail, bootstrappable IRC logs.

**Drift:** step numbers and versions are from master as of mid-2026 and will
move. The make-before-binutils *ordering* has been stable across the project's
whole history, including the older `sysa/` `sysb/` `sysc/` layout that current
master replaced with a flat `steps/manifest`.
