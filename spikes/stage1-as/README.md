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

## How it works (within stage0-as's language)

- **Memory**: buffers (inbuf/outbuf/nametable) come from `brk` — a large heap
  (~20 KB each), addressed with register `add` for base offsets and `[Xn+Xm]`
  loads/stores. A `read` loop fills inbuf until EOF, so large/chunked inputs are
  handled. This keeps stage1's own source small (~3 KB) while it can process
  much larger stage-2/3 sources.

- **No add-reg**: stage0-as `add` is immediate-only, so all indexing uses running
  offsets and `[base+index]` addressing; label chars come from a `.ascii` pool
  indexed by count (not `65+index` arithmetic).
- **Label pool** — 76 single-char slots: `A-Za-z0-9` plus punctuation
  `_$@?!%^&~|=<>+`. stage0-as accepts any byte as a label (its symtab is indexed
  by the raw character), so the pool can grow to serve larger stage-2/3 sources;
  the cap is the symtab size (128 entries), not the alphabet. Punctuation slots
  are only reached once a program has >62 distinct labels, so existing programs
  resolve byte-identically to before the expansion.
- **Subroutines**: uses the `bl`/`ret` added to stage0-as; helpers are leaves
  (no nested `bl`) so the link register is never clobbered.

## Known limits (motivate later stage-1 work)

- Single `read`/`write` of the whole program (buffers sized for spike programs).
- Up to **76** distinct labels per program (single-char pool; expandable toward
  the 128-entry symtab cap as later stages need it).
- Capability #1 only — later stage-1 increments add macros/convenience as stage 2
  (a small C compiler, written in stage-1's language) needs them.

## Verified

Byte-identical to real `aarch64-linux-gnu-as` for a multi-char-label program,
and runs under QEMU to the expected exit codes (loop+call → 7; adr+mem with a
multi-char data label → 9). Developed and regression-tested against a Python
model of stage0-as before pushing; CI (real `as` + QEMU) is ground truth. The
76-slot pool is exercised end-to-end (programs with 63–76 distinct labels
resolve, assemble, and run to the right exit code, including backward branches
and `adr` to punctuation-slot labels); `validate.py` pins this.
