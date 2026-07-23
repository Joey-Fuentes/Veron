# spikes/bench — developer aid for writing `.s0` code (NOT part of the bootstrap)

**This is not Veron. It is a scratch tool** for developing stage-1/stage-2 code
without a full CI round-trip. It is a Python **model** of `stage0-as` plus a tiny
ARM64 interpreter, so you can assemble *and run* `.s0` programs locally and check
their output before pushing.

**CI is ground truth, not this.** The bench is a model and can diverge from the
real assembler + qemu. Two real bugs this session were *masked* by an unfaithful
bench (multi-char labels; `cmp w4 w5`). The lesson is baked in: run `validate.py`
after any change to `stage0-as` or the bench, and never trust a green bench over
a red CI.

> ### `validate.py` is currently too slow to use as an inner loop — KNOWN DEBT
>
> A full run is dominated by a handful of pathological cases: the capacity section
> compiles a 600-function, 36 KB input and emits ~585 KB through a Python
> interpreter roughly 1e4x slower than native, and stage 1's `findlabel` is a
> linear scan, so resolution is O(n^2) in label count. Several sections also
> rebuild the whole ladder from source independently.
>
> **Consequence, stated plainly:** rungs m67–m71 were developed against *targeted
> per-rung scripts*, and each new `validate.py` section was replay-verified
> standalone (extracted and executed on its own against the real assembled ladder)
> rather than by running the file end to end. Those sections are individually
> green but **have never been run together**. CI carries the equivalent gates, so
> the ladder itself is covered; what is missing is the fast local check.
>
> Optimizing this — sampling or tiering the capacity tests, memoizing the
> assembled ladder across sections, moving big-input cases to CI only — is its own
> task and is being picked up separately. Until then, prefer a targeted script for
> the rung you are writing, and lean on CI.

## Files

- `s0as.py` — models `stage0-as`: assembles its language to bytes **and** a
  decoded program. Encodings mirror `spikes/stage0-as/stage0-as.aarch64.s` and are
  byte-verified against real `as` in CI. Faithfully models its limits: labels are
  single-character; register-`cmp` is x-registers only.
- `interp.py` — a small ARM64 interpreter for the exact instruction subset in
  play (mov/add/sub/cmp/branches/ldrb/strb/ldr/str/adr/bl/ret/br/blr/orr/and/
  shifts/movk/svc), plus the syscalls used (`read`/`write`/`exit`/`brk`). Since
  **m50** it also **faults on wild addresses like hardware**: a load/store outside
  `[NULLFLOOR, brk)` raises `OOBAccess` instead of silently reading 0 (default-on;
  `run(..., oob_trap=False)` restores the old tolerant behaviour). This is what lets
  the bench witness the `&member`-class bug that previously only qemu could catch.
  Since **m70** it also models the **initial process stack**: `R` covers `x0..x31`
  with `x31` = SP pointing at a block laid out as the AArch64 Linux kernel lays it
  out — `argc`, the `argv` pointers, a NULL, envp NULL, then the strings — and
  `run(..., argv=["prog","-o","out"])` sets it. Before this there was no `x31` at
  all, so nothing that reads the initial stack could be tested here. The block sits
  between the code and the start of brk, which means a wild pointer in those ~80
  bytes no longer faults; that is faithful rather than a regression, since the real
  initial stack is mapped readable memory too, and what the m50 trap exists for
  (below `NULLFLOOR`, above the break) is unchanged.
- `stage1_ref.py` — a plain-Python reference of stage 1 (two-pass **numeric label
  resolver**: labels -> positions -> `@<pos>`, pool retired), used to develop and
  cross-check `stage1-as.s0`.
- `lint_asm.py` — lints the hand-written **GNU-as** sources. The bench models *our*
  assembler (`s0as.py` covers stage0-as's own language) and **not GNU `as`**, and there is
  no aarch64 assembler on the dev box — so every `.s` edit was unguarded until CI. Two
  pushed commits failed there: `.ascii` placed in `.bss` (NOBITS cannot hold initialised
  data), and, after a buffer was raised to 64 MiB, symbols following it falling outside
  `adr`'s ±1 MiB reach. The lint catches both classes plus MOV immediates that are not a
  shifted imm16. Run it (or `validate.py`, which runs it first) before pushing any `.s`.
- `validate.py` — pins the bench to CI-confirmed results (byte output, exit
  codes) and to faithfulness guards. **Run this whenever stage0-as changes.**

## Use

```
cd spikes/bench
python3 validate.py                 # must pass before you trust the bench
python3 -c "from interp import asm_run; print(asm_run(open('prog.s0').read())[0])"
```

## Test stage-N through the REAL stage-(N-1), not the Python reference

When developing stage 2+, resolve/assemble it by running the **actual assembled**
lower stage through `interp.py` — not the convenience Python reference. The
reference has no read/buffer limits, so it can hide real caps (e.g. a stage-1
that only reads 500 bytes silently truncating a 2 KB stage-2 source). The real
binary via `interp` models `read`/`brk`/buffer sizes.

## Faithfulness guards (known stage0-as limits the bench MUST model)

- Labels are single-character (multi-char defs raise an error here).
- Register `cmp` only recognizes x-registers; `cmp w4 w5` assembles as `cmp w4,#0`
  (the exact trap that broke stage 1's byte comparison).

If you extend `stage0-as`, mirror the change in `s0as.py`, add a guard/expected
value to `validate.py`, and re-run it.
