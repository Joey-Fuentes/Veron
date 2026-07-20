# spikes/stage2-mini-c — SPIKE stage 2 (mini-c)

**Invariants SUSPENDED.** A compiler our own seed produces: C-ish source in,
working aarch64 machine code out. Written **in stage-1's language** (multi-char
labels), so it exercises the whole ladder:

```
stage2-mini-c.s1 | stage1 | stage0-as | elf  ->  stage2   (the compiler)
prog.c           | stage2 | stage0-as | elf  ->  a.out ; ./a.out   (exit == value)
```

## What it compiles

`int main(){ return <expr>; }` where `<expr>` is integers with `+ - *`, correct
precedence, and **parentheses** to any depth:

```
return (2+3)*4;   ->   ... value-stack code ...   -> exits 20
```

### How

The compiler is **iterative** — it uses the shunting-yard algorithm with a
compiler-side operator stack (no compiler recursion, which the language can't do
cheaply). It emits **stack-machine code**: each number pushes onto a runtime
**value stack** (a `brk` region addressed by `x9`), and each operator pops two,
applies `add`/`sub`/`mul` (register), and pushes the result. The final value is
popped into `x0` before exit.

This is the general foundation for everything nested that follows.

## Increments so far / next

- ✅ `return N`
- ✅ `+ -` (immediate chains)
- ✅ `+ - *` with precedence (register codegen)
- ✅ `+ - *` with precedence **and parentheses** (shunting-yard + value stack) — this
- ⏭ `/` (needs a `udiv` in stage0-as); then variables + assignment (named slots,
  reusing the name-table technique); then control flow — toward the
  M2-Planet-grade subset that hands off to the borrowed chain.

## Verified

Developed and tested through the **real assembled ladder** on the dev bench
(`spikes/bench/`). CI (real `as` + QEMU) is ground truth.
