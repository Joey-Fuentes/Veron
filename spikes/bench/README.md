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

## Files

- `s0as.py` — models `stage0-as`: assembles its language to bytes **and** a
  decoded program. Encodings mirror `spikes/stage0-as/stage0-as.aarch64.s` and are
  byte-verified against real `as` in CI. Faithfully models its limits: labels are
  single-character; register-`cmp` is x-registers only.
- `interp.py` — a small ARM64 interpreter for the exact instruction subset in
  play (mov/add/sub/cmp/branches/ldrb/strb/ldr/str/adr/bl/ret/br/blr/orr/and/
  shifts/movk/svc), plus the syscalls used (`read`/`write`/`exit`/`brk`).
- `stage1_ref.py` — a plain-Python reference of stage 1 (multi-char label
  resolver), used to develop and cross-check `stage1-as.s0`.
- `validate.py` — pins the bench to CI-confirmed results (byte output, exit
  codes) and to faithfulness guards. **Run this whenever stage0-as changes.**

## Use

```
cd spikes/bench
python3 validate.py                 # must pass before you trust the bench
python3 -c "from interp import asm_run; print(asm_run(open('prog.s0').read())[0])"
```

## Faithfulness guards (known stage0-as limits the bench MUST model)

- Labels are single-character (multi-char defs raise an error here).
- Register `cmp` only recognizes x-registers; `cmp w4 w5` assembles as `cmp w4,#0`
  (the exact trap that broke stage 1's byte comparison).

If you extend `stage0-as`, mirror the change in `s0as.py`, add a guard/expected
value to `validate.py`, and re-run it.
