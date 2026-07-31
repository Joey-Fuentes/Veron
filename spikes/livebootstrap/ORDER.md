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

**Our ordering was already right** — musl, then make, then binutils — and now
for a checked reason rather than a remembered one. `make 3.82` is confirmed as
the version that builds this way.

**One place we knowingly differ.** live-bootstrap builds musl **1.1.24** at the
tcc rung and only reaches 1.2.5 later, under gcc. We build **1.2.5** directly
with tcc, which is untested upstream at that position — and it works: the
reference arm compiles 1348 of 1349 sources. Recorded because it is a
divergence, not because it is a problem. If musl ever becomes the suspect, 1.1.24
is the fallback with precedent behind it.

**One place we skip a rung.** live-bootstrap builds gcc **4.0.4** (C frontend
only) before 4.7.4. We go straight to 4.7.4, which `stage4-complete` already
proves a tcc can do.

---

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
