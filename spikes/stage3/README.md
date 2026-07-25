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

**The userland half of the Linux leg.** A musl + BusyBox userland compiled
entirely by tcc boots as PID 1 under a GCC-built arm64 kernel.

```
==== VERON USERLAND ALIVE ====
pid1  : /bin/busybox        shell and busybox: compiled by tcc
                            kernel under them: compiled by gcc
==== VERON BOOT OK ====
```

Gated by `.github/workflows/tcc-userland-arm64.yml`. Full record, evidence chain
and named substitutions in **[`TCC-USERLAND.md`](./TCC-USERLAND.md)**.

The single real compiler gap it found: **tcc has no dead-code elimination**, so
BusyBox's `if (ENABLE_FEATURE_X)` idiom leaves references to functions that were
never defined. Everything else was build plumbing. The kernel uses the same
idiom via `IS_ENABLED()`, so leg 3 will meet this again.

**gcc 4.7 can carry gcc 4.8's aarch64 backend, and the result compiles.**

```
configure rc=0   build rc=0   cc1 BUILT
cc1 emits   stp x29, x30, [sp, -48]! / cmp w0, 1 / ble .L4
assembled   ELF 64-bit LSB relocatable, ARM aarch64
ran         exit=55                (fib(10) = 55)
```

gcc 4.7.4 — the last release written in C — with `gcc/config/aarch64` from 4.8.5
spliced in, builds a `cc1` that emits correct aarch64 code. That was the leg's
whole question, because it makes the gcc route native **and** C-only:

```
tcc -> gcc 4.7 + this backend -> g++ 4.7 -> gcc 4.8 -> modern gcc
```

4.7 yields a full C++98 compiler built from C, which is exactly what 4.8 asks
for. Total adaptation: **0 target hooks, 3 config case arms, 34 `.md`
definitions expanded, 7 qualified attribute refs, 3 functions at 24 call
sites** — nothing structural, and within the ~148 lines the vax control
predicted.

Full record in **[`GCC-BACKPORT.md`](./GCC-BACKPORT.md)**. Gated by
`.github/workflows/gcc47-aarch64-backport.yml`.

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

**The direct path pins its own tcc**, because live-bootstrap's 0.9.27 cannot
self-host on aarch64 and has no inline assembler at all:

| | pin | |
|---|---|---|
| tcc | `5ec0e6f8` + 5 patches | `sources/tcc.toml` |
| musl | 1.2.5 `a9a118bb…` | `sources/musl.toml` |
| BusyBox | 1.36.1 `b8cc24c9…` | `sources/busybox.toml` |

tcc's base commit was located by matching the **pre-image blob hashes** in the
patch series rather than by date or ancestry — `apply-series.sh` does this, and
it is the reliable way to find the tree a mailing-list patch was written
against.

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
- **The gcc leg, past the entry point.** The backport builds and compiles
  correct aarch64 code (`GCC-BACKPORT.md`). What is not yet shown: **libgcc**
  (the arms run `make all-gcc`, so `xgcc` cannot link — `cannot find
  crtbegin.o`); **tcc building this tree** (every arm uses the host gcc, one
  variable at a time); and **g++ 4.7 building 4.8**, which is the entire reason
  for choosing 4.7.
- **The kernel is still borrowed.** `tcc-userland-arm64` boots Ubuntu's kernel,
  which is correct for the ABI claim but is a distro artifact. Building
  `arch/arm64/configs/defconfig` from a pinned tree with the host gcc replaces
  it and supplies the UAPI headers currently taken from `linux-libc-dev` —
  two open items, one build. Leg 3's first spike.
- **The userland has not been rebuilt twice.** It is pinned and hashed but not
  yet shown byte-identical across two runs. Cheap to add, and the natural gate.
- **`mescc-tools-full` / `no-host-chain` / `stage3-m2-demo`** are still red from
  the stale generic `bootstrap.c` (they reference a file that does not exist at
  1.13.1). One fix, several workflows: replace `$L/bootstrap.c` with either the
  patched arch file + shim (if fed to *our* stage 2) or the unpatched arch file
  (if fed to *upstream's* M2-Planet).

## Where things live

```
spikes/stage3/          this folder -- current state, roadmap
spikes/stage3/TCC-USERLAND.md   the tcc userland result, in full
spikes/stage3/GCC-BACKPORT.md   the gcc 4.7 + 4.8-aarch64 result, in full
spikes/stage3/patches/  the tcc arm64 assembler series + our two fixes
spikes/stage3/probes/   the CC shim, the pinned fetcher, the C probes
sources/*.toml          url + hash + license + declared substitutions
spikes/UPSTREAM-PINS.md the pin set and what is open at it
spikes/PROGRESS.md      stages 0-2 history; reference only
spikes/bench/           the local ladder model
spikes/reference/       vendored upstream sources (NOTE: the OLD pin)
```
