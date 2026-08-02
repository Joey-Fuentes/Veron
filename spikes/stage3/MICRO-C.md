# micro-c — the direct route from M2-Planet to tcc

**What this is.** `ROADMAP.md` leg 1 proposed enhancing M2-Planet until it can
compile tcc directly, rather than reaching tcc through Mes. That enhanced
compiler is called **micro-c**: M2-Planet at pin `bd2fe4b` plus a patch series.
This file is its state.

**Status.** micro-c is M2-Planet at pin `bd2fe4b` plus **59 patches**. It
compiles `tcc.c` -- tcc's whole source including its command-line driver -- to
**378,759 lines of M1 across 707 functions**, and the linked **1.57 MB** aarch64
binary (`mc-tcc`) is a working-enough tcc that:

```
mc-tcc --version              tcc version 0.9.28rc (AArch64 Linux)   tcc's own driver
the twelve end-to-end progs   12 / 12          native aarch64, in the box
tcc's own tests2              59 / 127 match tcc's .expect (diff -b rules)
mc-tcc -c tcc.c               870,242 byte object   UNDER QEMU ONLY -- see below
```

**IT IS NOT SELF-HOSTING.** A fixpoint needs five things and this is the first:

```
1. gen1 compiles tcc.c          UNDER THE EMULATOR ONLY -- see below
2. gen2 LINKS                   no -- needs a libc; see "The libc rung"
3. gen2 runs                    not reached
4. gen2 compiles tcc.c -> gen3  not reached
5. gen2 == gen3                 not reached
```

**STEP 1 DOES NOT HOLD ON REAL HARDWARE, and that is the sharpest open lead in
this file.** Under `qemu-aarch64-static` it succeeds -- rc=0, an 870,242 byte
object. In `stage3-hermetic-arm64`, on a NATIVE aarch64 runner, the same
mc-tcc (same 1,574,765 bytes) **segfaults**:

```
    step A: gen1 cannot compile tcc.c, rc=139
      SIGNAL 11
```

Not host headers -- `-nostdinc` changes nothing locally and the box has no
`/usr/include` at all. `tcc-two-ways` reproduces it independently
(`gen2 died on SIGNAL 11`), so it is not the hermetic box either.

**AND IT DISAPPEARS UNDER INSTRUMENTATION**, which is the part that decides how
to chase it. `tcc-two-ways` step 26 builds the same tcc with a marker after
every statement:

```
    instrumented binary: 1571918 bytes
    exit 0 -- NO SIGNAL under instrumentation.
    THAT IS THE FINDING: the fault is sensitive to code size or
    layout, and reducing it by construct will not work.
    LAST STATEMENT THAT COMPLETED: E02  tccelf.c:116  free_section: ENTRY
```

A fault that vanishes when you add code is a fault about LAYOUT, not about a
construct. That is the same shape as the heap corruption chapter above, where
the failure moved with the length of the input's FILENAME and bisecting by
construct produced two confident wrong answers. **So do not reduce this one by
deleting statements** -- that is the move that works for a construct bug and
wastes rounds on a layout bug. `tools/layout-sweep.sh` is the instrument for
this class.

Alignment remains the leading hypothesis, because this file already records the
same asymmetry one level down: *"ON AMD64 AN UNALIGNED LOAD MERELY COSTS TIME.
ON AARCH64 IT IS A FAULT"* -- which hid the member-alignment bug for as long as
the local suite was amd64. qemu-user is permissive in the same direction.
**Trust CI over the local run for step 1.**

`rc=0` on step 1 is not proof the object is correct. What it is worth: against
the gcc-built control on the same source, the two objects carry the **same 705
function symbols**, relocation counts within two, and sizes within 0.4%
(870,242 against 873,890). Structurally right; unverified beyond that.

**The heap corruption that dominated this file is closed** -- see "The
corruption, and the measurement that was lying about it" below. So is the
`.eh_frame` fault. What remains is listed under "What is still wrong".

**A correction, because this file was wrong about it for several rounds.** The
remaining fault was recorded here as `++*(p)` in tcc's token reader caused by
*pointer arithmetic that does not scale* -- case 21. The shape was right and
the cause was not. Scaling was a real gap and it has been closed
(`EXPERIMENT-zz7`); closing it moved the marker trail **by nothing at all**.
What was actually stopping tcc is in `EXPERIMENT-zz8`, and the load-bearing
line of it is four characters wide:

```
*(t) = 7;      stored through the LOADED VALUE -- SIGSEGV
*t   = 7;      correct, and always was
```

An assignment through a *parenthesised* dereference: the eighth copy of the
`assigning` rule in `cc_core.c` and the third one found missing. That is the
same one-rule-many-implementations shape this file counts nineteen of for
`load_value`, arriving from a direction nobody was watching. tcc writes the
parenthesised form because `TOK_GET` is a macro and `*(t)` is the only safe way
to dereference a macro parameter.

---

## Where it gets to

Run by `.github/workflows/tcc-two-ways.yml` on `ubuntu-24.04-arm`, native, no
emulation -- and, since the toolbox described under **Tools** below, on an
x86_64 development machine under `qemu-aarch64-static` in about a minute.

```
micro-c compiles libtcc.c    369,255 lines of M1, 695 functions
assembles and links          ~1.52 MB, ELF64 AArch64, main aligned
runs                         tcc_new completes
                             tcc_set_output_type completes
                             crt files are absent and it SAYS SO:
                                 tcc: error: file 'crt1.o' not found
                                 tcc: error: file 'crti.o' not found
                             tcc_add_file -> tcc_compile
                             preprocess_start, tccpp_new
                             980 keywords interned, 29 hash collisions resolved
                             its own predefs preprocessed without error
                             tccgen_init, tccgen_compile, next()
                             macro_subst_tok -> macro_subst
                             out of macro expansion entirely
                             compiling the input file, with real
                             diagnostics carrying file context:
                                 In file included from seven.c:0:
                                 <command line>:27: warning:
                                     integer constant overflow
                             faults later, and elsewhere
```

**Since `int` became four bytes** (`EXPERIMENT-zzw`) and the seven defects
behind it were fixed, it compiles rather than faulting:

```
mc-tcc --version             tcc_new and tcc_delete completed
mc-tcc -c seven.c            rc=0, a 1,038-byte object
a freestanding hello world   builds, runs, prints "hello, world"
```

Four of the twelve programs in the hermetic suite pass outright -- a constant,
globals in `.bss`, `char`/`switch`/`goto`, and a string literal written through
`write`. Two segfault at RUN time; see **What is still wrong**.

**Where it stands now.** micro-c's tcc compiles a file end to end and emits a
real object:

```
    exit=0
    /tmp/t.o: ELF 64-bit LSB relocatable, ARM aarch64, version 1 (SYSV)
```

That needs ONE thing that is not committed and is not a fix: a NULL check in
`tal_free_impl`, which walks its buffer list without one. Without the check the
same run segfaults. The check hides a stray write rather than repairing it, so
it stays out of the tree; the write is the open frontier and is described below.

**Everything above about P151 was wrong, and the way it was wrong is the
lesson.** For five rounds this file recorded the fault as "in tccgen, past
where `next()` returns". It was a member offset three functions away: a member
of an anonymous struct nested in an anonymous union resolved to OFFSET 0, so
`sym_push2`'s `s->c = c` wiped the token `s->v = v` had just written, and every
symbol tcc created came back with `v == 0`. `EXPERIMENT-zzh`. The marker trail
had been read as pointing AT the fault when all it can do is bracket between
probe points.

**Corrections to what this file used to say**, each because it was measured
rather than reasoned about:

| was recorded as | actually |
|---|---|
| the P151 fault is in tccgen | a member offset in `cc_types.c`, `zzh` |
| `<command line>:27` changed to "extra tokens after directive" -- possibly new | pre-existing; it was third in the list all along, behind two overflow warnings that `zzb` removed |
| `constant_expression` folds `a\|b&c` right-to-left | not confined to constant expressions, and not right-to-left: the five bitwise/logical operators had NO precedence and parsed flat, left to right. `zze` |
| case 31 closed array-of-pointers | it closed it for a STRUCT element. A `char*` element was still loading one signed byte of an eight-byte pointer, in `tcc`'s own `char *include_stack[32]`. `zzd` |
| the tcctest.c step measures tcctest.c | it died in option parsing before opening the file -- a single `-B` flag segfaulted a one-line program. `zzi` |

**`EXPERIMENT-zza` is what moved it, and the diagnosis that preceded it was
wrong for four rounds.** The fault was recorded here as being in macro
expansion because the last completed statement was a `begin_macro` call. It was
not in macro expansion. `next()` executes `goto redo` immediately afterwards,
and **`tccpp.c` has five functions that each declare a `redo:` label** —
emitted into one flat assembler namespace, so every `goto redo` in the unit
went to whichever definition survived. Nothing was wrong with the macro code at
all; the last-marker report was describing the last statement before a jump,
not a crash site.

The trail either side of `EXPERIMENT-zz8`, which is what "the frontier moved"
means here rather than an impression:

```
before   ... P97 P100 P115 P116 P119 [SIGSEGV]
after    ... P97 P100 P115 P116 P119 P100 P65 [SIGSEGV]
```

`P100` is `TOK_GET(&t, &macro_str, &cval)`. It now completes a **second** time
-- the loop body iterates, which it had never done -- and `P65`
(`ret = macro_subst(tok_str, nested_list, jstr)`, tccpp.c:3396) completes in
the caller before the fault. 21 markers to 23. **The new fault is after
`macro_subst` returns, around `tok_str_free_str`, and has not been
diagnosed.**

Those two error lines are worth their own sentence: they are printed through
`cstr_vprintf`, the path that used to crash, and they mean tcc is judging a
program rather than dying in setup. The crt files genuinely are not on the
runner.

THE KEYWORD NUMBERS RECONCILE, which is a stronger claim than "it did not
crash". Each keyword is scanned len+1 times and hashed len times, so the
scan-loop count minus the intern count must equal the hash-loop count:

```
6522 - 980 = 5542      and the hash loop ran 5542 times      exact
980 + 29   = 1009      buckets read, with 29 chain steps     exact
```

If `r - p - 1` were wrong for any one of 980 keywords those totals would not
reconcile. The pointer difference is provably right across the whole table --
a thing this file previously recorded as suspect on the strength of a
miscounted marker.

The control in the same job — tcc built by gcc — passes tcc's own `test1`,
`test2` and `test3`, passes `make test`, and reaches a byte-identical
self-compilation fixpoint:

```
gen1  427,576 bytes  gcc-built
gen2  543,689 bytes  built by gen1
gen3  543,689 bytes  built by gen2      identical -- FIXPOINT
```

That control is the yardstick and it runs on the same machine as the subject.
On x86_64 the same fixpoint lands at 425,212 bytes, which is why quoting a
number from a laptop would have been wrong.

---

## What was wrong with micro-c, and what it means

Twenty patches. The interesting thing is not the count but that almost every
one falls into two families: **a missing concept applied inconsistently**, or
**one rule with several implementations that disagree**. The sections below are
the first round of them; the ones after are later and the pattern holds.

**And a third family appeared once the frontier got past the compiler's own
bugs: upstream code that is correct for everything its author compiled and has
never been asked to compile tcc.** Three of the twenty are that, and none of
them are ours.

### No notion of alignment, anywhere

micro-c had none. It surfaced four times, each looking like something else:

| symptom | actual cause |
|---|---|
| SIGBUS on every call | string data unpadded, so function labels landed off a 4-byte boundary |
| pointers in `TCCState` garbage | struct members placed end to end, so `tcc_lib_path` sat at offset 9 where gcc puts it at 16 |
| whole-struct copy faulting | `sizeof` not padded to the largest member's alignment — 25 for a struct gcc makes 24 |
| arrays of structs misbehaving | consequence of the above: every element after the first misaligned |

**All four were invisible on amd64 and fatal on aarch64**, because x86 tolerates
unaligned access and ARM does not. Every one cost a CI round to find, because
the development machine cannot execute aarch64.

### One rule, nineteen implementations

`emit_out(load_value(...))` appears **19 times** in `cc_core.c`, across at least
five functions — `primary_expr_variable` alone has eight — and each site carries
a different subset of the guards:

```
1594  postfix_expr_arrow   guards: = , compound-assign
1644  postfix_expr_arrow   guards: = , compound-assign, postfix, size, is_array, Address_of
1766  postfix_expr_dot     guards: = , compound-assign
1818  postfix_expr_dot     guards: size
```

Four bugs this session were one of those sites missing a condition another site
already had:

- array members loaded instead of decaying — fixed at the arrow site, **found
  again** at the dot site
- indexing a pointer member never loaded the pointer, so `m.p[0]` read the
  pointer's own bytes
- the `assigning` check existed in `postfix_expr` and was absent from
  `postfix_expr_inc_or_dec`, so `*p++ = x` stored through a loaded value —
  52 sites in tcc
- element width was computed from a **name comparison** (`match("char*", ...)`),
  so `char msg[] = "hello"; msg[0]` loaded eight bytes

**The real fix is to stop having nineteen of them** — one `should_load(type,
context)` answering "load or address, and how wide", called everywhere. That is
a substantial refactor of `cc_core.c` and it is not done. Until it is, the
twentieth site is a matter of time.

It was six weeks. **`EXPERIMENT-zzzl`** is the ninth copy of the `assigning`
rule found missing, and it is the same shape as `zz8`: `is_assignment` at
`cc_core.c:1831` is `match("=")` and nothing else, so `*p += v` fell through to
the RVALUE branch — which steps the type down and *then* loads, because that is
what an rvalue read of `*p` wants. The lvalue branch loads first, at the
pointer's own width. Both orders are correct for their own case; the flag
selecting between them did not know about `+=`:

```
*p = 5     lea_rax,[rbp-8] / mov_rax,[rax]                8 bytes, correct
*p += 5    lea_rax,[rbp-8] / movsx_rax,DWORD_PTR_[rax]    4 bytes, SIGNED
```

Same expression, two different loads, differing only in which operator follows.
A four-byte sign-extended read of an eight-byte pointer, then stored through.

`is_compound_operator` was already computed on the very next line and already
consulted by the two guards above it, at 1834 and 1922. Only the branch that
chooses load ORDER was missed.

**What it cost.** `tccgen.c:4153`, inside `find_field`, accumulates an offset
with `*cumofs += s->c;` while walking anonymous struct members — so every
recursive resolution stored through a truncated pointer. A designated
initializer naming a member of an anonymous struct segfaulted mc-tcc at compile
time, while the same initializer written with braces was fine, because the
braced form never takes the recursive path. `tests2/90_struct-init`, closed.

**How it was found**, because the route matters more than the result here.
Layout sweep first: eight filename lengths, all failing identically, so *not*
heap roulette and bisection by construct was legitimate. Reduction converged in
two passes. Then phase-splitting (`-E` clean, `-c` faults), the faulting PC out
of qemu mapped through the hex2 label table to `find_field`, then tagging all 22
`load_value` sites and rebuilding to see which one emitted it: SITE1997 for
compound, SITE1943 for plain.

Four speculative probes came first — recursion through `&s->type`, `&cumofs`,
the `&&` guard, operator precedence — and all four came back AGREE. They cost
turns and proved nothing. **Reading the emitted instruction is what worked.**

### The type that wins is decided by declaration order

`promote_type` walked `global_types` and returned the **first entry whose name
matched either operand**. Which type won was therefore decided by the order
things were registered, not by the types:

```c
for(i = global_types; NULL != i; i = i->next)
{
    if(a->name == i->name) break;
    if(b->name == i->name) break;
    ...
}
return i;
```

That is right whenever the wider type happens to be registered first. `int` is
registered early, so anything meeting an `int` and declared later simply lost —
and **every typedef is declared later**:

```
unsigned long x;   x >> 43     shr_rax,cl    logical, correct
u64           x;   x >> 43     sar_rax,cl    arithmetic, WRONG
```

Same width, same signedness, different answer, because `u64` is a typedef. The
promoted type came back as `int` carrying `is_signed = TRUE`, so **every
unsigned typedef in the program was signed as far as codegen was concerned**.
Division and comparison went the same way: a probe of shift, division and
comparison returns 42 through a typedef and 0 with the primitive spelled out.

**What it cost.** tcc's `elf.h:34` is `typedef unsigned long long int uint64_t`,
so this was every `uint64_t` in tcc. `arm64_movi` encodes a value whose only set
bit is bit 63 with

```c
if (!(x & ~(m << 48)))
    return 0xd2e00000 | r | x >> 43;            arm64-gen.c:184
```

and an arithmetic shift turns `0x100000` into `0xfff00000`, so the emitted word
was `0xfff00001` — not an aarch64 encoding at all. `tests2/118_switch` died with
SIGILL on the one case range in the file whose low bound is exactly `LONG_MIN`.
`LONG_MIN+1 ... -1` was fine, which is what made it look like a switch bug.

**`EXPERIMENT-zzzm`** replaces the walk: wider wins, and at equal width the
unsigned one wins, which is C's rule for equal rank. A pointer is wider than an
int and still wins, which is what the old walk produced for pointer arithmetic.
Case 110 remains a declared `KNOWN GAP` — this is not the full usual arithmetic
conversions, it is the selection rule those conversions need underneath them.

**Two wrong answers came first.** The README listed "every integer literal is
truncated to 32 bits" as the known blocker and this looked like it — but a
direct probe of bare 64-bit literals AGREES on both columns, so that item was
stale and `zzb` had already closed it. The second answer was that a typedef
loses `is_signed` in `mirror_type`; instrumenting `mirror_type` shows it copying
`src_signed=0` correctly. Only instrumenting `promote_type`'s **inputs** showed
both operands arriving intact and the wrong one being returned.

### Branching inside an expression clobbers the frame pointer

On aarch64 a far jump loads its target into **x16** and does `br_x16`. x16 is
`REGISTER_TEMP`, and micro-c's call sequence holds the callee's new base pointer
there while arguments are evaluated. So a ternary or a `&&` **inside an argument
list** overwrote the base pointer with a code address.

tcc does exactly this:

```c
tcc_open_bf(s1, filename ? filename : "<string>", len);
```

and `len` arrived as `0xF9400000D100A688` — which is not a number, it is
`ldr x0,[x0]` followed by another instruction. Eight bytes of machine code,
loaded as data, passed as an allocation size.

Fixed by bracketing both constructs with a push/pop of `REGISTER_TEMP`. 1,343
protected sites in libtcc alone. amd64 never had the problem, because its far
jump is a plain `jmp` touching no register.

### `&&` and `||` did not short-circuit

They emitted a bitwise AND of both operands. tcc relies on short-circuit in
**48 places** shaped like `if (esym && esym->st_shndx == SHN_UNDEF)`, every one
of which dereferences null when the guard is the left operand.

The fix appeared to make things catastrophically worse — the full unit was
OOM-killed — and was shelved for several rounds. The measurement that settled
it took one command:

```
 200 logical operators      83 MB
 800 logical operators     320 MB
3200 logical operators    1279 MB     -- 400 KB each
```

`reset_emit_string` calloc'd `MAX_STRING` for **every emitted instruction**, and
nothing is ever freed. At `--max-string 65536` that is 64 KB per line of output,
and short-circuit emits about six lines per operator: 64 KB × 6 = 400 KB
exactly. Short-circuit did not leak; it emitted more instructions, and every
instruction cost 64 KB.

The emit buffer now starts at 256 bytes and grows on demand. **micro-c is
faster and smaller than it was**: the full tcc unit went from 39 s to 23 s, and
a 200-operator file from 83 MB to 3.4 MB.

---

## FIXED: `if (long double)` was always false, and it stopped perl

**`gvtst_set` folded a register as if it were a constant.** Two patches, both
in `spikes/stage3/patches/tcc-arm64-asm/`, and the probe on a native arm64
runner now formats every value correctly with no gcc object anywhere:

```
                      before        after
literal 5.008         8.000000      5.008000
1.5 2.5 3.5           2.000 4.000   1.500 2.500 3.500
(double)L             8.000000      5.008000
```

### The bug

`tccgen.c`'s `gvtst_set` turns a value into a condition:

```c
if (vtop->r != VT_CMP) {
    vpushi(0); gen_op(TOK_NE);
    if (vtop->r != VT_CMP) /* must be VT_CONST then */
        vset_VT_CMP(vtop->c.i != 0);
}
```

The comment is the bug. On arm64 a long double comparison calls `__netf2` and
turns the result into 0/1 with `cset`, so `gen_op` leaves a real **integer
register** -- neither `VT_CMP` nor `VT_CONST`. `c.i` is then the constant field
of a register-resident value, in practice zero, and the condition folds to a
compile-time false. No branch is emitted at all:

```
bl __netf2 ; cmp w0,#0 ; cset w0,ne ; nop ; mov w0,#0
```

`A != B` works because it is consumed as a *value*, where the `cset` result is
exactly right. **Only the condition path breaks** -- which is why every
explicit comparison passed and only `if (x)` failed, and why it took five wrong
theories to find.

musl's `fmt_fp` is built on `for (; y; y = ...)` and `if (y)`. Every one exits
before its first iteration, no digits are extracted, and the value prints as
its exponent alone: 1.5 → 2, 2.5 → 4, 5.008 → 8.

### Two patches, both needed

**0007** is the fix above. **0006** corrects long double *constant emission*
when cross-compiling: `init_putv` chose its path by comparing **sizes**, and
x86_64 and arm64 are both 16 bytes with completely different formats -- x87
80-bit versus IEEE binary128 -- so a cross tcc memcpy'd host x87 bytes into a
binary128 slot and `__trunctfdf2` returned zero for everything.

Measured on a clean tree: 0007 alone fixes `if(A)` but leaves `!Z` wrong,
because that needs `0.0L` to be a correct constant. 0006 is inert on a native
arm64 build, which is why the CI fix needed only 0007.

### How it was found, after five wrong theories

| theory | how it died |
|---|---|
| optimisation | `-O0` changed nothing |
| `libtcc1.a` missing f128 helpers | all 22 quad routines present |
| `__trunctfdf2` wrong | byte-identical to host gcc, both directions |
| variadic ABI / `va_arg(double)` | correct in three shapes, three columns |
| `__trunctfdf2` returning zero locally | a **cross-compilation artefact** -- 0006, a real bug, but not this one |

What broke the loop was building tcc locally and running its output under
`spikes/toolbox/qemu-aarch64-static` -- seconds per iteration instead of a
twenty-minute CI round. That emulator has been in the repository the whole
time.

And the step that actually located it was instrumenting `gjmp_cond` with a
`fprintf` and finding it **was never called** for the failing case. Every round
spent reading code and reasoning about mechanisms produced a wrong answer;
the first measurement produced the right one.

## tcc miscompiles musl's vfprintf.c, and one object swap proves it

**The bug is `src/stdio/vfprintf.c` compiled by tcc.** Take the musl tcc built,
replace exactly one object with a gcc-compiled `vfprintf.o` from the same
source, relink, and every value is correct:

```
                        tcc-built vfprintf.o      one gcc-built object
literal 5.008           8.000000                  5.008000
1.5 2.5 3.5             2.000 4.000 4.000         1.500 2.500 3.500
(double)L               8.000000                  5.008000
```

One variable, no theory required.

### Four theories died first, and each one narrowed it

| suspected | measured |
|---|---|
| optimisation | `-O0` changes nothing; the compiles carry no `-O` at all |
| `libtcc1.a` missing f128 helpers | all 22 quad routines present -- `__addtf3` through `__trunctfdf2` |
| `__trunctfdf2` wrong | **byte-identical to host gcc**, both directions, as are `__trunctfsf2` and `__extenddftf2` |
| variadic ABI / `va_arg(double)` | correct in three shapes and three columns: double alone, int-then-double, second of two |

Every piece `fmt_fp` uses is also correct in isolation: union type-punning,
exponent extraction, `frexp`, `frexpl`, and the `uint32_t big[]`
multiply-and-carry accumulator. So the fault is in how they **combine** in that
one translation unit -- which is what a miscompile looks like from outside.

### Why nothing noticed for four compilers

The symptom is exponent-preserved, mantissa-destroyed: `1.5 → 2`, `2.5 → 4`,
`5.008 → 8`. Every value becomes the next power of two at or above itself.

Nothing in a compiler build formats a float. gcc built gcc built gcc without
the code being reached where the answer mattered. It surfaced at perl, because
`use 5.008` compares against `$]` and perl builds `$]` by **formatting** a
double -- so the version string read as v8.0.0 and perl refused to build
against itself.

### It is not upstream's, and it is not fixed upstream

Current tinycc HEAD is 101 commits ahead of our pin, four of them touching
`lib/lib-arm64.c`. Both compilers give **identical, correct** conversion
results, so there is nothing to backport for this. The bug is in code
generation for that file, not in the soft-float library.

`d9a6d9ae "reverts (11/2025 - 04/2026)"` is worth a look separately: a bulk
revert spanning five months, landing after our December pin. Our tree may
contain something upstream later removed.

### What to do about it

Three options, in increasing order of honesty:

1. **Nothing.** Nothing between here and a booting kernel formats a float
   except perl, and perl only needs it for `$]`. Provable by continuing.
2. **Ship a gcc-built `vfprintf.o`**, as this experiment does. Fast, and a
   declared substitution -- but it means one object in the libc did not come
   from the chain, which is exactly the kind of hole this project exists to
   close.
3. **Find the miscompile.** Bisect `vfprintf.c` by compiling halves with each
   compiler until one function is named, then reduce that to a case for the
   difftest suite. Slowest, and the only one that fixes the compiler.

## The chain cannot print a double, and only printing is wrong

Found at rung 11.5 of `stage3-to-stage4-reference`, where perl refused to build
with `Perl v8.0.0 required--this is only v5.42.2`. That message names a version
and is not about versions: `use 5.008` compares against `$]`, and perl builds
`$]` by **formatting** a double.

A probe compiled by gcc 10 -- four compilers above tcc -- answers:

```
literal 5.008      = 8.000000   (expect 5.008000)
snprintf %.6f      = 8.000000
(double)5 printed  = 8.0
two doubles        = 2.000 4.000   (expect 1.500 2.500)
int then double    = 7 4.000       (expect 7 3.500)

manual whole.frac  = 5.008000   CORRECT
(int)(5.008*1000)  = 5008       CORRECT
5.008 > 5.007      = 1          CORRECT
```

**Every printed value is the next power of two at or above the real one.**
1.5 → 2, 2.5 → 4, 3.5 → 4, 5.0 → 8, 5.008 → 8. The exponent field arrives
intact and the mantissa does not.

**The double itself is sound.** `(long)a` and `(a - whole) * 1000000` both give
the right answer, so the value is correct in memory and correct through
arithmetic. It is damaged between the caller and `printf`.

**And the integer in the same call is fine** -- `int then double = 7 4.000`
gets the 7 right. On aarch64 variadic doubles travel in `v0-v7` and integers in
`x0-x7`; the general-purpose path works and the SIMD one does not.

That is why nothing noticed for four compilers: every operation in a compiler
build is integer or pointer work. gcc built gcc built gcc without ever
formatting a float where the answer mattered.

**Whose fault it is remains open.** musl's `vfprintf.c` was compiled by tcc at
rung 2 and could be reading the va_list wrongly; or the caller places the value
wrongly. `sources/musl.toml` drops only `src/complex/*.c`, so the formatting
code is all present, and rung 2 reports 1349/1349 compiled. The rung now builds
the same probe with tcc as well as gcc: if tcc's binary formats correctly
against the same musl, the formatting code is sound and the calling convention
is the suspect.

**It is adjacent to a known gap.** `MICRO-C.md` records that micro-c has no
working floating point at all -- `double a = 12.5; (long)a == 12` is false in a
binary mc-tcc produces. This is the REFERENCE arm, so mc-tcc is not in this
chain; but tcc's own soft-float helpers from `libtcc1.a` are, underneath
everything.

## What is still wrong

| gap | consequence |
|---|---|
| ~~`int` is EIGHT bytes~~ | **CLOSED, `EXPERIMENT-zzw`.** tcc forced it: `#define DATA_ONLY_WANTED 0x80000000` into an `int` has to WRAP NEGATIVE or `put_extern_sym` takes its early return and every global is dropped. One line in `cc_types.c`, and six further defects behind it -- zzu, zzv, zzx, zzy, zzz, zzza, zzzb -- because at eight bytes `int`, `long`, every pointer and the register were all one width, so no width or signedness decision had ever been exercised. See the table below |
| ~~pointer arithmetic does not scale~~ | **CLOSED, `EXPERIMENT-zz7`.** All four shapes (`p+n`, `n+p`, `p-n`, `p-q`) scale; cases 21 and 50. It was never the blocker -- see the correction above. The shelved `scale_pointer_operand` failed for a reason this file did not have: **an integer literal had no type**, so `q + 1` reported a pointer on *both* sides and read as a difference. Three further losses had to go with it -- see the patch preamble |
| ~~every integer literal is truncated to 32 bits~~ | **CLOSED, `EXPERIMENT-zzb`.** `strtoint` returns `int` AND sign-extends from bit 31, `int2str` masks to 32, and `write_load_immediate` took an `int`; built by gcc, micro-c could not REPRESENT a 64-bit constant in the source it compiles. `strtolong`/`long2str` and a `long long` emitter path close it, emitting the vocabulary `patches/m2libc/0005` landed. tcc no longer warns "integer constant overflow" on every constant it reads. Cases 53 and 54 |
| **a constant with bit 31 set was wrong on one architecture or the other, always** | The threshold for the wide path is 2^31 rather than 2^32 because between the two there is no correct 32-bit form: aarch64's `ldr_w` zero-extends (right there, wrong for negatives) and amd64's `mov_<r>,%imm32` sign-extends (right for negatives, wrong there). 189 constants in one compile of libtcc.c sat in that range, every one of them becoming `0xFFFFFFFF80000000` on amd64. Sixth instance of the class below and the **first running the other way** -- here amd64 is the wrong column |
| `&x` reports x's own type | One level short of what it is: there is no `T*` handed back. `EXPERIMENT-zz8` cancels it locally for `*(&x)`, the only shape that has bitten, but the under-reporting itself is untouched and will surface again |
| ~~a negative `case` label~~ | **CLOSED, `EXPERIMENT-zz9`.** `case -2:` loaded 4294967294: the value is kept as its label SPELLING, rendered unsigned, and the jump table recovered it by `strtoint`ing the name back. Fifth instance of the class below, and the first the case suite caught on its own -- case 16 had been red on aarch64 and green on amd64 for some time |
| **amd64 hides what aarch64 faults on -- FIVE times -- and once the reverse** | Unaligned members, unpadded string data, struct `sizeof`, arrays of structs, and a sign-extending `mov_rax,%imm32` making a wrong constant land on the right value. The rule this earned: **a green amd64 difftest is not a result.** `EXPERIMENT-zzb` supplies the mirror image -- 189 constants that aarch64's zero-extension put back on the right answer and amd64 got wrong -- so the rule is now symmetric: **neither column is the reference.** Read both |
| ~~a goto label is global~~ | **CLOSED, `EXPERIMENT-zza`.** A C label is scoped to its function; this emitted the bare name flat, so tcc's five `redo:` labels collided. **This was the blocker.** M2-Planet's own source has globally unique labels, which is why upstream never needed it -- our stage 2 fixed the same thing at m58 and the note there says it is "stricter than the target requires, at no cost". It was exactly what the target required |
| one lvalue rule, EIGHT implementations | Beside the nineteen load sites, `cc_core.c` decides "is this an assignment target" in eight places, and **three have been found missing a case the others had, one per round**. Same disease, worth its own row: it is the one that has cost tcc the most |
| **a pointer walked over a local array, and a function pointer in a struct member** | Both SEGFAULT at run time in programs mc-tcc builds -- `while (p < a + 4) ... p = p + 1`, and `o.add(2,3)` through `struct Ops { int (*add)(int,int); }`. difftest case 14 is the second and is still unreduced after many attempts: every hand-written reduction passes while the real file faults. These are the last two known wrong-codegen shapes |
| `float`/`double`/`long double` | one word-sized integer type |
| ~~`constant_expression` precedence~~ | **CLOSED, `EXPERIMENT-zze`.** And the description here was wrong twice over: not confined to the constant parser, and not right-to-left. All five bitwise/logical operators sat at ONE level and parsed flat, left to right, so `1\|2^3` was `(1\|2)^3`. A right-to-left fold would have got that one right by accident. Case 59 |
| 19 load sites | see above |
| `&((*p)->m)` | grouping parens around a **dereference**. `&(p->m)` works. `&(X)` needs address-of TRUE at X's final lvalue step and FALSE inside it, and with a dereference in the middle those are different points; one global flag cannot say both. Case 44 |
| ~~a switch cannot be instrumented~~ | **PARTLY CLOSED.** A marker still cannot go *inside* a switch body — micro-c answers `ERROR in process_switch / MISSING }` — but that is now a no-marker ZONE rather than a reason to skip the whole function. `next_nomacro` and `tok_str_add2` are instrumented everywhere else and the switch is reported in the map as a `!!` blind spot with its line range. A named gap beats a function nobody may instrument |

---

## Later rounds, and where they came from

Everything above was found before micro-c could be built outside CI. What
follows was found after, mostly in minutes rather than rounds. The
distinguishing feature is that several are **not micro-c's bugs at all**.

### A global struct is a struct

`primary_expr_variable` decides whether to load a variable's value, and its
"do not load a struct" guard tested a width that only becomes the type's real
size for `TLO_LOCAL` and `TLO_ARGUMENT`. A **global** struct kept
`register_size`, so the guard could not see a struct at all and loaded its
first eight bytes as an address:

```
char_pointer_type = char_type;          tccgen.c:392
```

both file-scope, so the copy's source became `char_type.t` -- the integer 3 --
used as a pointer. The local form had already been fixed; this is the same
rule in the other storage class.

The first attempt at the fix was wrong and the suite said so in a second:
suppressing the load on element size alone broke cases 31 and 43, because that
load does **double duty** -- for a scalar it fetches the value, for a global
ARRAY it dereferences the pointer cell the symbol holds.

### `++` and `--` on a global

Upstream's own condition in `primary_expr_variable`:

```c
is_postfix_operator = match("++", ...) && (options != TLO_STATIC
                                        && options != TLO_GLOBAL);
```

It reads like a guard and is not one. Excluding a global makes it fall through
to the ordinary path, which LOADS the value; the increment then treats that
value as an address and stores through it. Every form -- postfix, prefix, a
bare `n++` -- segfaulted. `ts->tok = tok_ident++` at tccpp.c:480 is the
statement tcc died on. **M2-Planet never increments a global; tcc does it
constantly.**

### A label is a prefix, not a statement

`lab: stmt;` is ONE labelled statement. `statement()` emitted the label and
returned, which is invisible inside a block -- the block loop parses the next
line anyway -- and wrong wherever exactly one statement is expected:

```c
if (t0 == TOK_PPJOIN)
bad_twosharp:
    tcc_error("'##' cannot appear at either end of macro");   tccpp.c:1621
```

The `if` got the label as its whole body and the `tcc_error` became the next
statement, unconditional. **Every `#define` tcc preprocessed raised that
error**, and the first one reported was line 1 of its own predefs. It reads
like a macro bug and is a parser one.

The fix needed a guard of its own: an ordinary goto label may sit directly in
front of a `case` or `default` (tccpp.c:952), and those belong to
`process_switch`, not to `statement()`.

### Address-of does not survive a nested parse

`Address_of` is a global flag, and two things destroyed it.

**Grouping parens.** `primary_expr` clears the flag unless it sees `&`, and
`&(ts->hash_next)` -- tccpp.c:516, as tcc writes it -- re-enters
`primary_expr` for `ts`. `&ts->hash_next` was always fine: it never re-enters.

**The index parse.** `postfix_expr_array` saves the flag for its own use, and
`common_recursion` clears the global, so the `.next` in `&pool[0].next` read
FALSE and emitted the member load.

Clearing on the way OUT of `primary_expr` instead is the tidier change and is
**wrong**: 22 cases pass against 42, because `&a[i]` parses its index through
there and needs the flag down. That took one minute to find locally and would
have been a round and a confident wrong explanation.

### Three that are not ours

**`va_copy`'s arguments are reversed in M2libc.**

```c
#define va_copy(ap1, ap2) ap2 = ap1
```

C says `va_copy(dest, src)` copies src into dest. tcc's `va_copy(v, ap)`
therefore became `ap = v` with `v` uninitialised -- destroying the live
argument pointer and passing garbage to `vsnprintf`. That is on the path of
**every diagnostic tcc emits**, which is why the crt-not-found message crashed
instead of printing.

Nothing upstream uses `va_copy`. The single use in the whole tree is a test,
and the test is written backwards in the same direction as the macro, so the
two errors cancel and it has always passed. Fixing the macro breaks that test;
the test is wrong, not the fix.

**Three aarch64 macros encode x16 as x8.**

```
DEFINE add_x0,x16,x0 0020008b        ->  ADD x0, x0, x0, LSL #8
```

Not a missing macro -- a wrong one. It assembles, links, runs, and is used 315
times in one compile of libtcc.c. It is the source-pointer advance in the
struct copy, so the struct's SIZE decided everything: eight bytes worked, and
sixteen read its second word from address 2056. Case 05 was red from the day it
was written because of this, and the emitted copy loop was correct all along.

`vocabulary.sh` cannot find this: it asks whether a macro EXISTS, and all three
do. `tools/verify_defs.py` asks whether it is CORRECT, which for a
register-to-register form is fully determined by the name.

**`int` IS NOW FOUR BYTES.** It was eight, and that was the deepest open item
in this file for a long time. tcc forced it: tccgen.c keeps

    ST_DATA int nocode_wanted;
    #define NODATA_WANTED     (nocode_wanted > 0)
    #define DATA_ONLY_WANTED  0x80000000

and sets DATA_ONLY_WANTED for every file-scope variable. On a 32-bit int that
sets the SIGN bit, so NODATA_WANTED is false and put_extern_sym defines the
symbol; at eight bytes 0x80000000 stays positive and put_extern_sym takes its
early return. Every global in every program our tcc compiled was silently
dropped.

The change is EXPERIMENT-zzw, one line in cc_types.c. What it cost is the
interesting part: at eight bytes, `int`, `long`, every pointer and the register
were all the same width, so a whole class of width and signedness decisions had
never been exercised. Six further defects came out of it, each invisible before:

| | |
|---|---|
| **zzu** | a signed four-byte load must sign-extend; aarch64 used `ldr_w0`, which zeroes the top half. Every other target already had this right. Needs `ldrsw_x0,[x0]`, added as patches/m2libc/0008. |
| **zzv** | the bitfield clear mask overflowed according to the width of the int in *micro-c's own source* -- four bytes under gcc, eight under stage 2 -- so the same line produced different masks depending on who built the compiler. |
| **zzx** | `++`/`--` dereferenced at register width rather than the variable's. |
| **zzy** | a prefix `++`/`--` target is an assignment target: `--*p` loaded an eight-byte pointer with a four-byte `ldrsw`. |
| **zzz** | a vararg slot is a register, not a `sizeof`. `%d` desynchronised every argument after it, so every tcc diagnostic came out corrupt. |
| **zzza** | a global scalar is stored at its type's width and was read at the register's. Positives survived because the neighbours are zero; `-1` did not. |
| **zzzb** | a struct member never carried its `is_signed`, so every member read zero-extending. `p->c = -1; p->c != -1` was true. |

The last two are worth reading together: both are store-narrow/load-wide, in
different storage classes, and both were invisible to any test using positive
values. Several tests written for exactly these sites passed for that reason.

**Every struct micro-c lays out now matches a normal ABI for its integer
members** -- which was the other half of the old note, and is no longer true of
the compiler.

**What this does NOT yet mean.** mc-tcc compiles and links, and the programs it
builds run, but two shapes still fault at run time: a pointer walked over a
local array (`while (p < a + 4) ... p = p + 1`) and a function pointer held in a
struct member. difftest case 14 is the second of those and is still unreduced.

---

## The runtime underneath

`micro-c-libc/` supplies what M2libc lacks. Two files matter:

- **`impl/runtime.c`** — real `strtoX` (base-0 handling included), `qsort`,
  `getenv` walking `environ`, `strerror`. What cannot be real is marked as such:
  `strtod` returns 0 because micro-c has no float representation to parse into.
- **`impl/setjmp-aarch64.c`** — `libtcc.c:806` wraps every compilation in
  `setjmp`, so without it nothing compiles, *including successfully*.

  A portable aarch64 `setjmp` saves x19–x28 because the ABI calls them
  callee-saved. **micro-c uses none of them** — its convention is x13 locals,
  x17 base, x18 stack, `lr` return. Saving those four is sufficient for code
  *this* compiler generates, which is all the code here. Against any other
  compiler it would be wrong, and that is worth stating rather than
  discovering later.

A **layout audit** of everything in `micro-c-libc/` that must match something
outside micro-c found three wrong: `siginfo_t.si_code` at offset 16 where the
kernel puts it at 8, `struct sigaction` in glibc's field order rather than the
kernel's, and `struct tm` at 72 bytes instead of 36. All three were latent
because the functions reaching them are stubbed. The rule now: **any struct
crossing a boundary uses explicitly sized types for every field. `int` is not a
width here.**

---

## Tools

Built during this work, in `tools/`. Each exists because something was found
the slow way first.

| tool | what it answers | cost |
|---|---|---|
| `difftest.sh` | does this C construct behave as gcc does? | ~1 s per case, local |
| `vocabulary.sh` | does every macro micro-c can emit exist for that architecture? | static, five architectures at once |
| `regression.sh` | does micro-c still compile everything the reference compiles? | local |
| `instrument.py` | which statement did execution last complete? | one build, ~1 min local |
| `verify_defs.py` | does each aarch64 macro ENCODE what its name says? | static, instant |
| `verify-imm64.sh` | do the 64-bit immediate macros DO what they claim? | ~5 s, local under the emulator; native in CI |
| `imm-identity.sh` | did widening the immediate path move anything below the threshold? | ~10 s, local, both architectures |

**`difftest.sh` should have existed on day one.** micro-c targets amd64 and the
development machine *is* amd64, so its output can be compiled, linked and **run**
locally — no CI, no emulation. That was true from the start and went unused
because the work was aimed at aarch64. Every codegen bug found the hard way is
now a case in `tools/cases/`, and each takes about a second to check.

It now runs on **both** architectures — `ARCH=aarch64` in CI, where the
alignment class of bug is fatal rather than invisible, and locally too under
the emulator described below.

**Twice it has reported clean while assembling with the WRONG TABLE.** difftest
takes an M2libc directory and assembles each case with
`$M2LIBC/aarch64/aarch64_defs.M1`; it was being handed the vendored copy while
the patches went to another. Cases 05 and 46 stayed red against a compiler that
passed them locally. Whatever a tool is handed, check it is the thing the
patches reached.

**`vocabulary.sh` closed a whole class.** Four bugs were "that instruction does
not exist here" — `mov_x15,x1` missing on aarch64, `mov_rbx,r15` missing on
amd64, and two more. Each was found by assembling or running. All four ask a
question that can be answered **statically, for five architectures at once**. It
is a hard gate in CI.

**`verify-imm64.sh` asks a question neither of them can.** `verify_defs.py`
covers register-to-register forms, where the encoding is fully determined by the
name; a PC-relative literal load and a branch are not that shape. Those are
checked by RUNNING them -- a 64-bit constant goes through the literal pool and
both halves are read back, because a form that loaded only the low 32 bits (the
exact bug the vocabulary exists to fix) passes a low-byte check. It runs under
the committed emulator locally and NATIVELY in CI, and CI additionally
byte-anchors the same macros against real `as`, which is the one thing an
emulator cannot settle.

Worth stating plainly, because the opposite was believed for a round: **a
byte-compare is not the only way to check an encoding.** Byte-identity proves
the bytes are what `as` would emit. Running it proves the CPU does the intended
thing. The second is usually the question actually being asked, and this
repository has had an aarch64 emulator committed the whole time.

**`verify_defs.py` asks the question `vocabulary.sh` structurally cannot.**
Existence and correctness are different, and three macros in M2libc's aarch64
table exist and are wrong. For a register-to-register form the encoding is
fully determined by the name, so name and bytes can be compared by machine —
which is the only way, because by eye is exactly how three of them got in. It
covers `mov`/`add`/`sub` register forms only; immediates, loads, stores and
branches are left alone rather than half-checked, and amd64 is not covered at
all because x86-64 encoding is not a function of the mnemonic in the same way.

It nearly shipped reporting **eight false positives**: every `mov` involving
`sp`. SP and XZR are both register 31, and `MOV Xd,Xm` is an alias for
`ORR Xd,XZR,Xm` where 31 means XZR — so SP cannot be named that way and those
forms use `ADD Xd,Xn,#0`. All eight were right. A gate with false positives
gets switched off, and then the real errors beside it go unnoticed too.

**`instrument.py` matched CALL SITES, not definitions, and it was reading
wrong for as long as this file has existed.** `find_function` took the first
line containing `name(` that reached an opening brace within twelve lines, and
an `if` header ending in `{` is one:

```
tccgen.c:7274   if (!decl(VT_JMP)) {        <- was MATCHED as the body
tccgen.c:8664   static int decl(int l)      <- is the definition
```

Five functions in the set the workflow entry-marks landed on a call site —
`decl`, `is_compatible_types`, `parse_btype`, `pointed_type` in tccgen.c and
`bind_exe_dynsyms` in tccelf.c — out of 304. `--entry` does not dodge it; entry
marking still has to know where the body starts. `is_compatible_types` is on
the call path quoted below as the local win, so this was being read.

Nothing downstream could have caught it: **a wrong map and a right map look
identical in a log.** That is why `test_instrument.py` now exists and runs as
the first step of `tcc-two-ways`, and why the instrumented tree is put through
`gcc -fsyntax-only` before micro-c is asked to spend 55 seconds on it. Two of
the three bugs it pins were found by compiling the output rather than reading
it.

**`instrument.py` replaced hand-placed markers.** Six CI rounds were spent
adding one marker each and still ended with "somewhere in
`tcc_set_output_type`". The placement is mechanical, so the tool does every
statement at once. It also marks **control-flow rejoin points**, because a
marker after `if (...) {` sits inside the body and cannot print when the branch
is skipped — which understated progress by a dozen statements once.

It has had **four placement bugs**, and they share a shape: a line ending in a
character the tool reads as structure, in a context where it means something
else. A braceless loop body, so a frequency count meant nothing. A function's
own closing brace, so a marker landed at file scope. An aggregate initialiser,
so a marker landed between the braces of a constant expression. And the byte
count hardcoded at 4 — right for `"P01\n"`, one short for `"P100\n"`, so past
the hundredth marker the newline was dropped and two markers ran together on
one line, invisible to every `^`-anchored grep in the reporting. That one cost
a round chasing a dropped statement that had not been dropped.

**It cannot enter a switch.** Markers inside a switch body produce
`ERROR in process_switch / MISSING }`, so `next_nomacro` and `tok_str_add2` —
both squarely on the token path — must be probed by hand.

**And the set it covers has to follow the frontier.** When the fault moved into
`macro_subst_tok`, which was not in the list, the report named the last marker
INSIDE the list — `tok_alloc_new`, doing ordinary work — as the last thing that
happened. The step now prints what it instrumented and warns that a fault
outside that set appears as the last marker inside it.

### A note on reading these tools

Every reporting bug in this work had the same shape: **the tool answered
confidently in a case it could not distinguish.** The raw data was correct every
time; the sentence underneath it was wrong.

- a grep for `^T[0-9]` could not see markers `TA` through `TF`, so six markers
  added specifically to narrow a fault were invisible to the thing reporting on
  them
- "DIED IN tcc_set_output_type" came from markers that only bracket the
  *driver's* calls and never meant that
- a report announced "RETURNED NORMALLY" while the process was dumping core
- the instrumenter skipped `if (s1->do_debug && filename)` because it tested
  `'do' in line` and `"do"` appears inside `"do_debug"` — hiding the single most
  important line in that run

A tool that says nothing should be assumed **silent**, not conclusive. Twice the
instrumentation going quiet was read as the program becoming mysterious, when it
was the instrument running out of reach.

---

## Method: differential testing, reconciled

`README.md` says differential testing produced four confident root causes for
one bug and every one dissolved. That is accurate and it refers to a **different
technique with the same name**: mutating tcc's source and diffing exit codes,
which moves emitted layout and symbol-table state together.

What worked here is narrower and does not have that problem: compile a **small,
self-contained C program** with gcc and with micro-c, run both, compare the exit
code. Nothing about tcc is involved, so nothing about tcc can shift underneath
the measurement.

Both notes stand. The lesson is that "differential testing" names two things and
only one of them is sound here.

---

## Building and running it outside CI

For most of this work every question cost a CI round. It no longer does, and
the change was not cleverness — it was noticing that `spikes/reference/m2-planet`
had drifted **56 commits** past the pin, so the patch series would not apply to
it and micro-c could not be built locally at all. At the pin, all patches apply
and the binary is byte-identical to CI's.

What a sandbox needs, none of which it can fetch for itself. **All three are
now committed:**

| piece | why | where |
|---|---|---|
| M2-Planet at `bd2fe4b` | build micro-c | `spikes/reference/m2-planet/` |
| `qemu-aarch64-static` | RUN aarch64 output on an x86_64 host | `spikes/toolbox/` |
| tcc at the pin, configured | `tcc.h:27` includes a generated `config.h` | `spikes/toolbox/` |

`spikes/toolbox/README.md` records what each one is, which version, where it
came from and why it is acceptable to commit an opaque binary in a repository
whose whole point is that nothing opaque is committed. The short answer is that
neither file is on any build path: they cannot influence an output, only what
we observe about one.

`.github/workflows/local-toolbox.yml` regenerates them. It asserts the runner
is x86_64 — a `qemu-aarch64-static` built for aarch64 emulates aarch64 on
aarch64 and is useless — and it proves the emulator works by running a real
aarch64 binary under the copy it is about to upload, rather than claiming it.

**Two scripts do all of it**, and they are the answer to "how do I reproduce
this" rather than a list of commands in prose:

```sh
sh spikes/stage3/tools/local-build.sh
    # micro-c + patched M2libc + M1/hex2, then difftest on BOTH architectures

sh spikes/stage3/tools/local-tcc.sh build/local
    # compile tcc with micro-c, link it, run it under the emulator

sh spikes/stage3/tools/twelve.sh build/local
    # THE GATE. The twelve end-to-end programs, compiled and run by that tcc.
    # difftest and the corpus do not compile tcc and cannot stand in for this:
    # EXPERIMENT-zzzg left both green and broke all twelve.

sh spikes/stage3/tools/local-tcc.sh build/local tccpp.c macro_subst
    # the same, with those functions instrumented -- the last marker names
    # the statement execution reached
```

They exist as scripts because doing the obvious thing produces a compiler that
segfaults on case 05, and the natural conclusion is that micro-c is broken. It
is not. Four traps sit between a clean checkout and a working setup, all
silent:

| trap | symptom if you miss it |
|---|---|
| `git apply` inside this repo **skips and exits 0** | the patch series appears to apply and does nothing |
| M1's `max_string` defaults to 4096 | linking tcc dies on the keyword table, then hex2 fails on a file that does not exist |
| the `.M1` tables must come from the **patched** M2libc | cases 05 and 46 segfault against a compiler that passes them |
| code must precede strings in the joined `.M1` | a function lands off a 4-byte boundary and every call is SIGBUS |

Three of those were found the hard way and two of them cost days. The scripts
encode all four and assert the result rather than the action -- "the patch was
applied" and "the fix is in the file" are different claims and only the second
one matters.

With them the whole loop is local: micro-c builds in seconds, `libtcc.c`
compiles in about 30 s, the link produces a 1.52 MB aarch64 binary, and it runs
under the emulator. An instrumented round is about a minute. Every finding in
**Later rounds** above came out of that loop, and several of them were wrong
first — cheaply.

**The sandbox does not persist**, but since all three pieces are in the tree, a
fresh session needs only the repository.

---

## Honest limits of the case suite

90 cases -- 89 passing on both architectures and one KNOWN GAP -- plus 419 of the
426 programs in stage 2's conformance corpus, borrowed because a suite written
FROM bugs already found measures what has been fixed rather than what remains.
Three live codegen bugs came out of that corpus in one sitting, all of them
invisible to the case suite. It is **not** a claim about micro-c generally, because most cases were
written *from* bugs already found — they measure what has been fixed, not what
remains.

Three failures of the suite itself are worth more than the count:

**A case can pass because both sides are broken identically.** Case 43 checked
`&(x)` against `&x` and required them equal. Both loaded the member, so they
agreed, and it passed. It is anchored to a real address now. A case comparing
two forms of one construct tests only that they are consistent.

**A case can fail for another case's reason.** Case 27 used a global array to
test argument lists, so it failed on the global-array bug and would have gone
green when that was fixed, teaching nothing about argument lists. Its array is
local now.

**A case suite can be structurally blind.** Every array-of-pointers probe used
`long*`, where the element width and the pointed-at width are both 8 — so no
case could detect a wrong choice between them. Three green rounds passed while
tcc did not move. Case 31 makes the two numbers differ by six.

The cases written for constructs that had **never** failed are the ones that
earned their keep: nine of them, eight passed, and the ninth found `*p++ = x`
storing through a loaded value. That is the difference between a suite that
confirms fixes and one that finds bugs, and the remaining work is more of the
second kind: varargs, `const`/`volatile`, bitfield edge cases, nested
initialisers with designators.

A case whose first lines say `KNOWN GAP` is expected to fail and does not fail
the run. A known gap that starts **passing** is reported loudly, because it
means either the gap closed or the case stopped testing what it claims.

---

## Where the pieces are

```
patches/m2-planet/            0001-0004, the base fixes
patches/micro-c-experiments/  the enhancement series + README.txt (the long history)
patches/m2libc/               free(NULL), malloc reporting, va_copy's argument
                              order, and three wrong aarch64 encodings
patches/tcc-debug/            write() markers ONLY -- no logic, scratch copy, never the control
patches/tcc-arm64-asm/        pre-existing: the ARM64 assembler upstream tcc lacks
micro-c-libc/                 headers and impl/ -- the runtime under tcc
tools/                        difftest, vocabulary, regression, instrument, verify_defs
tools/cases/                  one C file per construct, 90 of them
```

55 patches build micro-c and 11 patch M2libc. Both workflows assert the count
with `-ge`, because a missing codegen patch looks exactly like a codegen bug.

`patches/micro-c-experiments/README.txt` is the working log — every wrong turn,
what it cost, and what settled it. It is long and it is the honest record.
`tools/README.txt` continues it round by round.

---

## The state, after the narrowing cast

**mc-tcc now compiles and runs all twelve programs in `stage3-hermetic-arm64`.**
That is the first time the end-to-end suite has been green, and it moved on one
fault, not four.

**READ THAT NARROWLY.** All twelve programs are small enough that tcc never
grows a section past its first allocation, so not one of them reaches
`realloc` -- which is where every larger input now dies. 12/12 means the twelve
things we chose to ask are all below that threshold, not that mc-tcc works. The
tests2 sweep below is the wider measurement and it is much less flattering.

```
    00-does-it-start                   rc=0   tcc_new and tcc_delete completed
    01-return-a-value  02-arithmetic  03-loops-and-if  04-recursion       ok
    05-pointers-and-arrays             exit=10   ok
    06-structs-by-pointer              exit=42   ok
    07-globals-and-bss  08-string-literal-write  09-char-switch-and-goto   ok
    10-function-pointers               exit=42   ok
    11-function-pointer-member         exit=0    ok
    12-prefix-operator-through-a-dot   exit=0    ok
    pass 12   fail 0
```

The fault was that **micro-c never truncated a narrowing cast** — `(uint32_t)x`
set the type and emitted nothing. Correct by accident while `int` was eight
bytes, and wrong from EXPERIMENT-zzw onward. tcc sign-extends a 32-bit local
offset by hand at `arm64-gen.c:494` and the extension ran on a value that was
never truncated, so every local offset came out 2^32 too small.

**Why it looked like four unrelated bugs.** The corrupted offset is masked away
in one path and fatal in the other:

| path | what happens |
|---|---|
| `svr == (VT_LOCAL \| VT_LVAL)` — a scalar load | reaches `arm64_ldrx`, which emits `ldur` with `(off & 511)`. The high bits are **masked off** and the damage never lands. |
| `svr == VT_LOCAL` — the **address** of a local, `:572` | the value goes into a range test and then straight into an instruction word, **unmasked**. |

So scalars worked, globals worked — they go through `VT_CONST` and a symbol —
and every program that took the address of, or indexed, a *local aggregate*
segfaulted. 05, 06, 11 and 12 are exactly that set. Nothing about the four
programs was the common factor; the common factor was one branch of `load()`.

### What this round is actually about

**A resemblance is not a cause.** Case 14 (`function-pointer-member`) and
program 11 are the same twelve lines of C, and case 14 was red at the same
time. It was tempting, and wrong, to read that as one bug: case 14 is compiled
by **micro-c**, program 11 by **mc-tcc**, so tcc lays that struct out, not
micro-c. Checking the tcc tree settled it in one grep — the only inline
function-pointer member in all of tcc is `void (*error_func)(...)` at
`tcc.h:856`, and `void` is register-sized, so micro-c's layout bug could not
reach tcc at all. Two real bugs, adjacent, sharing a shape and nothing else.
EXPERIMENT-zzzd fixes case 14 and moves no program.

**The probe cost nothing and named the cause in one run.** Six sub-steps of
the `arm64-gen.c:494` idiom, one bit each, compiled and run against gcc:

```
    bit 1  the cast truncates      FAIL        bit 8   sign extension   FAIL
    bit 2  (v >> 31) & 1           ok          bit 16  -svcul == 32     FAIL
    bit 4  (unsigned long)1 << 32  ok          bit 32  range test       FAIL
```

Five of the six were either already right or failing as a *consequence*.
Splitting them is what separated the one cause from the four symptoms — a case
checking only the final value would have said "the idiom is wrong" and named
nothing. zzb and zze had already made the shift and the precedence correct,
which is why bits 2 and 4 are green and worth keeping in case 102 anyway.

**Twelve lines of C, no tcc build, seconds per round.** The whole diagnosis ran
without compiling tcc once. Building tcc was needed only to *confirm* the fix,
after the cause was already known.

---

## The wider measurement: tcc's own tests2, one at a time

129 tests, each compiled by mc-tcc and run under the emulator, against a
control tcc built by **gcc from the same source**. The control decides which
tests count: one it cannot pass is measuring a gap in `tcc-test-shim` -- no
malloc, no file I/O, no floats -- not a defect in the compiler we built.

```
    pass 0    fail 57    not-applicable 72
```

Of the 57 that the control passes and we do not:

```
    46   M2libc: realloc: pointer was never returned by malloc
     5   SIGNAL 11 during compile
     1   error: type 'void *' does not match any association    (_Generic)
     1   compiled and ran, output differs
```

**One fault is eighty per cent of the failures.** Everything else is noise
until it is fixed.

BOTH SIDES GET THE SAME SINGLE FILE. mc-tcc cannot yet take two inputs in one
invocation, so `test.c` and `crt.c` are concatenated before either compiler
sees them. Handing the control two files and mc-tcc one would have measured
the multi-TU gap instead of codegen, and reported it as 57 codegen failures.
`tools/tests2-sweep.sh` encodes that. **It needs a control tcc built first** —
`gcc -w -O1 -o /tmp/tcc-control <workdir>/tcc-work/tcc.c -I<workdir>/tcc-work
-lm -ldl -lpthread`, which is an aarch64 cross compiler because the tree is
already configured for arm64. Without it the sweep reports 129
not-applicable and no failures, which reads as a clean run and is a harness
that never started.

---

## Confirmed in CI, on real hardware, in the box

`stage3-hermetic-arm64`, run 82972144199, commit `5bf4bac` — **green**, and
stage 3 reports `end to end: yes` for the first time.

```
    micro-c (ours)                   422320  083abe4a65edf263
    mc-tcc (ours, end to end)       1575057  c644e111c6c70b65
    00-does-it-start            rc=0  tcc version 0.9.28rc (AArch64 Linux)
    01..12                            all ok
    stage 3 end to end: yes
```

The driver line is the one to read: that is **tcc's own `--version`**, not our
175-line stub, produced by a tcc compiled from the seed. `GATE 1` passed in the
same run — `ours-gen1.M1` and `ref-gen1.M1` both 2,947,903 bytes,
`dc38e13e4ceaeecb` — with `BUDGET_PATH` empty, busybox as the only driver, **no
emulator** (native aarch64) and no network.

### And step 11's diagnostic now prints

The `head -3` truncation is gone, so the full trail is in the log — and the
native heap reproduces the local finding exactly:

```
    realloc: bad ptr        = 165789984
    realloc: nearest block  = 165787968     +2016
    realloc: nearest size   = 256
    realloc: live blocks    = 16
    realloc: ptr[-3] (blk?) = 165789984     <-- EQUALS THE BAD POINTER
    realloc: ptr[-2] (size?)= 256
    realloc: ptr[-1] (used?)= 1
```

The distance differs from the local run — 2016 rather than 288, because the
heap is laid out differently on the runner — **and the node signature is
identical**. A live block whose node is intact and unreachable. That the same
signature appears under a different allocator layout is worth more than either
measurement alone: the fault is in what the list contains, not in where the
heap happens to sit.

### The other two jobs

`tcc-two-ways` (82971079942) is **green**, and it now gets much further than
the run that opened this round — that one died at `imm-identity` before
reaching any of the subject steps. It reports:

```
    byte-identical 170   moved 8 (declared 8, undeclared 0)
    difftest clean on aarch64
    aarch64  426 rows: pass 419
    realloc GROWS AND PRESERVES correctly       (the standalone probe)
    SIGNAL 11 -- past the link inputs, crashing in output   (step 21)
```

**Step 21 is the first measurement of the libc-facing surface**, and it is not
a regression — the previous run never reached it. It compiles a trivial program
and **links it against the system crt and glibc**, borrowing `libtcc1.a` from
the control. It crashes inside `tcc_output_file`, past the point where the
input file was added. Everything else stage 3 has measured is
`-nostdlib -static` single-file, so this is new ground rather than a step
backwards.

`micro-c-builds-tcc` (82971079882) is **green**: every link set runs to exit
42, `tcc_new` completes. One thing to know about it — it reports

```
    skipped 0004-...  -- other revision       (and 0005 through 0011)
```

so it builds against an m2libc carrying only patches 0001–0003. That is
pre-existing and deliberate for that job's pin, but it means **its results say
nothing about the aarch64 encoding fixes, the narrowing-cast macros, or the
realloc diagnostics**, and it should not be read as a second opinion on them.

---

## The corruption, found — and the first fix for it withdrawn

> **HISTORICAL -- this fault is CLOSED.** `EXPERIMENT-zzzh` fixed all three
> faults in `*f(args)` and the case that guards them (105) is green. It did
> NOT close the `realloc` corruption, which had a different cause entirely;
> see "The corruption, and the measurement that was lying about it" below.
> Kept because the withdrawal of `zzzg` is the reason the twelve are the gate.

**A pending `*` lands on the function's ARGUMENT.**

`*f(8)` is `*(f(8))`. `primary_expr_variable` eats the stars and parks the
count in `num_dereference_after_postfix` for the postfix walk — but the
argument list is parsed between those two points, and every argument is a full
expression reading the same global:

```
    mov_x0,8            # primary expr number
    ldrsw_x0,[x0]       # <-- dereferencing the literal 8 as an address
    str_x0,[x18,-8]!    # function argument
```

**tcc writes every byte of `.eh_frame` through exactly this shape** —
`tccdbg.c:550`, `*(uint8_t*)section_ptr_add((s), 1) = (data)`. In a twelve-line
program the bogus address is unmapped and the process dies, which is why no
case caught it. Inside tcc the address is usually **mapped**: the write
silently lands on the wrong memory, an allocator node's `next` takes a small
value, and 62 of 79 nodes drop off the list — surfacing much later as
`realloc: pointer was never returned by malloc`, true of the list and false of
the heap.

### The diagnosis is solid. The fix was not.

`EXPERIMENT-zzzg` saved and restored the count around the argument list. Case
105's read forms passed, difftest stayed 89/0, the 426-corpus stayed at 419 —
**and mc-tcc went from 12/12 to 0/12 on the end-to-end programs.** Bisected:
the `num_dereference_after_postfix` save/restore alone does it; the
`Address_of` half is innocent. **Withdrawn.**

There is already a note in the file explaining why this is delicate:

> `CONSUMED HERE.` This branch applies the dereference itself, so the deferred
> count added for `*bf->buf_end` must be cleared or postfix_expr applies it a
> **second time** — which is exactly what broke `*pal = al`.

The count is cleared deliberately on at least one path, so restoring it
unconditionally after an argument list resurrects it somewhere that had already
consumed it. **A correct fix has to know which pending count belongs to the
call and which belongs to an enclosing expression, and a single global cannot
express that.** That is the structural problem this file counts eight
implementations of, and it is the strongest argument yet for carrying the state
on the expression rather than in a global.

### What that says about the gates

difftest (90 cases) and the stage-2 corpus (426 programs) were **both green**
over a change that breaks every one of the twelve end-to-end programs. Neither
compiles tcc. **The twelve are the only gate that exercises micro-c's output on
a real program**, and they need a tcc build to run — so the cheap suites cannot
stand in for them. Run the twelve before believing any codegen change.

### The route that found it

Four hypotheses died against the realloc message first. What moved it:

1. classify the bad pointer three ways — free list, interior, neither
2. **read the memory at it** — the 32 bytes below were a `_malloc_node` whose
   `block` field *was* the pointer. Live block, unreachable node.
3. a node-loss detector — created vs reachable, bounded so a cycle reports
   rather than hangs. 62 lost in one store.
4. **read the neighbour's bytes** — a DWARF CIE, augmentation `"zR"`,
   return-address register 30. `.eh_frame`.
5. reduce the writer's shape to twelve lines and diff against gcc.

Steps 2 and 4 are the same move and both were decisive.

---

## The next piece of work

> **HISTORICAL -- superseded by "Next" below.** All three `*f(args)` faults
> listed here are fixed (`EXPERIMENT-zzzh`); case 105 is no longer a KNOWN GAP.

**Three faults in `*f(args)`, none fixed.** Case 105 is `KNOWN GAP`.

1. **The pending `*` lands on the argument.** Diagnosed exactly; the naive fix
   regresses tcc. Needs the count to be owned by the expression rather than by
   a global.
2. **The return type does not reach `current_target`**, so the dereference uses
   the wrong width. Cause known: under a leading `*`, `primary_expr`'s
   direct-call fast path does not match (it tests `global_token->s`, which is
   `*`), so the call goes through `function_call(NULL, TRUE)` with no symbol.
   A fix that carried the symbol in another global was written and **not
   shipped**, because it was measured against a contaminated tree and the
   attribution was never established cleanly.
3. **`*f(x) = v` loads through the returned pointer.** For a variable one load
   is right; for a call result it is one step too far.

All three are on the `.eh_frame` path, so tcc keeps corrupting its heap until
they close.

---

---

## The corruption, and the measurement that was lying about it

**The `realloc: pointer was never returned by malloc` fault is closed.** It was
`sizeof` of a dereferenced MEMBER pointer.

```
sizeof(*p)        on a plain pointer   CORRECT, and always was
sizeof(*s->tab)   through a member     returned the POINTER's width -- 8, not 16
```

`sizeof(*s->tab)` is `sizeof(*(s->tab))`, but the stars were applied to the BASE
VARIABLE's type before the member chain was walked, so it measured `(*s).tab`.
The two forms disagree only when a member sits between the star and the name,
which is why a plain pointer tested clean every round. Entry 20 fixed exactly
this precedence in `postfix_expr`; `sizeof` kept its own copy. `EXPERIMENT-zzzi`.

WHAT IT COST. `tccelf.c:815` sizes the symbol-attribute table with
`n * sizeof(*s1->sym_attrs)`, so the table was ALLOCATED at half the width its
own indexing strides through. Probing every input to the GOT relocation, same
object linked two ways:

```
    sym_index    control      mc-tcc
        2        0x18         0x18
        3        0x20         0x65007374     <-- printable ASCII, from a string
        4        0x28         0x20
```

One GOT entry resolved to `0x654281f0` instead of `0x420ea0`, and every linked
binary died on its second string literal.

**THE FAILURE WAS HEAP-LAYOUT DEPENDENT, AND THAT INVALIDATED TWO ROUNDS OF
BISECTION.** The same source, same binary, succeeded or failed on the length of
its own FILENAME:

```
a.c ab.c abc.c        rc=0    compiles
abcd.c ... abcdefgh.c rc=1    realloc: pointer was never returned
```

The filename is stored on the heap, so its length shifts every later allocation
and decides whether the stray write lands on a live allocator node. Bisecting
the INPUT therefore finds filename lengths, not language constructs: two
confident diagnoses -- "a declaration after a statement" and "two printf calls"
-- were both really measuring layout and were withdrawn. `tools/layout-sweep.sh`
exists so this is a swept parameter rather than an uncontrolled one; it went
0/24 to 16/16 over the fix, which is what distinguishes a fix from displaced
damage.

WHAT ACTUALLY FOUND IT was not a probe or a bisection. It was splitting tcc's
own phases and cross-linking against the control:

```
mc-tcc -E     rc=0    preprocessing fine
mc-tcc -c     rc=0    CODE GENERATION FINE
-c -> control links   42 / 64 / 12, 34   correct output
-c -> mc-tcc links    42, then SIGSEGV
```

That cleared codegen and confined the fault to the linker in one command.
Byte-diffing the two binaries gave a single ADRP+LDR pair, and a probe on the
relocation inputs named the one value that differed.

---

## What is still wrong

**1. Floating point does not work at all.** Not "is imprecise" -- a binary
mc-tcc produced gets `double a = 12.5; (long)a == 12` FALSE. Add, multiply,
divide and compare all fail the same way. This is micro-c's recorded
unsoundness (float, double and long double are one word-sized integer) reaching
the tcc it builds. It accounts for **ten of the thirteen** remaining tests2
differences, and it is why `sources/musl.toml` will matter: nothing that
touches a float can be trusted until this is closed.

`patches/tcc-microc/0001` sets `LDOUBLE_SIZE 8` so the built tcc is at least
CONSISTENT with itself -- tcc's own guard otherwise refuses to emit any long
double constant, not even `0.0`. That made `tcc.c` compilable. It did not make
floats work, and it gives long double 8 bytes where the aarch64 ABI gives 16.

**2. `tcctest.c` does not compile.** It is the file tcc's own test1, test2 and
test3 all begin with, so all three are blocked. The wide-literal fix
(`EXPERIMENT-zzzk`) moved it from line 424 (`string_test`) to line 1103
(`struct_test`) -- 679 lines -- and it segfaults there. **Ten probes against
that range reproduced nothing in isolation** (`__alignof__`, zero-length
arrays, `__attribute__` before the tag, pointer diffs with casts, `uintptr_t`,
empty structs, unions, large locals), so it is cumulative or not yet spotted.
The technique that worked for 00_assignment -- bisect INSIDE the function
rather than probe around it -- has not been tried yet.

**3. The usual arithmetic conversions.** Case 110, `KNOWN GAP`. An `int`
compared against a hex literal above `INT_MAX` should convert the int to
unsigned; micro-c folds constants as signed 64-bit (correctly, per `zzb`) and
never applies the literal's TYPE to the other operand. Found because it made
case 109 fail for a reason case 109 did not claim to test.

---

## The libc rung -- what gen2 actually needs

gen2's object references **90 undefined symbols**. They are not one problem:

| what | count | source | who builds it |
|---|---|---|---|
| `__addtf3`, `__divtf3`, `__clear_cache`, ... | ~19 | tcc's own `lib/` | **mc-tcc, proven** |
| `memcpy`, `printf`, `malloc`, `open`, ... | ~70 | musl | not yet attempted |

**NEITHER IS A HOST DEPENDENCY**, and that is the whole point of stage 3.
`stage4-complete.yml` binds host `/usr` and masks only compilers -- its own
header calls tcc's provenance "the one declared hole". The stage 3 box has no
`/usr` at all, only busybox, so nothing can be borrowed.

`tools/runtime-ladder.sh` measures the floor and it is CLEAR:

```
A. libtcc1 for arm64          7 of 7    including the three .S files
B. musl's idioms              4 of 4    weak_alias, hidden, __typeof, weak
C. register syscalls          ok        write() correct, exit(7) correct -- RUN
```

Note `libtcc1.c` is NOT in the arm64 build (`ARM64_O = lib-arm64.o $(COMMON_O)`);
reaching for it gives a misleading "unsupported CPU type" that says nothing
about the compiler. Rung C is executed rather than compiled because musl pins
syscall operands to `x8`/`x0-x5` with register asm, and a compiler that accepts
the syntax and allocates a different register makes the WRONG SYSCALL silently.

**M2libc does not need to become mc-tcc-compilable, and an earlier plan here
saying so was wrong.** live-bootstrap never compiles mes-libc with tcc either:
the weak compiler builds the bootstrap libc, the first real compiler builds the
real one. M2libc already plays mes-libc's part, already compiled from source
from the seed. The next rung is **musl 1.2.5, built by mc-tcc** -- pinned in
`sources/musl.toml`, with the 9 aarch64 `.s` files that fall back to portable C
and `src/complex/*.c` dropped for `_Complex` already declared there. Stage 4
proved that recipe with a HOST-BUILT tcc; whether mc-tcc clears the same bar is
untested and needs a runner with network.

---

## The harness has been the dominant term, twice

Both times, a number that looked like a compiler defect was the measurement.

**FIRST: the comparison was stricter than tcc's own.** tcc's
`tests2/Makefile:142` uses `diff -Nbu` -- `-b` ignores whitespace differences --
and the `.expect` files rely on it. `38_multiple_array_index` prints `"%d "` per
element and so emits a trailing space its `.expect` does not carry. Comparing
with `cmp` marked three tests failed and reported a compiler defect where there
was a space. busybox has no `diff`, so step 11 normalises instead and compares
through command substitution, which also handles a missing final newline.
**56 -> 59.**

**SECOND: the shim mislabels a compiler defect as its own gap.** Of the
thirteen tests2 programs that still differ:

```
10   printf %f / %g -- "[shim: ... is not implemented]"
 1   31_args -- _start calls main(void), so argc/argv are garbage
 1   134_double_to_signed -- %llu genuinely unhandled
 2   03_struct, 102_alignas -- a missing WARNING in the output, not wrong code
 0   genuinely wrong values
```

The ten are not a shim gap. mc-tcc has no working floating point, so a `%f`
implementation would format wrong values precisely -- and the shim is itself
compiled by mc-tcc, so its own arithmetic would be wrong too. **There is nothing
to implement there until floats work.** The message should name floating point
as the cause instead of this file's incompleteness. THIS IS NOT DONE; see
"Next".

The two that ARE real shim gaps -- argv and `%llu` -- are small and worth
fixing, and the design is written out under "Next".

---

## A THIRD TIME: a header, and a local gate that could not see it

`stage3-hermetic-arm64` at `e01bc10` reported

```
    micro-c could not compile libtcc.c (rc=1)
      tccgen.c:25:Unable to find include file: float.h
    stage 3 end to end: no
```

after two consecutive green runs, and nothing about micro-c had changed. The
cause is two commits from the float work: `0b07e37` and `2a8bf60` added
`tcc-arm64-asm` patches 0006 and 0007, and 0006 opens with

```c
 #define USING_GLOBALS
 #include "tcc.h"
+#include <math.h>
+#include <float.h>
```

`micro-c-libc` had `math.h`. It had no `float.h`, so tccgen.c stopped
preprocessing at the second line and every rung above it -- tests2, tcctest.c,
self-compilation -- reported `skipped: no mc-tcc was produced`.

**WHY NOTHING ELSE WENT RED.** Twelve jobs apply that series. Ten of them build
tcc with the HOST compiler, and a host has a `float.h`; the include is
invisible there. Only `stage3-hermetic-arm64` and `micro-c-builds-tcc` put
*micro-c* behind that `#include`, with an include path of `-I . -I
micro-c-libc -I m2libc-veron` and no system directory at all. A patch tested
against a host toolchain landed on the one path that has no host.

**WHY local-tcc.sh STAYED GREEN, WHICH IS THE WORSE HALF.** It never applied
the `tcc-arm64-asm` series -- the pinned tarball is pre-patched for 0001-0005,
so skipping it was correct right up until the series grew. From `0b07e37`
onward the local gate compiled a tccgen.c with no `#include <float.h>` in it:
a different tree from the one CI compiles, differing precisely at the fault.
The script now applies whichever patches in that series are not already in the
tarball -- two today, five skipped -- and asserts the two float patches are
present in the file afterwards, because "the patch ran" and "the fix is there"
are the different claims TRAP 3 already separates for the m2libc defs.

**THE FIX.** `spikes/stage3/micro-c-libc/float.h`, integer macros only, saying
what micro-c's float model actually is: one eight-byte type, so `FLT_`, `DBL_`
and `LDBL_` all carry the IEEE double values. That makes 0006's own guard

```c
#if defined LDBL_MANT_DIG && LDBL_MANT_DIG == 64
```

false, and its x87-to-binary128 conversion -- written for an x86_64 host
cross-compiling to arm64, which micro-c is not -- compiles out. The header
declines to define `FLT_EPSILON`, `DBL_MAX` and the rest of the value macros:
the whole pinned tcc tree references exactly one name from `float.h`
(`FLT_ROUNDS`) and 0006 adds one more (`LDBL_MANT_DIG`), neither of them a
float literal, and this directory's rule is measured rather than complete.

Two exact-count guards went with it. `micro-c-builds-tcc` and
`upload-gap-trees` both asserted `[ "$n" = 5 ]` over a series that is now
seven, which would have failed those jobs for the arithmetic rather than for
anything about tcc. Both are floors now, like the other four.

**THE GENERAL SHAPE, WHICH IS THE POINT.** micro-c has no system include path,
so any patch that adds an `#include <...>` to tcc's source is a change to
micro-c's libc whether or not its author was thinking about micro-c. The
airlock now sweeps every angle-bracket include in the patched tree against the
three directories step 10 actually passes and prints the ones that do not
resolve. Four do not -- `dispatch/dispatch.h`, `glob.h`, `io.h`, `process.h`,
all macOS or Windows and all behind `#ifdef`s that never fire here -- so it is
a NOTE rather than a failure, but the next one arrives named, in the airlock,
instead of as three truncated lines of stderr four hundred lines later.

---

---

## CI, and what each job is worth

All three green as of `fff3b7d`. They answer different questions and none of
them subsumes another.

| job | what it proves |
|---|---|
| `stage3-hermetic-arm64` | the climb, in the sealed box, `BUDGET_PATH` empty. GATE 1: our seed-built M2-Planet emits **byte-identical** output to upstream's (`2947903`, `dc38e13e4ceaeecb`). Then `stage 3 end to end: yes`, the twelve, and the full tests2 sweep |
| `tcc-two-ways` | the same compiler measured against a **gcc-built control from the same source**. The control decides which tests count; it also reaches `FIXPOINT: gen2 and gen3 byte-identical`, which is the bar our side has to clear |
| `micro-c-builds-tcc` | the link-set ladder, every rung `MAIN RAN (exit 42)`. Note it **skips m2libc patches 0004-0011 as "other revision"**, so it says nothing about the aarch64 encoding fixes, the narrowing-cast macros or the realloc diagnostics -- do not read it as a second opinion on those |

**THE HERMETIC JOB IS THE ONE WITH NO CONTROL IN IT**, because a control needs
gcc and gcc is not in the budget. That is why step 11 there reports how many of
tcc's own programs match `.expect` and does NOT attribute the failures.
Attribution lives in `tcc-two-ways`; the count lives in the box.

TWO THINGS CI CAUGHT THAT LOCAL RUNS DID NOT, both recorded above and both
structural rather than bad luck:

  * `imm-identity` went red on cases 107 and 110 carrying undeclared wide
    constants. The guard was right and the case author was wrong.
  * `101-cast-to-a-narrower-integer` was BROKEN on the runner -- plain `char`
    is signed on x86-64 and unsigned on aarch64, and the local reference is
    built by an x86-64 gcc. See `tools/README.txt` for the `-funsigned-char`
    check that catches this class before it reaches CI.

## Next -- in order, with the work already scoped

**1. FIX THE SHIM. Designed, not written.** `spikes/stage3/tcc-test-shim/crt.c`.
Three changes, none of them large:

  a. **argc/argv.** `_start` is an ordinary C function calling `main()` with no
     arguments, so `31_args` reads garbage. Reading `sp` from inside a C
     function does NOT work -- the prologue has already moved it -- so the entry
     has to be a global asm block that captures `sp` and tail-calls a C
     function. mc-tcc assembles this; `mov x0, sp` and `b` are both covered:

         __asm__(".global _start\n"
                 "_start:\n"
                 "    mov x0, sp\n"
                 "    b _start_c\n");
         void _start_c(long *sp) {
             int argc = (int)sp[0];
             char **argv = (char **)(sp + 1);
             ...  /* envp follows argv's NULL */
             sys3(93, main(argc, argv, envp), 0, 0);
         }

  b. **`%ll`.** Same width as `%l` on LP64, so consume one more `l`.
     `134_double_to_signed` writes `%llu` and hits the abort as though the shim
     could not print a long. Add `%zu`/`%zd` at the same time.

  c. **SPLIT THE ABORT IN TWO.** This is the one that matters and it is the
     reason the shim's numbers have been misread:

         [shim: ...]        this file is missing something. Our fault.
         [needs-float: ...] the conversion is fine and THE COMPILER is not.

     Give the second a distinct exit status (71 against 70) so a harness can
     tell them apart without parsing text, and teach the sweeps a third bucket.
     Ten tests2 differences move from "harness gap" to "blocked on floating
     point", which is where they belong.

  Flags and width should be SKIPPED rather than interpreted -- `diff -b` does
  not care about column alignment -- but a ZERO-padded field changes characters
  and must keep aborting.

**2. WHY STEP A SEGFAULTS NATIVELY BUT NOT UNDER QEMU.** The emulator is
permissive where real aarch64 traps, and alignment has hidden two bugs in this
project already. It needs a native runner: the local loop is structurally blind
to it. Until it closes, "mc-tcc compiles tcc.c" is a qemu-only claim.

DO NOT REDUCE IT BY CONSTRUCT. It disappears under instrumentation, so it is a
layout fault; see the note under the status block. Sweep layout instead.

**3. `tcctest.c`'s `struct_test` blocker.** Bisect INSIDE the function by
deleting statements, which is what cracked 00_assignment; ten probes AROUND it
found nothing. Unblocks test1/test2/test3.

**4. Floating point in micro-c.** The largest item and the one everything
numerical waits on. Ten tests2 differences, `sources/musl.toml`'s
`src/complex/*.c` exclusion, and any honest claim about compiling gcc.

**5. musl 1.2.5, built by mc-tcc.** Needs a runner with network. The floor is
clear (`tools/runtime-ladder.sh`); whether musl itself compiles is untested.
Landing it gives gen2 something to link against, and steps 2-5 of the fixpoint
follow.

### Reproducing any of this

Everything below runs from the repository alone, no network, in this order:

```
sh spikes/stage3/tools/local-build.sh              micro-c + difftest + corpus
sh spikes/stage3/tools/local-tcc.sh   build/local  compiles tcc -> mc-tcc
sh spikes/stage3/tools/twelve.sh      build/local  the twelve; the gate that matters
sh spikes/stage3/tools/runtime-ladder.sh           libtcc1, musl idioms, syscalls
```

`tools/tests2-one.sh` and the full tests2 sweep additionally need a **control**,
which nothing else builds:

```
gcc -w -O1 -o /tmp/tcc-control build/local/tcc-work/tcc.c \
    -Ibuild/local/tcc-work -lm -ldl -lpthread
```

The tree is configured for arm64, so that is an aarch64 CROSS compiler on an
x86_64 host -- same source, same target, different builder, which is the point.
Without it the sweep reports every test not-applicable, which reads as a clean
run and is a harness that never started.

### The tools, and which question each answers

| tool | question |
|---|---|
| `local-build.sh` | does micro-c build, and does the case suite pass |
| `local-tcc.sh` | does micro-c compile tcc into `mc-tcc` |
| `twelve.sh` | **the only gate that runs micro-c's output on a real program** |
| `one.sh` | one case, one architecture, and the emitted M1 -- the microscope |
| `difftest.sh` / `difftest-qemu.sh` | the 95-case suite, per architecture |
| `stage2-corpus.sh` | 426 programs written for a different compiler |
| `layout-sweep.sh` | is a failure real, or heap-layout roulette |
| `tests2-one.sh` | walk tcc's tests2 one at a time, stop at the first failure |
| `runtime-ladder.sh` | can mc-tcc build the pieces a libc stands on |

**RUN THE TWELVE BEFORE BELIEVING ANY CODEGEN CHANGE.** difftest and the
426-corpus were both green over `EXPERIMENT-zzzg`, which broke all twelve.
Neither compiles tcc; the twelve is the only gate that does.

**AND CHECK BYTE-IDENTITY WHEN TOUCHING A HEADER.** `micro-c-libc/` is on
micro-c's own build path. Recompiling the whole tcc unit before and after and
requiring an identical `.M1` is what caught a `fcntl.h` shadow silently
dropping M2libc's `_open` -- 95 lines -- which nothing else would have found.

## And then the structural work

Unchanged and still argued for. Nine of the bugs in this file are "one rule,
several implementations, and the copies disagree", and **that class has cost
more than every missing feature put together**. This round adds a tenth of a
slightly different kind: `build_member` had the right type in hand and read the
size from the wrong variable, eighty lines apart.

The fix is to carry the type on the expression instead of in a global, and to
have one function answer "load or address, and how wide" — and, on `zz8`'s
evidence, a second answering "is this an lvalue", since that question is
currently asked eight different ways. `EXPERIMENT-zz7` is a small down payment
on the first.

That is a refactor of every site that reads the flags, and it wants the case
suite as a net — which is why the suite came first, and why its three
structural failures above are worth reading before trusting it.
