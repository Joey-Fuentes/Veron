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

- **variables + assignment**: single-char names (`a`..`z`) → labeled **4-byte
  (word) slots** (`:a`..`:z`) in the emitted program, accessed via `adr` +
  `ldr`/`str`. Declared with `int c=…;`, updated with `c=…;` (reassignment).
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

Jump targets use **uppercase** labels `A`, `B`, … drawn from a compile-time
counter; variable slots use lowercase `a`..`z`, so the two never collide (up to
26 control-flow labels per program). For `if (c) { body }` the compiler emits the
condition, pops it, `cmp x0 0`, `b.eq L`, the body, then `:L`. For
`while (c) { body }` it emits `:A`, the condition, `b.eq B`, the body, `b A`,
then `:B`. Statement dispatch keys on the **second** character: a keyword's is a
letter (`in`/`if`/`wh`/`re`), a single-char reassignment's is a space or `=`, so
variables may be named `i`, `w`, or `r` without ambiguity.

## Notes / limits (what later increments lift)

- Variables are **word-sized** (32-bit): 4-byte slots via word `ldr`/`str`,
  matching the 32-bit value stack. Slots are aligned by construction (the emitted
  program is all 4-byte instructions up to the slot table). NB: with only
  `+ - *` and a mod-256 exit code, byte vs word storage was not distinguishable by
  exit code — so the word-slot guard is structural; the width matters for
  out-of-byte-range values and once `/` lands.
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
truth. The compiler is written in stage-1's language and now uses **74** of the
76 pool slots; adding equality took it from 61 to 74, so further stage-2 growth
that needs more labels should economise or expand the pool (a cheap stage-1
change) rather than cram.
