# spikes/stage2-mini-c — SPIKE stage 2 (mini-c)

**Invariants SUSPENDED.** A compiler our own seed produces: C-ish source in,
working aarch64 machine code out. Written **in stage-1's language** (multi-char
labels), so it exercises the whole ladder:

```
stage2-mini-c.s1 | stage1 | stage0-as | elf  ->  stage2   (the compiler)
prog.c           | stage2 | stage0-as | elf  ->  a.out ; ./a.out   (exit == value)
```

## What it compiles

`int main(){ return <expr>; }` where `<expr>` is integers combined with `+` and
`-`, evaluated left to right:

```
return 2+3-1;   ->   mov x0 2
                     add x0 x0 3
                     sub x0 x0 1
                     mov x8 93
                     svc
```

`+`/`-` become `add`/`sub` **immediate** chains — no new stage0-as ops needed.
Whitespace is ignored; `int main(){}` (no `return`) compiles to `return 0`.

## Increments so far / next

- ✅ `return N` (seed)
- ✅ `return <int +/- int ...>` (this)
- ⏭ `*` and precedence — needs a `mul` in stage0-as (next stage-0 convenience),
  then a real expression parser. After that: variables, then control flow, toward
  the M2-Planet-grade subset that hands off to the borrowed chain.

## Verified

Developed and tested through the **real assembled ladder** on the dev bench
(`spikes/bench/`) — not the Python references — so stage-1 read/buffer limits are
modeled. CI (real `as` + QEMU) is ground truth.
