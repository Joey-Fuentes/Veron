# spikes/stage2-mini-c — SPIKE stage 2 (mini-c)

**Invariants SUSPENDED.** A compiler our own seed produces: C-ish source in,
working aarch64 machine code out. Written **in stage-1's language** (multi-char
labels), so it exercises the whole ladder:

```
stage2-mini-c.s1 | stage1 | stage0-as | elf  ->  stage2   (the compiler)
prog.c           | stage2 | stage0-as | elf  ->  a.out ; ./a.out   (exit == value)
```

## What it compiles

```
int main(){
  int a=<expr>;          // declare (word slot)
  a=<expr>;              // reassign
  if (<expr>) { ... }    // run body when <expr> is nonzero
  while (<expr>) { ... } // loop while <expr> is nonzero
  return <expr>;
}
```

- **variables + assignment**: single-char names (`a`..`z`) → **frame-relative
  word (4-byte) slots** at `x10 + off` (`off = (c-'a')*4`) in a `brk` region,
  accessed via `add x1 x10 <off>` + word `ldr`/`str`. The offset is emitted as a
  3-digit decimal from a compile-time offset table (`offtab`), so the emitted
  program needs **no per-variable labels** — a strategy change that removes the
  26-label variable cost (see notes). Declared with `int c=…;`, updated with
  `c=…;` (reassignment).
- **expressions**: integers, variables, `+ - *`, the full **comparison** set
  `< > <= >= == !=`, precedence, and parentheses, via shunting-yard; emitted code
  uses a `brk` value stack. Four precedence levels (low→high): `== !=` `<`
  `< > <= >=` `<` `+ -` `<` `*`, all left-associative. Comparisons yield `0`/`1`,
  so `while(i<=n)`, `if(a==b)`, and `a==b<c` compose naturally with arithmetic.
- **control flow**: `if` and `while`, arbitrarily nested. The condition is any
  expression, tested for **nonzero = true** (C truthiness). Codegen is iterative
  with an explicit *block stack* (no recursion — a nested `bl` would clobber the
  return register), so nesting depth is bounded only by that stack.

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
The position field is written by `pos6`, a division-free 6-digit itoa. Because both
variables (frame-relative) and control flow (backpatched) are label-free, **the
emitted program contains no labels** — control-flow count is no longer bounded by
the pool/symtab (program *size* is bounded only by the compiler's buffers, raised
in m30 to 64 KB input / 256 KB output). Statement and expression scanning share a
single **tokenizer** (`next_token`, added in m34): it skips whitespace and returns
a token kind (num/id/kw/op/punct) with its value, matching keywords by **whole
word** (`int`/`if`/`while`/`return`) and scanning identifiers as runs — so a
single-char variable named `i`, `w`, or `r` is an identifier, never a keyword.

## Notes / limits (what later increments lift)

- Variables are **word-sized** (32-bit) and **frame-relative**: each single-char
  name maps to `x10 + (c-'a')*4` in a `brk` frame, loaded/stored with word
  `ldr`/`str`, matching the 32-bit value stack. The emitted program sets `x10` to
  the frame base in its prologue and addresses each variable with `add x1 x10
  <off>` — **no labeled slot table**. This is floor item 2a (of the "label/codegen
  strategy"): it removes the per-variable label so the emitted program's label
  budget is spent only on control flow, and it's the addressing shape a real call
  stack needs (once functions land, `x10` becomes a moving frame pointer). NB:
  with only `+ - *` and a mod-256 exit code, byte vs word storage isn't
  distinguishable by exit code, so the word/frame guards are structural; the width
  matters for out-of-byte-range values and once `/` lands.
- **All six comparisons are branchless and unsigned-32.** A comparison emits no
  branch and no label, using only `sub`/`orr`/`lsr` that stage0-as already has,
  so it costs **zero** of the emitted program's 26 uppercase labels. The recipes
  all reduce to the sign bit of a 64-bit difference of two zero-extended 32-bit
  words: `a<b` is `(a-b) >> 63`, `a>b` is `(b-a) >> 63`, `a!=b` is
  `(d | -d) >> 63` with `d = a-b`, and `a==b`, `a<=b`, `a>=b` are the `1 - x`
  flip of `!=`, `>`, `<` respectively (a reversed-operand `sub x0 x2 x0`). Because
  the loads zero-extend, ordering is **unsigned** 32-bit; signed ordering would
  need sign-extension (`ldrsw`, not in stage0-as) and is a later refinement —
  equality is sign-agnostic. The two-char operators carry internal operator-stack
  sentinels (`1 2 3 4` for `<= >= == !=`) so the shunting-yard opstack stays
  one byte per entry.
- Still no `/` (needs `udiv` in stage0-as).

Equality and `/` are small, self-contained increments that are available to pick
up any time, but they are **not the critical path** to stage 3. What actually
gates stage 3 is the stage-2 **"floor"** — functions + a real call stack,
pointers/`char`/arrays, `struct`, a small heap, multi-char labels/identifiers,
and I/O — because stage 3 is a *compiler* written in stage-2's C. That floor,
and the full target C subset it builds toward, are laid out in
[`TARGET-SUBSET.md`](./TARGET-SUBSET.md) (derived from the pinned M2-Planet
self-host, vendored at `spikes/reference/`).

## Verified

Developed and tested through the **real assembled ladder** on the dev bench
(`spikes/bench/`): `stage2_ref.py` carries the codegen design plus an independent
interpreter used as a test oracle, and `validate.py` pins structure and exit
codes (including nested loops, reassignment, and all six comparisons — precedence,
`<=`/`>=` loop guards, and `==`/`!=` guards). CI (real `as` + QEMU) is ground
truth. The compiler is written in stage-1's language with **~100 multi-char
labels**, which stage 1 now resolves **numerically** (m32 — the single-char pool
is retired), so no pool cap applies and the source can keep growing; the m34
tokenizer added `next_token` and a number-span copier while dropping the old
`skipsp`/`copydig` scanners. Program *size* is bounded by the compiler's buffers, raised in m30 to 64 KB input
and 256 KB output (with stage0-as INBUF and elf CODEBUF raised to 256 KB to match),
so large multi-block programs compile end-to-end.
