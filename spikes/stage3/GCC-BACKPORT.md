# gcc 4.7 + gcc 4.8's aarch64 backend — the entry point to the gcc leg

**Status: the compiler builds and produces correct aarch64 code, 2026-07-24.**

```
configure rc=0    build rc=0    cc1 BUILT (55,044,256 bytes)

cc1 emits:   stp  x29, x30, [sp, -48]!
             cmp  w0, 1
             ble  .L4
assembled:   ELF 64-bit LSB relocatable, ARM aarch64
ran:         exit=55            (fib(10) = 55)
```

Gated by `.github/workflows/gcc47-aarch64-backport.yml`, arm `C-474-backport`.

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

## What this does NOT show

- **libgcc is not built.** The arms run `make all-gcc`, which stops before the
  runtime, so `gcc/xgcc` cannot link a program: `cannot find crtbegin.o`,
  `cannot find -lgcc`. `cc1` is exercised directly instead — emit assembly,
  assemble with the system `as`, link, run. A full `make` is the next step.
- **tcc has not built this tree.** Every arm uses the host gcc: one variable at
  a time. `gcc-entrypoint-probe` already cleared the previous blocker by
  building gmp, mpfr and mpc under tcc.
- **g++ 4.7 has not built 4.8.** That is the next rung, and the entire reason
  for choosing 4.7.
- **No reproducibility gate.** Pinned but not yet rebuilt byte-identically
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
