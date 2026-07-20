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
- **expressions**: integers, variables, `+ - *`, precedence, and parentheses,
  via shunting-yard; emitted code uses a `brk` value stack.
- **control flow**: `if` and `while`, arbitrarily nested. The condition is any
  expression, tested for **nonzero = true** (C truthiness). Codegen is iterative
  with an explicit *block stack* (no recursion — a nested `bl` would clobber the
  return register), so nesting depth is bounded only by that stack.

```
int a=5; int b=a+1; return a*b;                         ->  exits 30
int n=10; int s=0; while(n){ s=s+n; n=n-1; } return s;  ->  exits 55  (sum 1..10)
int n=4; int f=1; while(n){ f=f*n; n=n-1; } return f;   ->  exits 24  (4!)
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
  `+ - *` and a mod-256 exit code, byte vs word storage is not distinguishable by
  exit code; the width matters once `/` or comparison operators land.
- Conditions test **nonzero**, not a relation: there are no comparison operators
  (`<`, `==`, …) yet, so loops are written as countdowns (`while(n){…;n=n-1;}`).
  Relational/logical operators are a later increment.
- Still no `/` (needs `udiv` in stage0-as). These are the next steps toward the
  M2-Planet-grade subset that hands off to the borrowed chain.

## Verified

Developed and tested through the **real assembled ladder** on the dev bench
(`spikes/bench/`): `stage2_ref.py` carries the codegen design plus an independent
interpreter used as a test oracle, and `validate.py` pins structure and exit
codes (including nested loops and reassignment). CI (real `as` + QEMU) is ground
truth.
