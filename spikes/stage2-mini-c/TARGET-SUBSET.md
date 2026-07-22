# Target C subset — the handoff spec for the stage ladder

**Invariants SUSPENDED (spike doc).** This is a planning/reference doc for the
`spikes/` tracer, not part of the aspirational trunk. It defines the *finish
line* for the self-hosted compiler ladder and the C subset each rung is working
toward, grounded in the actual upstream source rather than guesswork.

## 0. The finish line (why this doc exists)

The near-term plan (see `HANDOFF` / `PROGRESS.md`) is: grow the self-hosted
ladder (stage 0 → 1 → 2 → 3 …) until one of our stages can **compile M2-Planet's
own source** into a working `M2-Planet` binary, then hand that binary to the
already-GREEN borrowed chain (`spikes/borrow-m2/`, `spikes/livebootstrap/`):

```
M2-Planet source ──[ our stage-N compiler ]──► M2-Planet binary
                 ──[ M1 + hex2 (mescc-tools) ]─► drives Mes → tcc → gcc
```

M2-Planet is **self-hosting**: its own compiler is written in the C subset it
accepts. So its source *is* the precise definition of the C subset we must
eventually accept — no more, no less. That makes "M2-Planet-grade C" a concrete
checklist instead of a vibe, which is what this doc records.

The borrow-m2 spike currently builds M2-Planet with the *host* gcc (it only
proves the downstream chain runs on our setup). The bootstrap goal is to replace
that one step — "host gcc builds M2-Planet" — with "our seed compiler builds
M2-Planet." Everything below is scoped to that single replacement.

## 1. Pinned spec sources

Because we now treat this source as our spec, it must not drift under us. The
`borrow-m2-demo` workflow pins the upstreams:

| upstream   | commit                                     | role                         |
|------------|--------------------------------------------|------------------------------|
| M2-Planet  | `34fbd5c2a9b6eb634a4f6ad95158dcd1efcf19e0` | defines the C subset (spec)  |
| M2libc     | `ca023d8dc855171fd0618951add5817e0e568fca` | runtime we must provide      |

M2libc is pinned transitively via M2-Planet's submodule gitlink at that commit.
(`mescc-tools` — the M1/hex2 assembler+linker — is not part of the C-subset spec
and remains unpinned for now; pin it when the handoff spike graduates.)

These are upstream **build dependencies** (same category as gcc/musl), fetched in
CI. A pinned, read-only copy of both is also vendored at
[`../reference/`](../reference/) so the source can be consulted locally (the
assistant's sandbox has no network and does not persist between sessions); the
vendored copy is reference only and is not part of the build.

## 2. How this subset was derived

By reading the pinned compiler sources (`cc.c`, `cc.h`, `cc_core.c`, `cc_emit.c`,
`cc_globals.c`, `cc_macro.c`, `cc_reader.c`, `cc_strings.c`, `cc_types.c`) plus
`gcc_req.h`, and the M2libc C sources it links (`bootstrappable.c`, `stdio.c`,
`stdlib.c`, `string.c`, `ctype.c`).

The important distinction is **used vs. recognized**: M2-Planet, being a compiler,
*recognizes* many constructs in its input (there are string literals like
`"switch"`, `"union"`, `"typedef"` and code that parses them). What constrains
*us* is only what its own source **uses**, since that's what our compiler has to
accept. All claims below are about usage, filtered of comments and string
literals.

## 3. MUST accept (used by the self-host)

**Types**
- `int`, `char`, and pointers — including multi-level and `struct*`.
- `struct`: self-referential, multiple members, member access `.` and `->`,
  including chained `a->b->c` (used pervasively — the token/type/list data model
  is entirely linked structs).
- `enum` with explicit integer values (used for all the option/flag constants).
- **Function pointers** — passed and called (e.g. `common_recursion(FUNCTION f)`).
  `gcc_req.h` exists solely to give gcc the naked-function-pointer support that
  M2-Planet's self-host relies on.

**Statements**
- `if` / `else` (nested, heavily), `while` (the workhorse loop), `for` (rare but
  present), `return`, `break`, `continue`, `goto` + labels, and `{ }` blocks.
- Multiple functions with parameters and return values, forward declarations,
  and **recursion** (the parser recurses). This is what forces a real call/return
  discipline, not a fixed-depth scheme.

**Operators**
- Arithmetic `+ - * / %`; bitwise `& | ^ ~ << >>`; logical `&& || !`; all six
  comparisons `== != < > <= >=`.
- Address-of `&`, dereference `*`, member `.`/`->`, **array indexing `a[i]`**
  (used everywhere), `sizeof`, assignment plus compound forms (`+=` etc.), and
  `++`/`--`.

**Literals**: `int` (incl. hex/char-code), `char` `'c'` (used constantly for the
byte-level scanner), and string `"..."`.

**Preprocessor (modest)**: `#include`, include guards (`#ifndef`/`#define`/
`#endif`), and simple object-like `#define` constants. The self-host does **not**
lean on function-like macros or conditional-compilation gymnastics.

## 4. NOT needed (the self-host deliberately avoids these)

These appear only as things M2-Planet *parses*, not as things it *uses* — so our
compiler does **not** need them to compile M2-Planet. This is a real scope win:

- `switch` / `case` — zero uses in its own source (switch handling is written
  with `goto`).
- `do { } while` — zero uses (`while` and `for` suffice).
- `union`, `typedef` — zero uses in the self-host (the one `typedef` is the
  gcc-only shim in `gcc_req.h`).
- Ternary `?:` — zero uses.
- Floating point (`float`/`double`), and the `long`/`short` size qualifiers.

Don't spend rungs implementing these; the target doesn't require them.

## 5. Runtime / libc surface we must provide

To *run* the compiled M2-Planet, we supply the small libc it calls. Grounded in
its actual call sites, the surface is narrow:

- **Heap**: `calloc` (used constantly for nodes) and `free`. A bump/`brk`
  allocator suffices; `free` can be a near-no-op for a batch compiler.
- **File I/O**: `fopen` / `fclose` / `fputs` / `fputc`, and raw `open` / `read` /
  `write` / `close`. All map to `svc` syscalls.
- **Process**: `exit`.
- **String**: `strlen` (and a handful of helpers M2-Planet defines itself, e.g.
  `match`, `require`, `in_set` — those are in its own source, not libc).

This mirrors how M2libc's aarch64 rung is structured: a small `_start` +
syscall-level primitives (`libc-core.M1`) under a thin C layer. Our equivalent is
a `_start` that calls `main` and syscall wrappers — the same shape we'd need for
any self-hosted stage that does real I/O.

## 6. Mapping to our ladder

The pain is asymmetric: features added to a stage written in assembly
(stage-1's language) are expensive; features added in C (stage 3+) are cheap. So
the strategy is to build the **minimum floor** into stage 2 that makes *a
compiler writable in it*, then never hand-write assembly again and grow the
accepted subset in C.

### Floor — what stage 2 needs before stage 3 is writable

A compiler is a program that reads bytes and writes text, so the floor is higher
than the current "compute an exit code" target. In rough dependency order:

1. **stage 0: 64-bit `ldr x` / `str x`** (small, byte-verifiable, mirror in
   `s0as.py`/`interp.py` + a `validate.py` guard). Word `str` truncates a 64-bit
   return address, so this is the enabler for a real software call stack — which
   recursion + function pointers require.
2. **stage 2 label/codegen strategy.** The whole chain caps an assembled program
   at ~128 distinct labels (stage0-as's 128-entry symtab; stage 1 just maps
   multi-char names into it). A compiler emits far more, so stage 2 must stop
   emitting a label per variable/branch: **backpatch branch offsets** and use
   **frame-relative variable addressing**, leaving only function-entry labels.
3. **Multi-char identifiers** (lifts the 26-name wall; makes the source legible).
4. **`if`/`else` + full comparisons** (`== != <= >=`).
5. **Functions**: params, returns, recursion, on the software call stack from (1).
6. **Pointers + `char` + byte load/store + arrays + globals** (buffers).
7. **`struct` + a `calloc`/`free` heap** (the compiler's data model — confirmed
   required by §3/§5).
8. **I/O primitives + string literals** (`read`/`write`/`open`/`exit`, emit
   `.ascii`), so a compiled program can read source and write assembly text.

**Status (m48):** items 1–6 are in, and of item 7 the `struct` half is done (m46).
With **function pointers** landed (m48 — `int (*f)(...)` at every scope, function-name
decay, and call-through `blr`), the floor's **type system is complete**. What remains is
the **`calloc`/`free` heap** (rest of 7) and the **I/O primitives** (8: `read`/`write`/
`open`/`exit`), after which stage 2 is at the self-hosting floor.

After (8), stage 2 is at the self-hosting floor. **Two things happen there — and the
second is a deliberate change of plan from earlier drafts of this section.**

**(a) Run a self-host TEST — but don't make it a permanent rung.** Once heap + I/O
land, do a *proof-of-pivot* before investing in anything else: confirm the ladder can
compile a real, **compiler-shaped** program that reads a file and writes output (deep
recursion, structs, function pointers, nested control flow), and ideally a **toy
fixpoint** — a tiny compiler written in stage-2's C subset that compiles its own source,
byte-compared across a second generation. This de-risks the single scariest unknown —
that a compiler compiling compiler-shaped input actually works through this ladder — and
it does so **cheaply, first**. It is a test/canary, not a stage we keep.

**(b) Do NOT pivot to a stage-3 compiler written in Veron's own C.** Earlier drafts said
"stop growing stage 2 and add the rest in C as stage 3." **We are dropping that.** A
throwaway stage-3-in-C has no independent value — **M2-Planet is the actual target.** So
instead: keep growing **stage 2 (in asm)** until it accepts M2-Planet's *entire* source
subset — the §3 features stage 2 still lacks: a modest preprocessor (`#include`/guards/
object `#define`), `&&`/`||`, `goto`+labels, multi-level pointers, `for`/`break`/
`continue`, compound assign `+=`/`++`/`--`, forward declarations, `^` (via a stage-0
`eor`), hex literals, and `enum`. Then compile **M2-Planet's own source** with stage 2.
**M2-Planet effectively becomes "stage 3."** No disposable intermediate compiler; the
artifact we build is exactly the hand-off node.

The cost, stated honestly: those remaining features land in **`.s1` assembly**, not in
comfortable C — the expensive side of the asymmetry above. We accept that in exchange for
a clean M2-as-stage-3 endgame and no throwaway rung. The scope rule still applies: if a
feature is genuinely nicer to add one stage down (e.g. `^` needs a stage-0 `eor`), do that.

## 7. Open design decisions (resolve on the bench/refs first)

- **Label/branch strategy**: backpatched offsets vs. expanding the symbol table.
  Model in `stage2_ref.py` against the oracle before touching asm.
- **Call stack**: 64-bit `ldr x`/`str x` + a stack pointer in `brk` (preferred),
  vs. any fixed-depth scheme (insufficient once recursion is in play).
- **`struct` layout + allocator**: member offsets, alignment, and the
  bump-allocator contract (`calloc` zeroing matters — M2-Planet relies on it).
- **Output target**: whether stage-2/3 emit stage0-as directly (with backpatched
  offsets, few labels) or route through stage 1 (multi-char labels, ≤128 cap).

## 8. Caveats

- **Cross-arch handoff (deferred — but the seam is now mapped, and probed).** Veron
  produces a **native aarch64 M2-Planet**: M2-Planet targets aarch64 directly
  (`--architecture aarch64`; exercised green in `borrow-m2`). The seam is one rung *up*:
  **MesCC has no _native_ aarch64 backend** — its code generators are x86 (i386) and
  **armhf** (32-bit ARM) only (confirmed against GNU Mes 0.27 and the current manual:
  "aarch64-linux uses mes for armhf-linux"). aarch64 is reached, in Guix, by running the
  **armhf Mes on aarch64 hardware** and lifting to 64-bit — not by a native aarch64
  compiler. live-bootstrap's Mes→tcc→gcc upper half is x86-framed and ships no aarch64
  config, so **reaching a native arm64 gcc is a porting effort, not a config flip.** The
  earlier note ("no Mes/tcc backend … gcc lands on amd64") was directionally right but
  imprecise: the non-x86 MesCC backend is armhf, and "amd64-only" overstated it. Two
  routes forward:
  1. **armhf-Mes detour** — *hardware-viable on our CI, verified.* GitHub's
     `ubuntu-24.04-arm` / `ubuntu-22.04-arm` runners use Cobalt 100 (Neoverse N2), which
     retains **AArch32 EL0**; a freestanding static armhf binary runs **natively** (exit
     42, no emulation, no interfering binfmt) on both images — see
     `.github/workflows/armhf-probe.yml`. But it's a build-out, and it's **fragile**: it
     breaks the day GitHub's fleet moves to Cobalt 200 (Neoverse V3, no AArch32). Keep the
     probe as a **canary** (its CPU-identity dump flags the change immediately).
  2. **Cross-compile from the amd64 gcc** the chain already lands (build an
     aarch64-targeting cross-gcc, then a native arm64 gcc, then self-rebuild) — more steps
     but durable against any CPU refresh.
  **Current lean: (2) as the durable endgame; (1) is now a legitimate option, not a dead
  end.** None of this changes the C subset above, and it stays deferred behind M2-Planet.
- **This is a spec of the pinned commit**, not of "M2-Planet in general." If the
  pins in §1 move, re-derive §3–§5 from the new source.
