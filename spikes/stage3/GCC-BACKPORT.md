# gcc 4.7 + gcc 4.8's aarch64 backend — the entry point to the gcc leg

**Status: the compiler builds and produces correct aarch64 code, and tcc builds
it. 2026-07-25.**

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

**Two independently built cc1 binaries emit the same code.** The host-gcc-built
cc1 (55,044,256 B) and the tcc-built one (80,016,473 B) each produced 44 lines
from the same input, identical across every line captured in both logs. That is
diverse double compilation in miniature — two unrelated compilers, one source,
one output — and it is the strongest correctness signal here, because a cc1 that
merely *links* proves nothing about whether tcc miscompiled it. The size gap is
tcc's lack of an optimiser, not a difference in the compiler's behaviour.

It is not yet a *proof*: the two `.s` files were produced in different jobs and
have never been byte-compared in one place. Doing that is cheap and is the
obvious next gate.

## What this does NOT show

- **libgcc is not built.** The arms run `make all-gcc`, which stops before the
  runtime, so `gcc/xgcc` cannot link a program: `cannot find crtbegin.o`,
  `cannot find -lgcc`. `cc1` is exercised directly instead — emit assembly,
  assemble with the system `as`, link, run. A full `make` is the next step.
- **Only `cc1`, and only C.** Both arms configure `--enable-languages=c`, so
  **g++ 4.7 has never been built by anything** — and g++ 4.7 is the entire
  reason 4.7 was chosen over 4.8. All of gcc 4.7 is C, including its C++ front
  end, so this should follow; "should" is not "does". This is the next rung.
- **The two `.s` files have not been byte-compared.** Identical across every
  line both logs captured, but produced in different jobs. One job emitting both
  and running `cmp` would turn a strong signal into a result.
- **No reproducibility gate.** The gcc tarballs are now pinned by hash
  (`sources/gcc.toml`), but nothing here has been rebuilt byte-identically
  twice.

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
