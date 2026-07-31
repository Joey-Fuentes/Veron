# micro-c — the direct route from M2-Planet to tcc

**What this is.** `ROADMAP.md` leg 1 proposed enhancing M2-Planet until it can
compile tcc directly, rather than reaching tcc through Mes. That enhanced
compiler is called **micro-c**: M2-Planet at pin `bd2fe4b` plus a patch series.
This file is its state.

**Status: it compiles all of tcc, links a 1.52 MB aarch64 binary, and that
binary runs, reports diagnostics, preprocesses its own predefs and a real
source file, interns the whole keyword table, and is now INSIDE macro
expansion, having survived a full pass of `macro_subst`'s substitution loop.**
It is not a working tcc. It is a long way past "gets into the preprocessor",
which is what this file said before.

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

87 cases, all passing on both architectures -- plus 423 of the
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
tools/cases/                  one C file per construct, 87 of them
```

53 patches build micro-c and 10 patch M2libc. Both workflows assert the count
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
`tools/tests2-sweep.sh` encodes that.

---

## The next piece of work

**THE OPEN FRONTIER: realloc is handed an address that was never a block.**

Reproduction, about a minute, no instrumentation:

```
    cat tests/tests2/00_assignment.c            > u.c
    grep -v '^int main(void);$' crt.c          >> u.c
    mc-tcc -B<tcc-src> -I<shim> -nostdlib -static -o m.bin u.c
```

### What it is not

Each ruled out by measurement, and each ruling-out is cheap to redo:

* **Not the allocator.** `main-06-realloc.c` passes.
  `main-07-realloc-sequences.c` was written for this and passes too -- seven
  shapes main-06 does not reach: a block reused from the free list, chained
  reallocs, a grow with another block freed in between, a shrink, sixty-four
  allocations of churn before growing the *oldest* block, twenty-four reallocs
  interleaved with mallocs, and content survival across a move.
* **Not a use-after-free.** m2libc patch 0011 walks `_free_list` before dying.
  The pointer is not on it.
* **Not an interior pointer or a header skip.** 0011 also checks whether the
  address falls inside any live block. It does not -- so it is not
  `((tal_header_t *)p) - 1`, which was the obvious guess.
* **Not the malloc/realloc signature mismatch.** M2libc defines
  `malloc(unsigned)` and `realloc(void*, unsigned)` -- four bytes since zzw --
  while `micro-c-libc/stdlib.h` declares both with `unsigned long`. That is a
  real disagreement and worth tidying, but it is **not this bug**: the probes
  above cross the same boundary and pass. It was the first hypothesis here and
  it was wrong.

### What is known

The address is in the heap region, is not a block start in either list, and is
not interior to any live block. 0011 reports the distance to the nearest block
start:

```
    realloc: not a block; bytes to the NEAREST block start is (288)
```

**288 is not a new number in this file.** The earlier frontier -- the two-slot
write into `table_ident`, recorded above as closed -- reported its two
overwritten values as `288 bytes apart`. Whether that is the same structure is
**not established**, and it must not be assumed. It is written down because the
coincidence is worth one grep by whoever picks this up, and because "already
closed" is exactly the reason nobody looked again. That frontier section stood
in this file describing a fault that had stopped reproducing before the round
that finally read it.

### Where to look next

The five `SIGNAL 11 during compile` failures are a separate set and may or may
not share a cause; nothing here has looked at them. `_Generic` is a genuine
missing feature and is the only failure in the sweep that is honestly a
*feature* gap rather than a defect.

The instrumentation loop in `local-tcc.sh` -- `INST_MODE=entry` over
`tccpp.c` and `libtcc.c` -- is the tool for naming the call site, and it has
not been run on this yet. Read the warnings in `tools/README.txt` first: four
instrument bugs during the last hunt produced false negatives that were acted
on, and three "ruled out" conclusions had to be retracted.

### Multi-file input: CLOSED, and it was never a compiler fault

**mc-tcc is now built from `tcc.c` -- tcc's own `main`.** EXPERIMENT-zzzf taught
micro-c the one declaration that stood in the way, `static const ArHdr
arhdr_init` at tcctools.c:60, and tcc.c compiles unmodified: 707 functions
against libtcc's 695.

```
    $ mc-tcc --version
    tcc version 0.9.28rc (AArch64 Linux)
```

`-E`, `-c`, `-print-search-dirs` and **multiple input files** all work now,
because they are tcc's code and always were. Two files in one invocation
compile, link and run.

What had looked like a codegen frontier was `micro-c-libc/impl/main-tcc.c`, a
175-line driver of our own holding `char* input = 0;` -- one pointer, overwritten
by each file. `stage3-hermetic-arm64` step 11 passes a test and a crt, so it
compiled the crt alone and reported `undefined symbol 'main'`: a true message
about an invalid test, recorded as a stage-3 failure for several rounds. That
driver is superseded, kept only for bisecting "compiler or driver", and it now
REFUSES a second input rather than silently keeping the last.

**And a second fault surfaced only when tcc.c was linked.** The `.M1` join split
two ways, at `# Program strings`, which left each unit's GLOBALS glued to its
code. A global holding a string is arbitrary-length data between one unit's code
and the next unit's functions -- harmless while libtcc.M1's globals happened to
total a multiple of four, and fatal once tcc.c added

    :GLOBAL_STORAGE_version   "tcc version 0.9.28rc (AArch64 Linux)\n"

Every function after it landed misaligned: SIGBUS before `main`. The join is
three-way now, in `local-tcc.sh` and in the workflow. It was latent in both.

---

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
