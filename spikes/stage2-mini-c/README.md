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
int main(){ int a=<expr>; int b=<expr>; ... return <expr>; }
```

- **variables + assignment**: single-char names (`a`..`z`) → labeled byte slots
  (`:a`..`:z`) in the emitted program, accessed via `adr` + `ldrb`/`strb`.
- **expressions**: integers, variables, `+ - *`, precedence, and parentheses,
  via shunting-yard; emitted code uses a `brk` value stack.

```
int a=5; int b=a+1; return a*b;   ->  exits 30
```

## Notes / limits (what later increments lift)

- Variables are **byte-sized** (values 0-255) for now — keeps the emitted slot
  table small. Intermediate expression values use the 32-bit value stack; only
  variable *storage* is a byte. (Word-sized vars come with a stage-1 buffer
  upgrade to brk.)
- Statement forms: `int <c> = <expr>;` and `return <expr>;`. No reassignment,
  `/`, or control flow yet — those are the next increments toward the
  M2-Planet-grade subset that hands off to the borrowed chain.

## Verified

Developed and tested through the **real assembled ladder** on the dev bench
(`spikes/bench/`). CI (real `as` + QEMU) is ground truth.
