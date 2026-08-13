# Roadmap — stage 3: M2-Planet to a real tcc

**Scope.** This file plans one thing: reaching an unmodified, self-hosting tcc
from M2-Planet. Everything *above* tcc — gcc, the userland, the kernel — moved
to `spikes/stage4/ROADMAP.md` when the two stages were separated.

**Status: leg 1 is well underway. See `MICRO-C.md` for its state.**

The short version: the enhanced compiler exists, is called **micro-c**, and
compiles all of tcc into a binary that runs, reports diagnostics, interns the
whole keyword table, preprocesses its own predefs and a real source file, and
is now through the preprocessor and faulting in the code generator. The
measurement below is the honest map of what the direct route required.

**Read `MICRO-C.md` for the state; this file is the PLAN and its status line
has been wrong before.** Twice now a cause recorded here as settled turned out
to be a hypothesis nobody had measured -- pointer arithmetic that does not
scale was named as the blocker for four rounds, was real, was fixed, and moved
the marker trail by nothing. The list of "largest remaining" items below is
documentation, not evidence.

**The thesis held.** The gap was measured at four missing features and turned
out to be four features plus a long tail of code generation that was wrong
rather than absent, in a compiler whose own sources never exercised it. Three
of the twenty-four patches fix upstream code that was correct for everything
its author compiled and had never been asked to compile tcc -- and a fourth,
`zza`, fixes something upstream is *entitled* to get away with: M2-Planet's own
source has globally unique labels, so a flat label namespace has never cost it
anything.

The enhanced M2-Planet exists and is called **micro-c**. It compiles the whole
of `tcc.c` -- the driver included -- assembles and links a 1.57 MB aarch64
binary, and that binary answers tcc's own `--version`, runs the twelve
end-to-end programs, matches 59 of tcc's 127 `tests2` `.expect` files, and
compiles tcc's own source back to an object. It is not self-hosting: gen2 does
not link yet, because it needs a libc. See `MICRO-C.md`. The
measurement below is still the honest map of the *gap*; what has changed is
that most of it has been closed, and the remaining problems are different in
kind — not missing language features, but wrong code generation for features
that parse fine.

The largest of those, and the reason this is not finished:

- **every integer literal is truncated to 32 bits.** `strtoint` returns `int`
  and micro-c is built by gcc, so it cannot represent a 64-bit constant in the
  source it compiles. tcc's `parse_number` therefore marks every constant it
  reads as unsigned. The missing M1 instructions landed in
  `patches/m2libc/0005`; the emitter change is the next rung
- **`int` is eight bytes**, so every struct micro-c lays out differs from a
  normal ABI
- **one rule has many implementations.** `emit_out(load_value(...))` appears 19
  times in `cc_core.c` with a different subset of guards at each site, and the
  "is this an lvalue" question is asked in eight places — three of which have
  been found missing a case the others had, one per round. That class has now
  cost more than every missing feature put together

*(Pointer arithmetic that does not scale was the third item here for several
rounds. It is closed — `EXPERIMENT-zz7` — and it was never the blocker.)*

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

## FIXED: the bootstrap compiler stored a double where an x87 long double belongs

`patches/tcc-microc/0007`. The section after this one is the earlier account,
kept because its measurements are real even though the conclusion it reached was
wrong twice over.

**The fault.** Patch 0005 added the branch for a host whose `long double` is
narrower than the target's, and made it copy:

    else if (sizeof(long double) < LDOUBLE_SIZE)
        memcpy(ptr, &vtop->c.ld, sizeof(long double));

x86_64-tcc's `long double` is an eight-byte IEEE double, because mc-tcc built it
and patch 0001 sets `LDOUBLE_SIZE 8`. The x86_64 target's is x87 80-bit
extended. Different **representations**, not just different widths.

**Where it bites.** musl's `floatscan.c` accumulates decimal digits with
`y = 1000000000.0L * y + x[...]`. That constant came out as the eight-byte
double `65cdcd41` instead of `…00286bee1c40`, so `decfloat` multiplied by
garbage. Small integers survived because `decfloat` returns them from its fast
path without touching it -- which is why `1.0`, `3.0` and `1024.0` looked fine
while `0.5` and `0.1` did not.

**The chain.** Broken musl `strtod` → tcc linked against it misparses every
decimal literal → gcc built by that tcc holds `M_LOG10_2` as `1.27e-12` → `cc1`
dies at `real.c:1724` → rung 6 fails.

**Verified end to end, locally, from stage 0.** The whole seed was rebuilt from
the vendored sources -- micro-c (M2-Planet + 76 patches), M1 and hex2 with the
`max_string` raise, mc-tcc (its `.M1` part sizes match the seed log exactly at
20750 and 14772 lines), an aarch64 musl with `rungs.sh`'s `bits/float.h`
rewrite, x86_64-tcc, an x86_64 musl, then tcc-x86_64. Twice, differing only in
whether 0007 was applied:

| | without 0007 | with 0007 |
|---|---|---|
| `0.5` | `0x1.9796cp-35` -- byte for byte what the shipped binary gives | `0x1p-1` |
| `M_LOG10_2` | `1.266209359584991e-12` | `ff799f501344d33f` |

**Both halves are needed.** A fixed x86_64-tcc linked against a musl built by
the *unfixed* one still gives wrong answers -- the broken `floatscan` is already
baked into that libc. The correction lands only once the fixed compiler builds
the libc too, which is what the ladder does anyway. An earlier attempt looked
like a failure for exactly this reason.

**Not claimed.** Rungs 6 and beyond have not been run with this patch.

## The bootstrap compiler miscompiles one assignment, and both ladders stop there

`patches/tcc-arm64-asm/0010` works around it. The defect itself is not fixed and
this is the record of what is known.

**The symptom.** rung 6 of the hermetic amd64 ladder fails with

    <built-in>:0:0: internal compiler error: in ?, at real.c:1724

reproducible with `cc1 -E -dM /dev/null`, which is what configure runs. gcc's
`M_LOG10_2` is compiled in as `1.266209359584991e-12` instead of
`0.30102999566398119521`, so every decimal exponent real.c estimates is nonsense.

**Reproduced directly.** `work/ref-tcc` from the compiler-under-test artifact --
the tcc that built that gcc -- gets decimal float literals wrong on demand:
`0.5` becomes `0x1.9796cp-35`, `123456789.0` becomes `0x1.4af7p-10`. But `0.0`,
`1.0`, `2.0`, `3.0`, `10.0` and `1024.0` are right, and so is the HEX spelling
of the same number: `0x1p-1` gives exactly `0.5`.

**What was ruled out, each by test rather than by reading:**

| suspect | how it was cleared |
|---|---|
| musl's `strtod` | `floatscan.o` lifted from the ladder's own `libc.a` and linked into a gcc-built musl in place of its own -- every value correct, including 0.5, 0.1 and 123456789.0 |
| x87 long double arithmetic | divide, multiply, an accumulating loop and `(long double)unsigned` all bit-identical between ref-tcc and gcc |
| the target model | `sizeof(long double)` is 16, and musl's own configure agrees the compiler's definition matches float.h |
| the tcc source | a tcc built from this exact patched tree by a host gcc emits the constant correctly, and so does a tcc built by THAT tcc -- x86_64 self-hosting is clean |

**What is at fault.** The two literal paths in `tccpp.c` differ in one way:

    hex      d = strtod(hbuf, 0);  ...  tokc.d = (double)d;   via a local, works
    decimal  tokc.d = strtod(token_buf, NULL);                direct, broken

Same working strtod. Only the direct assignment of a returned double into the
`CValue` union is mishandled, and the mishandling is in the ref-tcc BINARY --
put there by **x86_64-tcc**, which runs on aarch64 and is itself built by
mc-tcc. That is the same leg the `signed char` imm8 bug came from.

**What is still open.** x86_64-tcc's code generation is still wrong for this
construct, and anything else assigning a floating return value straight into a
struct or union member will hit it. Finding it needs mc-tcc and x86_64-tcc run
under qemu-aarch64; both now travel with the seed handoff and neither has been
examined.
