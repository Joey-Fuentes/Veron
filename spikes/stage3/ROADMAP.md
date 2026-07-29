# Roadmap — stage 3: M2-Planet to a real tcc

**Scope.** This file plans one thing: reaching an unmodified, self-hosting tcc
from M2-Planet. Everything *above* tcc — gcc, the userland, the kernel — moved
to `spikes/stage4/ROADMAP.md` when the two stages were separated.

**Status: leg 1 is well underway. See `MICRO-C.md` for its state.**

The enhanced M2-Planet exists and is called **micro-c**. It compiles the whole
of `libtcc.c`, assembles and links a 1.45 MB aarch64 binary, and that binary
runs far enough to reach tcc's preprocessor before faulting. The measurement
below is still the honest map of the *gap*; what has changed is that most of it
has been closed, and the remaining problems are different in kind — not missing
language features, but wrong code generation for features that parse fine.

The largest of those, and the reason this is not finished:

- **`int` is eight bytes**, so every struct micro-c lays out differs from a
  normal ABI
- **pointer arithmetic does not scale** — `p + n` advances n bytes, not n
  elements
- **one rule has nineteen implementations.** `emit_out(load_value(...))` appears
  19 times in `cc_core.c` with a different subset of guards at each site; four
  bugs this session were one site missing a condition another site already had

---

## The thesis

Much of what the bootstrap ecosystem does is **incidental** complexity — build
plumbing, submodule sprawl, kaem scripts calling kaem scripts, utilities that
exist to untar and string-replace. Some of it is **forced** — real capability
gaps between rungs. The two get conflated because they arrive together. This
track separates them, and removes only the first.

**Measure, don't estimate.** `../stage2-pico-c/TARGET-SUBSET.md` §2 derived stage 2's required
feature set mechanically from pinned source instead of guessing, and that is why
it was right. Every leg below starts with a measurement spike that enumerates
real failures, not an opinion about difficulty.

---

---

## Leg 1 — enhanced M2-Planet builds REAL tcc

> **Update 2026-07-24.** The *upper* end of this leg is now proven independently
> of how tcc is reached: a tcc-built musl + BusyBox userland boots as PID 1
> (see `../stage4/TCC-USERLAND.md`). That does not build tcc from M2-Planet — it assumes
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

### MEASURED, 2026-07-25 — the gap is four features, not a rewrite

`m2-tcc-gap-probe`, static half: tcc at pin `5ec0e6f8`, comments and literals
stripped by a character-level state machine, every construct counted.

| construct | uses in tcc | M2-Planet 1.13.1 |
|---|---|---|
| ternary `?:` | 405 | **ABSENT** |
| `float`/`double` declarations | 38 | **keyword only — no `new_primitive`, so no type** |
| floating literals | 17 | needs constant folding |
| bitfields | ~84 | **ABSENT** |
| stack aggregate init `= {` | 89 | globals fine; **stack arrays refused outright** |
| `long long` | 39 | present |
| `union` | 27 | present |
| `switch` | 196 | present |
| `goto` | 509 | present |
| varargs `...` | 18 | present (`__va_start`/`__va_arg`/`__va_end`/`__va_copy`) |
| `typedef` | 126 | present |
| compound assignment | 970 | present |
| `++` / `--` | 1122 | present |
| inline `asm` | 1 | present |
| computed `goto` | **0** | absent — and not needed |
| `_Generic` | **0** | absent — and not needed |
| `_Atomic` | **0** | absent — and not needed |

**The expected-gap table above was wrong in three places, and the corrections
all point the same way.**

- **varargs is not a gap.** M2-Planet 1.13.1 implements `__va_start`, `__va_arg`,
  `__va_end` and `__va_copy`. tcc uses `...` 18 times.
- **Floating point is far smaller than feared.** This file called it "likely the
  hardest item". It is **38 declarations and 17 literals**, concentrated in
  `tccgen.c` (15), `tccpp.c` (12) and `tcc.h` (8). The worry was that tcc
  constant-folds floats so its own source does double arithmetic — 17 literals
  suggests a much narrower requirement than implementing IEEE 754. Confirm what
  those 17 actually do before scoping it.
- **Two gaps were missing from the list**: the ternary operator (405 uses, zero
  support — `cc_core.c` contains no `"?"` at all) and bitfields (~84, clustered
  in `tcc.h`).

**What M2-Planet actually implements is much larger than `../stage2-pico-c/TARGET-SUBSET.md`
§3–§4 suggests**, because that section documents what its *self-host uses*. Read
from the pinned source, the type table alone carries `void`, `char`,
signed/unsigned `char`, `_Bool`, `short`, `int`, `long`, `long long`, the
`intN_t` family, `size_t`, `ssize_t`, `FILE`, `FUNCTION` and `__va_list`, plus
`struct`, `union`, `enum`, `typedef`, stack struct arrays, `switch`/`case`,
`do`/`while`, and global struct initializer lists.

**Two things this measurement does NOT support, stated so nobody builds on
them.**

- **The 1,149 "designated initializers" figure is wrong** and has been dropped
  from the table above. The probe matched `\.\w+\s*=` and `\[\d+\]\s*=`, which
  also match every ordinary `s.field = x` and `arr[0] = y` in the codebase.
  Counting real designated initializers needs a parser, not a regex. The same
  caveat applies to the struct-by-value probes, which returned 0 from a
  deliberately weak heuristic and should be read as "unmeasured", not "absent".
- **The empirical half measured nothing.** All 26 files reported
  `line 7: : command not found` — `$M2` was empty because the preceding `find`
  did not locate the binary, so every command line began with a bare `:`.
  M2-Planet never ran. Until that is fixed there is no compiler-side
  corroboration of any number above.

**Read as a scope estimate:** four features, three of them small (ternary is one
grammar rule and one branch emission; stack array initialization is a stack
write loop; float/double may be narrow), one fiddly (bitfields), against a
compiler that already has everything else. That reads as weeks rather than
months — but it rests on one uncorroborated static pass and one broken probe, so
it is a hypothesis with numbers attached, not a plan.

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

## Sequencing

1. **Finish the Mes path to a green tcc.** Three rungs out. Its value is now
   narrower than when it was written: stage 4's userland result already supplies
   a reference tcc binary, so this is about reaching tcc *from the seed*, not
   about having one at all.
2. **Check M2-Mesoplanet first.** stage0-posix pins it at `4b011a85`. It is
   M2-Planet plus a real preprocessor and driver; if it closes half the gap, the
   remaining work is much smaller than starting from M2-Planet.
3. **Fix the empirical half of the gap probe** (see above — it measured nothing)
   so there is compiler-side corroboration of the static counts.
4. **Grow M2-Planet over the four measured features**, ternary first.

## The rule this track runs on

*Eliminate accidental complexity; do not eliminate capability jumps.* Build
plumbing is genuinely disposable. Layer count mostly is not — each rung is small
enough to audit, and that is the point of a bootstrap. Where this track removes
a layer, it must replace the lost gate with a self-validating one (self-compile
fixpoint, 3-stage compare) rather than with an assurance.
