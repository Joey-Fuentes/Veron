# Roadmap — the direct path (separate investigation track)

**Status: proposed, not started.** The Mes → tcc → gcc route continues in
parallel; nothing here replaces it yet. This file records the plan and, more
importantly, *which parts of the received wisdom we intend to test rather than
accept*.

The destination:

```
our toolchain -> enhanced M2 -> REAL tcc -> simplified gcc -> real Linux
```

---

## The thesis

Much of what the bootstrap ecosystem does is **incidental** complexity — build
plumbing, submodule sprawl, kaem scripts calling kaem scripts, utilities that
exist to untar and string-replace. Some of it is **forced** — real capability
gaps between rungs. The two get conflated because they arrive together. This
track separates them, and removes only the first.

**Measure, don't estimate.** `TARGET-SUBSET.md` §2 derived stage 2's required
feature set mechanically from pinned source instead of guessing, and that is why
it was right. Every leg below starts with a measurement spike that enumerates
real failures, not an opinion about difficulty.

---

## Leg 1 — enhanced M2-Planet builds REAL tcc

> **Update 2026-07-24.** The *upper* end of this leg is now proven independently
> of how tcc is reached: a tcc-built musl + BusyBox userland boots as PID 1
> (see `TCC-USERLAND.md`). That does not build tcc from M2-Planet — it assumes
> a tcc — but it settles what a real tcc is worth once you have one, and it
> retires the guesswork about tcc's aarch64 backend: it self-hosts, assembles
> all of musl's aarch64 asm, and compiles 401 BusyBox applets.
>
> It also supplies the **known-good tcc binary** this leg's validation section
> below asks for, ahead of schedule.

**Goal.** Skip Mes entirely. Grow M2-Planet until it compiles unmodified
tcc, not live-bootstrap's patched-and-reduced 0.9.26.

**Why Mes exists** (so we know what we are taking on): M2-Planet's C subset is
deliberately tiny; tcc needs far more C than that. MesCC — a C99 front end in
Scheme, running on an interpreter small enough for M2-Planet to compile — is the
bridge. Removing it means writing a compiler that spans the whole gap.

**Expected gap, to be confirmed by measurement:**

| feature | why tcc needs it |
|---|---|
| varargs | `printf`/`fprintf`-style calls throughout |
| floating point | tcc parses and constant-folds floats, so its *own source* does double arithmetic — likely the hardest item |
| real preprocessor | `#define`/`#if`; ours is minimal and `--bootstrap-mode` does not expand object-like macros (open as m75) |
| aggregate initializers, struct-by-value | tcc's tables and node structures |

**First spike:** run M2-Planet over real tcc's source and report failure classes
with counts. Cheap, decisive, useful even if the leg is never built.

**Look at M2-Mesoplanet first.** stage0-posix pins it at `4b011a85`. It is
M2-Planet plus a real preprocessor and driver — if it closes half the gap, the
remaining work is much smaller than starting from M2-Planet.

**Validation without upstream checksums.** Every gate that has moved this
project was an upstream published number (`proof.answer`, `62895fcf…` for
mes-m2). A custom chain produces artifacts nobody else produces, so those
disappear — but the replacements are *stronger*, not weaker:

- **tcc self-compiles.** Build tcc with enhanced-M2, have that tcc rebuild tcc,
  and again. That is the same G1/G2/G3 fixpoint test that proved the hand-off.
  A compiler that is a fixpoint of itself and passes tcc's own test suite is
  strong evidence independent of anyone's checksum.
- Keep the Mes path green in parallel so there is a **known-good tcc binary** to
  diff against when this route produces its own.

---

## Leg 2 — simplified gcc

**One thing here is genuinely load-bearing and must not be collapsed:**
**gcc 4.8 switched its own implementation language to C++.** Everything ≤ 4.7
builds with a C compiler; ≥ 4.8 needs a C++ compiler. The old-gcc/new-gcc dance
is not plumbing — it is the reason you can reach a C++-capable gcc at all. Gut
the build system around it; keep the step.

> **Update 2026-07-24 — on aarch64 the dance does not work as written.**
> `gcc-entrypoint-probe` measured both boundaries and they are the *same
> version*: 4.7 has no aarch64 anywhere (config.guess 0, config.sub 0,
> config.gcc 0, `config/` has arm only), and 4.8 — which does have it — enforces
> CXX in its `gcc/` subdirectory configure. There is no release that both
> targets our architecture and builds with a C compiler.
>
> **A fifth escape, not in the probe's original list of four.** Every gcc up to
> 4.7 is written in C, which is exactly what the 4.8 boundary means — so 4.7
> yields not just a C compiler but **`g++` 4.7, a full C++98 compiler built from
> C**. And 4.8 asks only for "an ISO C++98 compiler". The single thing wrong
> with 4.7 here is a missing backend, and a gcc backend is a self-contained
> directory plus `config.gcc`/`config.sub` entries:
>
> ```
> tcc -> gcc 4.7 + backported aarch64 backend -> g++ 4.7 -> gcc 4.8 -> modern
> ```
>
> This is the only route that stays native **and** C-only end to end. Every
> other option either reintroduces the cross-architecture detour the direct path
> exists to delete, or leaves us maintaining a C fork of gcc 4.8 against its own
> build system.
>
> **Its cost is the backend↔middle-end interface delta between the two
> releases**, and that is measurable without doing the work:
> `gcc-backend-backport-probe.yml` diffs the *existing* arm backend across
> 4.7→4.8 as a control — arm absorbs exactly the churn a backported aarch64
> would — with `vax` as a control for the control, since nobody was developing
> vax, so its delta is close to pure interface change. It then counts how many
> target hooks new in 4.8 the aarch64 backend actually uses.
>
> **It measures 4.8.0 and 4.8.5, not one of them.** 4.8.0 is the release the
> aarch64 port landed in and therefore the minimum interface distance from 4.7 —
> diffing against 4.8.5 would conflate the port with four point releases of
> unrelated 4.8 development. But 4.8.5 is the last and most bug-fixed of the
> series and the likelier eventual build target. The probe also diffs the
> aarch64 backend 4.8.0→4.8.5, which decides *which* version to backport: a
> small delta means take 4.8.0's backend for the shorter distance, a large one
> means the initial port was buggy and 4.8.5's is worth the wider gap.
>
> Measure before picking, per this file's own rule.
>
> **MEASURED, run #1 (2026-07-24).** The control answers clearly:
>
> ```
> vax  4.7.4 -> 4.8.0 :  15 files,   76 +,   72 -      ~148 lines, whole backend
> vax  4.7.4 -> 4.8.5 :  15 files,   76 +,   72 -      IDENTICAL
> arm  4.7.4 -> 4.8.0 :  97 files, 8796 +, 5050 -      thumb2.md, vfp.md, unspecs.md
> aarch64 backend     :  28 files, 46,073 lines (36k C/H + 9.3k .md)
> aarch64 4.8.0->4.8.5:  14 files, 1035 +,  774 -
> ```
>
> **The backend↔middle-end interface barely moved across the C-to-C++ boundary.**
> An entire backend nobody was developing needed ~148 lines of adaptation. arm's
> 14,000-line delta is arm's own development — thumb2, VFP, a new `unspecs.md` —
> which is exactly what the vax control exists to separate out.
>
> **And it decides which 4.8 to take.** vax's delta is *identical* at 4.8.0 and
> 4.8.5, so the interface did not move at all within the 4.8 series. 4.8.5's
> backend is therefore no further from 4.7 than 4.8.0's, and it carries ~1,800
> lines of fixes to a port that was one release old. **Backport 4.8.5's
> `gcc/config/aarch64/`, not 4.8.0's.**
>
> **MEASURED, run #2 — the interface dependency is nil.**
>
> ```
> target hooks new in 4.8 : 21
> used by the aarch64 backend : 0
> positive control        : legitimate_address_p 4 files, function_value 1,
>                           rtx_costs 2   <- the search finds hooks when present
> ```
>
> Run 1's 0 was unsafe — it searched the lowercase `target.def` spelling
> (`add_stmt_cost`) while a backend writes `TARGET_VECTORIZE_ADD_STMT_COST`, so
> the grep would return 0 either way. Re-measured case-insensitively with a
> control that proves the search works. **The answer really is 0.**
>
> The 40 symbols the backend references that 4.7 lacks also classify away
> entirely:
>
> | count | kind |
> |---|---|
> | 30 | `gen_*` — emitted by `genemit` from the backend's **own** `.md` files |
> | 1 | `ggc_alloc_cleared_machine_function` — emitted by `gengtype` from its own GTY markers |
> | 9 | backend-local statics that simply lack the `aarch64_` prefix (`emit_set_insn`, `sizetochar`, `offset_9bit_signed_unscaled_p`, …) |
>
> **Not one is a middle-end feature 4.7 lacks.** Every one is supplied by the
> backend itself or generated from it — which is also a nice confirmation of
> this file's own point that gcc's generator programs are real structure.
>
> `gcc47-aarch64-backport.yml` now attempts the transplant for real and prints
> the failure inventory. It builds with the **host gcc** — one variable at a
> time; whether *tcc* builds the result is the question after.

**What can go:** autotools. One target, one language, one configuration — a
hand-written driver replaces `configure` entirely.

**What cannot go:** gcc's **generator programs** (`genemit`, `genattrtab`, …)
read the machine-description files and emit C that is then compiled. That is
real structure, and any hand-rolled build must reproduce it. Tedious, mechanical,
knowable.

**Built-in gate:** gcc's 3-stage bootstrap already requires stage2 and stage3 to
compare **byte-identical**. gcc insists on exactly the property we would want to
prove, using its own machinery. Free, and strong.

---

## Leg 3 — real Linux, minimally

**Linux is the best case in the stack for this argument, better than gcc.**
The kernel has **no autotools** — no `configure`, no libtool, no aclocal. Plain
Make plus its own `scripts/`. The entire m4/autoconf tower that makes everything
else sprawl simply does not apply.

**Received dependencies, and how real each is:**

| claimed dep | reality |
|---|---|
| **perl** | was `kernel/timeconst.pl`; **removed in 3.19**, replaced by a `bc` script. Remaining perl is `checkstack.pl`, `kernel-doc` — diagnostics, not the build. Near non-dependency depending on version. |
| **bison/flex** | the real one — builds `scripts/kconfig`, and `syncconfig` turns `.config` into `include/generated/autoconf.h`. That is a mechanical transform, so generating `autoconf.h` directly may sidestep kconfig entirely. |
| **libssl** | module signing — config-gated |
| **libelf / objtool** | ORC unwinder — config-gated |
| **pahole** | BTF — config-gated |
| **rsync** | some install targets only |

**Honest floor:** `make`, a C compiler, binutils (`as`, `ld`, `ar`, `objcopy`),
`sh`, basic coreutils, `bc`, and a way to produce `autoconf.h`. Everything else
is a config choice or a version choice.

**Two caveats.** The kernel builds **host tools** during the build — `scripts/`
compiles programs that run on the build machine — so the compiler must handle
those too, a second target. And **compiling Linux is not running Linux**: a
kernel with no userland boots to a panic. A booting system needs at minimum an
init and a shell, which is a separate and much smaller problem than
live-bootstrap's step count suggests.

**First spike:** pin a kernel version, take `tinyconfig`/`allnoconfig` plus a
minimal `defconfig`, build against a deliberately bare environment, and let the
failures enumerate themselves.

> **Update 2026-07-24 — the userland half is DONE.** `tcc-userland-arm64` proves
> the second caveat above ("compiling Linux is not running Linux") can be split
> from the first: a tcc-built musl + BusyBox userland boots as PID 1 on a
> GCC-built kernel, because the syscall ABI is the contract. See
> `TCC-USERLAND.md`.
>
> **What that leaves for this leg**, now sharper than when it was written:
>
> - **The kernel build itself is still not attempted.** Ubuntu's kernel is
>   borrowed. Building `arch/arm64/configs/defconfig` from a pinned tree with
>   the host gcc is the next step, and it also replaces the UAPI headers
>   currently borrowed from `linux-libc-dev` via `make headers_install`.
> - **`IS_ENABLED()` will be the wall.** The userland leg found exactly one real
>   tcc capability gap — **no dead-code elimination** — and the kernel leans on
>   `if (IS_ENABLED(CONFIG_FOO))` far more heavily than BusyBox does. Expect
>   this to dominate, not the header/plumbing issues.
> - **`asm goto` with outputs, jump labels, linker scripts** remain untested
>   claims. They gate a tcc-built kernel, not a gcc-built one, so they do not
>   block the pinned-kernel step above.

---

## Sequencing

0. ~~Get a working tcc userland~~ **done** — `TCC-USERLAND.md`. Yields the
   known-good tcc binary that step 1 was wanted for.
1. **Finish the Mes path to a green tcc.** Three rungs out. Its value is now
   narrower: the userland result already supplies a reference tcc, so this is
   about reaching tcc *from the seed*, not about having one.
2. **Leg 1 measurement spike** — M2-Planet over real tcc, failure classes with
   counts. Check M2-Mesoplanet first.
3. **Leg 2** — gut the gcc build, keep the 4.7→4.8 step.
4. **Leg 3** — minimal kernel config against a bare environment.

## The rule this track runs on

*Eliminate accidental complexity; do not eliminate capability jumps.* Build
plumbing is genuinely disposable. Layer count mostly is not — each rung is small
enough to audit, and that is the point of a bootstrap. Where this track removes
a layer, it must replace the lost gate with a self-validating one (self-compile
fixpoint, 3-stage compare) rather than with an assurance.


---

## Leg 2, measured — the gcc arms (2026-07-24)

Three arms, run identically, host gcc throughout
(`.github/workflows/gcc47-aarch64-backport.yml`):

| arm | what | configure | build | cc1 |
|---|---|---|---|---|
| A | 4.8.5 vanilla, target aarch64 | rc=0 | rc=2 | **no** |
| B | 4.7.4 + config.sub/guess only, target arm-none-eabi | rc=0 | **rc=0** | **BUILT** |
| C | 4.7.4 + aarch64 transplant, target aarch64 | **rc=0** | rc=2 | no |

**B is the result that matters so far: gcc 4.7.4 builds a working `cc1` on
aarch64 in 2026.** The C-era compiler builds *more easily* than the C++-era
one, which is the opposite of the intuition and is precisely why the control
arm exists. Its earlier apparent failure was `doc/gccint.info` —
`sourcebuild.texi:679: @itemx should not begin @table`, 2026's makeinfo
rejecting 2012's texinfo — documentation, not a compiler. With `MAKEINFO=true`
it is a clean pass.

**A's failure is the language moving, not the architecture.** gcc 4.8.5's
`reload1.c` does `spill_indirect_levels++` where that expands to a `bool`:

```
error: use of an operand of type 'bool' in 'operator++' is forbidden in C++17
```

Modern g++ defaults to `gnu++17`. Building 4.8.5 needs
`CXX="g++ -std=gnu++98"`. Worth recording independently of this leg: **any**
attempt to build a 4.8-era gcc in 2026 hits this.

**C got through configure**, which means the `config.gcc` transplant is
structurally right — 4.7.4 accepted `--target=aarch64-unknown-linux-gnu` and
ran the gcc subdirectory configure. It then failed inside that configure, and
the reason was not captured: a failing `configure` writes to `config.log`, and
the inventory step was aborting early anyway because it lacked `set +e` while
deliberately re-running a failing command under `bash -e`.

Nothing here yet contradicts the backport thesis. What it does show is that
**the C-only route's foundation is real** — 4.7.4 builds — and that A's
obstacle is a two-word configure flag rather than anything structural.

### config.gcc's real shape (2026-07-24)

Three attempts put the aarch64 dispatch arms in the wrong place because I
reasoned about `config.gcc`'s structure instead of printing it. The map:

```
case ${target} in : 250 281 342 523 546 556 805 2667 2706 3559
*** Configuration : 270 331 2086 2662 3148
esac              : 276 334 506 543 550 803 2665 2676 2698 2900 2974 3555 3684
```

**Ten `case ${target} in` blocks and five "not supported" messages.** Anchoring
on the *first* message put the arms in the block at 281..334 — which is the
`cpu_type` table, right for that one arm and wrong for the other two. The real
per-target dispatch is **805..2665, 1860 lines**, owning the catch-all at 2662.

The rule that works is structural: parse every `case ... esac` block and take
the **largest** — the dispatch carries an arm for every target gcc supports, so
it is bigger than the rest by more than an order of magnitude. The `cpu_type`
table is identified by the block that assigns `cpu_type=`.

Two lessons worth keeping, both already in this repo's method note:

- *Counting proved nothing.* "3 arms spliced, cpu_type present" was true in
  every failing run. Only the block structure could distinguish right from wrong.
- *A shell fragment can be tested directly.* `config.gcc` is sourced by
  `gcc/configure`; sourcing it in the transplant step with the same variables
  gives the answer in seconds instead of after a 40-minute build. Two traps
  there: `$( . file )` runs in a subshell so every variable it sets is lost, and
  `exit` inside a sourced file kills the shell, so the check must read a
  captured file from the parent.

### The transplant configures. The failure moved to the machine description.

Run 6 of `gcc47-aarch64-backport`:

```
configure  rc=0            <- 4.7.4 accepts --target=aarch64-unknown-linux-gnu
generators genemit genattrtab genrecog genextract genoutput genpreds  ALL BUILT
compiler   0 errors, 471 warnings
objects    264
failures   s-preds  s-conditions  s-preds-h  s-constrs-h
```

Three things follow.

**The `config.gcc` transplant is correct.** Configure passing means the dispatch
arms are in the right block and 4.7.4 knows the target. That question is closed.

**No C failed to compile.** Zero compiler errors across 264 objects. Whatever
the middle-end interface drift is, it is not showing up as broken C — which is
what the vax control (~148 lines) predicted.

**The failing targets are generator RUNS, not generator builds.** `s-preds` is
`genpreds` reading `predicates.md`; `s-conditions`, `s-preds-h`, `s-constrs-h`
are the same shape. Every generator compiled and linked; they fail on aarch64's
machine description. That is the layer this spike's verdict table called "the
.md files need porting -- real work, but bounded and knowable", and it is the
most informative place the failure could have landed.

What the run could not say is *what* the generators objected to, for three
reasons since fixed: the inventory greps for `error:` and generators report
`file.md:LINE:`; the serial rebuild ran `make s-preds` at the top level where
that target does not exist (it is a `gcc/` subdirectory target); and the
config.gcc source-proof died on `gas_flag: unbound variable` because the
subshell inherited `set -u` and config.gcc is not written to be `-u` clean.

### The blocker, named: `define_int_iterator`

Run 7 got the generators to run and they said exactly one thing:

```
config/aarch64/iterators.md:664: unknown rtx code `define_int_iterator'
  following context is `MAXMINV [UNSPEC_UMAXV UNSPEC_UMINV'
```

`define_int_iterator` and `define_int_attr` are **machine-description language
features added in gcc 4.8**. They let one `.md` pattern stand for a family of
UNSPEC codes, and aarch64's `iterators.md` leans on them heavily for NEON.

This is a precise and encouraging place to be stuck:

| layer | status |
|---|---|
| `config.gcc` / target recognition | **works** — configure rc=0 |
| target hooks | **works** — the backend uses 0 of the 21 new in 4.8 |
| backend C | **works** — 0 compiler errors across 264 objects |
| generator programs | **build** — all six |
| **machine-description language** | **the gap** — 4.7's reader lacks one construct |

The interface measurement was right: nothing about the backend's *code* needs
4.8. What needs 4.8 is the `.md` **dialect**.

**Two ways past it, and `SIZE THE NEXT FIX` measures both:**

1. **Teach 4.7's generators the construct** — `read-rtl.c`, `rtl.def`,
   `gensupport.c`. Principled, fixes it for any backend, and bounded by the
   4.7→4.8 delta of those three files.
2. **Expand the iterators in our copy of aarch64's `.md`** — mechanical text
   expansion, touches nothing outside the backend we already vendor.

Do not pick before the numbers land. Option 1 is the honest one if it is small;
option 2 keeps the change inside a directory we already treat as ours.

### Sizing the two fixes — run 8's numbers, and one that was wrong

What run 8 did establish, from the `.md` side:

```
aarch64 files using the construct : iterators.md only
define_int_iterator uses          : 20
define_int_attr uses              : 14
```

So the whole 4.8-only dialect surface in this backend is **34 definitions in one
file** — a much smaller target than the backend's 46,000 lines.

What it did **not** establish: the RTL reader delta. It reported `read-rtl.c`,
`gensupport.c`, `rtl.def`, `read-md.c` and `read-md.h` all "identical", which
cannot be true of a release that introduced a new `.md` construct. The command
was `diff -u a b | diffstat -s`: `diffstat -s` closes the pipe early, `diff`
dies on SIGPIPE, and `${d:-identical}` turned the resulting empty string into a
confident claim. **The Broken pipe messages were right there in the log next to
each "identical".**

Same failure shape as the earlier "0 hooks" reading: a measurement that cannot
distinguish *no difference* from *no measurement*. It now diffs to a file,
reports `cmp -s` byte-identity separately from a real delta, and counts how many
changed lines mention int iterators.

The `<ITERATOR>` reference count was also misleading — 1,938 counts `<mode>`,
`<MODE>` and every code iterator, which 4.7 already supports. Only references to
the 34 int-iterator names matter for option 2, and those are now counted by name.

### Both fixes sized (2026-07-24)

```
OPTION 2  expand the int iterators in our vendored .md
  files affected        iterators.md, one
  definitions           34   (20 define_int_iterator + 14 define_int_attr)
  references            81
  touches upstream      nothing

OPTION 1  teach 4.7's generators the construct
  read-rtl.c    +514 -300  29 hunks
  gensupport.c  +964   -9  21 hunks
  rtl.def        +14  -13   7 hunks
  read-md.c      +27  -17   3 hunks
  read-md.h       +3   -3   2 hunks
```

**Option 2 is the smaller and better-bounded change**, and it lands inside a
directory this project already vendors and reviews. 34 definitions, 81
references, one file.

**Option 1's number is not trustworthy and should not be quoted.** Only 4 of
~1,500 changed lines literally mention int iterators, which does not mean the
feature is four lines — it means 4.8 implements it through a generic
`iterator_group` abstraction whose names the grep cannot see. The true cost sits
somewhere between 4 and 514 lines of `read-rtl.c` and this measurement cannot
narrow it. Saying so is the honest reading; picking option 1 on the strength of
"4 lines" would be exactly the kind of unmeasured estimate this track exists to
avoid.

**Recommendation: option 2, via a reviewable expander.** `define_int_iterator`
expansion is mechanical — a pattern using an iterator with N values becomes N
patterns, with `define_int_attr` supplying the per-value substitutions. That is
precisely what `read-rtl.c` does internally, and writing it as a small tool
matches what `tools/drop_asm.py` already does for the stage-2 substitution: a
named, reviewable delta rather than a fork of upstream.

The result would be a `.md` in 4.7's dialect, produced by a tool whose output
can be diffed against the original, with the substitution declared in the
ledger like every other.
