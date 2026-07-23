# Target C subset — the handoff spec for the stage ladder

**Invariants SUSPENDED (spike doc).** This is a planning/reference doc for the
`spikes/` tracer, not part of the aspirational trunk. It defines the *finish
line* for the self-hosted compiler ladder and the C subset each rung is working
toward, grounded in the actual upstream source rather than guesswork.

## 0. The finish line (why this doc exists)

The near-term plan (see `HANDOFF` / `PROGRESS.md`) is: grow the self-hosted
ladder (stage 0 → 1 → 2 → 3 …) until one of our stages can **compile M2-Planet's
own source** into a working `M2-Planet` binary, then hand that binary to the
already-GREEN borrowed chain (`spikes/borrow-m2/`, `spikes/livebootstrap/`):

```
M2-Planet source ──[ our stage-N compiler ]──► M2-Planet binary
                 ──[ M1 + hex2 (mescc-tools) ]─► drives Mes → tcc → gcc
```

M2-Planet is **self-hosting**: its own compiler is written in the C subset it
accepts. So its source *is* the precise definition of the C subset we must
eventually accept — no more, no less. That makes "M2-Planet-grade C" a concrete
checklist instead of a vibe, which is what this doc records.

The borrow-m2 spike currently builds M2-Planet with the *host* gcc (it only
proves the downstream chain runs on our setup). The bootstrap goal is to replace
that one step — "host gcc builds M2-Planet" — with "our seed compiler builds
M2-Planet." Everything below is scoped to that single replacement.

## 1. Pinned spec sources

Because we now treat this source as our spec, it must not drift under us. The
`borrow-m2-demo` workflow pins the upstreams:

| upstream   | commit                                     | role                         |
|------------|--------------------------------------------|------------------------------|
| M2-Planet  | `34fbd5c2a9b6eb634a4f6ad95158dcd1efcf19e0` | defines the C subset (spec)  |
| M2libc     | `ca023d8dc855171fd0618951add5817e0e568fca` | runtime we must provide      |

M2libc is pinned transitively via M2-Planet's submodule gitlink at that commit.
(`mescc-tools` — the M1/hex2 assembler+linker — is not part of the C-subset spec
and remains unpinned for now; pin it when the handoff spike graduates.)

These are upstream **build dependencies** (same category as gcc/musl), fetched in
CI. A pinned, read-only copy of both is also vendored at
[`../reference/`](../reference/) so the source can be consulted locally (the
assistant's sandbox has no network and does not persist between sessions); the
vendored copy is reference only and is not part of the build.

## 2. How this subset was derived

By reading the pinned compiler sources (`cc.c`, `cc.h`, `cc_core.c`, `cc_emit.c`,
`cc_globals.c`, `cc_macro.c`, `cc_reader.c`, `cc_strings.c`, `cc_types.c`) plus
`gcc_req.h`, and the M2libc C sources it links (`bootstrappable.c`, `stdio.c`,
`stdlib.c`, `string.c`, `ctype.c`).

§3–§4 were **re-derived mechanically** against the pinned tree (comments, string
literals and char literals stripped first, then each construct counted per file),
which is where the per-feature counts below come from. That pass corrected three
entries the original hand-reading got wrong — `do { } while`, compound
assignment/`++`, and the omission of `void`/`unsigned` — each flagged in place
below. Re-run that pass, don't hand-read, if the pins in §1 ever move.

The important distinction is **used vs. recognized**: M2-Planet, being a compiler,
*recognizes* many constructs in its input (there are string literals like
`"switch"`, `"union"`, `"typedef"` and code that parses them). What constrains
*us* is only what its own source **uses**, since that's what our compiler has to
accept. All claims below are about usage, filtered of comments and string
literals.

## 3. MUST accept (used by the self-host)

**Types**
- `int`, `char`, and pointers — including multi-level and `struct*`. Multi-level
  is **one** site (`int main(int argc, char** argv)` in `cc.c`), so `char**` as a
  parameter is the whole requirement, not general `T**` arithmetic.
- `void` — **167 uses**, and the most-overlooked entry in this list. It appears
  as a return type (`void require(int bool, char* error);`) and as an empty
  parameter list (`void program(void);`), both pervasively. Neither needs a
  `void` *value* type: a `void` function is one whose result is never consumed,
  and `(void)` is a spelling of "no parameters". Cheap, but the compiler must
  **accept the keyword in both positions** or it cannot parse the source at all.
- `unsigned` as a type keyword — 4 uses in `cc_core.c` (`unsigned size`,
  `unsigned ceil_div(unsigned a, unsigned b)`, `unsigned struct_depth_adjustment`).
  It can be accepted as a synonym for the machine word: our `/` and `%` are
  already unsigned, and `ceil_div` is the only arithmetic that cares.
- `struct`: self-referential, multiple members, and chained member access
  `a->b->c` (used pervasively — the token/type/list data model is entirely linked
  structs). Access is **`->` only**: 496 uses, against **zero** uses of `.` on a
  struct value anywhere in the self-host. Every struct M2-Planet touches is
  reached through a pointer, which means struct *values* — locals, parameters,
  copies — are never needed, only `struct T*`.
- `enum` with explicit integer values (used for all the option/flag constants).
- **Function pointers** — passed and called (e.g. `common_recursion(FUNCTION f)`).
  `gcc_req.h` exists solely to give gcc the naked-function-pointer support that
  M2-Planet's self-host relies on.

**Statements**
- `if` / `else` (nested, heavily), `while` (the workhorse loop), `for` (rare but
  present — 4 uses), `return`, `break` (13), `continue` (2), `goto` + labels
  (**13 gotos, 8 label definitions** — an earlier draft said 8/4, which came from a
  stripper that mis-handles the `/*` inside M2-Planet's own string literals and so
  dropped `cc_core.c` entirely), and `{ }` blocks.
- **Braces are frequently ABSENT** — ~370 statement bodies are braceless
  (`if(cond) return x;`), split 199 `return …;`, 120 call/assign, 34 bare `else`,
  11 `break;`, 2 `goto`. None of them nest, so the controlled statement always ends
  at the first `;` at paren depth 0 and there is no dangling-`else` case. This was
  omitted from earlier drafts and is the second-largest gap after escapes.
- **Forward prototypes** — 73 file-scope declarations `int f(int, int);`. Omitted
  from earlier drafts; it is the single biggest *blocker*, since M2-Planet declares
  nearly every function ahead of use.
- `int main(int argc, char** argv)` with **29 `argv` uses** — a runtime requirement
  as much as a syntactic one: `_start` must read the kernel's initial stack and hand
  `argc`/`argv` to `main`.
- `do { } while` — **7 uses** (`cc_core.c` ×4, `cc_reader.c` ×2, `cc_macro.c` ×1).
  An earlier draft said 2, from the same faulty strip pass as the goto count. An earlier draft of this
  doc listed it under §4 as "zero uses"; that was wrong, and it is the one entry
  §4 got backwards. It is small — the same block-stack record as `while` with the
  condition test emitted after the body instead of before — but it is **required**.
- Multiple functions with parameters and return values, forward declarations,
  and **recursion** (the parser recurses). This is what forces a real call/return
  discipline, not a fixed-depth scheme.
- Forward declarations may carry **unnamed parameters** — abstract declarators
  such as `int global_static_array(struct type*, char*);` in `cc_core.c`. A
  prototype's parameters are never entered into a symbol table anyway, so (as of
  m59) our compiler skips the whole declarator and this needs no separate support.

**Operators**
- Arithmetic `+ - * / %`; bitwise `& | ^ ~ << >>`; logical `&& || !`; all six
  comparisons `== != < > <= >=`.
  `&&` and `||` must **short-circuit** (37 and 53 uses); they guard null-pointer
  derefs like `NULL != a && a->s`, so evaluating both sides is not merely
  wasteful, it faults.
- Address-of `&`, dereference `*`, member `.`/`->`, **array indexing `a[i]`**
  (used everywhere), `sizeof` (40 uses), and plain `=` assignment.
- **Not** compound assignment, and **not** `++`/`--` — see §4. An earlier draft
  listed both here; the self-host uses neither.

**Literals**: `int` (incl. hex — one use, `0xFF` in `cc_strings.c` — and
char-code), `char` `'c'` (used constantly for the byte-level scanner), and string
`"..."`. **Escapes are not optional**: `\n`, `\t`, `\0`, `\\`, `\"` appear ~995
times across the source, overwhelmingly in the assembly-text strings M2-Planet
emits. A lexer that stores `\n` as two literal bytes produces a compiler whose
output is textually wrong everywhere.

**Preprocessor (modest)**: `#include`, include guards (`#ifndef`/`#define`/
`#endif`), and simple object-like `#define` constants. The self-host does **not**
lean on function-like macros or conditional-compilation gymnastics.

## 4. NOT needed (the self-host deliberately avoids these)

These appear only as things M2-Planet *parses*, not as things it *uses* — so our
compiler does **not** need them to compile M2-Planet. This is a real scope win:

- `switch` / `case` — zero uses in its own source (switch handling is written
  with `goto`).
- **Compound assignment** (`+= -= *= /= %= &= |= ^= <<= >>=`) — **zero uses**, and
  `++`/`--` likewise **zero**. M2-Planet is written in bootstrappable style and
  spells every update out as `i = i + 1`. An earlier draft of this doc listed
  these under §3 as required; they are not, and dropping them is a real scope win
  (compound assignment in particular would have forced an lvalue to be evaluated
  once and reused, which the current single-pass expression compiler has no shape
  for).
- `union`, `typedef` — zero uses in the self-host (the one `typedef` is the
  gcc-only shim in `gcc_req.h`).
- Ternary `?:` — zero uses.
- Floating point (`float`/`double`), and the `long`/`short` size qualifiers.
- `static`, `const` — zero uses as declarations; they appear only as strings
  inside M2-Planet's own keyword matcher.

Don't spend rungs implementing these; the target doesn't require them.

**Note on `do { } while`:** it was listed here in an earlier draft. It is used —
twice — and has moved to §3. Every other entry above was re-checked against the
pinned source at the same time and holds.

## 5. Runtime / libc surface we must provide

To *run* the compiled M2-Planet, we supply the small libc it calls. Grounded in
its actual call sites, the surface is narrow:

- **Heap**: `calloc` (used constantly for nodes) and `free`. A bump/`brk`
  allocator suffices; `free` can be a near-no-op for a batch compiler.
- **File I/O**: `fopen` / `fclose` / `fputs` / `fputc`, and raw `open` / `read` /
  `write` / `close`. All map to `svc` syscalls.
- **Process**: `exit`.
- **String**: `strlen` (and a handful of helpers M2-Planet defines itself, e.g.
  `match`, `require`, `in_set` — those are in its own source, not libc).

This mirrors how M2libc's aarch64 rung is structured: a small `_start` +
syscall-level primitives (`libc-core.M1`) under a thin C layer. Our equivalent is
a `_start` that calls `main` and syscall wrappers — the same shape we'd need for
any self-hosted stage that does real I/O.

## 6. Mapping to our ladder

The pain is asymmetric: features added to a stage written in assembly
(stage-1's language) are expensive; features added in C (stage 3+) are cheap. So
the strategy is to build the **minimum floor** into stage 2 that makes *a
compiler writable in it*, then never hand-write assembly again and grow the
accepted subset in C.

### Floor — what stage 2 needs before stage 3 is writable

A compiler is a program that reads bytes and writes text, so the floor is higher
than the current "compute an exit code" target. In rough dependency order:

1. **stage 0: 64-bit `ldr x` / `str x`** (small, byte-verifiable, mirror in
   `s0as.py`/`interp.py` + a `validate.py` guard). Word `str` truncates a 64-bit
   return address, so this is the enabler for a real software call stack — which
   recursion + function pointers require.
2. **stage 2 label/codegen strategy.** *(Half superseded — see the note.)* The chain
   once capped an assembled program at ~128 distinct labels (stage0-as's 128-entry
   symtab; stage 1 then only mapped multi-char names into it), so stage 2 had to stop
   emitting a label per variable/branch: **backpatch branch offsets** plus
   **frame-relative variable addressing**, leaving only function-entry labels.

   > **The label cap no longer exists.** **m32** made stage 1 a two-pass *numeric
   > resolver*: label count is "bounded only by memory" and stage0-as's symtab is never
   > in the path. The backpatcher outlived its justification by six milestones.
   > **m63 (A22)** retired it — `if`/`while`/`else` and `&&`/`||` now emit named
   > `:__L<id>` labels exactly as `goto` does, which is what lets stage 2 **stream** its
   > output, and which deleted the absolute-position (`x17`) invariant along with its
   > entire silent-drift bug class (m54). Frame-relative variable addressing (m26) is
   > unaffected and still stands.
3. **Multi-char identifiers** (lifts the 26-name wall; makes the source legible).
4. **`if`/`else` + full comparisons** (`== != <= >=`).
5. **Functions**: params, returns, recursion, on the software call stack from (1).
6. **Pointers + `char` + byte load/store + arrays + globals** (buffers).
7. **`struct` + a `calloc`/`free` heap** (the compiler's data model — confirmed
   required by §3/§5).
8. **I/O primitives + string literals** (`read`/`write`/`open`/`exit`, emit
   `.ascii`), so a compiled program can read source and write assembly text.

**Status (m48):** items 1–6 are in, and of item 7 the `struct` half is done (m46).
With **function pointers** landed (m48 — `int (*f)(...)` at every scope, function-name
decay, and call-through `blr`), the floor's **type system is complete**. What remains is
the **`calloc`/`free` heap** (rest of 7) and the **I/O primitives** (8: `read`/`write`/
`open`/`exit`), after which stage 2 is at the self-hosting floor.

After (8), stage 2 is at the self-hosting floor. **Two things happen there — and the
second is a deliberate change of plan from earlier drafts of this section.**

**(a) Run a self-host TEST — but don't make it a permanent rung.** Once heap + I/O
land, do a *proof-of-pivot* before investing in anything else: confirm the ladder can
compile a real, **compiler-shaped** program that reads a file and writes output (deep
recursion, structs, function pointers, nested control flow), and ideally a **toy
fixpoint** — a tiny compiler written in stage-2's C subset that compiles its own source,
byte-compared across a second generation. This de-risks the single scariest unknown —
that a compiler compiling compiler-shaped input actually works through this ladder — and
it does so **cheaply, first**. It is a test/canary, not a stage we keep.

**(b) Do NOT pivot to a stage-3 compiler written in Veron's own C.** Earlier drafts said
"stop growing stage 2 and add the rest in C as stage 3." **We are dropping that.** A
throwaway stage-3-in-C has no independent value — **M2-Planet is the actual target.** So
instead: keep growing **stage 2 (in asm)** until it accepts M2-Planet's *entire* source
subset. **Landed (m57/A16):** short-circuiting `&&`/`||`, hex literals, and `^` (via a
small stage-0 `eor` leaf). **Landed (m58/A17):** `goto` + labels (function-scoped;
a named label resolved by stage 1, so a forward `goto` needs no backpatching).
**Landed (m60/A19):** **braceless statement bodies** — `if(cond) stmt;` with no
braces, including bare `else`, braceless `while`, nested braceless `if`, and correct
dangling-`else` binding. Required bounding the condition expression at its closing
paren (it previously relied on the body's `{` to terminate, and read any keyword as
`sizeof`). Braced programs emit byte-identical output, so it is a pure superset.
**Landed (m59/A18):** **forward prototypes** — a paren-matching lookahead tells
`f(...);` from `f(...){...}`. A prototype emits nothing (a function never needed a
prior declaration, since the `bl`-vs-`blr` split is read off the symbol tables), so
**unnamed prototype parameters** are covered too and drop off this list.

**Already working, verified against the compiler rather than assumed** — strike these
from any remaining-work list: `void` return types and `(void)` parameter lists (all
244 uses), `char**` parameters, `sizeof(int)`/`sizeof(char)`, and the fact that the
source has **zero initialised globals** (so the uninitialised-only limit is fine).

**Landed (m61/A20):** string/char escapes — `\n \t \r \\ \" \' \0` decoded in the char
lexer, the string scanner and the data emitter. **Landed (m62/A21):** preprocessor
directives — a `#` token discards the line, matching M2-Planet's own `--bootstrap-mode`.
**Landed (m63/A22):** label-based control flow, streaming output, and capacity work.
**Landed (m67/A27):** `unsigned` and `long` as word-typed keywords — see item 8 below.

### Still open — the actual remaining list

**A. Capacity — do first; nothing else can be tested at scale until it lands.**
1. **stage 2's input** is still a *single* `read()` of 65,000 bytes into a 64 KB buffer.
   The self-host translation unit is **222 KB**, and a single read on a pipe returns only
   what is buffered, so even 64 KB is not reliably filled. Needs what stage 1 got in m63:
   an `mmap` arena plus a read loop.
2. **stage 2's data section** is a ~124 KB region under the m55 bound. M2's 1,942 string
   literals decode to 30,676 bytes, emitted as `.byte NNNN\n` — about **337 KB of text**.
3. **`adr` reach.** `adr x0 __dN` targets a *trailing* data section, but `adr` is ±1 MB
   while M2's compiled code is ~0.7–1.4 MB, so the address is silently wrong at scale.
   Emitting each literal **inline behind a skip branch** fixes this *and* deletes (2).

**B. Language.**
4. ~~**`enum`**~~ — **DONE (m66)**. 10 blocks, all anonymous and file-scope, every member
   with an explicit integer value. This was the largest gap: `NULL` (287 uses), `TRUE`,
   `FALSE`, `EOF`, `stdin/stdout/stderr` and `EXIT_*` are all enum constants in
   `M2libc/bootstrap.c` — which is precisely *why* stripping every directive (m62) works.
   Constants are looked up after locals and globals and before the `adr x0 <name>`
   function-address fallback, so variables still shadow them and function names still
   become addresses.
5. ~~**`break` (13) / `continue` (2)**~~ — **DONE (m64)**. Was silently miscompiled;
   outside a loop it is now a diagnostic + exit 2. `break`/`continue` scan the block stack
   for the nearest loop record, skipping `if`/`else` — which is what the 11 breaks sitting
   in braceless `if` bodies need.
6. ~~**`do { } while`**~~ — **DONE (m64)**, all 7 uses' shapes covered, including the
   `while` on the line after the `}` and char literals (`'}'`, `'\n'`) in the condition.
   7. ~~**`for`**~~ — **DONE (m65)**, all 4 linked-list-walk uses. No span replay was
   needed: the clauses are emitted in source order with a branch over the step, and the
   init/step clauses ride the ordinary statement machinery via phase records. **The loop
   family is now complete.**
8. **Word-typed keywords** — ~~`unsigned` (9), `long` (4)~~ **DONE (m67)**: both accepted
   as spellings of the machine word (the tokenizer returns the `int` keyword id for each,
   so no consumer site changed), with multi-word runs — `unsigned int`, `long long`,
   `unsigned long long int` — collapsing to one token, and `unsigned char` reaching the
   byte path. Still open here: `FILE`/`size_t`/`ssize_t`, which M2-Planet pre-registers as
   primitives in bootstrap mode (`cc_types.c:177`) — a typedef-table question, not a
   keyword one. `signed`/`short` remain unimplemented; zero uses in the pinned source.
9. **`char**` subscripting** — `argv[i]`, 28 uses, needs an 8-byte stride. Our subscript
   scaling keys off `is_char`/`is_array` with no pointer-to-pointer notion, so it would
   emit *byte* access. A type-model gap, distinct from the argv plumbing below.

**C. Runtime.**
10. **`argc`/`argv`** — `_start` must read the kernel's initial stack and hand them to
    `main`; today it does `bl main` with an empty value stack.
11. **`brk`** — `M2libc/bootstrap.c`'s `malloc` is a `brk` bump allocator, and its
    `calloc`/`free` would **override ours** under the user-definition-wins contract,
    putting the chain back on qemu's small brk region — the thing m51 moved *off*.
12. **`asm("...")`** — 6 uses in `m2libc/aarch64/linux/bootstrap.c`, in M1 mnemonic
    syntax (`"mov_x0,x17"`). Supporting it means embedding an M1 assembler in stage 2.
    Avoidable only by omitting that one file and letting our m53 builtins supply those
    five functions — a substitution, i.e. patching by omission. m53 matched m2libc's
    syscall numbers *and* argument order precisely so that this remains possible.

**D. Unknown — never attempted.** Whether `M2libc/bootstrap.c` and `bootstrappable.c`
compile in our subset at all. Once (1) lands, concatenating the `-f` list and feeding it
to stage 2 is a cheap, high-information experiment: unlike any amount of grepping, it
reports ground truth.

Compound assignment and `++`/`--` are **not** on this list — see §4. Then compile
**M2-Planet's own source** with stage 2.
**M2-Planet effectively becomes "stage 3."** No disposable intermediate compiler; the
artifact we build is exactly the hand-off node.

The cost, stated honestly: those remaining features land in **`.s1` assembly**, not in
comfortable C — the expensive side of the asymmetry above. We accept that in exchange for
a clean M2-as-stage-3 endgame and no throwaway rung. The scope rule still applies: if a
feature is genuinely nicer to add one stage down (e.g. `^` needs a stage-0 `eor`), do that.

## 7. Open design decisions (resolve on the bench/refs first)

- **Label/branch strategy**: backpatched offsets vs. expanding the symbol table.
  Model in `stage2_ref.py` against the oracle before touching asm.
- **Call stack**: 64-bit `ldr x`/`str x` + a stack pointer in `brk` (preferred),
  vs. any fixed-depth scheme (insufficient once recursion is in play).
- **`struct` layout + allocator**: member offsets, alignment, and the
  bump-allocator contract (`calloc` zeroing matters — M2-Planet relies on it).
- **Output target**: whether stage-2/3 emit stage0-as directly (with backpatched
  offsets, few labels) or route through stage 1 (multi-char labels, ≤128 cap).

## 8. Caveats

- **Cross-arch handoff (deferred — but the seam is now mapped, and probed).** Veron
  produces a **native aarch64 M2-Planet**: M2-Planet targets aarch64 directly
  (`--architecture aarch64`; exercised green in `borrow-m2`). The seam is one rung *up*:
  **MesCC has no _native_ aarch64 backend** — its code generators are x86 (i386) and
  **armhf** (32-bit ARM) only (confirmed against GNU Mes 0.27 and the current manual:
  "aarch64-linux uses mes for armhf-linux"). aarch64 is reached, in Guix, by running the
  **armhf Mes on aarch64 hardware** and lifting to 64-bit — not by a native aarch64
  compiler. live-bootstrap's Mes→tcc→gcc upper half is x86-framed and ships no aarch64
  config, so **reaching a native arm64 gcc is a porting effort, not a config flip.** The
  earlier note ("no Mes/tcc backend … gcc lands on amd64") was directionally right but
  imprecise: the non-x86 MesCC backend is armhf, and "amd64-only" overstated it. Two
  routes forward:
  1. **armhf-Mes detour** — *hardware-viable on our CI, verified.* GitHub's
     `ubuntu-24.04-arm` / `ubuntu-22.04-arm` runners use Cobalt 100 (Neoverse N2), which
     retains **AArch32 EL0**; a freestanding static armhf binary runs **natively** (exit
     42, no emulation, no interfering binfmt) on both images — see
     `.github/workflows/armhf-probe.yml`. But it's a build-out, and it's **fragile**: it
     breaks the day GitHub's fleet moves to Cobalt 200 (Neoverse V3, no AArch32). Keep the
     probe as a **canary** (its CPU-identity dump flags the change immediately).
  2. **Cross-compile from the amd64 gcc** the chain already lands (build an
     aarch64-targeting cross-gcc, then a native arm64 gcc, then self-rebuild) — more steps
     but durable against any CPU refresh.
  **Current lean: (2) as the durable endgame; (1) is now a legitimate option, not a dead
  end.** None of this changes the C subset above, and it stays deferred behind M2-Planet.
- **This is a spec of the pinned commit**, not of "M2-Planet in general." If the
  pins in §1 move, re-derive §3–§5 from the new source.
