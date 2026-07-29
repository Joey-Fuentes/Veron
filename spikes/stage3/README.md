# Stage 3 — M2-Planet, and reaching a real tcc

**Scope: the hand-off up to tcc, and nothing above it.** Stage 3 owns one
question — *can our ladder produce an unmodified, self-hosting tcc?* Everything
tcc is then **used** to build (gcc, a userland, a kernel, a QEMU boot) is
**stage 4**: see `spikes/stage4/README.md`.

Stages 0–2 are done; their detailed history is in `spikes/PROGRESS.md` (152 KB
of it) and you do not need to read it to work here.

**To run any of this yourself**, from this repository and nothing else:

```bash
sh spikes/stage3/tools/local-build.sh          # micro-c + the case suite, both arches
sh spikes/stage3/tools/local-tcc.sh build/local # compile tcc with it and run it
```

Requires gcc, git, tar and python3. No network. `MICRO-C.md` explains the four
silent traps those scripts encode — assembling the pieces by hand produces a
compiler that segfaults on case 05 and looks broken when it is not.

---

## What stage 3 is

There is no separately-written stage 3. **M2-Planet, compiled by our stage 2,
IS stage 3** — the plan to write our own was retired early.

That leaves stage 3 with one rung still to climb: **from M2-Planet to tcc.** Two
routes are open, and they are not in competition — one proves provenance, the
other already produced a binary:

| route | state |
|---|---|
| M2-Planet → Mes → tcc (live-bootstrap's) | Mes rung in progress, three rungs out |
| enhanced M2-Planet → tcc directly | **compiles all of tcc; the binary runs, diagnoses, preprocesses and reaches macro expansion** — `MICRO-C.md` |

The direct route now has a name — **micro-c** — and its own file. It compiles
`libtcc.c` to 369,255 lines of M1, assembles and links a 1.52 MB aarch64 binary,
and that binary runs: it reports that the crt files are missing, preprocesses
its own predefs and a real source file, interns all 980 keywords with their
collision chains, and faults inside macro expansion on `++*(p)` — pointer
arithmetic that does not scale, which is a documented gap rather than an
unknown. It is not a working tcc; it is a long way past "not started".

Stage 4 has since proven what a tcc is *worth* once reached: an arm64 tcc builds
a complete gcc 4.7.4 carrying gcc 4.8.5's aarch64 backend — libgcc, `xgcc`, and
a `cc1plus` — which is the rung the whole choice of 4.7 rests on. That raises
the value of closing this stage, and changes nothing about how it is closed.

Stage 4 already **has** a tcc, pinned and patched, and uses it. What stage 3
owes is a tcc reached *from the seed*.

## What is proven

**The hand-off.** Our ladder reproduces upstream's M2-Planet byte for byte.

```
refM2P (upstream tooling)   643257  d80317fc92ff4889
G1     (our ladder)         643257  d80317fc92ff4889
G2..G5 identical            -- stable fixpoint
```

Gated by `.github/workflows/m2libc-113-bisect.yml`.

**The micro-c route is gated by `.github/workflows/tcc-two-ways.yml`**, which
builds tcc twice on the same aarch64 runner — once with gcc as a control, once
with micro-c — and puts both through tcc's own `test1`/`test2`/`test3`, `make
test`, and a self-compilation fixpoint. The control runs **first** on purpose:
if the harness is wrong, that is where it shows, on a compiler nobody doubts.
The first version of that job reported "0 differing lines" against a reference
file that did not exist, and the control is what caught it.

`G0` is our M2-Planet, built by stage 2 from *patched* source. Every generation
after it is built from upstream's **unpatched** sources, because our M2-Planet
compiles `asm()` fine — so the patch applies to G0 only and leaves the chain
immediately. That G1 lands exactly on upstream's bytes is the proof the
substitution is behaviour-preserving: a checksum, not an argument.

**That is the whole of what stage 3 has proven.** The tcc rung is open.

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

**tcc is pinned separately**, because live-bootstrap's 0.9.27 cannot self-host
on aarch64 and has no inline assembler at all:

| | pin | |
|---|---|---|
| tcc | `5ec0e6f8` + 5 patches | `sources/tcc.toml` |

The patch series lives in `patches/tcc-arm64-asm/` and stays in stage 3, because
tcc is stage 3's deliverable. The musl and BusyBox pins moved to stage 4 with
the userland work that consumes them.

tcc's base commit was located by matching the **pre-image blob hashes** in the
patch series rather than by date or ancestry — `apply-series.sh` does this, and
it is the reliable way to find the tree a mailing-list patch was written
against.

## The substitution, in one paragraph

Stage 2 cannot compile `asm()`. At 1.13.1 M2libc's
`aarch64/linux/bootstrap.c` is the whole mini-libc with `asm()` in six of its
fifteen functions. `tools/drop_asm.py` drops those six at *function*
granularity; m53/m69 builtins supply `open`/`close`/`brk`/`exit`; and
`spikes/stage2-pico-c/m2libc-shim.c` supplies `fgetc`/`fputc`, the two left
over. Applies to G0 only.

## Tools worth knowing about

| tool | what it is for |
|---|---|
| `stage3/tools/difftest.sh` | compile one small C program with gcc **and** micro-c, run both, compare — about a second per case, no CI |
| `stage3/tools/vocabulary.sh` | does every macro micro-c can emit exist in M2libc's defs? Static, five architectures at once |
| `stage3/tools/regression.sh` | does micro-c still compile everything the reference M2-Planet compiles? |
| `stage3/tools/instrument.py` | put a marker after every statement of a function; the last one printed names the line |
| `tools/backtrace.py` | run a program through the ladder; on a fault, print the last N instructions with every PC mapped to `label+offset` |
| `tools/vstack.py` | find value-stack arity mismatches by *reading* emitted assembly — no execution |
| `tools/pcmap.py` | map a faulting PC back to a function label |
| `tools/drop_asm.py` | the substitution |
| `tools/fetch-pinned.sh` | pinned fetch with a cache, a hash check and bounded time (shared with stage 4) |
| `spikes/bench/` | Python model of the ladder; compiles M2-Planet locally in ~30 s |

## Method note (this one earned its place)

Differential testing — mutate the source, diff the exit code — produced **four**
confident root causes for one bug and every one dissolved on the next run,
because changing the source moves emitted layout and symbol-table state
together. What worked was watching the machine: trap the store, map the PC, read
the emitted instruction, then read the compiler's own branch. Reach for
`backtrace.py` before reaching for another source variant.

**A second technique also called "differential testing" is sound, and is now the
main tool on the micro-c route.** It is narrower: compile a *small,
self-contained* C program with gcc and with micro-c, run both, compare the exit
code. No tcc is involved, so nothing about tcc can shift underneath the
measurement — which is exactly what broke the first technique. See `MICRO-C.md`;
the distinction matters because the two share a name and only one of them is
trustworthy here.

**And the machine to watch was available all along.** micro-c targets amd64 and
the development machine *is* amd64, so its output can be compiled, linked and
run locally. That went unused for a long time because the work was aimed at
aarch64, and the cost was a CI round trip per bug.

## Open

- **The tcc rung itself** — the one thing this stage exists to close. Neither
  route has produced a *working* tcc from the seed, though the direct route now
  produces a tcc **binary** that runs and gets into the preprocessor
  (`MICRO-C.md`). `ROADMAP.md` has the measured gap for
  the direct route; `mes-rung.yml` is the reference arm for the other.
- **G0's x86 codegen** differs from upstream: compiling for x86 it takes the
  short-immediate branch in `write_add_immediate` where upstream emits the
  register form (~1350 sites, 31,698 bytes). G1 proves the aarch64 path is
  perfect and G0 is used exactly once, so this blocks nothing. Non-gating REPORT
  in the bisect workflow.
- **Stage-2 defects that are real but not on the critical path.** Stage 2 hangs
  on `M2libc/stdlib.c` (rc=124) and segfaults on `M2libc/stdio.c` (rc=139);
  object-like `#define` is still unsupported (m75), and that is what blocks the
  in-box link: stage 2 SEGFAULTS compiling hex2's sources (rc=139), because
  `hex2.h` needs object-like `#define` and `--bootstrap-mode` does not expand
  them. **Two older claims here did not survive native execution.** Under
  `qemu-aarch64` our M1 was recorded as hanging in M2libc's `memset` and our
  hex2 as crashing on exit; on real ARM64 hardware M1 builds and runs clean
  (rc=0, 57,028 bytes) and hex2 never gets built at all. Both were artefacts of
  the emulator, not defects in our output. See `stage3-hermetic-arm64`, GATE 2.
- **`mescc-tools-full` / `no-host-chain` / `stage3-m2-demo`** are still red from
  the stale generic `bootstrap.c` (they reference a file that does not exist at
  1.13.1). One fix, several workflows: replace `$L/bootstrap.c` with either the
  patched arch file + shim (if fed to *our* stage 2) or the unpatched arch file
  (if fed to *upstream's* M2-Planet).
- **`spikes/reference/` vendors the OLD pins** and is out of sync with CI.

## Where things live

```
spikes/stage3/          this folder -- the hand-off, and the road to tcc
spikes/stage3/ROADMAP.md        leg 1: enhanced M2-Planet builds real tcc
spikes/stage3/MICRO-C.md        that leg's STATE -- what works, what is wrong, why
spikes/stage3/tools/            difftest, vocabulary, regression, instrument
spikes/stage3/micro-c-libc/     the runtime under tcc: headers and impl/
spikes/stage3/patches/  the tcc arm64 assembler series + our two fixes
spikes/stage4/          EVERYTHING ABOVE TCC -- gcc, userland, kernel, boot
sources/tcc.toml        the tcc pin, hash, license and declared substitutions
spikes/UPSTREAM-PINS.md the pin set and what is open at it
spikes/PROGRESS.md      stages 0-2 history; reference only
spikes/bench/           the local ladder model
spikes/reference/       vendored upstream sources (NOTE: the OLD pin)
tools/                  shared tooling, used by both stages
```
