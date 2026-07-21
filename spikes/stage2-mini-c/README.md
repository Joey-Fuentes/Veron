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
- **variables + assignment**: **multi-char names** → **frame-relative word (4-byte)
  slots** at `x10 + off` in a per-call `brk` frame. The allocator is **declaration
  order** (params first, then locals; the i-th name declared gets `off = i*4`),
  resolved by a **live symbol table** — the old `(c-'a')*4` letter-map is retired.
  The offset is emitted as a computed 3-digit decimal, so the emitted program needs
  **no per-variable labels**. Declared with `int c=…;`, updated with `c=…;`.
- **expressions**: integers, variables, `+ - *`, unsigned `/` `%`, the full **comparison** set
  `< > <= >= == !=`, precedence, and parentheses, via shunting-yard; emitted code
  uses a `brk` value stack. Four precedence levels (low→high): `== !=` `<`
  `< > <= >=` `<` `+ -` `<` `*`, all left-associative. Comparisons yield `0`/`1`,
  so `while(i<=n)`, `if(a==b)`, and `a==b<c` compose naturally with arithmetic.
- **control flow**: `if` and `while`, arbitrarily nested. The condition is any
  expression, tested for **nonzero = true** (C truthiness). if/while codegen is
  iterative with an explicit *block stack*; the **expression** compiler, by
  contrast, is now **re-entrant** (it parks its return address + opstack base on a
  small compiler-side stack) so a call's argument expressions can nest and recurse.

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
- Variables are **word-sized** (32-bit) and **frame-relative**: each name maps to
  `x10 + i*4` (declaration order) in a per-call `brk` frame, loaded/stored with word
  `ldr`/`str`, matching the 32-bit value stack — **no labeled slot table**. NB: with
  only `+ - *` and a mod-256 exit code, byte vs word storage isn't distinguishable by
  exit code, so the word/frame guards are structural; the width matters for
  out-of-byte-range values and once `/` lands.
- Names are **multi-char** now (resolved by the symbol table); the old single-char
  `(c-'a')*4` letter-map is gone.
- **All six comparisons are branchless and unsigned-32.** A comparison emits no
  branch and no label, using only `sub`/`orr`/`lsr` that stage0-as already has.
  The recipes all reduce to the sign bit of a 64-bit difference of two zero-extended
  32-bit words: `a<b` is `(a-b) >> 63`, `a>b` is `(b-a) >> 63`, `a!=b` is
  `(d | -d) >> 63` with `d = a-b`, and `a==b`, `a<=b`, `a>=b` are the `1 - x`
  flip of `!=`, `>`, `<` respectively (a reversed-operand `sub x0 x2 x0`). Because
  the loads zero-extend, ordering is **unsigned** 32-bit; signed ordering would
  need sign-extension (`ldrsw`, not in stage0-as) and is a later refinement —
  equality is sign-agnostic. The two-char operators carry internal operator-stack
  sentinels (`1 2 3 4` for `<= >= == !=`) so the shunting-yard opstack stays
  one byte per entry.
- **Unsigned `/` and `%`** are in: `/` lowers to a single `udiv` (a small new
  stage0-as instruction, byte-identical to `as`), and `%` to `udiv;mul;sub`
  (`a - (a/b)*b`) — no extra stage0-as capability beyond `udiv`. Both bind at the
  multiplicative level with `*`, left-associative, and are **unsigned-32** like the
  comparisons; signed `/` waits on signed types (an `sdiv`/sign-extension refinement).

Equality and `/` are small, self-contained increments that are available to pick
up any time, but they are **not the critical path** to stage 3. With functions +
recursion now in, what remains of the stage-2 **"floor"** is
pointers/`char`/arrays, `struct`, a small heap, and I/O — because stage 3 is a
*compiler* written in stage-2's C. That floor, and the full target C subset it
builds toward, are laid out in
[`TARGET-SUBSET.md`](./TARGET-SUBSET.md) (derived from the pinned M2-Planet
self-host, vendored at `spikes/reference/`).

## Verified

Developed and tested through the **real assembled ladder** on the dev bench
(`spikes/bench/`): `stage2_ref_a2.py` carries the codegen design (declaration-order
allocator + live symbol table) plus an independent recursive interpreter used as a
test oracle, and `validate.py` pins structure and exit codes — nested loops,
reassignment, all six comparisons, and now the A2 **functions + call stack +
recursion** set (argument passing, nested-call args, `fact`/`fib`/`pw`/`tri`, mutual
recursion, Ackermann; 169 checks). CI (real `as` + QEMU) is ground truth: the
`stage2-mini-c-demo` workflow rebuilds the compiler and runs compiled programs
through `stage2 | stage1 | stage0-as | elf`, checking both the emitted instruction
forms (`:func` labels, prologue/epilogue, frame-relative vars, numeric if/while) and
exit codes across the whole sweep. The compiler is written in stage-1's language with
**~135 multi-char labels**, which stage 1 resolves **numerically** (m32 — the
single-char pool is retired), so no pool cap applies and the source can keep growing.
Program *size* is bounded by the compiler's buffers, raised in m30 to 64 KB input and
256 KB output (with stage0-as INBUF and elf CODEBUF raised to 256 KB to match), so
large multi-block programs compile end-to-end.
