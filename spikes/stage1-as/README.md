# spikes/stage1-as — SPIKE stage 1 (macro-as), capability #1: multi-char labels

**Invariants SUSPENDED.** The first rung written **in stage0-as's own language**
(a `.s0` file, assembled by `stage0-as`) — no more hand-written raw assembly.
It adds the capability stage 0 lacked: **multi-character labels**.

```
prog.s1 | stage1 | stage0-as | elf out && ./out
```

`stage1-as.s0` reads assembly where labels may be multi-character, and emits the
same program with each distinct label mapped to a unique single character, so
`stage0-as` (single-char labels only) can assemble it. Label positions handled:
`:name` definitions, `b`/`bl`/`b.eq`/`b.ne`/`b.lt`/`b.ge name`, and `adr xR name`.
`br`/`blr` (register operands) and everything else pass through unchanged.

## Constraint: stage 1's own source uses SINGLE-char labels

Stage 1 exists to give multi-char labels to programs *above* it — but
`stage1-as.s0` is itself assembled by `stage0-as`, which is single-char only.
So stage 1's own labels are single characters; the multi-char capability is for
its input, not its source. (This is the last tool bound by that limit; stage 2,
written in stage-1's language, gets multi-char labels.)

## How it works (within stage0-as's language)

- **Memory**: buffers (inbuf/outbuf/nametable) live in the ELF R+W+X segment as
  `.ascii` fillers, addressed with `[Xn+Xm]` register-offset loads/stores (the
  proven-writable path; no `brk` dependency).
- **No add-reg**: stage0-as `add` is immediate-only, so all indexing uses running
  offsets and `[base+index]` addressing; label chars come from a `.ascii` pool
  indexed by count (not `65+index` arithmetic).
- **Subroutines**: uses the `bl`/`ret` added to stage0-as; helpers are leaves
  (no nested `bl`) so the link register is never clobbered.

## Known limits (motivate later stage-1 work)

- Single `read`/`write` of the whole program (buffers sized for spike programs).
- Up to 62 distinct labels (single-char pool); fine for test programs.
- Capability #1 only — later stage-1 increments add macros/convenience as stage 2
  (a small C compiler, written in stage-1's language) needs them.

## Gotcha found the hard way

stage0-as's register-compare only accepts **x-registers** (`cmp x.. x..`); a
`w`-register second operand is silently parsed as an immediate. Stage 1's byte
compare therefore uses `cmp x4 x5` (bytes are zero-extended, so x-compare is
correct). The dev bench was made faithful to this so it can't mask it again.

## Verified

Byte-identical to real `aarch64-linux-gnu-as` for a multi-char-label program,
and runs under QEMU to the expected exit codes (loop+call → 7; adr+mem with a
multi-char data label → 9). Developed and regression-tested against a Python
model of stage0-as before pushing; CI (real `as` + QEMU) is ground truth.
