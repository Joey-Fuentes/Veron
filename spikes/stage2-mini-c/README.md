# spikes/stage2-mini-c — SPIKE stage 2 (mini-c)

**Invariants SUSPENDED.** A compiler our own seed produces: C-ish source in,
working aarch64 machine code out. Written **in stage-1's language** (multi-char
labels), so it exercises the whole ladder:

```
stage2-mini-c.s1 | stage1 | stage0-as | elf  ->  stage2   (the compiler)
prog.c           | stage2 | stage0-as | elf  ->  a.out ; ./a.out   (exit == value)
```

## What it compiles

`int main(){ return <expr>; }` where `<expr>` is integers combined with `+ - *`
and **correct precedence** (`*` binds tighter than `+`/`-`), via recursive
descent:

```
return 2+3*4;   ->   mov x0 2        ; first term
                     mov x1 3        ; next term
                     mov x2 4
                     mul x1 x1 x2    ; 3*4
                     add x0 x0 x1    ; 2 + 12
                     mov x8 93
                     svc
```

Codegen uses `x0` as the running accumulator, `x1` for the current term, `x2` as
multiply scratch — so it needs stage0-as's **register** `add`/`sub` and `mul`.
Whitespace is ignored; no `return` compiles to `return 0`.

## Increments so far / next

- ✅ `return N`
- ✅ `return <int +/- int ...>`
- ✅ `return <expr with + - * and precedence>` (this)
- ⏭ parentheses; then `/`; then variables and assignment; then control flow —
  toward the M2-Planet-grade subset that hands off to the borrowed chain.

## Verified

Developed and tested through the **real assembled ladder** on the dev bench
(`spikes/bench/`). CI (real `as` + QEMU) is ground truth.
