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

**Milestone 28 — stage 1: label pool 76 → 88 (headroom for the backpatch).** A
pure headroom step, same shape as m21 (62→76), setting up floor 2b-ii. The
backpatch codegen needs several more stage-2 source labels than the pool allowed
(the compiler was at 75/76): it adds a fixed-width integer→decimal routine for the
branch position field and a newline-based instruction counter. Rather than cram,
the pool gained 12 punctuation slots — `()*,-./;[]{}` — appended after the m21
set. stage0-as accepts any byte 0–127 as a label (symtab indexed by raw byte), so
this is a stage-1-only change; programs with ≤62 labels still resolve
byte-identically, and each new char was checked as a real label (def + backward
branch) through the assembled ladder. Mirrored in `stage1_ref.POOL` and pinned in
`validate.py` (resolves 62/76/80/88-label programs end-to-end; slots 63 and 87 are
punctuation; backward branch through an 80-label program). **CI-confirmed** (real
`as` + QEMU) via `stage1-as-demo` (now an 88-label pool program). Next: **floor
2b-ii** proper — stage 2 emits `if`/`while` control flow as backpatched `@<pos>`
offsets, using this headroom, leaving only function-entry labels.

**Milestone 29 — stage 2: backpatched control flow (floor item 2b-ii).** The last
per-emit label class is gone: `if`/`while` are now emitted with **backpatched
numeric branches** (`b.eq @<pos>` / `b @<pos>`, the m27 form), so — combined with
m26's frame-relative variables — **the emitted program contains no labels at all**.
Mechanism: the compiler keeps an emitted-**instruction counter** (`emitstr` counts
the `\n` bytes it writes, so a target's byte position is count×4); a forward branch
(if-skip, while-exit) emits a 6-digit `@000000` placeholder and records its output
buffer offset on the block stack, then backpatches the real target position at `}`;
a backward branch (while loop-back) is emitted directly since its target is known.
The block stack moved from 3 bytes to 3 words per entry (positions don't fit a
byte). The position field is written by `pos6`, a division-free 6-digit itoa
(repeated subtraction). Two real snags, both caught by testing through the real
ladder: (1) stage 1 parses any token starting with `w`/`x` as a register, so the
first-cut helper labels `wr6/w6l/...` weren't resolved — renamed to `pos6/p6l/...`;
(2) the compiler's fixed output buffer (~4.4 KB, between the output base and the
operand stack) overflows for programs with more than ~10 control-flow blocks — the
backpatch is correct, but program *size* is capped until the buffers are raised
(the next increment). Compiler grew 75→**81** of the now-88 pool slots (added the
counter, `pos6`, and branch strings; dropped the label emitter). Designed in
`stage2_ref.py` (byte-identical to the real `.s1`), verified through the assembled
ladder (deep nesting, if-in-while, sequential blocks, a 190-iteration loop; branch
targets hand-checked to land on the right instruction), pinned in `validate.py`
(no labels emitted; numeric branches; 4-aligned in-range targets; behavioural
sweep), and **CI-confirmed** via `stage2-mini-c-demo`. Next: **larger compiler
buffers** (input/output/stacks) to cash in the label-free codegen, then functions
on the m25 call stack.

**Milestone 30 — larger pipeline buffers (cashing in the label-free codegen).**
The m29 backpatch made control flow label-free, but the compiler's fixed buffers
capped real programs at ~10 blocks. This raises them across the whole pipeline:
stage 2's input to **64 KB**, output to **256 KB**, with the operator/block stacks
moved out accordingly (offsets built with `movk`, since they exceed a 16-bit
immediate); stage0-as's input buffer **16 KB → 256 KB** and elf's code buffer
**32 KB → 256 KB** (both `.bss`, so zero file bloat) so the *whole* `stage2 |
stage0-as | elf` pipeline handles large `.s`/binaries — otherwise stage 2 could
emit programs stage0-as would truncate (a bench-vs-reality gap the bench would
have hidden, since the Python assembler has no input cap). The change is entirely
compiler-internal: emitted output for any program is **byte-identical** to m29.
Result: a program with **150 sequential if-blocks** (~65 KB of emitted assembly)
compiles and runs to the right exit code — far beyond both the old ~63-label
ceiling and the old ~4.4 KB output buffer. Pinned in `validate.py` (20/40/80/150
sequential blocks, a big-body loop, and an >30 KB label-free emission) and
**CI-confirmed** via `stage2-mini-c-demo` (an 80-block program end-to-end).
Next: **functions + a real call stack** on the m25 64-bit `ldr x`/`str x`, the
first genuinely new language capability of the floor.

**Milestone 31 — stage 0: numeric PC-relative `adr xR @<pos>` (pool-retirement enabler).**
A small mirror of m27's numeric branch, for `adr`: it now accepts an absolute
output position (`adr xR @<pos>`) and encodes the PC-relative offset `(pos - here)`
itself, with the same `@`+digit disambiguation (a bare `@` stays the pool label).
Why now: **the single-char label pool is a dead end.** It maps stage-2 names onto
stage-0-as's 128-entry byte symtab (~91 safe printable), and as stage 2 grows into
a real compiler (functions, pointers, char/byte load-store, arrays, globals,
struct, a calloc/free heap, I/O, string literals) its *source* needs far more
labels than that — a self-hosting stage 3 needs hundreds. No pool expansion
reaches that. The fix is to make **stage 1 a two-pass numeric resolver**: compute
each label's position and rewrite every reference to `@<pos>`, dropping label
definitions, so its output is label-free and the symtab is never in the path.
Branches already had a numeric form (m27); the missing piece was `adr` (stage-2
source has 31 `adr`-to-data refs among 183 label refs), which this milestone adds.
Validated on the bench: numeric `adr` is **byte-identical** to the label form at
adjacent/near/far distances and loads the right data; mirrored in `s0as.py` and
pinned in `validate.py`; **CI** via the new `stage0-as-adrnum-demo` (byte-identical
to real `as`, numeric adr loads data, bare `@` label intact). Next: **stage 1 →
numeric resolver**, retiring the pool for good; then functions and the rest of the
floor land with label count off the table.

**Milestone 32 — stage 1 becomes a NUMERIC label resolver (the pool is retired).**
This is the architectural payoff the last two milestones set up. stage 1 was a
one-pass **pool mapper**: it renamed each multi-character label to a single-char
slot in stage0-as's 128-entry byte symtab (~91 safe printable). That cap is a dead
end for a growing compiler. stage 1 is now a **two-pass numeric resolver**: pass 1
walks the program tracking assembled position and records every `:name`
definition's position in a dynamic symbol table (names in a name buffer, positions
in a parallel word array); pass 2 re-walks, **drops** the `:name` definitions, and
rewrites every branch/`adr` reference to a numeric `@<pos>` — which stage0-as
encodes directly (numeric branch from m27, numeric `adr` from m31). The output is
**label-free**, so stage0-as's symtab is never in the path for stage-2/3 code and
the number of labels a program may use is **bounded only by memory**. stage 1's
*own* source still uses single-char labels (it is assembled by stage0-as) — ~53 of
them, well within 128 — but that constrains only stage 1's source, not the programs
it resolves. The resolver is authored with readable label names and mechanically
mapped to distinct single chars (`author_stage1.py`) so the 53-label single-char
source stays maintainable. One subtlety cost a debugging loop: `emitnl` does an
internal `bl`, so it must save/restore the link register (every other helper is a
leaf); a leaf-only assumption made its `ret` branch to itself. Validated on the
bench through the assembled ladder: the new stage 1 assembles (315 instrs, 53
labels); the real stage-2 compiler source resolves to a binary **byte-identical to
the old pool path** (2481 bytes, zero labels remaining) and the resolved compiler
compiles+runs correctly; numeric `adr`-to-data resolves; and the **ceiling is
gone** — 89/150/300/600-label programs resolve to label-free numeric output and run
to the right exit codes (300+ merely slow in the Python interp's O(n^2) lookup,
native-fast on hardware). `stage1_ref.py` is now the resolver model; `validate.py`
replaces the pool tests with resolver tests (label-free output + correct exit for
62/88/89/150 labels, numeric branch/adr refs present, a 120-label backward-branch
loop); the `stage1-as-demo` workflow proves byte-identity to real `as`, adr+mem,
and a 200-label program (no pool). Limits noted: `@<pos>` is 6 digits (positions
< 1,000,000 bytes) and lookup is linear (a hash table can come later). With labels
off the table, **functions** (design already validated) and the rest of the floor
can land unconstrained.

**Milestone 33 — stage 0: numeric `bl @<pos>` (completes the resolver's numeric set).**
Shipping m32 surfaced a real bench-honesty miss. The stage-1 resolver rewrites
*every* reference numerically, including the 46 helper **calls** in the stage-2
source (`bl compile_expr`, `bl emitstr`, …) which become `bl @<pos>`. But the
numeric-branch milestone (m27) had only added the `@<pos>` path to `b` and
`b.cond`, and m31 to `adr` — **`bl` was never given one.** Worse, the bench's
`s0as.py` modeled `bl @<pos>` as numeric all along (its `bl` shared the generic
branch encoder), so the resolver's output assembled to a byte-identical binary *in
the bench* while real stage0-as read the `@` as a label and mis-encoded all 46
calls — the stage-2 compiler built through the new stage 1 emitted nothing, and
`stage2-mini-c-demo` / `stage1-as-demo` went red. The bench was more capable than
reality, exactly the failure the bench-honesty rule exists to prevent; the gap was
that `bl @<pos>` had a model but **no CI anchor against real `as`**. Fix: add the
`@`+digit path to `h_bl_or_blr` (identical to the m27 branch, base `0x94000000`),
and close the honesty gap by anchoring `bl @<pos>` against real `as` in the
`stage0-as-brnum-demo` (byte-identical forward/back, label form vs `as`, and a
numeric-`bl` call that returns → exit 7) plus a `validate.py` guard. With `b`,
`bl`, `b.cond`, and `adr` all numeric, the resolver's output is fully assemblable
and the stage-2 pipeline is byte-identical to the pool path again — this time in
reality, not just the bench. Lesson recorded: a bench capability with no CI anchor
is a latent lie; every numeric form now has one.

---

**Milestone 34 — stage 2: tokenizer front end (lexer), byte-identical (floor backbone A1).**
The stage-2 floor ahead (functions, pointers/`char`/arrays, `struct`, a heap, I/O)
all need real name resolution and multi-char identifiers, so before adding any
capability this rebuilds the front end into the seam they share — and proves the
swap changes nothing. The old front end had two ad-hoc scanners: a **2nd-char
statement dispatch** (`in`/`if`/`wh`/`re`) and an inline character classifier inside
`compile_expr`. Both are replaced by ONE tokenizer, `next_token`, consumed by both
the statement loop and `compile_expr`: it skips whitespace, then returns a token
kind (num/id/kw/op/punct) with its value, doing a real **full-word keyword match**
(`int`/`if`/`while`/`return`) and scanning identifiers as runs (multi-char capable
— only single-char names are *used* today, but nothing assumes it). Frame offsets
keep the letter-map policy in `emitoff` (`(name-'a')*4`) — the A1 frame policy; the
declaration-order allocator and the live symbol table arrive in A2, where offsets
first depend on them (so they are behavior-tested, not latent). The whole point is
byte-identity: the emitted machine code is **unchanged**. Designed in
`stage2_ref.py` as three seams (lexer + symbol table + frame allocator), proven
byte-identical to the pre-refactor reference (117 differential checks: asm text,
assembled bytes, oracle value, end-to-end exit) and to the current `.s1` through
the assembled ladder; the `.s1` port was then verified byte-identical through the
**real assembled ladder** (`stage1` resolves it, `stage0-as` assembles it) on the
corpus plus a tokenizer-stress sweep — whitespace/newlines, multi-digit literals,
deep nesting, and single-char vars named `i`/`w`/`r` that must NOT be read as
keywords — with `validate.py` gaining end-to-end tokenizer anchors and staying
green (140→145 checks). Because output is byte-identical and the new front end uses
only instruction forms the compiler already emitted, there is **no new stage0-as
capability and no new byte-anchor needed** — the existing `stage2-mini-c-demo`
(which rebuilds the compiler and checks its emitted output + exit codes across the
whole sweep) is the CI witness. Next: **A2 — functions + a real call stack**,
flipping the frame policy to a declaration-order allocator and making the symbol
table live, on the m25 64-bit load/store.

---

**Milestone 35 — stage 2: functions + a real call stack + recursion (floor backbone A2).**
Building on the A1 tokenizer, the compiler gains real functions. A program is now
one-or-more `int name(params){body}`, and a call `f(a,b)` is a primary usable in any
expression. Three A1 seams that were latent become live at once: the **frame
allocator flips to declaration order** (params first, then locals; the i-th name
declared gets `off=i*4`), a **live symbol table** resolves multi-char names to those
offsets (the `(name-'a')*4` letter-map is retired — `emitoff` now emits a computed
3-digit offset), and `compile_expr` is made **re-entrant** so a call's argument
expressions can nest (each invocation parks its return address + opstack base on a
small compiler-side stack; `,`/`)` terminate an argument by scanning the opstack for
a pending `(`). Emitted programs now carry `:name`/`bl name` at function boundaries
(resolved by stage1) **mixed with** the numeric backpatched `b.eq @<pos>` if/while
branches (which stage1 passes through), so the pipeline becomes `prog.c | stage2 |
stage1 | stage0-as | elf`. The runtime calling convention uses three regions in one
brk block: `x9` value stack (temporaries, argument passing, and return value), `x10`
current frame base, `x11` frame stack top (frames nest → recursion). A call evaluates
args left-to-right onto the value stack then `bl f`; the callee prologue saves the
caller's `x10`/`x30` (64-bit `str x`, from m25), opens a 16-aligned frame, and pops
its params (reverse) into slots; `return e` leaves the result on the value stack,
restores `x10`/`x30`/`x11`, and `ret`s. The program is entered via `bl main`, and
`main`'s return is the exit code. Designed and proven in `stage2_ref_a2.py` (a
declaration-order allocator + live symtab + a recursive interpreter oracle) against
12 function/recursion programs plus 17 legacy single-`main` programs, then the `.s1`
port was verified through the **real assembled ladder** (`stage2 → stage1 →
stage0-as → run`) on 37 programs total — argument passing, frame-slot reuse across
calls, calls in loop bodies and `if` conditions, nested-call arguments (3-level),
mutual recursion, tree recursion (`fib`), tail-with-accumulator, deep linear
recursion (`cnt(200)`), and Ackermann (`ack(2,5)=13`). Five real bugs were found and
fixed in the port, each a register-discipline or tokenizer gap the reference could
not surface: `prescan` clobbering `x30`/counters across `next_token`; the param-pop
loop counter clobbered by `emitoff`'s digit register; `compile_call` overwriting the
scan cursor with the saved callee-name span (re-emitting args); and — the subtle one
— the A1 tokenizer silently **skipping `,` as whitespace** (it treats any
unrecognized char as space), which collapsed every argument list into one run-on
expression until `,` was added as a punct token. `validate.py` now resolves stage-2
output **through stage1** before assembling (retiring the "emitted output is
label-free" assertions — the only labels are function names, verified explicitly),
checks declaration-order offsets, and gains a functions+recursion section (145→169
checks). The `stage2-mini-c-demo` workflow inserts stage1 into the compiled-program
pipeline and adds structural (`:func` label, prologue/epilogue, `bl`) + behavioural
(add/sq/nested/fact/fib/pw/tri/mutual/ack) anchors on real aarch64; because the
emitted saves/restores use only the m25 64-bit `str x`/`ldr x` forms already
byte-anchored against real `as`, no new stage0-as capability or byte-anchor is
needed. Next: **A3 — pointers, `char`, and arrays** (typed loads/stores and address-of),
the first step toward the memory model M2-Planet's source needs.

---

**Milestone 36 — stage 2: unsigned `/` and `%`, via a new stage0-as `udiv` (leaf).**
The one remaining arithmetic operator that can't be synthesized from a short fixed
sequence (unlike the comparisons) is division, so this adds it as a self-contained
leaf. stage0-as gains **one instruction**, `udiv x<d> x<n> x<m>` — it's a
DP-2-source sibling of the existing `lsr`/`asr` (same `0x9AC00000` base, selector
`0x0800`), so the hand-written assembler reuses its `shift_common` path: a first-char
`'u'` dispatch plus a 3-line handler. The bench model (`s0as.py`) and interpreter
(`interp.py`) mirror it, and the demo **byte-anchors `udiv` against real `as`**
(`udiv x0,x1,x0` → `20 08 c0 9a`, i.e. `0x9AC00820`), the same discipline every
stage-0 opcode gets. In stage 2, `/` lowers to a single `udiv x0 x1 x0` and `%` to
`udiv x2 x1 x0; mul x2 x2 x0; sub x0 x1 x2` (`a - (a/b)*b`) — so `%` needs **no**
capability beyond `udiv`. Both are added to the tokenizer (`/`=47, `%`=37 as
operator tokens), bind at the **multiplicative** level with `*` (left-associative)
in the shunting-yard precedence machine, and emit through the existing `emitapply`
seam (two new operation strings `sdivr`/`smodr`). Semantics are **unsigned-32**,
matching the value stack and the existing unsigned comparisons; aarch64's divide-by-
zero → 0 is preserved end-to-end. Signed `/` is deliberately **not** added: the
value stack is zero-extended, so `sdiv` would be latent/untestable until signed
types land (it arrives with `sdiv` + sign-extension then). Designed against the
oracle (`stage2_ref_a2.py` gains `/`/`%` in its tokenizer, precedence, evaluator,
and codegen) and verified through the **real assembled ladder** on precedence
(`2+10/2=7`), left-associativity (`20/4/5=1`, `3*4/2=6`), the identity
`(n/d)*d + n%d == n`, divide-by-zero, and Euclid's `gcd(48,36)=12`; `validate.py`
gains a division section (169→184 checks) including the model's `udiv` encoding, and
the `stage2-mini-c-demo` workflow gains the `udiv` byte-anchor + `/`/`%` structural
and behavioural checks wired into its pass/fail gate. Next: **A3 — pointers, `char`,
and arrays**.

---

**Milestone 37 — stage 2: a 64-bit uniform machine-word model (A3a).** A3 is
pointers/`char`/arrays, and its prerequisite is the memory model: a pointer is a
64-bit address and cannot fit the old 32-bit value stack, so this milestone widens
stage 2 to the **machine-word model M2-Planet itself uses** — `int == pointer`
width. The value stack and every frame slot go from 4-byte to 8-byte: pushes/pops
become `str x`/`ldr x`, variable load/store become `ldr x0 x1`/`str x0 x1`, the
frame allocator hands out `off = i*8` (declaration order, unchanged), the param-pop
stores each arg into an 8-byte slot (`i*8`, a latent off-by-scale the port had to
fix), and `emitoff` widens from a 3- to a 4-digit decimal so bigger frames (arrays,
next) still address cleanly. Crucially the change is **surgical**: the four
frame-offset shifts scale `×4→×8`, but the *code-position* shifts (`x17×4`, the byte
address of a branch target) stay `×4` because instructions are still 4 bytes — the
two uses of the same `lsl` idiom are kept distinct. The arithmetic and comparison
op-strings are untouched (they already operate on `x` registers); the comparisons
keep their exact bytes but now mean a **signed-64** ordering (bit 63 of the
difference), correct across the whole bootstrap range. Small values exit exactly as
before, so the width is proven by a **distinguisher**: a product that overflows 32
bits and is then divided — `int a=2000; a*a*a/1000` — gives `200` under 32-bit
arithmetic but `0` under 64-bit, and the assembled ladder returns `0`. The oracle
(`stage2_ref_a3.py`, forked from the a2 reference) widens its frame and codegen and
lifts its word mask to `2^64-1` so it agrees; verification runs the **full A2 + div
corpus** (functions, recursion, `ack(2,3)`, `gcd`, `/`, `%` — all identical) plus
the new distinguishers through the real `stage2 | stage1 | stage0-as` ladder.
`validate.py` gains a word-model section (184→190 checks) and the
`stage2-mini-c-demo` workflow gains the 64-bit structural greps (`ldr x0 x1`,
`str x0 x9`, `off 0000/0008`) and the distinguisher runs in its pass/fail gate. No
stage0-as change — the ISA already had 64-bit `str x`/`ldr x` (byte-anchored since
m25). Next: **A3b — `char`, `&`, `*`, and arrays `[]`** on top of this word model.

---

**Milestone 38 — stage 2: pointers — `&`, `*`, and store-through (A3b).** With the
64-bit word model in place, this adds the capability it was built for:
**indirection**. A3b is scoped to single-level pointers — `int* p` declarations
(and pointer params), `&name` (address-of), `*name` (dereference as an rvalue), and
`*name = e` (store-through) — which is the smallest coherent rung that delivers
**pass-by-reference**. Because a pointer is exactly one machine word, every pointer
operation is a plain 8-byte load/store, so **no element-size or type machinery is
needed yet** (that arrives with arrays and `char`): `&x` pushes a frame address
(`add x0 x10 off`, no load), `*p` loads the pointer then loads through it
(`ldr x1 x1; ldr x0 x1`), and `*p = e` evaluates `e`, recomputes the address, and
stores (`str x0 x1`). The one real parser subtlety is that `*` is now **overloaded**
— binary multiply (`a*b`) vs unary dereference (`*p`) — resolved by an
**operand-position flag** threaded through the expression compiler in `x3` (set at
entry and after every operand/operator, read when a `*` token arrives); `a*b` and
`*p` compile correctly side by side, as does `*p*b`. Two smaller gaps the pointer
work exposed are filled: **uninitialised declarations** (`int* p;` with no
initialiser) and **bare call statements** (`set(&x);` — a call evaluated for its
side effect, its result discarded), both of which pass-by-reference needs. No
stage0-as change — `&`/`*`/store-through are all existing loads, stores, and adds;
the tokenizer gains only the `&` character. Designed against the oracle
(`stage2_ref_a3b.py`) and verified through the **real assembled ladder** on
dereference (`*p` → 5), store-through (`*p=42` → 42), read-modify-write via a
pointer (`*p=*p+y`), pointer copy (`q=p; *q=99`), `inc(&c)` twice → 43, and the
classic `swap(&x,&y)` → 83 — plus the **entire A2 + division + word-model corpus**
unchanged. `validate.py` gains a pointer section (190→201 checks) and the
`stage2-mini-c-demo` workflow gains the `&`/`*` structural greps and pass-by-
reference behavioural runs in its pass/fail gate. Next: **A3c — arrays `int a[N]`
and subscript `a[i]`** (per-var frame sizing + scaled indexing), then **A3d —
`char`** (byte `ldrb`/`strb` access + char literals).

---

**Milestone 39 — stage 2: arrays — `int a[N]` and subscript `a[i]` (A3c).** This
adds indexable memory. `int a[N]` reserves N words in the frame, `a[i]` reads and
writes the i-th element (rvalue and lvalue), and a bare array name **decays** to
`&a[0]` so arrays pass to functions as pointers (`sum(a, n)` with `int* p`). The
structural change under the hood is that **frame slots are now variable-size** — an
`int a[N]` takes N words, not one — which breaks the old shortcut of deriving a
variable's frame offset from its symbol-table index. The **symbol table is
reworked**: each entry grows to four words `[name_start, name_len, frame_offset,
size]`, `symdecl` computes a **running byte offset** (previous entry's offset + its
size) and stores it explicitly, and `symlookup` returns the stored offset plus the
size (so the code generator can tell an array from a pointer: an array's base is its
frame address `add x0 x10 off`, a pointer's base is loaded first with `ldr x1 x1`).
The frame **prescan** becomes size-aware — it now measures each declaration
(consuming `[N]` via a new `parsenum` digit-folder) and sums N words per array, so
the prologue reserves a frame big enough; without this an array silently overruns
its frame and a later call corrupts it. Subscripting scales the index by the word
size (`lsl x2 x2 x3`, ×8) and addresses `base + i*8`; `a[i]` reuses the **re-entrant
expression compiler** to parse the index (stopping at `]`), so nested subscripts
like `a[a[2]]` and expressions like `a[i]*b[i]` work. `&a[i]` yields an element
address. No stage0-as change — subscripting is adds, a shift, and word loads/stores
that already exist. Designed against the oracle (`stage2_ref_a3c.py`) and verified
through the **real assembled ladder** on element load/store, an indexed fill loop,
array→pointer decay, a two-array dot product (`dot(x,y,3)` → 32), nested subscript
`a[a[2]]`, and `&a[i]` — plus the **entire pointer + A2 + division corpus**
unchanged. `validate.py` gains an array section (201→211 checks) and the
`stage2-mini-c-demo` workflow gains subscript-scaling structural greps and array
behavioural runs in its pass/fail gate. Next: **A3d — `char`** (byte `ldrb`/`strb`
access + char literals), the last A3 rung before revisiting the M2-Planet subset.

---

**Milestone 40 — stage 2: `char` + byte access — `char* p`, `char s[N]`, `ldrb`/`strb` (A3d).**
This completes the A3 memory model. `char c` is a scalar (word-stored, since a char
promotes to int in expressions), but a `char*` dereference and a `char[]` subscript
use **byte-width** access — `ldrb`/`strb` with no ×8 scaling — and `char s[N]` is
**byte-packed** (N bytes, rounded up to 8-alignment). Single-character literals `'x'`
tokenize to their ASCII value (a new token kind emitted as `mov x0 <value>`). The
enabling structural change is in the **symbol table**: a small `char[N≤8]` rounds up
to size 8, which collides with a scalar's size, so the old "size > 8 means array"
heuristic no longer works. Each symbol-table entry therefore grows to carry an
explicit **flags word** (is_char, is_array), and the code generator branches on those
flags to choose word vs byte access and frame-base vs load-base. The frame prescan
became char-aware too (a `char[N]` reserves ⌈N/8⌉ words, not N). With byte pointers
and byte arrays, real string code works: the milestone's headline demo is **`strlen`
written in the language itself** — `int len(char* p){ int n; n=0; while(p[n]){ n=n+1; }
return n; }` — compiled through the self-hosting ladder and returning 3 on `"abc\0"`.
Byte-value wraparound (250+250 → 244 in a `char[]`), byte fill loops, `char*`
store-through, and `&s[i]` all verified end-to-end; the entire int-array, pointer,
A2, and division corpus is unchanged. **No stage0-as change** — `ldrb`/`strb` already
existed. One bench-side note: the larger self-hosting compiler needs more interpreter
steps than the old 5M runaway guard allowed, so the Python model's guard was raised
(the real CI runs native under qemu, with no such limit). `validate.py` gains a char
section (211→222 checks) and the `stage2-mini-c-demo` workflow gains `ldrb`/`strb`
and char-literal structural greps plus char behavioural runs. **A3 is complete**
(pointers, arrays, char, byte access on the uniform word model); the next work
revisits the M2-Planet C subset toward stage 3 — string literals (a data section),
general pointer arithmetic scaling, multi-level pointers, and structs/globals.

---

**Milestone 41 — stage 2: string literals + a static data section (A4a).** This is
the first piece past the A3 memory model and the start of the road toward a real
self-hosting C subset. A `"..."` literal becomes a `char*` into a **static data
section**: the compiler now carries a *second* output buffer, filled during
compilation with the literal's bytes under a generated label (`__d0`, `__d1`, …) and
a null terminator, and appended after all code at the end so `adr x0 __dN` reaches it
PC-relative (stage1 resolves the forward data-label reference like any other). Because
a string literal is just a `char*`, it flows straight into the byte-access machinery
from m40 — `s[i]`, `*s`, and `strlen` all work on literals — so the headline demo is
`strlen("hello") → 5` with the string living in the data section, plus string literals
passed as function arguments (`f("MN","XY")`). The design point, and the reason this
milestone matters more than its size suggests: the second-buffer data section is
**general infrastructure, not a string hack** — the same `add_data(bytes, label)`
primitive (anonymous `__dN` for strings, named `g_`-labels for globals) is what the
next milestone reuses for global variables, and it's the machinery every compiler
above us in the bootstrap chain (Mes, tcc) assumes exists. The `.s1` port surfaced one
sharp bug worth recording: `compile_call` rewinds the scan cursor to the first
argument's token start (`x18`) to re-read it, but the string tokenizer had moved `x18`
*past* the opening quote to the content start, so a literal used as a call argument
rewound *inside* the string and the compiler parsed `hi")` as code — fixed by keeping
`x18` on the opening quote (the true token start) and reading content from `x18+1`.
No stage0-as change. One bench note: `adr` is PC-relative with a bounded range
(fine for M2-Planet-scale programs; `adrp`+`add` for full range is a later refinement,
exactly the kind of thing tcc/gcc handle once the chain hands off to them).
`validate.py` gains a string-literal section (222→232 checks) and the
`stage2-mini-c-demo` workflow gains `adr`/`:__d`/`.byte` structural greps plus string
behavioural runs. Next: **globals** (reusing this data section), then general pointer
arithmetic and structs — the pieces M2-Planet's own source leans on.

---

**Milestone 42 — stage 2: global variables (A4b).** File-scope variables — `int g;`,
`int* p;`, `int a[N];`, `char s[N];`, `char* msg;` — shared across every function.
This is the capability M2-Planet's own source leans on hardest (its token buffer,
output pointer, and counters are all globals), and it landed on the m41 data section
with **no new data infrastructure**: a global is just a named `g_<name>` entry in the
same output buffer that holds string literals, emitted via the same primitive. Two
things were added. First, a **globals table** — a persistent name→flags map in its own
memory region, populated by `gsymdecl` as the top-level loop parses each file-scope
declaration (distinguishing a global `name ;` / `[N]` from a function `name (` by a
lookahead). Second, **two-level name resolution**: every variable reference now tries
the per-function frame first (`symlookup`), then the globals table (`gsymlookup`), and
the address it emits is `add xN x10 <off>` for a local or `adr xN g_<name>` for a
global. That routing was centralized into `emitbase0`/`emitbase1` so the ~seven
address-emitting helpers just call one of them, and the subscript/store callers now
save the variable's *name span* across sub-expression compilation (re-resolving after)
rather than a frame offset — which is what makes `g[i]`, `&g`, and `*g = e` work on
globals uniformly. No stage0-as change. The port surfaced two classic hand-assembly
bugs, both worth recording: `resolve`/`emitbase` are non-leaf (they call other
routines) yet initially saved their return address in `x27` — the same register their
callers use — so a variable reference returned into itself and span forever; and
`gsymlookup` used `x12` as a compare temporary, but `x12` is `compile_expr`'s operator-
stack base, so *global* references (locals never hit `gsymlookup`) corrupted the
expression compiler. Both fixed by saving through the `x28` spill stack. Verified
through the ladder: global scalars, arrays (int and byte-packed char), a `char*` global
holding a string literal, a counter mutated across calls, `&g`/`*p`, and accumulation
into a global — plus the whole local/pointer/array/char/string/function corpus
unchanged. `.s1` scope note: uninitialised globals only (initialise in code); data-
initialised globals (`int g = 5;`) stay reference-only for now. `validate.py` gains a
globals section (232→241) and the demo workflow gains `adr g_`/`:g_` structural greps
plus behavioural runs. Next: general pointer arithmetic (scaling by pointee size —
the first real exercise of a widened type descriptor) and structs.

---

**Milestone 43 — stage 2: unary and bitwise operators (A5a).** The expression compiler
had `+ - * / % < > <= >= == !=`; this rounds it out with the operators real C conditions
and bit-twiddling lean on: **unary** `!` (logical not), `-` (negation), `~` (bitwise
not), and **binary** `&`, `|` (bitwise), `<<`, `>>` (shifts). Three things made it fit.
First, the unary prefixes are handled through the existing operator stack: in operand
position (the same `expect-operand` flag that tells unary `*`/`&` from binary) a `!`/`-`/`~`
pushes a marker at the highest precedence, and `emitapply` grew a pop-one/push-one path
for them (`u-` = `0-x`, `u~` = `-x-1`, `u!` = `(x==0)`, all branchless). Second, binary
`&` is disambiguated from address-of by that same position flag — `&` after a value is
bitwise-and, `&` where an operand is expected is address-of — so `p=&g` and `a&3` both
do the right thing. Third, and most usefully for the future, the compiler's old
hand-coded precedence ladder (a chain of `cmp`s that only knew four levels) was replaced
by a small **`prec` table**: one leaf routine mapping an operator byte to its C
precedence, with the shunting-yard loop reduced to "pop while `prec(top) >= prec(cur)`".
That means the fifteen operators now sit at genuinely correct C levels — `| < & < == <
relational < shift < additive < multiplicative < unary` — and adding another operator
later is a one-line table entry rather than a surgery on branch logic. The binary
bitwise/shift ops map straight onto stage0-as (`and`, `orr`, `lsl`, `lsr`); no stage0-as
change. Verified through the ladder: every operator in isolation, precedence
interactions (`2+3<<1` = 10 with shift below additive, `a&3|8` = 10 with `&` above `|`),
`!` applied to a comparison, unary minus on both factors of a product, and a
`s = s | 1<<i` loop that builds `0xFF` bit by bit — plus the full arithmetic / pointer /
array / char / string / global / function corpus unchanged. `validate.py` 241→260; the
demo workflow gains `and`/`lsl` structural greps and nine behavioural operator runs.
Next: the type-system work these operators were the warm-up for — general pointer
arithmetic (scaling `p + n` by the pointee size) and structs.

---

**Milestone 44 — stage 2: the `else` clause (A6a).** The compiler had `if` and `while`
but no `else`, which every real branch needs. The whole thing rides the existing
block-stack backpatch machinery — no new state, no stage0-as change. When a `{...}` block
closes, its record on the block stack says whether it was an `if`, a `while`, or (new)
an `else`. At an `if`-block's closing brace the compiler now peeks one token ahead: if it
sees `else`, it emits an unconditional branch to jump *over* the else-body (a forward
slot to be backpatched later), retargets the `if`-condition's false-branch to the
else-body's start rather than the end, and pushes an `else` record whose own closing
brace backpatches that skip branch. If there's no `else`, it un-consumes the peeked token
and behaves exactly as before. Because an else-block's close is just "backpatch one
forward branch", `else if` chains fall out for free — `else { if (…) {…} else {…} }`
nests to any depth with no special case, since each level is an ordinary block record.
`else` became the sixth keyword (a four-char match sharing the length-4 lexer arm with
`char`). Verified through the ladder: `if/else` returning different values, a two-arm
`max`, a three-way `sign` built from nested else, `else` inside a `while` body, and the
full arithmetic/pointer/array/global/operator/recursion corpus unchanged. `validate.py`
260→267; the demo workflow gains a `b @`/`b.eq @` structural check and five behavioural
runs. Next: the type-system work — general pointer arithmetic (scaling `p + n` by the
pointee size) and structs.

**Milestone 45 — stage 2: general pointer-arithmetic scaling (A7a).** Bare pointer
arithmetic did not scale by the pointee size: `int* p; p = p + 1;` added **1**, not
`sizeof(*p) = 8`, so `*(p+1)` read the wrong bytes. `a[i]` already scaled (m39), but
`p + n` / `p - n` / `p[n]`-via-a-pointer were untyped — every value on the expression
compiler's stack was a raw machine word with no notion of what it pointed at. This is
the first milestone that **threads a per-operand type through the expression compiler**,
the seed of the real type descriptor the floor's remaining type-work needs. Two parts:
(1) the symbol table's flags word gained an **`is_ptr` bit** (bit 2, beside is_char and
is_array), recorded at all **three** declaration sites (file-scope globals, function
parameters, and locals) — each previously discarded the `*` in `int* p`; now it sets the
bit. (2) `compile_expr` carries a **compile-time type stack** that mirrors the runtime
value stack: every operand push also pushes its *ptype* (0 = plain integer, else the
pointee size — 8 for `int*`, 1 for `char*`), computed from the flags for variables
(array/pointer decay), `&name`, and `&a[i]`, and 0 for numbers, literals, derefs,
subscript rvalues, and call results. When `emitapply` lowers `+`/`-` it pops the two
operand ptypes and, at **compile time**, decides the scaling: `ptr + int` / `int + ptr`
emits a shift of the integer operand by 3 (× 8) before the add when the pointee size is
8 (char pointers, size 1, emit nothing); `ptr - int` scales the same way; `ptr - ptr`
subtracts then divides the byte distance by the element size (a `>> 3`). The result
ptype propagates (pointer ± int stays a pointer; pointer − pointer becomes a plain int),
so chained arithmetic and `*(p + n)` land on the right element. Because the whole
mechanism is compile-time and keys off ptype, **plain integer arithmetic is byte-for-byte
unchanged** (both operands ptype 0 → no scaling). The one register hazard worth noting:
`emitapply` must hold the operand types in scratch registers that survive the emit calls
**without clobbering `x14`** (the store-offset a local declaration's initializer needs
after its expression is compiled) — the types live in `x4`/`x13` instead. The reference
(`stage2_ref_a7a.py`) models the identical type-stack design and is the new design of
record. Verified through the assembled ladder: `p + 2` / `p + 1` / `2 + p` (commuted) /
`p - 1`, `char*` walks (scale 1), `int*`/`char*` pointer differences, `&a[i] ± n`,
string-literal arithmetic, pointer parameters, a real `strlen` over a `char*`, and
globals — plus the full pre-existing corpus (including local decls whose initializers
contain operators, e.g. `int b = a + 2;` and `gcd`'s `int t = a % b;`) unchanged.
`validate.py` 267→286 (a new pointer-scaling section: structural `lsl x0 x0 x3` /
`lsr x0 x0 x3` presence-and-absence checks + behavioural exits + non-pointer
regressions); the demo workflow gains the same structural block and a twelve-program
behavioural sweep. Known limits kept honest: function return values are typed plain
(a function returning a pointer won't scale in later arithmetic), and `*(expr)` deref
(vs `*name`) is still outside the subset — both wait for the fuller type descriptor.
Next: `struct` — the gate to self-hosting.

---

**Milestone 46 — stage 2: `struct` (A8a).** The self-hosting gate. Stage 2 now
compiles `struct Tag { ... };` definitions, `sizeof(struct Tag)`, struct value and
pointer variables at all three scopes (locals, parameters, file-scope globals), and
`.` / `->` member access as both rvalue and lvalue — including multi-link chains
(`a.nx->nx->v`), `&member`, and the linked-list traversal that motivates the whole
feature. The layout is deliberately flat: **one 8-byte word per field** (int, char,
`T*`, or `struct Tag*`), offset `= field_index * 8`, so `sizeof` is `nfields * 8` and
a member address is `base + offset` — the same shape as an array subscript, reusing
the value-stack and address-emit machinery already in place. A **struct table** (tags
+ fields, each with name, offset, and a `stag` back-reference for pointer fields) lives
in stage-1 memory alongside the symbol table; **field names are looked up in that table
and never emitted as labels**, so the only labels an emitted program carries are still
`:func` names. `.` and `->` are treated identically at codegen — correctness comes from
the *base kind* (a value base takes `&name`; a pointer base is derefed first) plus
following pointer links along a chain — so `p.f` and `p->f` differ only in whether the
first `ldr x1 x1` is emitted. The shared `emit_maddr` walk leaves the field address in
`x1`; the rvalue path loads+pushes (word or `ldrb` for char fields) and pushes the
member ptype, while the lvalue path pushes the address, compiles the RHS, then pops
value+address and stores. Four register hazards paid for this: `prescan` saves the scan
cursor in `x7`, so `struct_findtag`/`field_find` had to grow `x7` to their spill sets
(they used it as the table base); `prescan`'s dormant `ps_struct` hook needed a real
definition (it had resolved to position 0 and jumped wild the moment `struct` became a
keyword); byte stores need the 3-operand `strb w0 x1 x2` form; and `emit_gdata` reuses
`x27` as its return-save, so a struct global's `stag` must be stored *before* the data
section is emitted. The reference (`stage2_ref_a8a.py`) models the identical struct
table + flat layout and is the design of record. Verified through the assembled ladder:
`sizeof` (folds, and `sizeof(struct P)/sizeof(int)`), value `.` get/set (int + char
fields, multiple locals, field-from-field), pointer `->` get/set, two- and three-link
chains (get and set), `&p.x`, struct-pointer parameters, a `while(p)` linked-list sum /
count / find-last, and struct value/pointer/char globals with member access and chains
— plus the full pre-existing corpus unchanged. `validate.py` grew a struct section
(structural offset/`sizeof`/`:g_`/no-field-labels checks + a behavioural exit sweep) and
the demo workflow gains the matching structural block, a 24-program behavioural sweep,
and an `sm_ok` gate. Known limits kept honest: nested struct-*value* fields, struct
arrays, struct-pointer arithmetic scaling, member-subscript (`s.arr[i]`), and pass-by-
value struct arguments are all outside the subset; and a pre-existing **stage-1**
lexical quirk (labels beginning with a register prefix, e.g. a function named `walk`,
are misread as `w`-registers) means self-hosting code must avoid such names — a stage-1
fix for a later rung, not a struct concern. Next: begin retargeting stage 2's own
sources onto this subset (self-hosting).

---

**Milestone 47 — stage 1: resolve register-lookalike label/function names (grammar,
not spelling).** A prerequisite for self-hosting, parked since m46. Stage 2 emits a
user function verbatim as `:name` / `bl name`, and stage 1's pass-2 tokenizer decided
whether a branch/`adr` operand was a register or a label by **sniffing its leading
characters** — anything starting with `x`/`w` was taken for a register. That is right
for `adr`'s real register operand but also caught ordinary names: `bl walk` was copied
as if `walk` were a `w`-register and then a (missing) label resolved to position 0, so
the output became `bl walk @000000`, which stage0-as rejects. Any function whose name
began with `w`/`x` failed to link. The first cut narrowed the sniff to "`x`/`w` followed
by a digit," but that is still a spelling heuristic and still has a hole — `w0helper`
(a legal C identifier) would break exactly the same way. **Real assemblers never guess
register-vs-identifier from spelling**; they use the instruction grammar (each operand
slot accepts either a register or a symbol, not both) plus an exact-match register set.
So m47 makes pass 2 **mnemonic-driven**: it already knows the mnemonic, so `b` / `bl` /
`b.cond` treat their single operand as *always a label* and resolve it; `adr xR name`
copies slot 1 *always as a register* (verbatim, whatever the token) and resolves slot 2
as the label; `br` / `blr` pass through untouched. The register peek is deleted
outright. Now a name is classified by **position**, so the full C identifier space
works: `walk`, `w0helper`, `x9foo`, even a label literally named `x0` resolve in a
branch's label slot, while `x0` in a register slot stays a register — the same spelling
handled correctly in both roles. The change is two sites in `author_stage1.py`: route
`adr` to a new `:p2adr` (copy-register-then-resolve-label) path, and reduce `:p2ref`
(the `b`/`bl`/`b.cond` path) to copy-mnemonic-then-resolve; `p2reg`/the peek are gone,
net one label (`p2adr` replaces `p2reg`). Regenerated to `stage1-as.s0` — not
hand-edited. Because the Python reference resolves operands structurally it never had
the bug (it was *more capable than reality* — the exact bench hazard the rules warn
about), so this was verified **through the real assembled stage 1**: `bl walk` /
`bl w0helper` / `bl x9foo` / `bl write` / `bl x0` all resolve to numeric refs and run;
`adr x0 w0lbl` keeps the register and resolves the register-lookalike label (→33);
`adr`-to-data (→42) and `blr` passthrough unchanged; and the whole stage-2 corpus,
rebuilt through the fixed stage 1, is unchanged. `validate.py` 310→327 (a
register-lookalike section: five function names, an `x0` label, `adr` register/label
split, and adr/blr regressions). The stage1-as demo gains check (5): resolve
`bl w0helper`, **byte-compare the assembled result against real `as`**, run to 42, and
confirm `adr x0 w0lbl` keeps its register — a hardware anchor, not just a bench model.
This clears the last cross-stage blocker before retargeting stage 2's own sources onto
its C subset; self-hosted code (and M2-Planet's source) may use any C function names.

---

**Milestone 48 — stage 2: function pointers (floor backbone A9).** The last purely
type-system rung before self-hosting: a variable can now hold the address of a function
and a call can go through it. Three mechanisms, ported from the a9a reference of record
into `stage2-mini-c.s1` as a direct assembly-text patch (`patch_a9a_direct.py`). **(1)
Declarator parsing** — `int (*f)(...)` is recognised at all three declaration sites
(local, parameter, file-scope global) plus the frame **prescan**: after the type, a `(`
whose next token is `*` opens a function-pointer declarator, so `f` is declared as a
**one-word pointer** (the param list is depth-skipped — only the name matters, a code
address is one machine word) and carries a new `is_fnptr` flag (symtab bit 3). **(2)
Function-name decay** — a bare function name used as a *value* (`fp = inc`, or `inc`
passed as an argument) emits `adr x0 <name>` and pushes it, exactly like a small
integer literal; the reference's `tpush(0)` is mirrored so the type stack stays
balanced. **(3) The call split** — `f(args)` stays a direct `bl f` when `f` is a known
function, but becomes a call *through the variable* when `f` is a function pointer:
`add x1 x10 <off>` (or `adr x1 g_<f>`) then `ldr x16 x1` then **`blr x16`** (IP0 is free
under the runtime convention; stage0-as has emitted `blr` since m24). The single-pass
compiler has no `funcs` table, so the discriminator is **flipped** off the symbol
tables: after `bl resolve`, a called name found as a frame local (`x7`) or a global
(`x0`) is a variable → `blr`; a name absent from every table is a function → direct
`bl`. The same not-a-variable test drives decay, so both mechanisms share one rule.
This works for every well-formed program in the subset and needs no forward
declarations. Verified **through the real assembled ladder** (bench models `blr`/`br`):
a local fnptr assigned then called (→42), a fnptr **parameter** with a decayed argument
(`apply(inc,41)`→42), a **zero-argument** call through a parameter (`callit(seven)`→7),
a **two-argument** call (→42), a **global** fnptr (`gp(99)`→100), a fnptr **reassigned
inside a loop** (dispatch add1/dbl →62), and a fnptr parameter whose callee mutates a
**global** across two zero-arg calls (→2). `validate.py` 801→846 (a function-pointer
section: decay/`ldr x16`/`blr` instruction forms, the `bl`-vs-`blr` coexistence in
`apply`, a `:g_gp` global-fnptr data label, and seven ladder exit-code runs); the whole
prior stage-2 corpus is unchanged. `.s1` 412→432 labels. The stage2-mini-c demo gains a
function-pointer program built and run on real `as` + QEMU. **A8→A9 done — the floor's
type system is complete.** (Forward pointer since revised — see §6: finish the floor
(heap + I/O), run a self-host *test*, then grow **stage 2** to M2-Planet's full subset so
**M2-Planet becomes stage 3**; the earlier "retarget stage 2's own sources into a stage-3
C compiler" plan is retired.)

---

**Milestone 49 — stage 2: fix `&member` address-of in the `.s1` (a8a regression, latent
since m46).** `&p.x` / `&p->f` (address of a struct member) was mis-compiled by the
compiler binary — a bug that had been present since the m46 struct rung but masked twice
over: the demo's behavioural gate false-passed (a `fail=1` trapped inside a `$(...)`
subshell never reached the parent, since fixed), and the bench interp tolerated the wild
address the bad code produced (an undefined-symbol load reads as 0, so `&p + 0` landed on
the right slot by luck). On real QEMU it **segfaulted**. Root cause: the address-of path
(`:ceuaddr`) peeked the token after the name for `[` (subscript) but **not** for `.` /
`->`, so `&p.x` emitted `&p` and let the member name `x` leak out as a stray primary —
which the m45 pointer-scaling and (post-m48) the function-name-decay path then turned into
`&p + <junk>·8` / `adr x0 x`. The reference (`stage2_ref_a9a.py`) always handled this
correctly (`&(name.chain)` → `push_member_addr`); only the `.s1` port had ever been
missing the branch. Fix: `:ceuaddr` now routes a trailing `.`/`->` into the existing
`emit_maddr` member-address walk (the same one `.`/`->` rvalue/lvalue already use), pushes
the resulting address (`str x1 x9`), and pushes the member's address ptype (`1` for a
non-pointer `char` field, else `8`). Verified through the real assembled ladder: `&p.x`
and `&p.y` (offset ≠ 0) read back correctly, `*(&p.x)=v` writes through, chained bases,
whole-struct `&p`, plain `&var`, `&a[i]`, function pointers, and the full arithmetic
corpus all unchanged; the emitted code for `&p.x` is now `add x1 x10 …; add x1 x1 <off>;
str x1 x9` with no `adr x0 x` and no scale. Reference unchanged (it was already correct);
this is a `.s1`-only codegen fix. **CI-confirmed GREEN on real `aarch64-linux-gnu-as`
+ qemu-user** (`stage2-mini-c-demo`, run #43): the checkpoint case
`struct P{int x;int y;};int main(){struct P p; p.x=8; int* q; q=&p.x; return *q;}`
exits **8** on real qemu (it previously segfaulted, exit 139), and all 152 behavioural
exit-code checks are OK with the honest gate (the `$(...)`-subshell false-pass, which had
masked this bug, is fixed). This closes the checkpoint — real qemu was the only witness,
since the bench interp doesn't fault on wild addresses. Still queued to stop the model
from being more capable than reality: a **structural guard** (assert `&p.x` emits a
member-offset `add` with no `adr x0 x` and no scale) and an **interp wild-address trap**.

---

**Milestone 50 — bench faithfulness: an interp OOB/near-null trap so the model faults
like hardware.** No compiler change; this closes the m49 lesson that *the bench must not
be more capable than reality*. m49's `&member` bug went unwitnessed by the bench because
a wild address just indexed the flat `img` and read 0 — only real qemu SIGSEGV'd. The
interp now traps any load/store outside the region a correct program can legitimately
touch: the valid data window is **`[NULLFLOOR, brk)`** (`NULLFLOOR = 16`; `brk` = the
program's current break). Emitted code + data labels live in `[0, code_end)` and the
runtime value stack / frames / heap live in the brk-grown block `[code_end, brk)`, so
everything a well-formed program addresses is inside that window; a near-null deref (the
`adr x0 <undef>` → `@0` shape) faults below `NULLFLOOR`, and a junk-scaled / past-the-break
address faults at/above `brk`. Bounding by the *dynamic* `brk` (not `len(img)`, which the
bench over-allocates) is what makes the model fault like hardware — and it self-adjusts to
whatever a program brk'd, so both emitted a.outs and the compiler's own 0x90000 working
set stay valid. The trap is default-on (`run(..., oob_trap=True)`); disabling it reproduces
the old silently-tolerant read-0 behaviour exactly. Proven both ways: a hand-built null
load and a far load both raise `OOBAccess`, while the whole existing corpus stays green
(no false positives), including the compiler self-runs and every emitted program.

On top of the trap, `validate.py` gained an **`&member` guard section** (`add x1 x1 <off>`
present, `str x1 x9` address-push present, **no `adr x0 x`** leaked primary, **no scale**
on the address-of path) plus **five behavioural witnesses that now genuinely fault** if the
m49 shape regresses: `&p.x` (offset 0 → 8), `&p.y` (nonzero offset → 7), a write *through*
`&p.x` (→ 42), a **char** member `&c.a` (ptype 1 → 65), and `&(r->y)` (→ 9). The
`stage2-mini-c-demo` gained the matching **structural greps** (`amp.s`: field-offset add +
address push present, `adr x0 x` + `lsl` absent) and **four more behavioural `try` runs on
real `as`+QEMU** (7 / 42 / 65 / 9) — the class was effectively untested on hardware before
m49 because it segfaulted. `validate.py` 342 → **351**. Housekeeping: the harmless
**duplicate `:spushx1` template** in `stage2-mini-c.s1` (two byte-identical definitions) is
**de-duped** to one; the compiler binary's byte positions shift but its emitted output is
**byte-identical** across the corpus (verified by fingerprint), and all three
`adr x9 spushx1` references resolve to the surviving definition. No stage-0/1 change, no
reference change (`stage2_ref_a9a.py` was already correct). With the floor's type system
complete and the bench now honest about wild addresses, the next rung is the remaining
floor: a **`calloc`/`free` heap** and **file I/O** so a compiled program can run as a
compiler (see §6).

### m54 (A13) — the single-pass `@`-target accounting bug: member stores emitted a blank line

A **latent codegen state-leak** in the original `.s1`, unrelated to any one rung, that
made a function's compiled meaning depend on **what was defined before it**.

stage 2 is single-pass, so `if`/`while` targets are **absolute** `@<byte-pos>` values the
compiler computes itself from **`x17`**, its count of emitted instructions. `emitstr`
bumps `x17` once per `\n`, so the whole scheme rests on one invariant: *every emitted line
assembles to exactly 4 bytes.* The member-store templates **`smst2`/`smst2b` carried a
leading `\n`**. They are emitted right after `compile_expr`, which already ends at a fresh
line — so every `p->f = v;` emitted a **blank line**: `+1` to `x17`, **0 bytes** assembled.
Because `x17` is **monotonic across the whole program**, the drift never hurts the function
that caused it; it corrupts the `@`-targets of every function emitted **afterwards**.

An append-shaped function (`calloc` + three member stores + an if/else linking two global
struct pointers) drifted **12 bytes = 3 instructions**, so the *next* function's branch
targets landed three instructions past their intent. The symptoms looked unrelated to the
cause and were maddeningly order-dependent: the victim silently returned `0`/garbage, or —
when the mis-aimed target skipped a loop bound wrapped around an allocating call — **never
terminated**. That last shape is why a program combining a recursive emit path, a separator
predicate, and an allocating builder ran away: each half was green alone, and only the
combination put enough emitted code after `append` for the drift to land somewhere fatal.

**Fixed** by dropping the leading `\n` from both templates — which is also the convention
the working array-store path already used (`emitsubstore` → `spopval2` starts mid-line
precisely because `compile_expr` left the cursor at a fresh line). One-line class of fix,
no design change, no reference change. Verified: emitted code-region drift is now **0**
across a 24-construct corpus (member/chained/byte stores, arrays, globals, deref, if,
if/else, while, nested while, recursion, calls, arithmetic, comparisons, unary, bitops,
`calloc`); victims of every control-flow shape return the same value in **all definition
orders**; and the three-way emit+predicate+builder program now returns correct counts
instead of running away. Guarded so the class cannot return silently: `validate.py` gained
an **x17 emit-accounting section** (no blank line in the code region, `x17` == true
instruction count, order-independence witnesses, and the three-way shape), 412 → **429**,
and `stage2-mini-c-demo` gained a matching **`emit_ok`** section wired into the pass gate,
with `timeout` bounding the runaway case so a regression fails fast instead of hanging CI.
Confirmed the guards actually catch it: reverting the one-line fix turns 12 of them red,
including the nested-while victim, which reports `<runaway>`.

**Not** the separately-tracked frame-sizing bug below — that one is still open and
independent.

### m55 (A14) — four front-end gaps: comments, bare blocks, `struct*` returns, bounded global data

Four independent **front-end** holes, each of which presented as a **hang or a wild
address** rather than a wrong answer — which is exactly why they were mistaken for
codegen bugs.

**Comments** — the tokenizer's whitespace loop had no comment rule, so `/` fell through
to the operator path and the comment body was lexed as source. Added a `/`-peek in
`nt_ws` dispatching to a `//`-to-newline skip and a `/* */` skip, restoring the char
register before falling through so a lone `/` still lexes as division.

**Bare blocks** — `if`/`while` push a record onto the block stack; a bare `{` pushed
none, so its `}` popped the *enclosing* record, or ended the function early. Because
`compile_expr` resets the cursor to the token start on unrecognised punctuation, the
`{` after `if`/`while` is always consumed by `add x6 x6 1` — so **any `{` reaching
`stmtloop` is a bare block**, unambiguously. Added a plain-block record (kind 3) popped
by `dclose_plain`, emitting nothing. The block delimits *parsing*, not *scope*: locals
declared inside keep their frame slot for the rest of the function.

**`struct*` return types** — `struct T *f()` was routed to the **global**-struct path,
which declares a global then skips to the first `;` — which lands *inside the body*,
resuming top-level parsing mid-function. Added the same `(`-peek the `int` path already
uses, branching to the function path.

**Global data is bounded** — each global array byte emits `.byte 0\n` (8 chars) into the
fixed data region; ~24 KB of globals reached brk, having silently clobbered the save area
en route. The emission loop now stops with a diagnostic and exit `2`. This **bounds** the
failure rather than lifting the limit — `.byte`/`.ascii` are the only directives
`stage0-as` has, so compact zero-fill would be a lower-stage change.

None of the four adds an emitted line, so the **A13 `x17` invariant is untouched** —
re-verified per new construct (0 blanks, 0 drift). `validate.py` 429 → **462**;
`stage2-mini-c-demo` gained a matching **`fe_ok`** section wired into the pass gate, all
cases `timeout`-bounded so a regression fails fast instead of hanging CI.

Two notes for whoever picks this up. **Newly surfaced:** member access directly on a call
result (`id(n)->v`) returns garbage, while `q=id(n); q->v` is correct — a pre-existing
expression-parser gap that was unreachable while `struct*` returns did not work at all.
**And the frame-sizing rung did not reproduce:** three struct-pointer locals with a
`calloc` build loop, and the documented 5-locals-in-`main` + chained `mk()` shape, both
now return correct values on the bench. That suggests it may have been a symptom of the
A13 drift rather than a separate bug — but the bench is a model, so treat this as
*unconfirmed* until CI says otherwise, and do not cross the rung off on bench evidence.

### m56 (A15) — the self-host canary: a compiler-shaped program, and a fixpoint

The **proof-of-pivot** from `TARGET-SUBSET.md` §(a). With heap (m51) and I/O (m53)
landed, the question worth answering *before* investing in anything else was the
scariest unknown on the road to M2-Planet: **does a compiler-shaped program actually
survive this ladder?** Not "does a rung work" — the rungs each have their own guard —
but does a program with the *shape* of a compiler front end, exercising all of them at
once, compile and run correctly end to end.

`spikes/stage2-mini-c/selfhost/canon.c` is that program: a **lexical canonicalizer**.
It reads a file, tokenizes it into a **heap-allocated linked list of token records**
(`struct Tok{off,len,nx}` — M2-Planet's own token-list data model) driven by a
**function-pointer classifier** forwarded through two scanner helpers, walks that list
with **recursion one frame deep per token**, and writes a file. Structs, `calloc`,
`blr`, nested control flow, deep recursion and file I/O, in one program, through
`canon.c | stage2 | stage1 | stage0-as | elf`.

**The fixpoint.** Canonical form is one maximal run of non-separator bytes per line, so
the transform is **idempotent**: `canon(canon(x)) == canon(x)`. That gives the
"byte-compared across a second generation" property the spec asks for without needing a
full toy compiler — the program is run over **its own output** and must reproduce it
exactly. It is also run over **`canon.c` itself**, the very text it was compiled from:
3271 bytes in, 569 tokens out, stable across a second generation. A 500-token case
pins a **depth-500** recursive walk.

Two things it cost, neither a bug:

- **`main` returns the output length, but an exit status is one byte** — a 2833-byte
  output exits `17`. The harness compares against `len & 0xFF`, and the CI section
  judges every run on its **output file**, never its exit status (a *successful* run of
  `canon` exits **nonzero**, so each invocation is `set +e`-wrapped).
- **Buffers are `calloc`'d, not global arrays.** m55 *bounded* global data rather than
  lifting it, so `IN`/`OUT` are heap blocks held in global `char*` pointers. Input is
  capped at the 8192-byte buffer. `append` also binds `mk_tok`'s result to a local
  before `->`, avoiding the call-result member access m55 flagged as still open.

`validate.py` 462 → **471**. `stage2-mini-c-demo` gained a **`selfhost_ok`** section
wired into the pass gate: it builds `canon` through the real ladder, checks the
tokenization, both fixpoints, the 500-token scale case, and **structurally** greps the
emitted assembly for `bl calloc` / `blr` / `bl open` / `:emit_list` so the canary cannot
silently degrade into something trivial. Every stage is `timeout`-bounded, so a
regression fails fast rather than hanging the runner.

**This is a canary, not a rung — it is not kept and nothing depends on it.** Per §(b)
the plan does *not* pivot to a stage-3-in-C: stage 2 keeps growing in asm until it
accepts M2-Planet's entire source subset. What m56 buys is the knowledge that when that
day comes, the ladder underneath will hold.
---

### m57 (A16) — short-circuit `&&`/`||`, hex literals, and `^`

The first three rungs of the post-canary push from `TARGET-SUBSET.md` §6(b): keep
growing stage 2 in asm until it accepts M2-Planet's whole subset. These three were
picked together because they are independent and the second and third are small.

**`&&`/`||` are not ordinary binary operators**, and that is the whole difficulty. A
shunting-yard emits code when it **pops** an operator — by which point both operands
have already been evaluated onto the value stack, which is exactly too late to skip
the right one. Emitting `and`/`orr` of both sides would produce the right *answer* for
the cases that don't fault and a **SIGSEGV** for the cases that do: M2-Planet guards
its null derefs this way (`NULL != a && a->s`), so the right operand is not merely
wasteful to evaluate, it is unsafe.

The fix is to emit at **push** time instead. `cewhile` has already applied every
higher-precedence pending operator by the time control reaches `cepushop`, so the left
operand's value is final exactly there. The prologue pops it, pushes a provisional
result (`0` for `&&`, `1` for `||`), and emits `b.eq`/`b.ne @<placeholder>`; if the
branch is taken the provisional value *is* the answer, and if it is not, the
provisional is discarded and the right operand is evaluated normally. `emitapply` then
normalises the right operand to `0`/`1` and backpatches the placeholder to the
instruction after itself.

**The patch slot is keyed by the operator's opstack index**, not held on a separate
stack. That is the detail that makes re-entrancy free: opstack slots are unique per
nesting level, and `emitapply` is entered with `x25` already decremented to the
operator's own slot, so `f(a&&b, c||d)`, `a && g(c||d)` and arbitrarily nested
short-circuits all resolve to distinct slots with no save/restore and no LIFO
reasoning. The array lives in the previously-unused 16 KB gap at `x19+0x54000`, sized
to one word per opstack entry.

`b.ne @<pos>` turned out to **already exist** in stage0-as (`b / b.eq/ne/lt/ge @<pos>`),
so `||` is the exact mirror of `&&` and no stage-0 change was needed for either.

**Hex literals** are one lexer rule (a `0x`/`0X` prefix peek plus a hex-digit scan in
`nt_class`) and one value rule in `parseval`. `parsenum` was a duplicate decimal loop
and now simply calls `parseval`, so array sizes accept hex as a side effect and the
two parsers can no longer drift apart. Literals `>= 2^16` still go through the A11
`movz`+`movk` halfword path unchanged.

**`^`** is the one that needed a stage-0 rung, and it is the smallest possible one —
the same shape as the `udiv` leaf (m36). EOR is the logical shifted-register sibling of
AND and ORR, differing only in `opc`, so the encoder is `h_and` with `0x8A00` replaced
by `0xCA00`, and dispatch is two lines because no mnemonic previously started with `e`.
Mirrored in `s0as.py` and `interp.py` by folding `eor` into the existing `orr`/`and`
cases rather than bolting on a fourth. Precedence now runs
`|| < && < | < ^ < & < == < relational < shift < + < *`.

Neither `&&`/`||` nor `^` adds an emitted line that is not exactly 4 bytes, so the A13
`x17` invariant is untouched — and because that invariant's failure mode is silent and
*deferred* (drift corrupts the `@`-targets of every function emitted **afterwards**),
it is guarded directly for each new construct rather than inferred: zero blank emitted
lines, `x17` equal to the true instruction count, and victim functions defined after a
short-circuiting function still returning what they return alone.

`validate.py` 471 → **549**. The new guards are deliberately behavioural where the
feature is behavioural — a `bump()` side effect that must **not** happen, and a null
deref that must **not** be reached (a real witness since m50, when the interp began
faulting on wild addresses like hardware). `stage2-mini-c-demo` gained an `sc_ok`
section and an `eor_ok` byte-check against real `as`, both wired into the pass gate;
every stage is `timeout`-bounded, since a mis-aimed backpatch loops forever rather
than returning something wrong.

**Still open from the §6(b) list:** string/char escapes (~995 uses — the largest single
count), `for`, `break`/`continue`, `do {} while`, `unsigned` as a word-typed keyword,
`enum`, and the preprocessor (escapes landed in m61, the preprocessor in m62,
`do {} while` + `break`/`continue` in m64, `for` in m65 — the loop family is
complete — and `enum` in m66, which is what actually made the m62 directive-stripping
sound, since `NULL`/`TRUE`/`FALSE`/`EOF` were enum constants all along) — plus the gaps the m58 census surfaced (below), of which
**forward prototypes landed in m59** and **braceless bodies in m60**.
---

### m58 (A17) — `goto` + labels, and a re-census of the target subset

`goto L;` and `L:` label definitions, function-scoped. The rung is small because of a
decision two milestones back: since **m32 stage 1 is a two-pass numeric resolver**, an
emitted label can be *named* and stage 1 will resolve it — including a **forward**
reference. So a `goto` needs no backpatching in this single-pass compiler at all, unlike
`if`/`while` (m29), which must compute absolute `@<pos>` targets because their forward
target is not a name. A label emits `:__Lg<fnidx>_<name>`; a `goto` emits
`b __Lg<fnidx>_<name>`; stage 1 does the rest.

**Labels are function-scoped**, via a per-function index kept in a new save-area slot
(`0x7F000+48`), bumped once per function definition and read by both the label and the
goto emitter — so the two agree without a table, which is what makes it work in one pass.
Two functions may each define `lp:`. Worth recording: **M2-Planet's own compiler does
not do this** — it emits the bare source name into one flat assembler namespace (hence
the `/* because of how M2-Planet treats labels */` comment in its switch code), and
relies on every label in its source being globally unique. Ours is stricter than the
target requires, at no cost.

The load-bearing risk was the **A13 `x17` invariant**, not the codegen. A label line
assembles to **0 bytes**, so it must bump neither `x17` nor the byte position; if it did,
the `@`-targets of every function emitted *afterwards* would drift — the silent,
deferred, order-dependent corruption of m54. The label's trailing newline is therefore
written with a raw `strb`, never through `emitstr` (which counts `\n`), while the goto's
newline *does* go through `emitstr` because a `b` line is a real 4-byte instruction.
Guarded **exactly**: the same program with and without a label definition must emit the
**identical** `@`-target. That check matters more than it looks — when the bug was
deliberately re-injected, "no blank line" and "targets 4-aligned and in range" both still
passed (the drifted target is still aligned and still in range), and only the exact
witness plus the behavioural runs went red. Nine checks turn red on the injected bug,
including the order-independence witness. `validate.py` 549 → **569**;
`stage2-mini-c-demo` gained a `goto_ok` section wired into the pass gate, every stage
`timeout`-bounded since a mis-aimed branch loops forever rather than returning wrong.

Verified through the real assembled ladder on the shapes M2-Planet actually uses:
backward jump to a label at body top (its `reset:` loop idiom), forward jump near the end
(`goto exit_success;`), jumps out of nested `if`/`if`/`while`, out of a `while`, from an
`else` arm, two labels in one function, a label before a declaration, and the same label
name in two functions. The whole prior corpus is unchanged, and a program with no `goto`
emits no `__Lg` at all.

**Re-census of the target subset (see `TARGET-SUBSET.md` §3/§6b).** Checking goto against
the pinned source meant re-deriving the counts, and the doc was wrong in several places —
its stripper mis-handles the `/*` and `;` *inside M2-Planet's own string literals*, which
silently drops `cc_core.c`. Corrected: **13 gotos / 8 labels** (not 8/4), **7 `do {} while`**
(not 2). More importantly, four gaps were **missing from the list entirely**, all
confirmed against the current compiler rather than read off the source:

- **Braceless statement bodies — ~370 sites.** `if(cond) return x;` with no braces.
  Compiles to nonsense today. Breakdown: 199 `return …;`, 120 call/assign, 34 bare
  `else`, 11 `break;`, 2 `goto`. Zero of them nest, so there is no dangling-`else`
  problem — the controlled statement always ends at the first `;` at paren depth 0.
- **Forward prototypes — 73 sites.** `int f(int, int);` at file scope. **Hangs the
  compiler**: `funcloop` commits to a definition on seeing `(` and never expects `;`.
  This is the single biggest blocker — M2-Planet declares nearly every function ahead
  of use, so it affects all eight self-host files.
- **`break` (13) / `continue` (2).** Silently miscompiled today (parsed as a bare
  identifier expression and discarded), which is the dangerous failure mode.
- **`argc`/`argv` — 29 uses.** `int main(int argc, char** argv)`. This is a *runtime*
  gap, not a parser one: `smainpre` does `bl main` with an empty value stack, so
  `_start` needs to read the kernel's initial stack and push them.

### m59 (A18) — forward prototypes

`int f(int, int);` at file scope. This was the **largest blocker on real M2-Planet code**
and the one that failed worst: `funcloop` committed to a *definition* the instant it saw
`(` after the name, so the `;` where `{` should be derailed top-level parsing and the
compiler **hung**. M2-Planet declares nearly every function ahead of use — 73 sites
across all eight self-host files — so nothing of substance parsed before this.

The fix is a paren-matching lookahead at the two places that peek for `(`: the `int`/`char`
path (`fl_pkc`) and the `struct*`-return path added in m55 (`flg_sfpk`). Both now route
through `fl_pchk`, which scans from `(` to its partner, skips whitespace, and branches on
`;` (prototype — skip past it and resume) versus anything else (definition). Raw character
scanning, not the tokenizer, matching the existing peeks around it.

**A prototype declares nothing and emits nothing**, which is correct here rather than a
shortcut: since m48 the `bl`-vs-`blr` split is read off the *symbol tables* — a called
name found in no table is a function, so it gets a direct `bl` — meaning a function was
never required to be declared before being called. Two things fall out for free:
**unnamed parameters** (`int global_static_array(struct type*, char*);`) work because the
declarator is never parsed at all, so that separate entry on the open list is now moot;
and the emitted output is **byte-identical** with and without any number of prototypes,
which is the strongest possible form of the A13 `x17` guarantee — no drift is even
representable. Both are guarded (`cmp -s` of the two emissions; a prototype-only program's
only label is `:main`).

Verified through the real assembled ladder on all eight shapes that previously hung: named
and unnamed parameters, a `struct*` return type, `void`, prototype + recursion, a prototype
enabling mutual recursion, a prototype spanning several lines, and the no-prototype
regression. `validate.py` 569 → **579**; `stage2-mini-c-demo` gained a `proto_ok` section
wired into the pass gate, timeout-bounded since the old failure mode was a hang.

---

### m60 (A19) — braceless statement bodies

`if(cond) return x;` with no braces — ~370 sites in M2-Planet's self-host (199 `return`,
120 call/assign, 34 bare `else`, 11 `break`, 2 `goto`), silently miscompiled until now.
Two parts, and the first was the one that mattered.

**(1) The condition had to be bounded.** `compile_expr` never stopped at the condition's
closing `)` — it relied on the body's `{` to terminate it, since `{` is punctuation it
does not recognise. Worse, `ce_kw` treats **any** keyword in operand position as `sizeof`.
So `if(a) return 5;` swallowed `return` into the condition and mangled it, and
`if(a) f(b);` emitted the *call* as part of the condition and then tested **its** result.
The fix keeps `compile_expr` untouched: scan to the matching `)` and temporarily lower
**`x21`, the input length**, so the tokenizer reports EOF exactly there — a case
`compile_expr` already terminates on cleanly (`cmp x20 0 / b.eq ceflush`). `x21` is saved
and restored around the call on the `x28` spill stack. The scanner skips char and string
literals exactly as the lexer does, so `if(c=='(')` cannot unbalance it — deliberately
mirroring the lexer's current (escape-free) behaviour rather than being more capable than
it, so both get fixed together in the escapes rung.

**(2) A braceless body closes after one statement.** Block records now carry **kind+4**
for a braceless variant (4=if, 5=while, 6=else), and every statement-completion exit —
16 of them — routes through a new **`stmtend`**, which pops and closes while the top
record is braceless. The close routines re-enter `stmtend` rather than `stmtloop`, so
`if(a) if(b) x;` unwinds through both levels, and a **dangling `else` binds to the inner
`if`** (verified: `if(a) if(b) return 1; else return 2;` with `a=1,b=0` returns 2). The
`{`-consumption in `doif`/`dowhile`/the `else` arm became a shared `peekbrace` helper:
`{` present → consume it and push the braced kind; absent → push the braceless kind and
leave the cursor alone. A stray `;` at statement level now also completes a statement,
which makes C's empty statement (`if(a) ;`) terminate instead of hanging.

**This is a pure superset**, and that is checked rather than asserted: a corpus of braced
programs (if, while, else, recursion, structs, arrays, goto, short-circuit) emits
**byte-identical** output to the pre-rung compiler. The A13 `x17` invariant is re-verified
per new construct (0 blank lines, 0 drift for braceless if/while/else/nested).

The payoff witness is **M2-Planet-shaped code exercising m58+m59+m60 at once** —
forward prototypes, a `goto` loop, braceless `if` bodies, `char*` parameters, subscripts,
string literals, calls inside conditions, and unary `!`. `in_set` and `match` are the
shape of M2-Planet's own helpers, with `match` written as its goto-loop idiom; the program
returns 42 only if every assertion holds. It does. `validate.py` 579 → **611**;
`stage2-mini-c-demo` gained a `bl_ok` section (19 behavioural runs + structural checks +
the M2-shaped program) wired into the pass gate, timeout-bounded throughout.

---

### m61 (A20) — string/char escapes

`\n \t \r \\ \" \' \0` decoded in char literals, string literals and the data-section
emitter. ~993 sites in M2-Planet's self-host — the largest single count, and the one gap
**no source rewrite could paper over**: the escapes live inside the assembly text
M2-Planet *emits* (`"\n# Core program\n"`), so a lexer storing `\n` as two bytes yields a
compiler whose **output** is textually wrong everywhere. Distribution: `\n` 964, `\\` 10,
`\'` 7, `\"` 7, `\t` 4, `\r` 1; `\0` is implemented too (zero uses, but free).

Three sites had to agree: the char-literal lexer (it assumed a 3-character `'X'`), the
string scanner (it stopped at the first `"`, **including an escaped one**), and the
data-section emitter (it copied source bytes verbatim). The A19 condition scanner needed
it as well, since it skips literals to keep its paren count honest. A shared `escval`
table decodes; anything unrecognised yields the character itself, which is exactly right
for `\\ \" \'`. Escape-free programs emit **byte-identical** output. The load-bearing
guard is not structural — it `cmp`s the actual **bytes reaching stdout** against a
printf-built expectation, with `od -c` on mismatch.

### m62 (A21) — preprocessor directives

Nine lines, and the reason is the interesting part. Scoped by reading how M2-Planet's
self-host is *actually built* rather than by implementing C's preprocessor: its own
`hello-aarch64.sh` passes every translation unit as an ordered **`-f` list** and runs with
`--bootstrap-mode`, in which the entire preprocessor is `remove_preprocessor_directives`
— a token starting with `#` discards the rest of the line. No include expansion, no macro
substitution, no conditionals.

That works because the `-f` list makes `#include` redundant, and because there are **no
object-like `#define` constants** in the source; the only `#define` among its 23
directives is the `CC_H` include guard. Our equivalent of the `-f` list is concatenated
stdin, which already worked. `#` is a directive only at **token position** — a rule that
fired inside string literals would eat M2-Planet's own `"\n# Core program\n"`, so that is
guarded explicitly.

**What this uncovered:** `NULL` (287 uses), `TRUE`, `FALSE`, `EOF`, `stdin/stdout/stderr`
and `EXIT_SUCCESS/FAILURE` are **`enum` constants** in `M2libc/bootstrap.c` — which is
*why* stripping every directive works. So those 287 `NULL`s never depended on the
preprocessor at all; they depend on `enum`, which we do not have. `enum` is now the
largest remaining language gap.

---

### m63 (A22) — backpatching retired; label-based control flow, streaming output, real capacity

A capacity complaint ("don't hard-code artificial limits") turned into a design deletion,
because the constraint that justified the design had already been removed.

**The finding.** `TARGET-SUBSET.md` floor item 2 said why backpatching exists: *"the whole
chain caps an assembled program at ~128 distinct labels (stage0-as's 128-entry symtab),
so stage 2 must stop emitting a label per variable/branch."* Then **m32** made stage 1 a
two-pass numeric resolver — *"the number of labels a program may use is bounded only by
memory... the symtab is never in the path."* The backpatcher outlived its reason by six
milestones and nobody went back. m58's `goto` had already proved the replacement in CI.

**The change.** `if`/`while`/`else` and `&&`/`||` now emit named labels
(`:__L<id>` / `b.eq __L<id>`) exactly as `goto` does. Consequences, all deletions:

- **Streaming output.** No backward seeks, so `emitstr` flushes to stdout once the buffer
  is half full. The 256 KB output buffer stops being a ceiling: a 1200-block program emits
  **530 KB**. The flush test is stateless — `emitstrlit`/`emit_gdata` point `x22` at the
  data buffer, so "am I streaming?" is simply "is `x22` the code buffer?".
- **`bl pos6` went from 10 call sites to 1**, and that one writes *forward*.
- **The A13 `x17` invariant is gone**, and with it the entire **m54 bug class** — a 0-byte
  emitted line desynchronising the counter and silently corrupting every function emitted
  *afterwards*. Structurally impossible now: there are no absolute positions to drift.
- The `&&`/`||` patch array holds label ids instead of buffer offsets, keyed by the same
  opstack slot, so m57's re-entrancy property survives untouched.

**Capacity, properly.** The `@<pos>` field widened 6 → 9 digits — a **wire format**, not a
buffer, shared by all three stages, which would have *silently truncated* past 999,999
bytes (M2 lands at 0.7–1.4 MB). `stage0-as`'s `parse_dec` needed no change. A position
≥ 10⁹ now writes a diagnostic and exits 2; proved by temporarily lowering the threshold.
**stage 1** moved from `brk` to one 256 MB lazily-paged `mmap` (address-space reservation,
not memory — the same call the m51 calloc runtime already proves under qemu) with region
bases **derived from the actual input length**, not fixed offsets. `stage0-as` and `elf`
got 64 MiB demand-zero reserves. **Every remaining bound now fails loudly** — diagnostic
plus exit 2 — instead of truncating.

**Guards changed shape, not strength.** Backpatching gave label integrity *by
construction*; labels do not. So it is now checked directly: every referenced label
defined exactly once, every definition referenced, across if/while/else/short-circuit and
goto programs. Eight `validate.py` assertions and a dozen CI greps that asserted the old
numeric design were **rewritten, not relaxed**. `validate.py` 644 → **656**.

**Three CI failures, all mine, all instructive.** (1) `.ascii` placed in `.bss`, which is
NOBITS and cannot hold initialised data. (2) After raising `INBUF_SZ` to 64 MiB, `symtab`
and `outword` — which followed the reserve in `.bss` — went out of **`adr`'s ±1 MiB
reach**; the large `.space` must be *last*. (3) The workflow keeps a parallel copy of many
`validate.py` structural checks, so updating one did not update the other; the job also
*aborted* rather than reporting, because `bt=$(grep 'b.eq @...')` matching nothing fails
under `set -e`.

The root cause of (1) and (2) is that **the bench models our own assembler, not GNU `as`**
— `s0as.py` covers stage0-as's language, and there is no aarch64 assembler on the dev box.
Every `.s` edit was unguarded until CI. Hence **`spikes/bench/lint_asm.py`**, wired in as
`validate.py`'s first check: it flags initialised data in NOBITS sections, `adr`-referenced
symbols beyond 1 MiB (resolving `.equ` and running section offsets), and MOV immediates
that are not a shifted imm16. It was verified to fail on both broken files. For (3) the fix
was procedural: all 24 workflow greps are now dry-run against **real compiler output**
before pushing.

---

### m64 (A24) — `do {} while`, `break`, `continue`

Three statements, one rung, because they are one mechanism. A do-loop emits the **same
label pair a while-loop does** — top defined at the `do`, exit referenced by the
condition's `b.eq` and defined after the back branch — so `break` is a single routine
serving both:

```
:__L<top>            <- emitted at `do`
  <body>
[:__L<cont>]         <- only if a `continue` was seen
  <cond>; b.eq __L<exit>
  b __L<top>
:__L<exit>
```

The alternative for `do` was one label and a `b.ne` straight back to the top — tighter
emitted code, and wrong for this ladder: it has no exit label, so `break` would have
rewritten the rung a milestone later. Shape was chosen for what comes next, not for the
instruction count.

**The block record forced the rest.** `break`/`continue` scan the block stack **downward**
for the nearest loop record, skipping `if`/`else`/plain — which is the entire point, since
**11 of M2-Planet's 14 breaks sit in a braceless `if` body inside a loop**. The scan masks
the braceless flag off the kind, so `while(c) break;` finds its loop too. But `do` needed a
kind value, and 0–3 were taken (`if`/`while`/`else`/plain) with **+4 meaning braceless** —
and `stmtend` reads `kind >= 4` as braceless, so a braced `do` numbered 4 would have been
closed by the first `;` **inside its own body**. So the braceless flag moved from bit 2 to
bit 3 and the record grew **12 → 16 bytes**, the fourth slot carrying the continue target.
Mechanical, but it perturbs every construct sharing that stack, which is what the
byte-identity guard below is for.

**Slot c holds the continue label id PLUS ONE**, 0 meaning none allocated. The +1 is
load-bearing: `newlbl`'s first id is **0**, so a bare 0 could not be told apart from
`__L0`. A `do` allocates that label **lazily**, on the first `continue` inside it, because
C says continue-in-`do` jumps to the **condition** rather than the body top — a third label
that most do-loops, and all 7 of M2-Planet's, never need. Eager allocation would emit a
definition nothing references, which is exactly what m63's label-integrity rule forbids. A
`while` needs no laziness: its continue target *is* its top label. (Both of M2-Planet's
two `continue`s are in `while` loops; zero in do-loops. The do path is ours, not the
target's.)

**`break`/`continue` outside any loop now fails loudly** — diagnostic plus exit 2. Before
this rung they lexed as plain identifiers and were silently discarded, which is what m58's
census flagged as the dangerous failure mode.

**One real bug, found by the loop never terminating.** The first draft compiled the
condition with the cursor still sitting after the `}`, so `compile_expr` swallowed the
`while` keyword itself — and since m60, `ce_kw` treats *any* keyword in operand position as
`sizeof`. Every do-loop spun forever. `dclose_do` now consumes the `while` token first and
re-reads its labels from the record afterwards rather than trusting registers across the
call. Worth recording because the symptom (hang) was three steps from the cause (a
tokenizer rule about `sizeof`).

**Verified** through the real assembled ladder on the shapes M2-Planet actually writes: the
`while` on the line *after* the `}` (4 of its 7 sites), `} while(escape || (c != frequent));`,
`while((32 != c) && (9 != c) && ('\n' != c));`, and `if(match(…)) break;` inside a
`do{}while` (cc_macro.c:912). Conditions containing `')'`, `'}'` or `'\n'` **inside char
literals** are covered specifically, since `scancond` bounds the condition by counting
parens and an unskipped literal would truncate it — cc_core.c:3165 and :2203 test against
`'}'`. Braceless `do` bodies work too; M2-Planet has none, but the widened record made them
nearly free, the same call m58 made on function-scoped labels.

**The guard that matters** is not the new construct but the old ones: a corpus using none of
`do`/`break`/`continue` emits **byte-identical** output to the pre-rung compiler
(if/else/while/braceless/nested/recursion/arrays/goto). CI diffs against `HEAD~1` directly
and skips once HEAD~1 already has the rung; `validate.py` pins the behavioural half plus a
byte-level **order-independence** witness — appending a do-using function must not change
one byte of what precedes it, which is the m54 failure class and the specific way a
block-record change goes wrong. `validate.py` 680 → **725**; `stage2-mini-c-demo` gained a
`dw_ok` section wired into the pass gate, with a structural witness that **discriminates
`do` from `while`**: the two emit the same instructions and the same label pair, differing
only in order, so the check is that the body precedes the test in one and follows it in the
other. It was verified to go red when handed a while-shaped emission.

**Not unlocked by this rung alone:** `cc_macro.c`'s do-loop is `while(TRUE)`, which also
needs `enum` — landed separately in m66. `for` (4 uses) was
deliberately left out — its step clause appears before the body but must be emitted after
it, and m63 deleted backpatching, so the single-pass answer is to stash the step's *source
span* in the record and re-lex it at close time. That is a different mechanism, it widens
the record again, and it sits on top of this rung's loop stack.


---

### m65 (A25) — `for`

The step clause appears **before** the body in the source but must run **after** it, and
m63 deleted backpatching — so the obvious single-pass answer is to stash the step's source
span in the block record and re-lex it at close time. This rung takes the other option:
**emit everything in source order and jump over the step on the way in.**

```
    init
:__L<top>
    cond; b.eq __L<exit>
    b __L<body>
:__L<step>          <- continue target
    step
    b __L<top>
:__L<body>
    body
    b __L<step>     <- emitted at the closing brace
:__L<exit>
```

Two extra unconditional branches per iteration, and **no replay machinery at all**. Every
label is referenced by construction, so unlike `do`'s continue label none of them needs
lazy allocation. Better still, the **close is `dclose_while` unchanged** — a for record is
just `[a=step, b=exit, c=step+1]`, so "back-branch to a, define b" is already exactly
right. There is no `dclose_for`; kind 5 routes to the while closer, and `break`/`continue`
needed one line each (`findloop` learning that kind 5 is a loop).

**The init and step clauses are compiled by the ordinary statement machinery**, not by
bespoke clause code. The header pushes a *phase* record (14 = init, 15 = step) and returns
to `stmtloop`; when that statement completes, `stmtend` pops the phase record and resumes
the header. This works with no input-length juggling because `compile_expr` already
terminates cleanly at `;` **and** at an unmatched `)` (`ceclose` → `cc_term`) — precisely
the two clause terminators. The payoff is that a for clause can hold whatever a statement
can: `for(int i = 0; …)`, `for(p->n = x; …)`, `for(f(x); …)` all work without a line of
extra code. Empty clauses are peeked for explicitly; an empty condition emits a pushed `1`
so the exit label stays referenced and the layout stays uniform.

**The block record grew 16 → 24 bytes.** The step-phase record has to hold four labels at
once (top/exit/step/body) before the body record replaces it in place. That is the second
widening in two rungs, and it produced the only two bugs of this milestone — both stride
errors, both invisible until a program nested the constructs:

- **`doif` pushed 5 words instead of 6.** Every record stacked above an `if` was misaligned
  by 4 bytes, so the `if`'s own end label read back as 0 and a `break` inside a `for`
  branched to `__L0`. The emitted code looked *plausible* — right shape, wrong ids.
- **`findloop` still walked the stack in 16-byte steps**, so `break`/`continue` inside a
  `for` read a label id out of the middle of a record and branched to a label that was
  never defined.

Neither is subtle once seen; the lesson is that a stride change has no single point of
truth in this codebase — the record width is spelled out at eight separate sites — and the
only thing that catches a missed one is a test that actually nests the constructs. Both
were found by the behavioural suite within minutes, but a structural-only guard would have
passed the first one.

**Verified** through the real assembled ladder: M2-Planet's own shape
(`for(i = list; NULL != i; i = i->next)` walking a struct-pointer chain), zero-trip loops,
the loop variable's value surviving the loop, nesting, braceless bodies, `break`/`continue`
(including a `continue`-only body, which spins forever if continue targets the top instead
of the step), `goto` out of a `for`, a `for` as a braceless `if` body, declaration inits,
all three empty clauses including `for(;;)`, and break binding to the innermost loop across
all three loop forms. `validate.py` 725 → **757**; the for-free corpus is byte-identical to
the pre-rung compiler, and `stage2-mini-c-demo` gained a `for_ok` section whose structural
witness pins the whole jump-over layout in one assertion: the four labels are *allocated*
top, exit, step, body but *defined* top, step, body, exit, so the definition order is ids
0, 2, 3, 1. Any other layout changes it.

**All four of M2-Planet's `for` sites now compile**, and with this rung the loop family is
complete — `while`, `do{}while`, `for`, `break`, `continue`, `goto`.

*(Correction, added at m66: this entry originally called `enum` the last large gap, and the
m64 entry above said `cc_macro.c` was still blocked on it. Both were copied from §6's list
rather than checked against the compiler; `enum` landed in m66. The lesson is the same one
m58's re-census recorded — the remaining-work list is documentation, not evidence, and a
one-line grep for `:doenum` would have settled it either time.)*


---

### m66 (A26) — `enum` constants

M2-Planet's **10 enum blocks are all anonymous, all file-scope, and every member has an
explicit integer value** — checked against the vendored source rather than assumed. They
carry `NULL` (287 uses), `TRUE`/`FALSE`, `EOF`, `stdin`/`stdout`/`stderr` and `EXIT_*`,
which is precisely *why* m62 could strip every preprocessor directive and still have those
names resolve: **they were never macros**. `NULL` is an enum constant in
`M2libc/bootstrap.c`, not a `#define`.

Constants live in their own 16-byte-record table — `[name_start | name_len | value | pad]`
— with names compared against the input buffer exactly as `gsymlookup` does, so nothing is
copied. The interesting decision is *where the lookup sits*: in `ceid_var`, **after** local
and global variables miss and **before** the `adr x0 <name>` function-address fallback.
That ordering is the whole design:

- a local or global variable of the same name still shadows the constant;
- a function name still becomes an address;
- and an identifier that would previously have silently become `adr x0 <undef>` — the m55
  "faults below `NULLFLOOR`" shape — now resolves if it is a constant.

Implicit values (`enum{A,B,C}`) are supported although M2-Planet never uses them, because
the alternative is not "unsupported" but "silently wrong": without a running counter,
`enum{A,B}` parses as a member followed by junk. Anything else after `=` — an expression, a
negative literal, another constant — is a **diagnostic plus exit 2** rather than a guess.

**The risk in this rung was not `enum`.** Emitting a constant requires emitting an integer
whose value is in a **register**, whereas `emitnum` could only emit one whose *text* was in
the input buffer — it re-called `parseval` four times, once per halfword. So `emitnum` was
split: `emitval` does the halfword lowering from a value parked on the spill stack, and
`emitnum` is now a four-line wrapper that parses the token and calls it. **Every integer
literal in every program now flows through that new code.** The guard is therefore not the
enum tests but a byte-identity corpus spanning literals of all four halfword widths (255,
65535, 65536, 4294967295), which must match the pre-rung compiler exactly. It does.

**Verified** through the real assembled ladder on the target's own text: `cc.h`'s layout
(blank lines, tabs, comments inside the block, trailing commas) and **M2libc
`bootstrap.c`'s four blocks verbatim**, including `EOF = 0xFFFFFFFF`. Also: constants as
subscripts, arguments, `for` bounds and loop conditions; a named tag not being mistaken for
the first member; `else` still tokenizing correctly now that a second four-letter keyword
starts with `e`; and `enumerate` remaining an identifier. `validate.py` 757 → **~790**.

**One semantic nuance worth recording.** Values are stored in a 32-bit field, so
`EOF = 0xFFFFFFFF` becomes 4294967295, not −1. This is consistent as long as both sides of
a comparison come from the same constant — which is the case here, since we compile M2libc
too, so `fgetc`'s `return EOF` and the caller's `== EOF` are the same value. It would only
bite if a *host* libc supplied a sign-extended `-1`, which never happens in this ladder.

**With this rung the largest remaining gap is gone.** What is left for the M2-Planet
handoff: `unsigned`/`long` as word-typed keywords, `char**` subscripting, unnamed prototype
parameters, `argc`/`argv`, and `brk`/inline `asm`.


---

And three entries can be **struck** — verified working, not merely assumed: **`void`
return types and `(void)` parameter lists** (all 244 uses, free: the top-level loop
treats an unknown leading type-word like `int`, the param loop skips non-keyword tokens,
and `funcdone` already emits push-0 + epilogue so a function falling off the end returns
0 with a balanced value stack), **`char**` parameters**, and **`sizeof(int)`/`sizeof(char)`**.
The source also has **zero initialised globals**, so the uninitialised-only limit is fine.

---

### m67 (A27) — word-typed keywords: `unsigned` / `long`

Both are accepted as **spellings of the machine word**. The tokenizer returns keyword id
**1 (`int`)** for each, so *not one consumer site changed*: `funcloop`, `paramloop`,
`stmtkw`/`doint`, the struct-field loop, `fl_global` and `sizeof` all already handle
`int`, and by construction they cannot drift out of agreement with it. `TARGET-SUBSET.md`
§3 licenses exactly this — our `/` and `%` are already unsigned, and `ceil_div`
(`(a + b - 1) / b`, `cc_core.c:2059`) is the only arithmetic in the self-host that cares
about unsignedness. `unsigned char` is the one run that ends somewhere else: it lowers to
our `char`, which is *already* the unsigned one, since `ldrb` zero-extends.

**What was actually broken.** Both words previously lexed as plain identifiers, and the
three positions failed differently, which is why "it half worked" was the wrong reading:
a **return type** was fine (the top-level loop treats an unknown leading word as `int` —
the same accident that makes `void` work); a **parameter** was silently *dropped*, because
`paramloop` only starts a declaration on a keyword token, so the frame allocator lost a
slot and every later argument landed at the wrong offset; and a **local** was parsed as an
assignment to an undeclared variable. Only the second is the interesting one — it produced
no diagnostic and no wrong answer at the declaration, only corrupted values later.

**Multi-word runs** (`unsigned int` at `stdio.c:469,556`, and the `long long` family) are
absorbed by a small loop, `nt_wtype`, entered *only* from the two new recognizer arms. It
parks `x18`/`x29`/`x6` on the `x28` stack and **re-enters `next_token`**: if the trial
token is `int`-like it keeps the advanced cursor and loops, if it is `char` it adopts the
byte type and stops, and otherwise it restores the cursor and returns. Recursion rather
than a bespoke lookahead scanner is the whole economy of the rung — whitespace, comment
and `#`-directive skipping and the keyword recognizer are all reused, so
`unsigned /* t */ int` works with no code of its own, and the loop self-terminates because
an inner `long` has already absorbed its own tail. A hand-rolled scanner would have needed
a second comparator, four new string constants, and its own copy of the comment skipper —
the last of which is where the silent-misparse risk lived.

**Register discipline.** The absorption runs *inside* `next_token`, so it may only touch
that routine's established clobber set. It uses `x1`/`x2`/`x4` and saves `x30`. That rules
out reusing `nameq`, which writes `x7` — and `x7` must survive `next_token`, as
`pl_struct` reads it back across the call to size a struct parameter. Reaching for the
obvious helper would have been a silent miscompile of struct-by-pointer parameters.

**Guarded by byte identity, twice.** The `int` path is untouched, so a keyword-free corpus
of 25 programs spanning every construct through A26 — recursion, structs, fnptrs,
`calloc`, `enum`, `goto`, the whole loop family, escapes, hex, shifts, `argv` — emits
bytes identical to the pre-rung compiler. And in the other direction, 13 paired programs
check that each new spelling emits *exactly* what `int`/`char` emits at every position
(local, param, return, global, pointer, array, struct field, prototype, `sizeof`): if the
two ever diverge they have stopped being the same type, and the reasoning above no longer
holds. Behavioural witnesses use the shapes the pinned source actually writes rather than
invented ones — `ceil_div`, `global_variable_zero_initialize`'s `unsigned i` driving a
`!= 0` loop, `collect_local`'s uninitialised `unsigned` among other locals, M2libc's
`long ftell` / `int fseek(FILE*, long, int)` and file-scope `long _malloc_ptr`.
`validate.py` +27 checks.

**Newly characterised, NOT introduced here:** a bare type word as the *entire* translation
unit (`unsigned`, `long`, and equally `int`, `char`, `void`, or any identifier) spins
rather than exiting — `funcloop` commits to reading a name and then a `(`, and truncated
input never satisfies it. Confirmed against the pre-rung compiler, which hangs identically
on `int`. Well-formed programs are unaffected, and `int main(){unsigned` — EOF *mid*
declaration — terminates cleanly. Worth a diagnostic when the front end next gets one;
it is not this rung's bug.

---

### m68 (A28) — identifier type names: `FILE`, `FUNCTION`, `size_t`

**The list this rung was supposed to implement was wrong in both directions**, which is
the more useful half of the entry. Item 8 said `FILE`/`size_t`/`ssize_t`, read off the
`BOOTSTRAP_MODE` block in `cc_types.c`. Re-derived mechanically against the pinned tree,
in the translation unit the makefile actually builds: `FILE` 15 uses, **`FUNCTION` 6**,
`size_t` **zero** (its 41 uses are all in `stdio.c`/`stdlib.c`/`string.c`), `ssize_t`
**zero anywhere** — it is registered for *mes.c*, per the comment above it. `FUNCTION`
was missed because it is registered *above* the `BOOTSTRAP_MODE` block, unconditionally;
it is a plain value parameter in `common_recursion`, `general_recursion` and
`arithmetic_recursion`. §3 already named `common_recursion(FUNCTION f)` under "Function
pointers" — the item just never inherited it. The same pass showed `long` has zero real
uses in the TU (all 10 are in the M2libc C sources), which is recorded in the new
`TARGET-SUBSET.md` §2b along with the TU-vs-wider-set distinction that caused it.

**Nothing is hardcoded.** These are type *names*, not keywords — M2-Planet keeps them in
a table, so four recognizer arms would have been the wrong shape and would not have
covered a typedef later. Instead the two positions that still required a keyword to start
a declaration accept an identifier in type position, which is what the other two positions
have always done: `funcloop` treats an unknown leading word as `int` (the accident that
also makes `void` work) and `fl_global` follows it. The inconsistency *was* the bug. One
positional rule now covers `FILE`, `FUNCTION`, `size_t`, `ssize_t`, `va_list` and any
future typedef.

- **Parameter position is free.** After `(` or `,` an identifier can only be a type, and
  `paramloop` is already always at a type start when it dispatches, because the
  declaration path consumes `TYPE * NAME` whole. A peek for `*`-or-letter distinguishes a
  type from `(void)`, whose `)` must not be consumed.
- **Statement position needs the peek**, since a statement-initial identifier may also
  begin an assignment, call, subscript, member store, arrow store or label. The rule is
  `IDENT` → stars → `IDENT`, which in valid C is a declaration and nothing else. It is
  checked *after* the existing `( [ . -> :` tests, so every one of those forms reaches its
  old path unchanged.

**The second half was `prescan`, and it is the part that would have shipped broken.**
prescan sums declaration sizes so the prologue reserves a big enough frame; it also only
counted *keyword* declarations. So `size_t a[3]` parsed and allocated correctly but was
never reserved, the frame came up three words short, and the next call clobbered the
array — the exact m39 failure the prescan exists to prevent, surfacing as a wrong sum
rather than a crash. Caught by a behavioural test, not by reading the code. **prescan and
the statement parser must apply the identical rule**, or the reserved frame stops matching
what was declared, so prescan gained the same peek — plus a **statement-start flag**,
which the parser does not need: prescan scans the whole body, where `a * b` in an
expression is otherwise indistinguishable from a declaration. One sharp edge inside that:
`ps_scalar` swallows the `;` that terminates a scalar declaration, so the flag has to be
re-armed there or `int a; FILE* f;` loses the second declaration. The guard is therefore
emitted-code equality against the `int` spelling — array, scalar, pointer, parameter,
decl-after-decl, array-after-scalar — not merely a right answer.

**Why the old behaviour hid.** A dropped parameter emitted code byte-identical to omitting
it, and *later* parameters still landed correctly because pops come off the top of the
value stack. So `int use(FILE* out, int n){return n;}` returned the right answer while
leaking a value-stack slot per call, and only a *use* of the dropped name went wrong —
`FUNCTION f` then `f(v)` resolves through no symbol table entry, becomes a direct `bl f`
to an undefined label, and runs away. Three failure modes, one root cause, which is why it
never presented as a single bug.

**Verified** through the real assembled ladder on the shapes the pinned source writes:
`common_recursion`/`general_recursion`'s `FUNCTION` parameters called through (the
`bl`-vs-`blr` split is read off the symbol tables, so the call lowers to `ldr x16`/`blr`
for free once the parameter is genuinely declared), `FILE*` as parameter/local/global/
return/dereferenced across `cc.c:45`, `cc_core.c:62,73`, `cc_reader.c:24`,
`cc_macro.c:642`, and every disambiguation form that shares the entry point. 35 programs
spanning every construct through A27 — deliberately frame-shaped, since prescan runs for
every function — are byte-identical to the pre-rung compiler. `validate.py` +37 checks.

**`gcc_req.h` becomes a substitution, and is recorded as one.** Its whole content is
`typedef void (*FUNCTION) (void);` plus a comment saying it exists only because gcc lacks
naked function pointers. M2-Planet compiling itself does not need it — it pre-registers
`FUNCTION` unconditionally — and neither do we. Omitting that one file from the `-f` list
is the same *kind* of move as the `asm()` omission in item 12: a substitution, not a
capability. `typedef` itself remains unimplemented, and `char**` subscripting (item 9) is
untouched — a type-model gap, not a naming one.

---

## 6. What's next

The plan is a **capability-jump ladder**: keep each rung minimal, and write each
stage in the language of the stage below.

- **Stage 1** — DONE (multi-character labels) and upgraded to `brk` buffers so it
  can process large stage-2/3 sources. Now a **two-pass numeric label resolver**
  (m32): labels of any count resolve to numeric `@<pos>` positions and the
  single-char pool is **retired entirely** — **no pool, no ceiling**, so stage 2
  can keep growing without a label cap. (m47 also made resolution grammar-driven,
  so function/label names may start with any character, including `w`/`x`.) See
  `spikes/stage1-as/`.
- **Stage 2** — in progress. Compiles `int main(){ … }` with **word-sized**
  variables, declaration + **reassignment**, `+ - *` expressions plus the full
  **comparison** set `< > <= >= == !=` (four precedence levels, parentheses), and
  **control flow** (`if`/`while`, nested). Conditions can be comparisons or
  nonzero-tests. Unsigned `/` and `%` are now in too (m36 — via a new stage0-as
  `udiv`), so no arithmetic leaf remains; the **critical path to stage 3 is the
  stage-2 "floor"**:
  functions + a real call stack, pointers/`char`/arrays, `struct`, a small heap,
  multi-char labels/identifiers, and I/O. Floor progress: **64-bit `ldr x`/`str x`**
  (m25), **frame-relative variables** (m26), the **numeric PC-relative branch**
  (m27), and **backpatched control flow** (m29) are in, the pipeline buffers were
  raised (m30: 64 KB input / 256 KB output; stage0-as + elf to 256 KB), and the
  front end became a real **tokenizer** (m34, A1) that then enabled **functions +
  a real call stack + recursion** (m35, A2: declaration-order frames, a live
  multi-char symbol table, and a re-entrant expression compiler — emitted programs
  now carry `:func` labels resolved by stage1 alongside numeric if/while), then
  **unsigned `/` `%`** (m36, a new stage0-as `udiv` leaf) and a **64-bit uniform
  machine-word model** (m37, A3a: `int == pointer` width, 8-byte value stack + frame
  slots — the foundation pointers need), then **single-level pointers** (m38, A3b:
  `int* p`, `&` address-of, `*` dereference, `*p = e` store-through, pass-by-
  reference — unary `*` disambiguated from multiply by operand position), then
  **int arrays** (m39, A3c: `int a[N]`, subscript `a[i]` rvalue+lvalue, array-name
  decay — variable-size frame slots forced the symbol table to store each variable's
  frame offset explicitly), then **char + byte access** (m40, A3d: `char c`, `char* p`,
  byte-packed `char s[N]`, `ldrb`/`strb`, char literals — the symbol table gained an
  explicit is_char/is_array flags word, since a small `char[N]` collides in size with a
  scalar). **A3 is complete.** Then **string literals + a static data section** (m41,
  A4a: `"..."` as a `char*` into a second output buffer emitted after the code,
  `adr`-addressed — the globals-ready data infrastructure). Then **globals** (m42, A4b:
  file-scope `int g;` / `int a[N];` / `char* p;`, shared across functions, reusing the
  data section with `g_`-labels and frame-first name resolution — the capability
  M2-Planet leans on hardest). Then the **operator set** (m43, A5a: unary `!`/`-`/`~`,
  bitwise `&`/`|`, shifts `<<`/`>>`, with a `prec` table placing all fifteen operators at
  their correct C precedence). Then **`if`/`else`** (m44, A6a: the else clause via the
  block-stack backpatch machinery, `else if` chains falling out for free). Then **general
  pointer arithmetic** (m45, A7a: `p + n` / `n + p` / `p - n` scale the int operand by the
  pointee size and `p - q` divides by the element size — the first per-operand type
  threaded through the expression compiler, via an `is_ptr` symtab flag + a compile-time
  type stack). Then **`struct`** (m46, A8a: `struct Tag{...}` definitions + a struct
  table, `sizeof(struct T)`, value/pointer structs at all scopes, `.`/`->` member
  get/set incl. chains, `&member`, linked-list traversal — one 8-byte word per field,
  field names in the table never as labels). Then **function pointers** (m48, A9:
  `int (*f)(...)` at every scope, a bare function name decaying to its entry address, and
  a call through the variable via `ldr x16`/`blr` — the `bl`-vs-`blr` split read off the
  symbol tables, no `funcs` table needed). **The floor's type system is complete.** Then the
  **`calloc`/`free` heap** (m51, A10: `calloc`/`free` lower to a direct `bl`, and a **bump
  allocator over a large anonymous `mmap` arena** is appended once at program end for each
  builtin actually used, unless the user defines their own. `calloc(count,size)` rounds the
  request up to 8 bytes and bump-allocates from the arena; the arena is `MAP_ANONYMOUS`, so
  the kernel zero-fills it and bump-only allocation (never reused) keeps every block pristine
  zero — no explicit zero-fill, and no dependence on qemu-user's small `brk` region (which
  segfaulted a 64 KB `calloc` — the interp gained an `mmap`/lazy-paging model so the bench
  witnesses this). `free` is a no-op for a batch compiler; the bump pointer `__mp` lives
  inline after the routine in the R+W+X image. Emitted with **named labels** resolved by
  stage1, so the whole runtime is size-independent — `bl calloc` reaches via ±128 MB and
  `adr __mp` is always adjacent. Heap-allocated linked lists build and traverse correctly through struct-pointer-
  parameter helpers — the shape M2-Planet uses for its token/AST lists. Two pre-existing
  `.s1` decl-initializer bugs on the critical path to M2's `struct X* p = calloc(1,sizeof(…))`
  idiom were fixed alongside: `compile_expr` clobbered the decl slot-offset `x14` across the
  initializer (so `T r = <subscript/arrow>` stored to a garbage offset), and the struct-ptr
  decl path over-consumed one token (so `struct X* p = <expr>` mis-parsed the initializer).)
  Then **file I/O** (m53, A12: `open`/`read`/`write`/`close`/`exit` lower to a direct `bl`,
  and a thin syscall wrapper is appended **once** per used builtin — the same
  appended-once, user-overridable mechanism as the heap. Each pops its args off the value
  stack (last arg on top), loads the aarch64 syscall registers `x0..x3`, `svc`s, and pushes
  the kernel return value. The numbers and shapes match `m2libc/aarch64` exactly, so real
  M2libc — which defines its own `read`/`write`/`_open`/`close`/`_exit` — overrides them
  transparently: `open(name,flag,mode)` → **openat** (56) with dirfd `AT_FDCWD` (`-100`,
  built as `mov x0 0; sub x0 x0 100` since `mov` is a 16-bit MOVZ — aarch64 has no bare
  `open`); `read`→63, `write`→64, `close`→57, `exit`→93. Named labels resolved by stage1
  keep the wrappers size-independent. The dev interp gained a tiny in-memory filesystem +
  fd table so the bench **witnesses** the behaviour — files are created/read/written, an
  `open` of a missing file returns `< 0`, and a read past EOF returns 0 — rather than
  outrunning reality (the m50/m51 lesson); on real CI a compiled program copies a source
  file to an output file on qemu's own filesystem. **With heap + I/O in, the stage-2 floor —
  a program that reads bytes and writes text — is complete.** A pre-existing string-literal
  escape gap surfaced alongside but is a *separate* lexer rung, deliberately not folded in:
  the `.s1` lexer does not yet decode `\n`/`\t`/`\0` inside `"..."` (the a12a reference does),
  so a string emitted with `write(1,"a\nb",3)` carries a literal backslash — M2-Planet's own
  `"\n# Core program\n"` output strings and `fputc('\n', …)` char-literal escapes will need
  it before the self-host, but it is orthogonal to the I/O primitives.) *(Known deeper bug,
  cleanly characterized as the next codegen rung: a function with **several struct-typed
  locals** mis-sizes its frame — e.g.
  `struct N* p = a; … while(p){ s = s + p->v; p = p->nx; }` inside `main` with `a,b,c,s,p`
  locals — so locals collide; the same traversal via a **helper taking `struct N* p`** is
  correct. Minimal repro: a stack `while(p){ s=s+p->v; p=p->nx; }` in a many-local `main`
  returns 0 instead of the sum. Present in the original `.s1`; unrelated to the heap.)* Then
  **large integer literals** (m52, A11: a constant `>= 2^16` is materialised as
  `mov x<d> <lo16>` + a `movk x<d> <hw> <shift>` per nonzero higher halfword, since a bare
  `mov` is only a 16-bit MOVZ). The heap's 64 KB/256 KB buffer tests surfaced this
  pre-existing bug: the compiler emitted a single `mov x0 <n>` whose immediate overflowed
  into the shift/opcode bits on real hardware (`mov x0 262143` became `movz #0xffff,lsl#48`
  -> a wild address -> SIGSEGV), while the Python bench masked it by carrying the full value
  in its decoded op. Fixed in the compiler (no stage-0 change): the literal emitter now
  lowers each halfword; `s0as` was made faithful (it now **rejects** a `mov` immediate
  `>= 2^16` so the bench faults like hardware), and the interp gained an `mmap` model. A
  standalone `qemu-mmap-probe` workflow (raw brk/mmap syscalls + a stage0-as-vs-`as`
  encoding byte-check) pinpointed this on the real CI host. Then the **self-host canary**
  (m56, A15) and, with the pivot decided, the first three rungs of M2-Planet's remaining
  subset: **short-circuit `&&`/`||`, hex literals, and `^`** (m57, A16 — `&&`/`||` emit
  their test+branch at *push* time, where the left operand is final, and backpatch at
  apply time with the patch slot keyed by the operator's **opstack index**, which makes
  them re-entrancy-safe inside call arguments for free; `^` needed one small stage-0
  `eor` leaf, the `udiv` rung's shape). Then the plan (revised —
  see below and `TARGET-SUBSET.md`): **(1) run a self-host TEST** to prove the mechanism
  (compile a compiler-shaped, file-reading program; ideally a toy fixpoint), **not** as a
  permanent rung; **(2) do NOT pivot to a stage-3-in-C** — instead keep growing **stage 2
  (in asm)** to cover M2-Planet's remaining subset — `&&`/`||`, hex and `^` landed in
  m57, escapes in m61, the preprocessor in m62, and **`do {} while` + `break`/`continue`
  in m64** (one rung: a do-loop emits the same label pair a while-loop does, so `break` is
  one mechanism for both; the block record widened 12 -> 16 bytes and the braceless flag
  moved to bit 3 to make room for a `do` kind), and **`for` in m65** (emitted in source
  order with a jump over the step, so no span replay; its close is `dclose_while`
  unchanged, and its init/step clauses are compiled by the ordinary statement machinery
  via phase records on the block stack). **The loop family is complete.** **`enum` landed in m66**
  (anonymous file-scope blocks, looked up after variables and before the function-address
  fallback; the real risk was splitting `emitnum` into `emitval` so a value in a register
  could be lowered, which put every integer literal in the program on new code). **`unsigned`
  and `long` landed in m67** (accepted as spellings of the machine word — the tokenizer
  returns the `int` keyword id for both, so no consumer site changed, and multi-word runs
  like `unsigned int` / `long long` collapse to one token by re-entering `next_token`).
  Still open are `char**`
  subscripting (faults), `argc`/`argv` (compiles, but `argc` reads 0 — never wired to the
  stack), and `brk`/inline `asm`. **`FILE`/`FUNCTION`/`size_t` landed in m68** — not as
  keywords but as a positional rule (an identifier in type position starts a declaration,
  which is what the top-level loop and `fl_global` already did), so it covers any
  pre-registered primitive or typedef; the re-derivation behind it corrected item 8, which
  had omitted `FUNCTION` and listed `ssize_t`, a name with zero uses in the pinned tree. Unnamed prototype parameters were on this list and are
  **not** a gap: `int f(int);`, `int f(int,int);` and `int f(char*);` all compile and run (compound assign and
  `++`/`--` are **not** needed — zero uses in the self-host); **(3)** compile
  **M2-Planet's own source** with stage 2, so
  **M2-Planet becomes the de-facto "stage 3."** No throwaway compiler; the artifact we
  build is the hand-off node. Cost accepted: those features land in `.s1` asm, not C.
- **Stage 3** — **M2-Planet's own source, compiled by stage 2** (no separately-written
  Veron-C stage 3; earlier plan retired). A self-host *test* precedes this to de-risk the
  ladder, but the permanent path is stage 2 → M2-Planet-as-stage-3.
- **Hand-off**: the concrete finish line is compiling **M2-Planet's own source**
  (pinned at `34fbd5c…`, vendored read-only at `spikes/reference/`) into a working
  M2-Planet, which drives the borrowed live-bootstrap chain (see
  `spikes/borrow-m2/`, `spikes/livebootstrap/`). The target C subset is spelled
  out in `stage2-mini-c/TARGET-SUBSET.md`.
- **Cross-arch reality (mapped; deferred behind M2-Planet).** Our M2-Planet is **native
  aarch64** (M2-Planet targets aarch64 directly — verified in `borrow-m2`). The seam is
  one rung up: **MesCC has no _native_ aarch64 backend** (x86 + armhf only, confirmed vs
  GNU Mes 0.27); Guix reaches aarch64 by running the **armhf Mes** and lifting to 64-bit,
  and live-bootstrap's upper half ships no aarch64 config — so a native arm64 gcc is a
  **porting** effort, not a config flip. Two routes: (1) the **armhf-Mes detour**, which
  is **hardware-viable on our CI** — GitHub's arm64 runners are Cobalt 100 / Neoverse N2,
  which keeps AArch32 EL0, and a static armhf binary runs natively on both
  `ubuntu-24.04-arm`/`22.04-arm` (verified; `.github/workflows/armhf-probe.yml`), but it's
  a build-out and **fragile** (breaks on a Cobalt 200 / Neoverse V3 fleet move — the probe
  is the canary); or (2) **cross-compile from the amd64 gcc** (durable). Current lean: (2),
  with (1) a legitimate option. Earlier "amd64-only" wording was imprecise; corrected in
  `TARGET-SUBSET.md` §8 and `borrow-tcc/README.md`.

Scope rule: add the smallest capability per rung that makes the next rung
writable. If a stage feels unwieldy to write, that's the signal to add one small
convenience to the stage below — not to push through pain.
