# spikes/stage1-as — SPIKE stage 1 (macro-as): numeric label resolver

**Invariants SUSPENDED.** The first rung written **in stage0-as's own language**
(a `.s0` file, assembled by `stage0-as`) — no more hand-written raw assembly.
It gives the ladder the capability stage 0 lacked: **an unbounded number of
multi-character labels**, by resolving them to numeric positions.

```
prog.s1 | stage1 | stage0-as | elf out && ./out
```

`stage1-as.s0` is a **two-pass numeric label resolver**. It reads assembly whose
labels may be multi-character and of any count, and emits **label-free**
stage0-as assembly in which every reference is rewritten to a numeric position:

- **Pass 1** walks the program, tracking the assembled output position, and
  records every `:name` definition's position in a dynamic symbol table (names
  stored in a name buffer, positions in a parallel array).
- **Pass 2** walks it again and emits each line, **dropping** `:name` definitions
  and rewriting each reference — `b`/`bl`/`b.eq`/`b.ne`/`b.lt`/`b.ge name` and
  `adr xR name` — to `@<pos>` (a 6-digit absolute output byte-position). `br`/`blr`
  (register operands) and everything else pass through unchanged.

`stage0-as` then assembles the numeric output directly: it encodes the
PC-relative offset for `b @<pos>` (added in the stage-0 numeric-branch milestone)
and `adr xR @<pos>` (the numeric-adr milestone). **The single-char pool is gone**
— stage0-as's 128-entry symtab is never in the path for stage-2/3 code, so the
number of labels a program may use is bounded only by memory.

## How it works (within stage0-as's language)

- **Memory**: inbuf / outbuf / name-table / position-table all come from `brk`,
  addressed with register `add` for base offsets and `[Xn+Xm]` loads/stores. A
  `read` loop fills inbuf until EOF. Buffers are large (input/output room plus
  name and position tables) so stage 1 can process big stage-2/3 sources while
  its own source stays small.
- **Operand classification is by mnemonic, not spelling.** Pass 2 already knows the
  mnemonic, so it never guesses register-vs-label from an operand's letters: `b` /
  `bl` / `b.cond` have a single operand that is always a **label** (resolved); `adr xR
  name` has a **register** in slot 1 (copied verbatim, whatever the token) and a
  **label** in slot 2; `br` / `blr` (register operands) pass through untouched. So a
  label or function name is resolved by its *position*, and may be spelled any way a C
  identifier can — `walk`, `w0helper`, `x9foo`, even a label literally named `x0` all
  resolve in a branch's label slot, while `x0` in a register slot stays a register.
  This mirrors how a real assembler disambiguates (instruction grammar + an exact-match
  register set), and it lets stage 2 / M2-Planet use the full C identifier space for
  function names.
- **Symbol table**: `:name` definitions are appended to a name buffer
  (null-terminated) with their positions in a parallel word array; lookups are a
  linear scan with an inline string compare. Definitions are recorded in pass 1,
  looked up in pass 2.
- **No add-reg**: stage0-as `add` is immediate-only, so all indexing uses running
  offsets and `[base+index]` addressing; positions are emitted as fixed-width
  decimal (a division-free digit loop).
- **Subroutines**: uses stage0-as's `bl`/`ret`. Helpers are leaves except
  `emitnl`, which does an internal `bl` and therefore saves/restores the link
  register around it (a leaf-only assumption would loop).
- **stage 1's own labels are single-char** (it is assembled by stage0-as, whose
  symtab is per-byte): it uses ~53 distinct single-character labels, well within
  the 128-entry symtab. This per-byte limit constrains *stage 1's own source*,
  not the programs it resolves — those are now unbounded.

## Known limits (motivate later work)

- Single `read`/`write` of the whole program (buffers sized generously, raisable).
- Numeric positions are emitted as **6 decimal digits**, i.e. output positions
  below 1,000,000 bytes (~250k instructions) — far above any current stage-2/3
  program; widen the field if a future program exceeds it.
- Name lookup is a linear scan (O(n^2) over a program's labels). Fine at spike
  scale and native-fast on hardware; a hash table can replace it if a
  self-hosting stage 3 makes it a bottleneck.

## Verified

Byte-identical to real `aarch64-linux-gnu-as` for a multi-char-label program
(numeric references encode the same offsets), and runs under QEMU to the expected
exit codes (loop+call -> 7; adr+mem with a multi-char data label -> 9). The real
stage-2 compiler source resolves to a **binary byte-identical to the previous
(pool) path**, so retiring the pool changed nothing downstream. The absence of a
ceiling is exercised end-to-end: programs with far more labels than the old
88-slot pool (150 in the model; 200 in CI; 300/600 verified separately) resolve
to label-free numeric output and run to the right exit code. Developed and
regression-tested against a Python model before pushing; CI (real `as` + QEMU) is
ground truth; `validate.py` pins the resolver behavior.
