# gcc 4.7 + gcc 4.8's aarch64 backend — the entry point to the gcc leg

**Status: the compiler builds under both gcc and tcc, produces correct aarch64
code, and shows no miscompilation across 349 translation units. libgcc does not
build. 2026-07-25.**

```
                      host gcc 13        OUR arm64 tcc
configure                  rc=0                  rc=0
build (all-gcc)            rc=0                  rc=0
error lines                   0                     0
objects                     ---                   626
cc1                  55,044,256 B          80,016,473 B

cc1 emits:   stp  x29, x30, [sp, -48]!        <- both, 44 lines each
             cmp  w0, 1
             ble  .L4
assembled:   ELF 64-bit LSB relocatable, ARM aarch64
ran:         exit=55            (fib(10) = 55)
```

Gated by two workflows, one variable apart:

- `.github/workflows/gcc47-aarch64-backport.yml`, arm `C-474-backport` — host gcc
- `.github/workflows/tcc-builds-gcc-arm64.yml` — our arm64 tcc

**The entry point is now closed end to end.** A C compiler small enough to be
reached from a seed builds a gcc that targets aarch64:

```
tcc (arm64)  ->  gcc 4.7 + 4.8's aarch64 backend  ->  [g++ 4.7]  ->  gcc 4.8  ->  modern
   PROVEN                    PROVEN (cc1)                next
```

## The problem this solves

`gcc-entrypoint-probe` measured both boundaries on aarch64 and found they are
the **same release**:

```
oldest gcc with an aarch64 backend  = 4.8   (4.7 has zero aarch64: config.guess 0,
                                             config.sub 0, config.gcc 0)
oldest gcc requiring a C++ compiler = 4.8   (top-level configure is lenient;
                                             gcc/ subdir configure enforces CXX)
```

so no release both targets our architecture and builds with a C compiler. The
standard old-gcc/new-gcc ladder has no rung here.

The escape is that **every gcc up to 4.7 is written in C** — that is what the
4.8 boundary means — so 4.7 yields not just a C compiler but `g++` 4.7, a full
C++98 compiler built from C. And 4.8 asks only for "an ISO C++98 compiler". The
sole thing wrong with 4.7 is the missing backend, and a gcc backend is a
self-contained directory plus config entries:

```
tcc -> gcc 4.7 + this backend -> g++ 4.7 -> gcc 4.8 -> modern gcc
```

native **and** C-only, end to end.

## Why it was worth attempting before doing it

The cost of a backport is whatever the backend↔middle-end interface changed
across the release, and that is measurable with a control rather than argued.
`gcc-backend-backport-probe` diffed the **existing** backends 4.7.4 → 4.8:

```
vax  4.7.4 -> 4.8.0    15 files,   76 +,   72 -      ~148 lines, whole backend
vax  4.7.4 -> 4.8.5    15 files,   76 +,   72 -      IDENTICAL
arm  4.7.4 -> 4.8.0    97 files, 8796 +, 5050 -      thumb2.md, vfp.md, unspecs.md
```

vax is the control-for-the-control: nobody was developing it, so its delta is
close to pure interface change. **~148 lines for an entire backend.** arm's much
larger delta is arm's own development, which is exactly what the vax comparison
separates out.

That vax's delta is *identical* at 4.8.0 and 4.8.5 also decided **which**
backend to take: the interface did not move within the 4.8 series, so 4.8.5's
aarch64 is no further from 4.7 than 4.8.0's while carrying ~1,800 lines of fixes
to a port that was one release old.

The probe also found the backend uses **0 of the 21 target hooks new in 4.8**
(with a positive control proving the search worked), and that all 40 symbols it
references which 4.7 lacks are self-supplied — 30 `gen_*` emitted by `genemit`
from the backend's own `.md` files, 1 from `gengtype`, 9 backend-local statics.

## What the transplant actually cost

| layer | adaptation |
|---|---|
| target hooks | **0** |
| `config.gcc`, `libgcc/config.host` | 3 case arms, spliced by block structure |
| `config.sub`, `config.guess` | taken from 4.8.5 wholesale — standalone data files |
| `.md` dialect | 34 `define_int_*` expanded: 30 forms → 109 patterns |
| qualified `<ITER:attr>` refs | 7 |
| middle-end API | 3 functions, 24 call sites |

Nothing structural: no missing subsystem, no hook the backend needed, no C that
would not compile. Every obstacle was a **dialect** change in the machine
description or a **signature** change in three functions. The vax number held.

## The three deltas, each named

### `.md` dialect — `tools/expand_int_iterators.py`

`define_int_iterator` and `define_int_attr` are machine-description constructs
added in 4.8, and aarch64's `iterators.md` leans on them for NEON. 4.7's reader
stops at the first one:

```
config/aarch64/iterators.md:664: unknown rtx code `define_int_iterator'
```

**Expanded rather than backported, and the reason matters.** 4.7 already has the
generic `iterator_group` abstraction (`modes`, `codes`), so adding an `ints`
group looks like a handful of lines. It is not: 4.7 records iterator uses with
`struct map_value` and `htab_t`, while 4.8 replaced that with

```c
static vec<mapping_ptr>  current_iterators;
static vec<iterator_use> iterator_uses;
current_iterators.safe_push (iterator);
FOR_EACH_VEC_ELT (attribute_uses, i, ause)
```

which is **C++**. Backporting it would drag the C++ boundary into the one
release that does not need it — defeating the entire reason for choosing 4.7.

Expansion is what `read-rtl.c` does internally: a pattern using an iterator with
N values becomes N patterns, with `define_int_attr` supplying the per-value
substitutions. `reduc_s<fmaxminv>_v4sf` becomes `reduc_smax_v4sf` and
`reduc_smin_v4sf`.

### Middle-end API — `tools/port_gcc47_api.py`

Three functions, and 4.8 drifted in three different directions:

| call | change | sites |
|---|---|---|
| `plus_constant` | 4.8 **added** a leading mode; 4.7 infers it from the rtx | 22 |
| `assign_stack_temp` | 4.8 **removed** the trailing `int keep`; 4.7 requires it | 1 |
| `crtl->is_leaf` | 4.8 **moved** the flag into `struct rtl_data` | 1 |

The rule table is written to grow: one row per signature change, with an arity
check proving the rewrite hit the right call.

**One assumption, stated rather than buried.** `assign_stack_temp`'s `keep`
controls whether a stack temp slot may be reused after `free_temp_slots()`. The
tool passes `0`, the behaviour 4.8 made unconditional when it deleted the
parameter; the single call site builds a vector in memory and immediately loads
it, which is where that is safe. The tool logs every argument it adds or drops
so the choice appears in the run output.

### The transplant — `spikes/stage3/probes/backport-aarch64.sh`

Copies three directories (`gcc/config/aarch64`, `gcc/common/config/aarch64`,
`libgcc/config/aarch64` — missing either of the last two is the classic way a
backport almost works), takes `config.sub`/`config.guess` wholesale, and splices
the case arms extracted from 4.8.5 rather than hand-written.

It then **proves** the result by sourcing `config.gcc` the way `gcc/configure`
does, which turns a 40-minute build into an answer in seconds.

## Built by tcc

The host-gcc arms answered *does this transplant work*. They deliberately did
not answer *can our own compiler build it* — one variable at a time. That second
question was split in half and each half answered separately:

| | |
|---|---|
| tcc compiles gcc 4.7.4's source | `tcc-builds-gcc-x86`, arm `D-474-tcc`. Had to be x86: until this backport existed there was no arm64 4.7.4 to try. |
| gcc 4.7.4 targets arm64 | this document, arm `C-474-backport`, host gcc |
| **both at once** | `tcc-builds-gcc-arm64`, native `ubuntu-24.04-arm` |

**The conjunction holds.** 140 seconds wall clock, of which `all-gcc` was 56.

```
tcc            0.9.28rc HEAD@5ec0e6f8 (AArch64 Linux)
               sources/tcc.toml pin + the 5-patch arm64 series, applied 5/5
precondition   feat.c -> 6      the C constructs gcc 4.7's source uses
               kern.c -> 0      inline asm (not needed by cc1, reported anyway)
prerequisites  gmp 6.2.1 --disable-assembly, mpfr 4.1.0, mpc 1.2.1
               all configure rc=0, make rc=0, INSTALLED -- under tcc
gcc            configure rc=0   build rc=0
               0 error lines, 178 warnings, 626 objects
               6 of 6 generators built, 11 insn-*.c generated
               cc1 80,016,473 bytes
claim          44 lines of aarch64, assembled, ran, exit=55
```

Nothing in the transplant needed changing for tcc. The `.md` expansion, the
three API adaptations and the `config.gcc` splice are all compiler-agnostic —
which is what you would expect of a delta that is dialect and signatures rather
than code, but it was not guaranteed.

## Not miscompiled — measured

A `cc1` that links and returns 55 from `fib(10)` has exercised a conditional, a
subtraction and a recursive call. A `cc1` miscompiled in register allocation, or
in a mode that toy never reaches, passes that test unchanged. Running is not
being right.

`.github/workflows/tcc-gcc-miscompile-check.yml` asks the diagnostic question
instead. `cc1` is deterministic, so two compilers built from one source by two
unrelated compilers must **behave** identically — their own bytes differ and
should. Both are pointed at a corpus that needs no inventing, gcc's own source,
with the build system supplying every flag.

```
gate 0   the comparison can fail (-O2 vs -O1)          ok
gate 1a  the generators reproduce (regenerate in tree) 7 of 7
gate 1b  generated sources, H vs T                     7 of 21 differ
gate 1c  pattern set                                   T is a superset
gate 2   gcc's own translation units                   333 of 333 IDENTICAL
gate 3   libgcc's translation units                    16 of 16 IDENTICAL
```

**Given identical input, the two compilers emit identical assembly for all 349
translation units.** No miscompilation.

`-S` rather than object files, and both compilers run from one directory. Both
choices were paid for: comparing `.o` across two build trees reported 87 of 87
libgcc objects differing, which is not a miscompilation signature but the build
path in `DW_AT_comp_dir`; and letting each compiler read its own generated
headers reported 233 of 333 translation units differing, because the flags begin
`-I. -I.` Assembly text carries no build path, and one working directory means
the compiler binary is the only variable.

### The generated sources differ, and why that is not a defect

Seven generated files differ between the trees, and gate 1c names the cause in
one line of `insn-codes.h`:

```
H:  #define CODE_FOR_loadwb_pairsi_si CODE_FOR_nothing
T:          CODE_FOR_loadwb_pairsi_si = <a real number>
```

`CODE_FOR_nothing` is how gcc records a pattern **dropped** because its condition
is constant-false at compile time. The host-gcc tree proved four false and
deleted them; the tcc tree did not:

| | dropped | live |
|---|---|---|
| H (host gcc) | 5 | 2078 |
| T (tcc) | 1 | 2082 |

The four are `loadwb_pair{si,di}_si` and `storewb_pair{si,di}_si`. Every insn
code after them shifts by four — `case 603` → `case 607`, `output_51` →
`output_55`, `gen_split_1872` → `gen_split_1876` — so six files change without a
single instruction changing.

**A third tcc capability gap, in the same family as the other two.** gcc's
`genconditions` writes `gencondmd.c`, which folds insn conditions at compile
time, and takes that path only when the compiler building it is GCC. Built by
anything else, nothing is known false and nothing is dropped. It joins the
missing dead-code elimination in `TCC-USERLAND.md` — and like it, the fallback is
the safe direction: the extra patterns carry conditions that are false at run
time too, so they never match.

**The direction is what matters, and it is checked rather than assumed.** T
dropping a pattern H kept would be a compiler that cannot emit an instruction.
Gate 1c reports zero in that direction, and gates 2 and 3 are what turn the
argument into a measurement.

### They agree in failure too

Both trees fail to build libgcc, at the same file, the same line, the same
column, after the same 104 objects:

```
g474/libgcc/unwind-dw2.c:1490:44: internal compiler error: Segmentation fault
```

Agreement in failure is still agreement. It is also a real bug — see below.

## What this does NOT show

- **libgcc is not built.** The arms run `make all-gcc`, which stops before the
  runtime, so `gcc/xgcc` cannot link a program: `cannot find crtbegin.o`,
  `cannot find -lgcc`. `cc1` is exercised directly instead — emit assembly,
  assemble with the system `as`, link, run. A full `make` is the next step.
- **THE BACKPORTED COMPILER ICEs, AND libgcc CANNOT BE BUILT.**

  ```
  g474/libgcc/unwind-dw2.c: In function 'uw_init_context_1':
  g474/libgcc/unwind-dw2.c:1490:44: internal compiler error: Segmentation fault
  ```

  104 libgcc objects compile, then this. Reproduced under **both** compilers,
  identically, so tcc is not involved — it is a transplant bug, and
  `uw_init_context_1` is dwarf2 unwinder setup, exactly the backend↔middle-end
  surface the backport crossed. Without libgcc there is no `libgcc.a` and no
  `crtbegin.o`, so `xgcc` cannot link a program, which is why every result here
  exercises `cc1` directly. **This is the next thing to fix in this leg.**
- **Only `cc1`, and only C.** Both arms configure `--enable-languages=c`, so
  **g++ 4.7 has never been built by anything** — and g++ 4.7 is the entire
  reason 4.7 was chosen over 4.8. All of gcc 4.7 is C, including its C++ front
  end, so this should follow; "should" is not "does".
- **No reproducibility gate.** The gcc tarballs are pinned by hash
  (`sources/gcc.toml`), but nothing here has been rebuilt byte-identically
  twice.
- **No testsuite.** The differential test compares two compilers against each
  other, so a fault common to tcc and gcc 13 is invisible to it — they share no
  code, which makes that a coincidence rather than a risk, but it is not
  nothing. gcc's own DejaGnu suite is the next and much longer step.

## What the host supplies

Every result above was built with borrowed tools, and the chain diagram at the
top says PROVEN over arrows that all rest on them. Named, in the order they
matter:

| borrowed | used for |
|---|---|
| **gcc 13** | builds tcc. Our arm64 tcc is an Ubuntu-gcc artifact. |
| binutils | `as` assembles cc1's output, `ld` links cc1 itself |
| glibc + headers | everything links against the runner's libc |
| make, bash, perl, python3, bison, flex, m4 | the build machinery, and every `configure` |
| the kernel | declared trusted, per `TRUST-BOUNDARY.md` |

**The sharpest consequence: the differential test does not close trusting
trust.** `cc1_H` was built by gcc 13 and `cc1_T` by tcc, which was built by
gcc 13. Both descend from one compiler, so a Thompson-style attack in it could
infect both identically and the comparison would report 349 of 349 clean,
exactly as it did. What that test establishes is that *tcc as a compiler* did
not corrupt cc1. It says nothing about provenance.

This is the same order LFS and Gentoo work in — chapter 5 uses the host
toolchain — with one difference that is not in our favour: **they sever the
lineage and we do not yet.** LFS chroots and rebuilds everything with the
temporary toolchain, Gentoo goes stage1 → stage2 → stage3, and the shipped
system contains no bytes produced by host binaries. We build gcc 4.7 with gcc 13
and stop. Phase 4 of `hermetic-1-sandbox` is exactly that rebuild pass, which is
why it exists.

### The hermetic ladder

`.github/workflows/hermetic-1-sandbox.yml`. Isolation is not the absence of
dependencies — a chroot with Ubuntu's `/usr` copied in is perfectly isolated and
entirely host-dependent. What a sandbox buys is **enforcement**: an undeclared
dependency stops being silently satisfied and becomes a visible error, so the
bind list *is* the declaration and each step is a deletion from it.

```
step 1  bwrap, host toolchain still bound      DONE
step 2  musl sysroot, static, instead of glibc
step 3  our own binutils instead of host as/ld
step 4  our own make/shell/coreutils
step 5  a tcc not built by gcc 13   -- blocked on seed -> tcc
```

Step 5 is last because invariant #1 forbids a committed binary, so a tcc must be
*derived*, and today the only thing that can derive one is gcc 13. The
alternative is reaching it from the seed, which is leg 1.

**Step 1 result.** All four arms confirmed the box: the loader resolves, every
bind is present, `/work` is the only writable path, and `curl` cannot reach the
network. Arm A built gcc 4.8.5 end to end inside it and ran correct aarch64.

```
A  4.8.5 vanilla, host gcc   cc1 69,481,120 B   bbbc1eef83493def
B  4.7.4 control, host gcc   cc1 14,947,952 B   f1124f574c70fb48   REPRODUCIBLE
C  4.7.4 backport, host gcc  cc1 12,807,640 B   092daecfc3065ff6
D  4.7.4 backport, tcc       cc1 18,488,473 B   ace0418a5c58b8cb
```

Smaller than the numbers elsewhere in this document because the sandboxed arms
build with `CFLAGS=-O2` and no `-g`; debug info is not codegen.

**Arm B is the repository's first reproducibility result** — two builds, same
source, same flags, same path, byte-identical cc1. That matters beyond itself:
it is the control that makes a stage2/stage3 comparison readable, since without
it a difference could mean a miscompile or merely a timestamp.

A, C and D did not reach that phase. All three exited with **rc=55** — the fib
test returns 55 on success, the script runs under `set -e`, and a non-zero status
terminates it. The success condition was ending the run. B survived only because
it targets `arm-none-eabi` and skips the block. Fixed; not yet re-run.

## Method notes worth keeping

Three of these cost real runs and are worth remembering:

- **Controls first.** The first attempt had only the experimental arm, and its
  failure was uninterpretable — 24 "failing files" that were all `libiberty`,
  `libcpp` and `libdecnumber`. With A (4.8.5 vanilla) and B (4.7.4 control)
  added, the picture inverted: **4.7.4 builds more easily in 2026 than 4.8.5**,
  which needs `CXX="g++ -std=gnu++98"` because `reload1.c` does `bool++` and
  C++17 removed that.
- **Print the structure, do not reason about it.** `config.gcc` has ten
  `case ${target} in` blocks and five "not supported" messages; three attempts
  spliced into the wrong one while reporting "3 arms spliced, cpu_type present"
  every time. Counting could not distinguish right from wrong. Selecting the
  **largest** block — the per-target dispatch carries an arm for every target
  gcc supports — is what worked.
- **A measurement that cannot fail is not a measurement.** "0 hooks used" came
  from a grep for the wrong spelling; "all five reader files identical" came
  from `diff | diffstat -s` dying on SIGPIPE with the empty result reported as
  "identical". Both needed a positive control before the number meant anything.
