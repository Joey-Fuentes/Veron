# Stage 3 — M2-Planet and above

**Start here for anything above the hand-off.** Stages 0–2 are done; their
detailed history is in `spikes/PROGRESS.md` (152 KB of it) and you do not need
to read it to work here. This file is the whole current state.

---

## What stage 3 is

There is no separately-written stage 3. **M2-Planet, compiled by our stage 2,
IS stage 3** — the plan to write our own was retired early. Stage 3 work is
therefore everything from M2-Planet upward: Mes, tcc, gcc.

## What is proven

**The hand-off.** Our ladder reproduces upstream's M2-Planet byte for byte.

```
refM2P (upstream tooling)   643257  d80317fc92ff4889
G1     (our ladder)         643257  d80317fc92ff4889
G2..G5 identical            -- stable fixpoint
```

Gated by `.github/workflows/m2libc-113-bisect.yml`.

`G0` is our M2-Planet, built by stage 2 from *patched* source. Every generation
after it is built from upstream's **unpatched** sources, because our M2-Planet
compiles `asm()` fine — so the patch applies to G0 only and leaves the chain
immediately. That G1 lands exactly on upstream's bytes is the proof the
substitution is behaviour-preserving: a checksum, not an argument.

## The pin set (confirmed, do not drift)

`livebootstrap-pins-probe` resolved `live-bootstrap -> stage0-posix -> M2-Planet`
and found our pins **are** live-bootstrap's:

| | pin |
|---|---|
| M2-Planet | `bd2fe4b` (Release_1.13.1) |
| M2libc | `68a23cf` |
| mescc-tools | `5adfbf3` |
| live-bootstrap | `9a268c4` (2026-04-20) |
| matching upper half | Mes **0.27.1**, tcc **0.9.27** |

One coherent set, already adopted. No pin decision is outstanding.

## The substitution, in one paragraph

Stage 2 cannot compile `asm()`. At 1.13.1 M2libc's
`aarch64/linux/bootstrap.c` is the whole mini-libc with `asm()` in six of its
fifteen functions. `tools/drop_asm.py` drops those six at *function*
granularity; m53/m69 builtins supply `open`/`close`/`brk`/`exit`; and
`spikes/stage2-mini-c/m2libc-shim.c` supplies `fgetc`/`fputc`, the two left
over. Applies to G0 only.

## Tools worth knowing about

| tool | what it is for |
|---|---|
| `tools/backtrace.py` | run a program through the ladder; on a fault, print the last N instructions with every PC mapped to `label+offset` |
| `tools/vstack.py` | find value-stack arity mismatches by *reading* emitted assembly — no execution |
| `tools/pcmap.py` | map a faulting PC back to a function label |
| `tools/drop_asm.py` | the substitution |
| `spikes/bench/` | Python model of the ladder; compiles M2-Planet locally in ~30 s |

## Method note (this one earned its place)

Differential testing — mutate the source, diff the exit code — produced **four**
confident root causes for one bug and every one dissolved on the next run,
because changing the source moves emitted layout and symbol-table state
together. What worked was watching the machine: trap the store, map the PC, read
the emitted instruction, then read the compiler's own branch. Reach for
`backtrace.py` before reaching for another source variant.

## Open

- **G0's x86 codegen** differs from upstream: compiling for x86 it takes the
  short-immediate branch in `write_add_immediate` where upstream emits the
  register form (~1350 sites, 31,698 bytes). G1 proves the aarch64 path is
  perfect and G0 is used exactly once, so this blocks nothing. Non-gating REPORT
  in the bisect workflow.
- **Mes rung** — `mes-rung.yml` reference arm; see `MES-RUNG.md` when it lands.
- **`mescc-tools-full` / `no-host-chain` / `stage3-m2-demo`** are still red from
  the stale generic `bootstrap.c` (they reference a file that does not exist at
  1.13.1). One fix, several workflows: replace `$L/bootstrap.c` with either the
  patched arch file + shim (if fed to *our* stage 2) or the unpatched arch file
  (if fed to *upstream's* M2-Planet).

## Where things live

```
spikes/stage3/          this folder -- current state, roadmap
spikes/UPSTREAM-PINS.md the pin set and what is open at it
spikes/PROGRESS.md      stages 0-2 history; reference only
spikes/bench/           the local ladder model
spikes/reference/       vendored upstream sources (NOTE: the OLD pin)
```
