# Veron

A hermetic, reproducible, end-to-end auditable operating system — bootstrapped from a tiny, hand-audited, per-architecture **assembly seed** up a readable ladder to a traditional **GNU/Linux** desktop.

**Status:** The ladder runs natively and hermetically, **with no host tool on the build path.** `stage3-hermetic-arm64` climbs seed → stage 1 → stage 2 → 426 conformance programs → M2-Planet on real ARM64 hardware inside a `bubblewrap` sandbox with no network, and M2-Planet's self-compilation output is **byte-identical to upstream's own reference compiler** (`dc38e13e4ceaeecb`, 2,947,903 bytes). The seed assembler and ELF writer are committed binaries, verified on every push: each is disassembled and compared to its own source by **two independent disassemblers**, and the whole linked ELF is reconstructed from that disassembly and compared byte for byte. `BUDGET_PATH` is empty.

**Self-hosting, stated exactly.** `stage0-as` assembles a mechanical translation
of its own source. The result reproduces itself — `gen1 == gen2 == gen3`, 3328
bytes — and builds `stage1` to bytes identical to the reference build. It is not
byte-identical to the `as`+`ld` build and cannot be: that image keeps strings in
a separate `.rodata` section and page-aligns `.bss`, while `elf` writes one flat
blob, so four `adr` instructions encode a different displacement and 56 bytes of
string data sit inside the code image rather than beside it. The gate names all
four and requires that they are the only ones. Making the shas match would mean
teaching `elf` to imitate `ld`, which is the tool the exercise removes.


**License:** [MIT](./LICENSE) for Veron's own code. Upstream dependencies keep their own licenses, tracked per-node in the ledger.

---

## What Veron is

- **From-seed.** A few hundred lines of readable, bijectively-encoded, per-arch assembly (ARM64, RISC-V RV64I, x86-64) climb one rung at a time: assembler → C-subset compiler → self-hosting C → libc → GCC → GNU/Linux. The seed binary is *derived* and verified against its source by round-trip disassembly — nothing opaque is committed.
- **Hermetic + reproducible.** Every build is a pure function from hashed inputs to output, sandboxed with no network. Anyone can rebuild and diff rather than trust.
- **End-to-end auditable.** Every build *decision* — provenance, patches, flags, license — is pinned and recorded in an audit ledger. The ledger, not the package internals, is what makes the whole system auditable.
- **Two flavors, one trunk.** The tree forks exactly once, at libc: **musl/BusyBox** (minimal, maximally auditable, permissive dependency surface) and **glibc/GNU** (compatibility — official Chrome, CUDA, prebuilt blobs).

## What Veron is *not*

Veron is an independent exploration / proving-ground OS — a place to test what's buildable from a seed, not a finished product. It is self-contained and references no other project. Full scope note at the top of [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Where the ladder stands

Everything below lives under [`spikes/`](./spikes) and is a **feasibility tracer**, not Veron proper, answering one question cheaply: *can the ladder be built at all on this setup?* Nothing here should be copied into `seed/` or `stages/` without re-applying the invariants. Stage numbering below is the spike track's own.

Which invariants actually hold there is worth stating per-invariant rather than as a blanket suspension — see [`spikes/README.md`](./spikes/README.md). In short: **bijective encoding holds at stage 0** (both committed artifacts re-derived from source every push under two independent disassemblers), **hermeticity holds** (sealed box, pinned inputs, tier-1 budget empty and enforced), **the audit ledger is not built**, and **committed binaries are deliberate** rather than a lapse. Reproducibility is measured below.

| rung | what it is | state |
|---|---|---|
| `stage0-as` | two-pass mnemonic assembler, hand-written ARM64 assembly. The last tool written in raw assembly. | **self-hosting** — assembles its own source (817/817 forms); gen1 == gen2 == gen3 and gen1 rebuilds `stage1` byte-identically. Committed as a verified binary, re-checked on every push by round-trip disassembly under two independent decoders |
| `stage1-as` | two-pass numeric label resolver, written in *stage 0's own language* | **works** — gives the ladder unbounded multi-character labels |
| `stage2-pico-c` | C-subset compiler, written in *stage 1's language* | **works** — 220 KB of upstream C in, 81,893 instructions out |
| `stage3` | M2-Planet, compiled by stage 2. There is no separately-written stage 3 — M2-Planet *is* stage 3. | **hand-off proven** — our build reproduces upstream's M2-Planet **byte for byte**, stable over five generations |
| `stage4` | everything tcc is used to build: gcc, a userland, a kernel, a boot | **works** — `tcc → 4.7.4 → 10.2.0 → 15.2.0 → linux 7.1.5 → boot`, 61 min, one job. With **mc-tcc substituted** for the reference compiler the same ladder runs end to end: every rung 0–16, every phase-B rung, and **it boots** — `VERON-BOOT-OK`, 8 of 8 guest tests, and the gcc this chain produced compiling and running a program inside the kernel this chain produced |

The stage-2 → stage-3 hand-off is the sharpest single result:

```
refM2P (upstream tooling)   643257  d80317fc92ff4889
G1     (our ladder)         643257  d80317fc92ff4889
G2..G5 identical            -- stable fixpoint
```

`G0` is built from lightly patched source; every generation after it is built from upstream's **unpatched** sources, so the patch leaves the chain immediately. That G1 lands exactly on upstream's bytes is the proof.

And at the top, stage 4's end-to-end run — a gcc whose entire ancestry was built in the same process, from tcc:

```
VERON-BOOT-OK        Linux 7.1.5 aarch64
VERON-COMPILER       Linux version 7.1.5 (gcc (GCC) 15.2.0, GNU ld ...)
VERON-TESTS          pass=8 fail=0
VERON-GCC-IN-GUEST   ok compiled and ran, rc=42 (expect 42)
```

A separate box, `hermetic-gcc16`, carries the same recipe to **gcc 16.1.0 and linux v7.2-rc4**, booting with its own glibc 2.43 as PID 1.

---

## What remains for the rough draft

Two proven segments, one gap between them, and one dependency at the floor. Neither is a research question; both are measured work.

### 1. Stage 0 — stand on our own assembler

`stage0-as` and `elf` are committed as **verified binaries** (`spikes/stage0-as/stage0-as`, `spikes/elf/elf`). Git preserves the executable bit, so they run on checkout with no tool at all — `as` and `ld` have left `BUDGET_PATH`, and the `SEAL` step in `stage3-hermetic-arm64` fails the run if anything reappears. They are not trusted: `stage0-selfhost` verifies the committed artifacts on every push, against pinned binutils 2.47 **and** LLVM 22.1.8, checking that the disassembly matches the source as a plain `diff` and that the whole ELF reconstructs byte for byte. What remains at the floor is `busybox`, and it is worth stating its provenance exactly. It is **not** a borrowed binary: the tarball is pinned by version and sha256, the config is explicit, and it is compiled in the airlock before the box is sealed. It is tier 2 — it drives the build and touches no artifact byte — which is a different fact from tier 1 being empty, and the two should not be run together. What it *is*, indirectly, is host-built: the compiler that produced it is the runner's. That is the last thing in the chain of which that can be said, and the `.s0` driver in [`TRUST-BOUNDARY.md`](./TRUST-BOUNDARY.md) removes it by construction — assembled by our own committed `stage0-as` and `elf`, needing no host toolchain at all. See [`TRUST-BOUNDARY.md`](./TRUST-BOUNDARY.md) for the verification chain and why its ordering matters.

Closing this replaces `as` with the seed at the bottom of the ladder. See [`TRUST-BOUNDARY.md`](./TRUST-BOUNDARY.md) — the assembler is *untrusted* by design; the work is making that literal.

### 2. Stage 3 — reach tcc from M2-Planet

Stage 4 already **has** a tcc — pinned, patched, and used. What stage 3 owes is a tcc reached *from the seed*. Two routes are open and not in competition:

| route | state |
|---|---|
| M2-Planet → Mes → tcc | Mes rung in progress, three rungs out |
| **enhanced M2-Planet → tcc directly** | **the enhanced compiler exists.** It is called micro-c — M2-Planet at pin `bd2fe4b` plus 77 patches — and it compiles `tcc.c`, tcc's whole source *including its driver*, links a 1.63 MB aarch64 binary, and **that binary compiles and runs all twelve end-to-end programs**, all 107 applicable tests2 programs, and musl 1.2.5 entire. It compiles tcc's source *back* to an object, and that object is a **fixpoint**: gen2 == gen3 == gen4 — see below |

The direct route is the shorter one: extend M2-Planet's C subset far enough to compile real tcc, skipping the intermediate rungs entirely. The thesis behind it is that much of what the bootstrap ecosystem carries is *incidental* complexity — build plumbing, script-calling-script — rather than real capability gaps, and that the two can be separated by measuring instead of estimating. See [`spikes/stage3/ROADMAP.md`](./spikes/stage3/ROADMAP.md) for the plan and [`spikes/stage3/MICRO-C.md`](./spikes/stage3/MICRO-C.md) for the state.

It is not yet a finished tcc. A differential suite of **97 cases** stands at **96 passing on aarch64 and 94 on amd64**, with one `KNOWN GAP` and two cases skipped on amd64 where a bitfield write emits aarch64 mnemonics literally; alongside it, 419 of the 426 programs in stage 2's conformance corpus. The compiler, the emulator and the tcc tree can all be run outside CI, which is why the last several bugs took minutes rather than rounds.

Eleven codegen bugs have been closed since, and the two worth carrying up here are about method rather than about tcc. The fault was recorded for five rounds as living in `tccgen`, past where `next()` returns; it was a **member offset three functions away** — a member of an anonymous struct nested in an anonymous union resolved to offset 0, so every symbol tcc created had its token wiped immediately after it was written. A marker trail brackets between probe points; it does not point at a fault, and reading it as though it did cost those five rounds.

The second is that a test suite written *from* bugs already found measures what has been fixed, not what remains. Borrowing stage 2's 426-program conformance corpus — written for a different compiler, by someone not looking for these bugs — turned up three live codegen faults in one sitting, including an array of `char*` loading one signed byte of an eight-byte pointer. The stage-3 case suite had been green over that one every round, because every array-of-pointers case in it used `long*`, where the element width and the pointed-at width are both 8.

micro-c compiles **tcc's whole source, driver included**, and `stage3-hermetic-arm64` reports **`stage 3 end to end: yes`** — a 1.63 MB tcc built from the seed on native ARM64 inside the sealed box, answering `tcc version 0.9.28rc (AArch64 Linux)` from tcc's own driver, with all twelve end-to-end programs compiling and running, **all 107 applicable `tests2` programs matching tcc's `.expect` files**, and a self-compilation fixpoint: `gen2 == gen3 == gen4`, byte-identical. It builds musl 1.2.5 at its pinned sha256 — 1349 of 1349 sources — and drives stage 4's ladder as far as gcc 4.7.4. That number was for a long time 77 of 127 — a
number that moved from 59 mostly because the *harness* was wrong, not the
compiler: the sweep ran an aarch64 binary with no emulator, compared strictly
where tcc compares with `diff -b`, and never passed `31_args` its arguments.
Two of the remaining differences are real and named — `134_double_to_signed`
waits on floating point, `94_generic` on `_Generic` type matching.

That verdict regressed to `no` for two commits and is worth recording, because
the cause was not the compiler. The float work added `#include <float.h>` to
tccgen.c; micro-c's include set had a `math.h` and no `float.h`, and micro-c
has no system include path to fall back on, so tcc stopped preprocessing at
that line. Ten of the twelve jobs that apply the same patch series build tcc
with the host compiler and never saw it, and the local gate had never applied
the series at all — so it was compiling a *different* tccgen.c from the one CI
compiles, differing exactly where the fault was. **Closed and re-verified
green:** the header is written, the local gate now builds CI's tree, and the
airlock checks every angle-bracket include against the three directories
micro-c is actually given. See
[`spikes/stage3/MICRO-C.md`](./spikes/stage3/MICRO-C.md).

**The heap corruption is closed.** It was `sizeof` of a dereferenced *member* pointer — `sizeof(*s->tab)` returned the pointer's width, not the struct's, so `tccelf.c` allocated the symbol-attribute table at half the width its own indexing strides through, and later entries read past it into string data. One GOT relocation then resolved to a wild address and every linked binary died on its second string literal. The same construct through a plain pointer was always correct, which is why it survived: the two forms disagree only when a member sits between the star and the name.

**mc-tcc compiles tcc's own source back to an object on real ARM64**, inside
the sealed box, with no emulator: 874,610 bytes against the gcc-built control's
873,890, from a gen1 of 1,575,057 bytes. That is a change — it used to hold only
under `qemu-aarch64` and segfault natively, and the two long-double patches
(`0b07e37`, `2a8bf60`) are what moved it. Read it narrowly all the same: it is
step 1 of the five a fixpoint needs. **All five now hold**: gen2 links, runs,
builds gen3, and `gen2 == gen3 == gen4` byte-identically, objects and binaries.
micro-c's tcc is self-hosting.

The `setjmp` this section used to name as the blocker is written and in the
tree. It was the four-register micro-c one; it now saves the AAPCS64
callee-saved set as well — x19–x28, the frame pointer and the real `sp` —
because tcc's `-run` jumps into TCC-generated code, which follows AAPCS64 and
not micro-c's convention. `d8`–`d15` are still outstanding and recorded as
such: M1's macro vocabulary has no d-register load or store at all.

**The chain is continuous from hand-read assembly to a self-hosting C
compiler that builds musl, GNU make, binutils, gmp/mpfr/mpc and gcc 4.7.4.**
Rung 6 — the gcc mc-tcc produces failing to build libgcc, which stood as the
frontier for many rounds and was recorded as "a large unexplored surface,
possibly several defects wearing one hat" — was **one bug**, and not a codegen
bug: a preprocessor `#if` that expanded a macro only one level, which compiled
the addend store out of `tccelf.c` and made every `pointer = array + N` static
initialiser aim at element 0. gcc's builtin registration is table-driven, so
it died during initialisation before reading a line of source.

It was found by building a control tcc with gcc from the same source and
comparing object bytes over musl: 1175 identical, one differing by a single
byte in `.rela.data.ro`. Every case suite in the tree was green while it was
live, including the `gen2 == gen3 == gen4` fixpoint — **a fixpoint proves a
compiler is stable, not correct.**

**It boots.** The mc-tcc arm runs every rung to the end and the kernel it
built comes up under qemu: `VERON-BOOT-OK`, 8 of 8 guest tests, and
`VERON-GCC-IN-GUEST` — the gcc this chain produced compiling and running a
program inside the kernel this same chain produced.

**And it is reproducible, measured rather than asserted.** Two independent runs
of the same commit, compared byte for byte — **every artifact identical**:

| | |
|---|---|
| `cc1`, `cc1plus` — cross **and** native | identical |
| `ld`, `as`, `libc.so.6`, `busybox` | identical |
| `Image` | identical |
| `initramfs.cpio.gz` | identical |

Three defects were found and each was **one field**, not a class of problem:
gcc's own **MD5 self-checksum**, hashed over `ar` archives whose member headers
carry mtimes; a **build timestamp** in the kernel's built-in initramfs, leaking
through a `date` parse failure that `gen_initramfs.sh` swallows with `|| :`;
and `gen_init_cpio` stamping `time(NULL)` without `-t`. All three are recorded
with their evidence in [`DERIVATIONS.md`](./DERIVATIONS.md), along with the
four rounds lost to comparing runs that were not the same build.

This is same-platform reproducibility — the same inputs produce the same bytes,
every time, across the whole chain. It is not yet a `reprotest`-style claim
varying build path, locale, timezone and hostname; that distinction is stated
plainly in [`DERIVATIONS.md`](./DERIVATIONS.md).

What remains is re-applying the invariants, which the spike track suspends —
and the derivation phase in [`DERIVATIONS.md`](./DERIVATIONS.md), which turns a
green run into an auditable one.

### 3½. The bridge — what stage 4 borrows, built instead

Stage 4 already goes from a tcc to a booting Linux. Its one declared hole is
where that tcc comes from — `./configure --cc=gcc`. But its box also binds host
`/usr` and borrows binutils, make, perl, bison, flex and a libc, and its own
accounting says so plainly: *"the guarantee stage 4 currently makes is 'no host
compiler', not 'no host dependencies'."*

`stage3-to-stage4-reference` removes the rest, and **chapter 5 of Linux From
Scratch now closes**: from one static tcc to a glibc sysroot with its own
cross toolchain, in a sandbox whose entire host inventory is one busybox that
the job itself builds.

```
musl ─► make 3.82 ─► binutils 2.30 ─► make 4.4 ─► gmp/mpfr/mpc ─► gcc 4.7.4 ×2
    ─► gcc 10.2.0 ─► binutils 2.47 ─► gcc 15.2.0 pass 1 ─► perl ─► linux headers
    ─► gawk/m4/flex/bison/python ─► glibc 2.44 ─► libstdc++

CHAPTER 5 COMPLETE -- a cross toolchain and a glibc sysroot.
SEALED. 2 declared entries in /bin, both built by this workflow.
```

Chapter 6 and the boot are in progress: binutils and gcc pass 2, then busybox,
the kernel prerequisites, linux 7.1.5 and an initramfs. **Everything that ends
up in the boot artefacts is built by gcc 15 pass 2** — the compiler that was
itself built against the glibc this chain produced. `spikes/stage4/bridge/`
has the compiler table and the rung order.

musl is compiled by a shell loop because there is no make yet; make 3.82 by 27
literal commands because there is no `ld` for its configure to find; binutils by
that make; make 4.4 by that binutils. `ar` is `tcc -ar` until rung 4 produces a
real one. gcc 4.7.4 carries 4.8.5's aarch64 backend — 4.7 predates the
architecture — applied in the box as two declared patches with busybox `tar`
and `patch`.

**It proves the recipe, not the seed.** That arm's tcc is host-built and the
BUDGET step says so in every log. `stage3-to-stage4-bridge` runs the identical
script with mc-tcc and is the experiment that matters; the reference exists so
that when it fails, the failure is attributable to micro-c rather than to the
harness. Six of the first seven runs found harness bugs, not compiler bugs.

Twelve substitutions, all declared. Eleven are one thing: old GNU source
treating "not glibc" as "barely a libc" — `alloca`, `strncasecmp`, `getlogin`,
`__P`, `__ptr_t`, `__assert_fail`, `_IScntrl`. See
[`spikes/stage4/bridge/README.md`](./spikes/stage4/bridge/README.md) for the
ledger, the ordering argument against LFS's, and where the harness lied.

---

## Layout

```
seed/       readable per-arch assembly trust root (the only hand-authored root)   [empty]
stages/     the ladder: 0-seed-as → 1-macro-as → 2-pico-c → 3-full-c │ 4-libc → 5-…  [empty]
flavors/    musl / glibc instantiations (parameter files, not copies)             [empty]
lib/        the build engine: derivations, sandbox, binary cache                  [empty]
sources/    pinned upstream manifests (url + hash + signature + license)
ledger/     per-node audit records — the auditability deliverable                 [empty]
tools/      spike driver, backtrace, source-porting scripts
spikes/     the feasibility track — everything that currently runs (invariants OFF)
.github/    CI orchestration (fan-out under the 6h runner cap, cache, attest)
```

The empty directories are Veron proper and are written against the invariants. `spikes/` is the proving ground; the two are deliberately separate.

> **Note:** the `stages/` line above reflects [`AGENTS.md`](./AGENTS.md) §4, which numbers the ladder 0–5 with the flavor fork between 3 and 4. [`ARCHITECTURE.md`](./ARCHITECTURE.md) §2 currently numbers it 1–7 with no fork line. The two disagree and the disagreement is unresolved — treat neither as canonical until it is.

## Where to start reading

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the founding design: ladder, fork, audit criteria, trust boundary
- [`AGENTS.md`](./AGENTS.md) — invariants and working rules, if you are contributing
- [`spikes/README.md`](./spikes/README.md) — the live pipeline, and what each spike answered
- [`TRUST-BOUNDARY.md`](./TRUST-BOUNDARY.md) — what is trusted, what is verified, and the order that makes it a chain rather than a circle
- [`AUDIT.md`](./AUDIT.md) — the seven audit criteria and where the ledger record schema will live
- [`sources/MIRROR.md`](./sources/MIRROR.md) — the pinned-source mirror: 239 routes across 107 artifacts, every one reachable from at least two places, hash-verified on every fetch
- [`STAGE5.md`](./STAGE5.md) — the package set, and which jobs now answer its open questions: ~150 upstreams in dependency order, the five that are most of the work, networking, and the firmware-blob problem
- [`DERIVATIONS.md`](./DERIVATIONS.md) — the derivation phase: content-addressed inputs and outputs, one script for laptop and runner, the reproducibility check, and a provenance graph that expands from any installed file down to the exact commands and back to the seed
- [`spikes/builder/DESIGN.md`](./spikes/builder/DESIGN.md) — the driver shell and the bare-metal ARM64 builder: measured surface, syscall inventory, boot protocol, test targets
- [`spikes/stage3/README.md`](./spikes/stage3/README.md) — the open rung
- **Want to run it, not read it?** `sh spikes/stage3/tools/local-build.sh` builds micro-c and runs the case suite on both architectures from this repository alone, no network. Then `local-tcc.sh` compiles tcc with it, and `twelve.sh` runs the twelve end-to-end programs through that tcc — the gate that matters, and the only one that compiles tcc at all. See [`spikes/stage3/MICRO-C.md`](./spikes/stage3/MICRO-C.md) for what those scripts encode and why doing it by hand does not work
- [`spikes/stage4/README.md`](./spikes/stage4/README.md) — everything above tcc, including the end-to-end run
- `.github/workflows/stage3-hermetic-arm64.yml` — the native, sandboxed climb and its host budget
- `.github/workflows/stage0-selfhost.yml` — **yes.** `stage0-as` assembles its own source; the result reproduces itself across three generations and rebuilds `stage1` byte-identically
- [`spikes/PROGRESS.md`](./spikes/PROGRESS.md) — 150 KB of stage 0–2 history; reference only, do not load for context
