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
