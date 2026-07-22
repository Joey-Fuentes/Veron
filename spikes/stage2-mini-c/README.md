# spikes/stage2-mini-c — SPIKE stage 2 (mini-c)

**Invariants SUSPENDED.** A compiler our own seed produces: C-ish source in,
working aarch64 machine code out. Written **in stage-1's language** (multi-char
labels), so it exercises the whole ladder:

```
stage2-mini-c.s1 | stage1 | stage0-as | elf  ->  stage2   (the compiler)
prog.c  | stage2 | stage1 | stage0-as | elf   ->  a.out ; ./a.out   (exit == value)
```

Since A2, emitted programs carry `:func` labels (calls/recursion) alongside numeric
if/while branches, so the compiled program is resolved through **stage1** before
`stage0-as` — the compiler and the programs it emits now share the same pipeline.

## What it compiles

```
int name(int p, int q){    // one or more functions; a call is a primary
  int a=<expr>;            // declare (word slot, declaration order)
  a=<expr>;                // reassign
  if (<expr>) { ... }      // run body when <expr> is nonzero
  while (<expr>) { ... }   // loop while <expr> is nonzero
  return <expr>;           // leaves the result for the caller
}
int main(){ return name(2,3); }   // program is entered via bl main
```

- **functions + recursion** (A2): a program is one-or-more `int name(params){body}`,
  and a **call** `f(a,b)` is a primary usable in any expression (including as another
  call's argument, and recursively). Emitted with `:name` / `bl name` (resolved by
  stage1) plus a runtime calling convention: `x9` value stack (temporaries, args, and
  return value), `x10` frame base, `x11` frame stack top (frames nest → recursion). A
  call evaluates args left-to-right onto the value stack then `bl f`; the callee saves
  the caller's `x10`/`x30` (64-bit `str x`), opens a 16-aligned frame, pops its params
  into slots, and `return e` restores and `ret`s with the result on the value stack.
- **variables + assignment**: **multi-char names** → **frame-relative 64-bit word
  (8-byte) slots** at `x10 + off` in a per-call `brk` frame. `int` is the machine
  word (`int == pointer` width). The allocator is **declaration order** (params
  first, then locals; the i-th name declared gets `off = i*8`), resolved by a **live
  symbol table** — the old `(c-'a')*4` letter-map is retired. The offset is emitted
  as a computed 4-digit decimal, so the emitted program needs **no per-variable
  labels**. Declared with `int c=…;`, updated with `c=…;`.
- **expressions**: integers, variables, `+ - *`, unsigned `/` `%`, the full **comparison** set
  `< > <= >= == !=`, precedence, and parentheses, via shunting-yard; emitted code
  uses a `brk` value stack. Four precedence levels (low→high): `== !=` `<`
  `< > <= >=` `<` `+ -` `<` `*`, all left-associative. Comparisons yield `0`/`1`,
  so `while(i<=n)`, `if(a==b)`, and `a==b<c` compose naturally with arithmetic.
- **pointers (A3b)**: single-level `int* p` (and pointer params), `&name`
  (address-of), `*name` (dereference), and `*name = e` (store-through) — enough for
  **pass-by-reference** (`int set(int* q){*q=9;} … set(&x);`). Everything is one
  machine word, so a pointer op is a plain 8-byte load/store; `&x` is `add x0 x10 off`
  (no load), `*p` is `ldr x1 x1; ldr x0 x1`, `*p = e` recomputes the address and
  `str`s. `*` is disambiguated (unary dereference vs binary multiply) by
  **operand position**, so `a*b` and `*p` — and `*p*b` — all compile correctly.
  A3b also enables **uninitialised decls** (`int* p;`) and **bare call statements**
  (`f(args);`, result discarded). Arrays `[]` and `char` are the next two rungs.
- **arrays (A3c)**: `int a[N]` reserves N words in the frame; `a[i]` reads/writes the
  i-th element (rvalue and lvalue); a bare array name **decays** to `&a[0]`, so
  `sum(a, n)` passes the array to an `int* p` param; `&a[i]` is an element address.
  Indexing scales by the word size (`lsl x2 x2 x3`, ×8) and addresses `base + i*8`
  (an array's base is `add x0 x10 off`; a pointer's is loaded first). The index is a
  full re-entrant expression, so `a[a[2]]` and `a[i]*b[i]` work. Variable-size frame
  slots forced the **symbol table** to store each variable's frame offset explicitly
  (a four-word entry `[name_start, name_len, offset, size]`) rather than deriving it
  from the declaration index, and the frame **prescan** to sum array sizes so the
  prologue reserves enough — the guard against a call clobbering an under-sized array.
- **char + byte access (A3d)**: `char c` is a word-stored scalar (char promotes to int),
  but `char* p` deref and `char s[N]` subscript use **byte** access (`ldrb`/`strb`, no ×8
  scale), and `char s[N]` is byte-packed (N bytes, 8-aligned). Single-char literals `'x'`
  are their ASCII value. Because a small `char[N]` rounds up to size 8 and collides with a
  scalar, the symbol-table entry gained an explicit **flags word** (is_char, is_array) the
  code generator branches on for word-vs-byte and frame-base-vs-load-base. Real string code
  works: `strlen` as `int len(char* p){ int n; n=0; while(p[n]){ n=n+1; } return n; }`.
  No stage0-as change (`ldrb`/`strb` already existed). This completes the A3 memory model.
- **string literals + data section (A4a)**: a `"..."` literal is a `char*` into a **static
  data section** — a second output buffer the compiler fills with the literal's bytes under
  a generated `__dN` label (null-terminated), appended after all code so `adr x0 __dN` reaches
  it PC-relative. Literals flow into the byte machinery: `s[i]`, `*s`, `strlen("hello")`, and
  string arguments (`f("MN","XY")`) all work. The data section is general infrastructure —
  the same primitive serves globals next (named `g_`-labels vs anonymous `__dN`).
- **globals (A4b)**: file-scope variables — `int g;`, `int* p;`, `int a[N];`, `char s[N];`,
  `char* msg;` — shared across every function (what M2-Planet leans on hardest). They live
  in the same data section as string literals under `g_<name>` labels. Name resolution is
  **frame-first, then globals**: a reference emits `add xN x10 off` for a local or
  `adr xN g_name` for a global, routed through `emitbase0`/`emitbase1`. `g[i]`, `&g`, and
  `*g = e` all work. No stage0-as change. (Uninitialised globals; initialise in code.)
- **operators (A5a)**: the expression compiler covers unary `!` (logical not), `-`
  (negation), `~` (bitwise not); binary bitwise `&`, `|`; and shifts `<<`, `>>` — on top
  of the existing `+ - * / % < > <= >= == !=`. Unary prefixes ride the operator stack as
  highest-precedence markers (`emitapply` gained a pop-one/push-one path); binary `&` is
  told from address-of by operand position. A small `prec` table replaced the old
  hand-coded precedence ladder, so all fifteen operators sit at their correct C levels
  (`| < & < == < relational < shift < + < *`). Binary bitwise/shift lower straight onto
  stage0-as `and`/`orr`/`lsl`/`lsr`; no stage0-as change.
- **if / else (A6a)**: the `else` clause, built on the block-stack backpatch machinery. A
  then-block's closing brace peeks for `else`; if present it emits a branch over the
  else-body, retargets the condition's false-branch to the else-body start, and pushes an
  `else` block whose close backpatches the skip branch. `else if` chains (`else { if …
  else … }`) nest to any depth with no special case. Braces required, like `if`/`while`.
- **control flow**: `if` and `while`, arbitrarily nested. The condition is any
  expression, tested for **nonzero = true** (C truthiness). if/while codegen is
  iterative with an explicit *block stack*; the **expression** compiler, by
  contrast, is now **re-entrant** (it parks its return address + opstack base on a
  small compiler-side stack) so a call's argument expressions can nest and recurse.
- **structs (A8a)**: `struct Tag { ... };` definitions, `sizeof(struct Tag)`, struct
  value and pointer variables as locals, parameters, and file-scope globals, and `.` /
  `->` member access as rvalue **and** lvalue — including multi-link chains
  (`a.nx->nx->v`), `&member`, and linked-list traversal. Layout is flat: **one 8-byte
  word per field** (int / char / `T*` / `struct Tag*`), offset `field_index*8`, so
  `sizeof` is `nfields*8` and a member is `base + offset` — reusing the array-subscript
  address machinery. A **struct table** (tags + fields, kept in stage-1 memory beside the
  symbol table) resolves field names, so **field names are never emitted as labels** —
  the only labels a program carries are still `:func` names. `.` and `->` share codegen;
  the base *kind* decides deref (value → `&name`; pointer → `ldr x1 x1` first) and chain
  links follow pointers. Out of subset: nested struct-value fields, struct arrays,
  struct-pointer arithmetic scaling, member-subscript, and pass-by-value struct args.

- **function pointers (A9)**: `int (*f)(...)` as a local, parameter, or file-scope
  global; a bare function name decaying to its entry address (`fp = inc`, or `inc` passed
  as an argument → `adr x0 inc`); and a call through the variable — `ldr x16 <&f>` then
  **`blr x16`**. A fnptr is **one machine word** (a code address), so the declarator's
  parameter list is depth-skipped — only the name matters — and the variable is a plain
  pointer slot (an `is_fnptr` symtab flag records it). The compiler is single-pass with no
  `funcs` table, so the `bl`-vs-`blr` choice is read off the **symbol tables**: a called
  name that `resolve` finds as a frame local or a global is a variable → call through it
  (`blr`); a name in no table is a function → direct `bl`. The same not-a-variable test
  drives decay. Out of subset: fnptr **arithmetic** (a code address is never scaled) and
  fnptr-returning functions.

```
int a=5; int b=a+1; return a*b;                         ->  exits 30
int n=10; int s=0; while(n){ s=s+n; n=n-1; } return s;  ->  exits 55  (sum 1..10)
int n=4; int f=1; while(n){ f=f*n; n=n-1; } return f;   ->  exits 24  (4!)
int i=0; int s=0; while(i<10){ s=s+i; i=i+1; } return s; ->  exits 45  (count-up)
```

## How control flow is emitted

Control flow is emitted with **backpatched numeric branches** — no labels at all.
The compiler keeps an emitted-**instruction counter** (`emitstr` counts the `\n`
it writes, so byte position = count × 4). For `if (c) { body }` it emits the
condition, pops it, `cmp x0 0`, then `b.eq @<pos>` with a 6-digit placeholder,
records the placeholder's buffer position on the block stack, emits the body, and
at `}` backpatches the placeholder with the current position (the instruction
after the body). For `while (c) { body }` it records the loop-top position, emits
the condition and `b.eq @<placeholder>`, emits the body, then at `}` emits
`b @<top>` (a backward branch, target known) and backpatches the exit placeholder.
The position field is written by `pos6`, a division-free 6-digit itoa. if/while
control flow stays **numeric** (backpatched, never labelled), which stage1 passes
through untouched; the **only** labels an emitted program carries are **function
names** (`:name` / `bl name`), resolved by stage1. So control-flow count is not
bounded by the pool/symtab (program *size* is bounded only by the compiler's
buffers, raised in m30 to 64 KB input / 256 KB output). Statement and expression
scanning share a single **tokenizer** (`next_token`, m34): it skips whitespace and
returns a token kind (num/id/kw/op/punct) with its value, matching keywords by
**whole word** (`int`/`if`/`while`/`return`), scanning identifiers as multi-char
runs, and treating `( ) { } ; ,` as punctuation — so a variable named `i`, `w`, or
`r` is an identifier, never a keyword, and `,` separates call arguments.

## Notes / limits (what later increments lift)

- **Functions land in A2** (m35): a real call stack (`x9` value stack, `x10` frame
  base, `x11` frame stack), recursion, and a declaration-order frame allocator with
  a live symbol table. The frame policy is now the addressing shape a call stack
  needs: `x10` is a moving frame pointer (per call), and the saved-`x10`/`x30`
  frame links use the m25 64-bit `str x`/`ldr x` — already byte-anchored against `as`.
- Variables are **64-bit machine words** and **frame-relative**: each name maps to
  `x10 + i*8` (declaration order) in a per-call `brk` frame, pushed/popped and
  loaded/stored with `str x`/`ldr x` (8-byte). This is A3's foundation: `int` and a
  pointer are the same width, which the pointer/char/array work (A3b) needs. Small
  values exit as before, so the width is proven by a distinguisher — a product that
  overflows 32 bits then divides (`a*a*a/1000`) gives a different low byte in 32- vs
  64-bit, and the ladder gives the 64-bit answer.
- Names are **multi-char** now (resolved by the symbol table); the old single-char
  `(c-'a')*4` letter-map is gone.
- **All six comparisons are branchless.** A comparison emits no branch and no label,
  using only `sub`/`orr`/`lsr` that stage0-as already has. The recipes all reduce to
  the sign bit of a 64-bit difference: `a<b` is `(a-b) >> 63`, `a>b` is `(b-a) >> 63`, `a!=b` is
  `(d | -d) >> 63` with `d = a-b`, and `a==b`, `a<=b`, `a>=b` are the `1 - x`
  flip of `!=`, `>`, `<` respectively (a reversed-operand `sub x0 x2 x0`). Under the
  64-bit word model this is a **signed-64** ordering (bit 63 of the difference),
  correct for values within `±2^63` — the whole working range of the bootstrap —
  equality is sign-agnostic. The two-char operators carry internal operator-stack
  sentinels (`1 2 3 4` for `<= >= == !=`) so the shunting-yard opstack stays
  one byte per entry.
- **Unsigned `/` and `%`** are in: `/` lowers to a single `udiv` (a small new
  stage0-as instruction, byte-identical to `as`), and `%` to `udiv;mul;sub`
  (`a - (a/b)*b`) — no extra stage0-as capability beyond `udiv`. Both bind at the
  multiplicative level with `*`, left-associative, and are **unsigned-32** like the
  comparisons; signed `/` waits on signed types (an `sdiv`/sign-extension refinement).

Equality and `/` are small, self-contained increments that are available to pick
up any time, but they are **not the critical path**. With functions +
recursion, pointers/`char`/arrays, `struct`, and **function pointers** (A9) now in,
the floor's **type system is complete**; what remains of the stage-2 **"floor"** is a
small **heap** (`calloc`/`free`) and **file I/O** (`open`/`read`/`write`/`close`), so a
compiled program can run as a compiler. **Plan (revised):** after the floor, run a
self-host **test** to de-risk the ladder, then — rather than writing a throwaway stage-3
compiler in Veron's C — keep growing **stage 2 (in asm)** to cover M2-Planet's full
subset, and compile **M2-Planet's own source** so that **M2-Planet becomes the de-facto
"stage 3."** That floor, the full target C subset, and the revised plan are laid out in
[`TARGET-SUBSET.md`](./TARGET-SUBSET.md) (derived from the pinned M2-Planet
self-host, vendored at `spikes/reference/`).

## Verified

Developed and tested through the **real assembled ladder** on the dev bench
(`spikes/bench/`): the newest `stage2_ref_*.py` (currently **`stage2_ref_a9a.py`**,
the function-pointer milestone) carries the codegen design plus an independent
interpreter used as a test oracle, and `validate.py` pins structure and exit codes —
nested loops, reassignment, all six comparisons, functions + call stack + recursion
(argument passing, nested-call args, `fact`/`fib`/`pw`/`tri`, mutual recursion,
Ackermann), pointers/`char`/arrays, string literals + a data section, globals, the
full operator set, `if`/`else`, **general pointer-arithmetic scaling** (A7a:
`p + n` / `p - n` scaled by the pointee size, `p - q` by the element size), and now
**`struct`** (A8a: definitions, `sizeof`, value/pointer structs at every scope, `.`/`->`
member get/set incl. chains, `&member`, linked lists), and **function pointers** (A9:
`int (*f)(...)` at every scope, function-name decay, and call-through `ldr x16`/`blr` with
the `bl`-vs-`blr` split read off the symbol tables). Pinned in `validate.py`; CI
(real `as` + QEMU) is ground truth — the
`stage2-mini-c-demo` workflow rebuilds the compiler and runs compiled programs
through `stage2 | stage1 | stage0-as | elf`, checking both the emitted instruction
forms (`:func` labels, prologue/epilogue, frame-relative vars, numeric if/while,
pointer scaling `lsl x0 x0 x3`) and exit codes across the whole sweep. The compiler is
written in stage-1's language with **~430 multi-char labels**, which stage 1 resolves
**numerically** (m32 — the single-char pool is retired), so no pool cap applies (only
stage 1's *own* source is byte-symtab-bound) and the source can keep growing.
Program *size* is bounded by the compiler's buffers, raised in m30 to 64 KB input and
256 KB output (with stage0-as INBUF and elf CODEBUF raised to 256 KB to match), so
large multi-block programs compile end-to-end.
