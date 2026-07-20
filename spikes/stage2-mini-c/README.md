# spikes/stage2-mini-c — SPIKE stage 2 (mini-c), SEED capability

**Invariants SUSPENDED.** The first real **compiler** our own seed produces:
C-ish source in, working aarch64 machine code out. This seed handles the
smallest useful slice — `int main(){return N;}` → a program that exits `N`.

It is written **in stage-1's language** (multi-character labels), so it exercises
the whole ladder built so far:

```
stage2-mini-c.s1 | stage1 | stage0-as | elf  ->  stage2   (the compiler)
prog.c           | stage2 | stage0-as | elf  ->  a.out ; ./a.out   (exit == N)
```

## What it does

Scans the source for `return`, skips whitespace, copies the following digits, and
emits:

```
mov x0 <N>
mov x8 93
svc
```

`N`'s digits are copied straight from the source, so no number↔string conversion
is needed yet. Anything else in the source is ignored for this slice (so
`int main(){}` compiles to `return 0`).

## Notes / limits (what later stage-2 increments add)

- Only `return <decimal>`; no expressions, variables, types, or multiple
  statements yet. Those are the next increments toward an M2-Planet-grade subset.
- Uses `cmp x..` (not `w..`) for byte compares — stage0-as's register-compare is
  x-registers only.
- Buffers live in the ELF R+W+X segment as `.ascii` fillers (no `brk`).

## Verified

Developed and tested through the full ladder on the dev bench (`spikes/bench/`)
before pushing: 42→42, 7→7, 0→0, 200→200, and no-`return`→0. CI (real `as` +
QEMU) is ground truth.
