# micro-c — the direct route from M2-Planet to tcc

**What this is.** `ROADMAP.md` leg 1 proposed enhancing M2-Planet until it can
compile tcc directly, rather than reaching tcc through Mes. That enhanced
compiler is called **micro-c**: M2-Planet at pin `bd2fe4b` plus a patch series.
This file is its state.

**Status: it compiles all of tcc, links a 1.45 MB aarch64 binary, and that
binary runs and gets into tcc's preprocessor before it faults.** It is not a
working tcc. It is much further than "measured, not started", which is what
`ROADMAP.md` said before this.

---

## Where it gets to

Run by `.github/workflows/tcc-two-ways.yml` on `ubuntu-24.04-arm`, native, no
emulation.

```
micro-c compiles libtcc.c    371,437 lines of M1, 695 functions
assembles and links          ~1.45 MB, ELF64 AArch64, main aligned
runs                         tcc_new completes
                             tcc_set_output_type completes
                             tcc_compile reached, buffer allocated, source copied
                             preprocess_start reached
                             tccpp_new reached, keyword table loop entered
                             faults inside tok_alloc
```

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

Twelve patches, and the interesting thing is not the count but that **four
separate bugs turned out to be one missing concept, and four more were one
duplicated rule.**

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

## What is still wrong

| gap | consequence |
|---|---|
| `int` is EIGHT bytes | every struct differs from a normal ABI; three of our own headers had wrong layouts because of it |
| pointer arithmetic does not scale | `p + n` advances n **bytes**, not n elements. Indexing scales correctly, which is why it survived — M2-Planet indexes and rarely adds. Documented as difftest case 21 with a fix that is written and **not wired in**, because it fixed two cases and broke a third |
| `float`/`double`/`long double` | one word-sized integer type |
| `constant_expression` precedence | `a\|b&c` folds right-to-left |
| 19 load sites | see above |

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
| `instrument.py` | which statement did execution last complete? | one CI round |

**`difftest.sh` should have existed on day one.** micro-c targets amd64 and the
development machine *is* amd64, so its output can be compiled, linked and **run**
locally — no CI, no emulation. That was true from the start and went unused
because the work was aimed at aarch64. Every codegen bug found the hard way is
now a case in `tools/cases/`, and each takes about a second to check.

It now runs on **both** architectures — `ARCH=aarch64` in CI, where the
alignment class of bug is fatal rather than invisible.

**`vocabulary.sh` closed a whole class.** Four bugs were "that instruction does
not exist here" — `mov_x15,x1` missing on aarch64, `mov_rbx,r15` missing on
amd64, and two more. Each was found by assembling or running. All four ask a
question that can be answered **statically, for five architectures at once**. It
is a hard gate in CI.

**`instrument.py` replaced hand-placed markers.** Six CI rounds were spent
adding one marker each and still ended with "somewhere in
`tcc_set_output_type`". The placement is mechanical, so the tool does every
statement at once. It also marks **control-flow rejoin points**, because a
marker after `if (...) {` sits inside the body and cannot print when the branch
is skipped — which understated progress by a dozen statements once.

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

## Honest limits of the case suite

22 passing cases is 22 constructs behaving as gcc does. It is **not** a claim
about micro-c generally, because most cases were written *from* bugs already
found — they measure what has been fixed, not what remains.

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
patches/m2libc/               free(NULL) is a no-op; malloc reports refused sizes
patches/tcc-debug/            write() markers ONLY -- no logic, scratch copy, never the control
patches/tcc-arm64-asm/        pre-existing: the ARM64 assembler upstream tcc lacks
micro-c-libc/                 headers and impl/ -- the runtime under tcc
tools/                        difftest, vocabulary, regression, instrument
tools/cases/                  one C file per construct
```

`patches/micro-c-experiments/README.txt` is the working log — every wrong turn,
what it cost, and what settled it. It is long and it is the honest record.
