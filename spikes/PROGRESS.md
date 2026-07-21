# Bootstrap Spike — Progress

*Status record for the feasibility-spike track. Last updated at: stage 0
assembler-complete.*

> **Scope: invariants SUSPENDED.** Everything described here lives under
> `spikes/` and is a *feasibility tracer*, not Veron proper. It deliberately
> drops the bijective-encoding rule, reproducibility, hermeticity, the
> round-trip audit, and the no-committed-binaries rigor. Its only job is to
> answer, cheaply: *can we build the ladder at all on this setup?* The real
> seed/stages (invariants ON) live under `seed/` and `stages/` and are not yet
> implemented. Nothing here should be copied into those without re-applying the
> invariants.

---

## 1. What this track is proving

That, on our actual setup — hand-written assembly, built by GNU `as`, run under
QEMU user-mode on GitHub Actions — we can construct a working toolchain from the
ground floor: source text → a running executable, using only tools we wrote.
Reference architecture is **ARM64** (`aarch64`); it round-trips most cleanly.

**Where we are now:** stage 0 is *assembler-complete*. The pipeline

```
program.s ──[stage0-as]──► code bytes ──[elf OUTPATH]──► runnable executable
```

works end to end, every instruction byte-verified against the real assembler,
and the produced binaries run under QEMU. The entire hand-written-assembly phase
is done. From here, higher stages are written **in stage-0's own language**, not
hand-encoded.

---

## 2. The toolkit

Two live tools, both hand-written in ARM64 assembly, both built by GNU `as`:

### `stage0-as`  (`spikes/stage0-as/stage0-as.aarch64.s`)
A two-pass mnemonic assembler. Reads line-oriented assembly-with-labels on
stdin, emits raw ARM64 machine-code bytes on stdout. Pass 1 records label
positions; pass 2 emits with branch/`adr` offsets resolved. See the language
reference in `spikes/stage0-as/README.md`.

### `elf`  (`spikes/elf/elf.aarch64.s`)
Reads raw code bytes on stdin, wraps them in a minimal static ELF, writes a
runnable file to the path given as `argv[1]`, and sets it executable itself
(`openat` mode 0755 + `fchmod`). The 120-byte header is a fixed template (proven
by `elf-proto`); only `p_filesz`/`p_memsz` are patched from the code length.
Currently emits an **R+W+X** segment (spike convenience, so programs can use
memory).

Compose them: `program.s | stage0-as | elf out && ./out`.

---

## 3. How everything is verified

Two independent checks, used throughout:

- **Byte-compare against the real assembler.** For any instruction, we assemble
  the equivalent with `aarch64-linux-gnu-as`, extract `.text` with `objcopy`,
  and diff it against `stage0-as`'s output. Byte-identical output means the
  encoding is provably correct (the reference toolchain is ground truth). Any
  mismatch pinpoints the exact instruction.
- **Run under QEMU.** Pipe through `elf`, run the result with `qemu-aarch64`,
  and check the exit code / output. This catches semantic (not just encoding)
  bugs.

Every tool's demo uses one or both. This is why the tools could be written in
one shot without a local ARM64 runtime: the CI demo is the test.

---

## 4. Spike inventory

| Path | What it is | Status |
|------|-----------|--------|
| `spikes/hello/hello.{x86_64,aarch64,riscv64}.s` | write() a string, exit — smoke tests for the qemu-user CI loop | **live** — all three pass |
| `spikes/stage0-arm64/stage0.aarch64.s` | first experimental stage 0: ARM64 hello in mnemonics | reference / superseded by `stage0-as` |
| `spikes/stage0-arm64/stage0-handencoded.aarch64.s` | same program with hand-computed `.inst` words; the round-trip lesson | reference (teaches the seed's core idea) |
| `spikes/seedas/seed-as.aarch64.s` | hex0-style loader (hex text → bytes) | proof of an alternative stage-0 shape; not the chosen path |
| `spikes/stage0-as/stage0-as.aarch64.s` | **the** mnemonic assembler (labels, two-pass, memory, data) | **live** — assembler-complete |
| `spikes/elf/elf.aarch64.s` | **the** ELF wrapper tool | **live** |
| `spikes/elf-proto/elf_proto.py` | throwaway: pinned the ELF header byte layout | superseded (its bytes are baked into `elf`) |

Workflows: `spike.yml` (3-arch smoke matrix), `stage0-as-demo.yml` (the main
stage-0 test: loop + memory + byte-compares), `elf-demo.yml`,
`stage0-roundtrip.yml`, `seedas-demo.yml`, `elf-proto.yml`.

---

## 5. Milestones reached (in order)

1. qemu-user CI loop proven on all three arches (hello world).
2. Wrote and ran hand ARM64 assembly (experimental stage 0).
3. Hand-encoded instructions as raw `.inst` words; confirmed the **round-trip**
   (bytes → intended instructions) via disassembly.
4. `seed-as`: a hex0-style loader — proved an asm program can consume input and
   emit a binary.
5. `stage0-as` v1: a real mnemonic assembler (`mov`/`svc` → machine code),
   byte-identical to real `as`.
6. `elf` tool: wraps code bytes into a runnable, self-`chmod`-ing executable.
   Full pipeline text → executable working.
7. `stage0-as` + labels/two-pass + `add`/`cmp`/branches: a **loop** assembles
   byte-identically and runs.
8. `stage0-as` + memory/addressing (`adr`/`ldrb`/`strb`/`ldr`/`str`).
9. `stage0-as` + `sub`/`mov`-reg/`cmp`-imm/`.byte`/`.ascii`; `elf` segment made
   writable → **runtime memory works**. **Stage 0 assembler-complete.**
10. `stage0-as` + **subroutines** (`bl`/`ret`/`br`/`blr`), **shifts**
   (`lsl`/`lsr`/`asr`), **logical** (`orr`/`and`), **wide-immediate** (`movk`) —
   the base a stage-1 assembler is written on. Each byte-identical to real `as`.
11. **Stage 1 (`macro-as`) capability #1: multi-character labels** —
   `spikes/stage1-as/stage1-as.s0`, the first tool written **in stage0-as's own
   language** (not hand-encoded). Resolves multi-char labels to single-char and
   pipes into `stage0-as`; output byte-identical to `as`, runs under QEMU.
12. **Stage 2 (`mini-c`) SEED** — `spikes/stage2-mini-c/stage2-mini-c.s1`,
   written **in stage-1's language** (multi-char labels). Compiles
   `int main(){return N;}` to aarch64 machine code that exits N. The first
   real compiler our own seed produces. Full ladder:
   `stage2.s1 | stage1 | stage0-as | elf`, then `prog.c | stage2 | stage0-as | elf`.
13. **Dev bench** — `spikes/bench/` (NOT part of the bootstrap): a Python model
   of `stage0-as` + a small ARM64 interpreter to develop/test `.s0`/`.s1` code
   locally before CI. `validate.py` pins it to CI ground truth; CI stays
   authoritative.

14. `stage0-as` + register `add`/`sub` and `mul` (madd-with-xzr) — the arithmetic
   base stage 2 needs to emit expression codegen. Byte-identical to real `as`;
   immediate `add`/`sub` forms unchanged (disambiguated by an `x` 3rd operand).
15. **Stage 2 expressions** — `return <expr>` grew from `N` to `+ -` (immediate
   chains), then `+ - *` with **precedence** (recursive descent, register
   codegen), then **parentheses** to any depth (shunting-yard, iterative, with a
   runtime **value stack** in `brk` memory). The general expression foundation.
16. **Stage 2 variables + assignment** — `int main(){ int a=<expr>; ... return
   <expr>; }`. Single-char names → labeled byte slots (`:a`..`:z`) in the emitted
   program via `adr`+`ldrb`/`strb`; a factor may be a number, variable, or
   `( expr )`. A statement loop drives the shunting-yard expression compiler.
17. **Stage 1 brk-buffer upgrade** — stage 1's inbuf/outbuf/nametable moved from
   image `.ascii` fillers to a `brk` heap (~20 KB each) with a `read` loop, using
   the new register `add`. Source shrank 15 KB → ~3 KB and it now handles large
   inputs without truncation — removing the growth ceiling for stage 2/3.
18. **Stage 2 word-sized variables** — variable slots went from 1-byte
   (`ldrb`/`strb`, `:a .byte 0`) to **4-byte word slots** (`ldr`/`str`, four
   `.byte 0` per slot), lifting the 0-255 storage limit so variable storage
   matches the 32-bit value stack. Change is confined to the emitted-code
   strings — `ldr w0 x1`/`str w0 x1` are the same encoding family as the value
   stack's `ldr w0 x9`/`str w0 x9`, so no stage0-as change was needed. Slots are
   word-aligned by construction (all-4-byte instructions precede the slot table).
   `stage2_ref.py` and a structural bench guard in `validate.py` are kept in
   sync. (With only `+ - *` and a mod-256 exit, byte vs word storage is
   exit-code-indistinguishable; the width becomes observable once `/` or
   comparisons arrive — hence the guard checks the emitted *forms*, not just
   exit codes.)

19. **Stage 2 control flow — `if`, `while`, reassignment** — the compiler now
   handles `if (<expr>) { … }`, `while (<expr>) { … }` (condition tested for
   nonzero), and reassignment `c=<expr>;`, all arbitrarily nested. Reassignment
   rode along because a `while` that can't mutate its condition is hollow. Codegen
   is **iterative with an explicit block stack** (a nested `bl` would clobber the
   return register, so recursion isn't free) — on `{` the compiler pushes the
   pending block's labels, on the matching `}` it pops and emits the close. Jump
   targets are **uppercase** labels `A`,`B`,… (variable slots are lowercase, so no
   collision); the condition reuses the existing shunting-yard expression engine
   plus `cmp x0 0` / `b.eq`. No new stage0-as instruction was needed (the required
   branches already existed). Statement dispatch was reworked to key on the second
   character (keyword ⇒ letter, reassignment ⇒ space/`=`), which removed the
   keyword/variable-name collision entirely (vars may be named `i`/`w`/`r`).
   Designed and proven on the bench first: `stage2_ref.py` gained an independent
   C-subset interpreter as a test oracle, and the `.s1` was checked against it
   through the real assembled ladder (nested loops, factorial, sum 1..10,
   nested `if`) before shipping; `validate.py` grew a matching structural +
   exit-code guard.

Notable bug found and fixed along the way: the hand-built ELF failed to run
because it lacked the execute bit — a *file-mode* issue, not a byte issue
(`readelf` was happy, QEMU was not). The `elf` tool now sets it itself.

**Milestone 20 — stage 2 gains relational `<` and `>`.** Conditions can now be
*relations*, not just nonzero-tests: `while(i<n)`, `if(a>b)`, count-up loops.
The operators sit below `+ - *` in precedence and yield `0`/`1`, composing with
arithmetic. Codegen is **branchless and label-free**: `a<b` is the sign bit of
the 64-bit difference `(a-b) >> 63` (`sub`/`mov`/`lsr` — no new stage0-as
instruction, no emitted branch), so it costs none of the 26 emitted-label slots.
Comparisons are **unsigned-32** (loads zero-extend). Verified through the real
assembled ladder (count-up sum, factorial via `i<5`, nested `<` loops, `>`
guards, precedence) and pinned in `validate.py`. Only `<`/`>` shipped this
increment: equality (`== != <= >=`) needs ~8 more single-char labels than the
stage-1 pool (62, `A-Za-z0-9`) has room for — the compiler is at 61 — so the
next increment expands stage-1's label pool first. **CI-confirmed** (real `as` +
QEMU): relational `<`/`>` compile and run through the full ladder — count-up
loops, factorial via `i<5`, `while(n>0)`, nested `<`, `>` guards, precedence —
with branchless codegen verified structurally and no byte-slot regression.

**Milestone 21 — stage 1's label pool expanded (62 → 76).** stage 1 maps each
multi-char label to a single-char slot from a `.ascii` pool; that pool was the
hard cap on distinct labels per program (stage 2 had reached 61 of 62). Since
stage0-as accepts *any* byte as a label — its symtab is indexed by the raw
character (`.space 512` = 128 entries) — the pool was extended past `A-Za-z0-9`
with punctuation `_$@?!%^&~|=<>+`, no stage0-as change. Programs with ≤62 labels
resolve byte-identically to before (the new slots are only reached beyond 62), so
this is a pure headroom addition. Verified end-to-end on the bench (63–76-label
programs resolve, assemble via stage0-as, and run to the right exit code,
including backward branches and `adr` to punctuation-slot labels) and pinned in
`validate.py`. This unblocks the equality operators (`== != <= >=`), which need
~9 labels more than the old pool allowed.

**Milestone 22 — handoff target pinned + C-subset spec written** *(planning, not
a capability rung).* We now treat M2-Planet's own source as the concrete
definition of the C subset the ladder must eventually accept (M2-Planet is
self-hosting, so its source is written in exactly the subset it compiles). The
`borrow-m2-demo` workflow pins M2-Planet to `34fbd5c…` (M2libc transitively via
its submodule gitlink, `ca023d8…`) so the spec can't drift. `spikes/stage2-mini-c/
TARGET-SUBSET.md` records what that subset actually **uses** (structs, enums,
function pointers, multi-level pointers, arrays, full operators, recursion, a
small `calloc`/`free` heap, and file I/O) versus what it deliberately **avoids**
(`switch`/`case`, `do/while`, `union`, `typedef`, ternary, floats/longs — a real
scope win), plus the runtime surface to provide and the stage-2 "floor" that must
be cleared before stage 3 is writable.

**Milestone 23 — M2-Planet + M2libc vendored as local reference.** The pinned
spec source (M2-Planet `34fbd5c…`, M2libc `ca023d8…`) is now committed read-only
under `spikes/reference/` so it can be consulted locally when designing against
the target subset — the assistant's sandbox has no network and doesn't persist,
so a CI-only pin was not enough to actually *read* the source in a later session.
It is reference only (not built by CI; the `borrow-m2-demo` workflow still fetches
its own pinned copy). See `spikes/reference/README.md`.

**Milestone 24 — stage 2 equality + relational-equality: `== != <= >=`.** The
four remaining comparison operators, completing `< > <= >= == !=`. All branchless
and unsigned-32, reusing the sign-bit-of-a-difference recipe with **no stage0-as
change** and **no emitted labels**: `a!=b` is `(d | -d) >> 63` (`d = a-b`), and
`a==b`, `a<=b`, `a>=b` are the `1 - x` flip of `!=`, `>`, `<`. Two-char operators
are recognised with one-char lookahead and carried on the shunting-yard operator
stack as single-byte sentinels (`1 2 3 4`), and precedence gained a fourth level
so equality sits **below** the relational ops (C order: `a==b<c` is `a==(b<c)`).
Existing programs (no equality) emit **byte-identical** asm — verified by diffing
old vs new compiler output — so it's a pure superset. The compiler grew from 61
to **74** of stage-1's 76 pool slots (2 to spare; the m21 pool expansion is what
made this fit). Developed on the bench against the oracle, then through the real
assembled ladder. **CI-confirmed** (real `as` + QEMU): all six comparisons compile
and run — `<=`/`>=` loop guards, `==`/`!=` in `if`, arithmetic-into-comparison and
`==`-below-`<` precedence — with branchless codegen verified structurally and no
regression. Remaining stage-2 leaf: `/` (needs `udiv`); the critical path stays
the **floor** (see `TARGET-SUBSET.md`).

**Milestone 25 — stage 0: 64-bit `ldr x` / `str x`.** The first brick of the
stage-2 **floor**: a real software call stack. stage0-as gained doubleword
load/store — the first operand's register width now selects the size, so
`ldr x<t> x<n>` / `str x<t> x<n>` emit the 64-bit forms (`0xF9400000` / `0xF9000000`,
size bit 30) while `ldr w`/`str w` are byte-for-byte unchanged (`0xB94…`/`0xB90…`).
It's a one-line-of-logic change (peek the width letter after `skip_ws`, pick the
base) with no new mnemonic. This is the enabler the handoff flagged: you cannot
build a call stack by `str`-ing `x30` or a frame pointer with a 32-bit store — it
would truncate a 64-bit address — so functions + recursion + function pointers all
depend on this. Mirrored in the bench (`s0as.py` width-aware encode, `interp.py`
8-byte load/store) and pinned in `validate.py` (byte-compare of both widths, plus
runtime proofs). **CI-confirmed** (real `as` + QEMU) via `stage0-as-ldrx-demo`:
`ldr x`/`str x` byte-identical to `as` (w-forms intact); a 64-bit value survives a
`str x`+`ldr x` round-trip and a save/restore across a nested `bl` (the call-stack
pattern); and the same shape with word `str`/`ldr` truncates the high word, as
expected. Next on the floor: a stage-2 label/codegen strategy (backpatch branch
offsets, frame-relative variable addressing) so a compiler can emit far more than
~128 labels, then functions on this call stack. See `TARGET-SUBSET.md`.

**Milestone 26 — stage 2: frame-relative variables (floor item 2a).** The first
half of the label/codegen strategy. Variables were labeled `:a`..`:z` word slots
— 26 labels emitted in *every* program, addressed with `adr`. They now live at
`x10 + (c-'a')*4` in a `brk` frame: the prologue sets `x10` to the frame base
(value stack starts at `x10+104`, past the 26 word slots), and each access emits
`add x1 x10 <off>` + word `ldr`/`str`. The offset is a 3-digit decimal pulled from
a compile-time table (`offtab`) by a new leaf helper (`emitoff`), so **the emitted
program carries no per-variable labels** — only its uppercase control-flow labels
remain (≤26, and those go next). This is exactly the addressing shape a real call
stack needs: once functions land, `x10` becomes a moving frame pointer set per
call, and locals are automatically per-frame (which recursion requires) rather
than global slots. Designed in `stage2_ref.py` against the oracle first (the ref
matches the real `.s1` byte-for-byte), then verified through the real assembled
ladder: emitted programs contain zero labels for variable-only code, a 5-variable
program and the offset-100 case (`z`) run correctly, and `x10` is written only in
the prologue. Compiler label budget 74→**75** of 76 (net +1: added `offtab` +
`emitoff`, removed the slot table); source actually shrank (the big slot-table
string is gone). Pinned in `validate.py` (structural: frame base, per-var offsets,
no `:a`/`:z`/`.byte 0`; behavioural: many-variable programs) and **CI-confirmed**
(real `as` + QEMU) via `stage2-mini-c-demo`. Next: **floor item 2b — branch-offset
backpatching**, which removes the last emitted-label class (control flow), leaving
only function-entry labels; then functions on the m25 call stack.

**Milestone 27 — stage 0: numeric PC-relative branch `b/b.cond @<pos>` (floor 2b-i).**
The enabler for stage-2 branch-offset backpatching. A branch operand may now be a
**numeric absolute output byte-position** (`b @<pos>`, `b.eq @<pos>`, etc.) instead
of a label; stage0-as encodes the relative offset `(pos - here)` itself, exactly as
it does for a label, so it consumes no symtab entry. Byte-verified to be
**identical** to the equivalent label branch (forward and backward, `b` and
`b.cond`), which is itself byte-checked against real `as`. The one subtlety: `@` is
already a stage-1 pool label char, so stage 1's output legitimately contains
`b @` (branch to label `@`). Disambiguation is by the next character — only `@`
followed by a **digit** is numeric; a bare `@` stays the label — so stage 1's
≥63-label output is unaffected (guarded in `validate.py`). Mirrored in the bench
(`s0as.py` resolves `@<digits>` to a position) and pinned in `validate.py`
(byte-identity fwd/back for `b`/`b.cond`, a numeric-branch loop, and the label-`@`
preservation). **CI-confirmed** (real `as` + QEMU) via `stage0-as-brnum-demo`.
Next — **floor 2b-ii**: stage 2 tracks an instruction counter and emits `if`/`while`
branches as `@<pos>` with a fixed-width placeholder it backpatches when the block
closes, removing the last per-emit label class (control flow). Then functions.

---

## 6. What's next

The plan is a **capability-jump ladder**: keep each rung minimal, and write each
stage in the language of the stage below.

- **Stage 1** — DONE (multi-character labels) and upgraded to `brk` buffers so it
  can process large stage-2/3 sources; label pool expanded to **76** single-char
  slots (`A-Za-z0-9` + punctuation) so stage 2 can keep growing. See
  `spikes/stage1-as/`.
- **Stage 2** — in progress. Compiles `int main(){ … }` with **word-sized**
  variables, declaration + **reassignment**, `+ - *` expressions plus the full
  **comparison** set `< > <= >= == !=` (four precedence levels, parentheses), and
  **control flow** (`if`/`while`, nested). Conditions can be comparisons or
  nonzero-tests. `/` (needs `udiv` in stage0-as) is the one remaining small leaf
  increment, but the **critical path to stage 3 is the stage-2 "floor"**:
  functions + a real call stack, pointers/`char`/arrays, `struct`, a small heap,
  multi-char labels/identifiers, and I/O. Floor progress: **64-bit `ldr x`/`str x`**
  (m25, the call-stack enabler), **frame-relative variables** (m26, no per-var
  labels), and the **numeric PC-relative branch** `b @<pos>` (m27, the backpatch
  enabler) are in. Next: stage 2 emits `if`/`while` branches as backpatched
  offsets (removes the last emit-label class), then functions on the call stack.
  See **`stage2-mini-c/TARGET-SUBSET.md`**.
- **Stage 3** — a compiler written in stage-2's C, once stage 2 clears the floor.
- **Hand-off**: the concrete finish line is compiling **M2-Planet's own source**
  (pinned at `34fbd5c…`, vendored read-only at `spikes/reference/`) into a working
  M2-Planet, which drives the borrowed live-bootstrap chain (see
  `spikes/borrow-m2/`, `spikes/livebootstrap/`). The target C subset is spelled
  out in `stage2-mini-c/TARGET-SUBSET.md`.

Scope rule: add the smallest capability per rung that makes the next rung
writable. If a stage feels unwieldy to write, that's the signal to add one small
convenience to the stage below — not to push through pain.
