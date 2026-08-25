# Trust boundary

Stated honestly — this *is* criterion 6 applied to the system as a whole. Full
text in `ARCHITECTURE.md` §7. In brief:

Veron collapses the **userland** trust root to one small block of hand-read,
per-architecture assembly. It does **not** reach below that:

- The **assembler is untrusted** — its output is verified against the seed
  source by round-trip disassembly. A sliver of trust rests on the
  **disassembler**, which is small and diverse-implementable.
- The **seed is per-architecture** (x86-64, ARM64, RISC-V).
- The **Linux kernel and hardware are trusted, declared inputs.** The kernel is
  the single largest trusted component — larger than GCC. It is built
  reproducibly as a normal package but is not bootstrapped from the seed.

"From nothing" honestly means: from a few small blocks of hand-read assembly,
plus a declared, recorded trust in kernel and silicon.

---

## The verification chain, and why it is a chain and not a circle

This is the part that is easy to get backwards, so it is written down.

`.github/workflows/stage0-selfhost.yml` verifies a built binary against its own
source by disassembling it and comparing. The obvious objection is that a
disassembler built by our own assembler cannot be trusted to audit that
assembler — a Thompson-shaped circle. **The order of operations is what
defuses it.**

```
1.  binutils 2.47 and LLVM 22.1.8 verify stage0-as and elf against their source
      - two independent implementations, from different vendors, neither built
        by anything of ours
      - the WHOLE linked ELF is reconstructed from its own disassembly and
        symbol table and compared byte for byte, not just .text
      - the canonicalised source and the canonicalised disassembly are compared
        by plain `diff`, with no normaliser deciding what counts as equal
2.  those verified binaries build everything above them, including any
    disassembler of our own
3.  our disassembler verifies things thereafter
```

By the end of step 1 the assembler is known to correspond exactly to
human-readable source. A subverted `stage0-as` would have had to carry its
subversion **visibly in the disassembly** — and the disassembly is
character-identical to the source under two decoders from different vendors. It
could not have passed step 1 while hiding anything, so a disassembler it then
builds is not subverted by construction.

Successor-verified-by-predecessor is sound **only because the root was audited
independently first.** If that ordering is ever lost — if a future change
verifies stage0-as using a disassembler stage0-as built, without an external
check having established the root — the chain becomes a circle and the
guarantee evaporates. Do not reorder these steps.

### What our own disassembler is for

It is a **replacement**, not a second opinion. Once it exists the round-trip can
run with `BUDGET_PATH` empty, which is the goal; binutils and LLVM are how we
get there, not a permanent dependency of the build.

They remain worth running as a **periodic independent re-audit**, because they
are the only thing that can catch a defect introduced at the root itself. That
is cheap — both are pinned and cached — and it matters whenever the root moves,
not on every run.

## What must be committed, and what must not

**A raw executable, not hex.** Git preserves the executable bit, so a committed
ELF is run by the kernel's own loader on checkout and needs no tool at all. A
committed hex file is inert until something converts it, and that converter is
precisely the host dependency being removed.

No commented-hex artifact is committed alongside, because there is nothing for
one to add. `stage0-posix` commits hex because **hex is its source language** --
its assembler reads it. Veron's source is ARM64 assembly with mnemonics, labels
and comments, which is what a person reads; a hex rendering would be strictly
less legible and one more file to keep in sync.

The comparison is worth stating precisely, because it is easy to get the wrong
way round. `builder-hex0`'s own README concedes that you must trust the hex
codes represent the opcodes in the comments -- the correspondence there is
**assumed**. Here it is **verified**: two independent disassemblers prove the
committed bytes decode to exactly the committed source, and two independent
assemblers prove that source produces exactly those bytes. A human never audits
an encoding; they read a program and judge whether it is correct, which is the
only part of the job a human is good at.

Byte count is not a meaningful axis of comparison. It would be if the reader had
to decode the bytes, which is their situation and not ours. And the layers are
not equivalent: hex0 is a hex decoder, and reaching what `stage0-as` does --
mnemonics, labels, a symbol table -- takes hex0 -> hex1 -> hex2 -> M0/M1 there,
every rung of which is also a thing a human must audit.

Only the binaries that host tools produce need committing and round-tripping:

```
committed + verified   stage0-as, elf
derived, not committed stage1, stage2, M2-Planet, any disassembler of ours,
                       and everything above them
```

`stage3-hermetic-arm64` runs exactly four host-tool commands, and two of them
are for `elf`. **Committing a verified `stage0-as` while `elf` still needs `as`
and `ld` does not move `BUDGET_PATH` at all.** It is both or neither.

Everything above those two is reproducible from committed `.s0`/`.s1` source by
a verified toolchain, and `spikes/stage0-as/LADDER-BASELINE.txt` already checks
that it rebuilds identically. A disassembler written in `.s0`, or in stage 2's C
subset, is in that category: source only.

## What self-hosting does and does not claim

`stage0-as` assembles a mechanical translation of its own source, and the result
is a fixpoint: `gen1 == gen2 == gen3`, 3328 bytes, `18a1c7e0004359bb`. `gen1`
then rebuilds `stage1` to bytes identical to the reference build.

It is **not** byte-identical to the `as`+`ld` build, and the difference is
structural rather than a defect:

| | as+ld | .s0 build |
|---|---|---|
| strings | `.rodata`, a separate section | inline, 8-aligned after the code |
| `.bss` | page-aligned to `0x411000` | straight after the strings |
| image | 176-byte prefix, section headers | 120-byte header, one flat blob |

So `reference.bin` is 3268 bytes of pure `.text` and `gen1.bin` is 3328 -- the
same code plus 56 bytes of string data and 4 of alignment -- and within the
shared 3268 exactly four words differ, all `adr` into `.bss`. The gate names
each one and fails if the count or the targets change.

Making the two match would mean teaching `elf` to reproduce `ld`'s layout: a
176-byte prefix, a separate `.rodata`, a page-aligned `.bss`. That would make
the self-hosting claim depend on imitating the tool the ladder exists to remove,
which is the wrong direction. The claim that matters is behavioural and it is
checked: an assembler that reproduces itself across three generations and
rebuilds the ladder to identical bytes is the same assembler.

## Deferred, and deliberately so

Three pieces are understood, scoped, and **not** being built yet. They are
recorded here so that "not done" is never mistaken for "not thought about" --
and so that none of them is mistaken for a gap being patched. Each narrows the
set of things this project depends on to things this project wrote. None of
them removes a host dependency, because there is no host binary in the box to
remove.

**A driver written in `.s0`, replacing busybox.** `BUDGET_DRIVER` is the last
non-empty tier. Measured, the in-box script needs a real shell today -- 27
pipes, 18 command substitutions, 29 conditionals -- but almost all of that is
reporting and verification, not building. Move the checking outside the box and
what remains is: run a program with args, redirect stdin and stdout, run in
sequence, abort on a non-zero exit. That is `kaem`'s feature set: roughly
200-300 ARM64 instructions, needing `open`, `close`, `read`, `dup3`, `clone`,
`execve`, `wait4` and `exit`.

The property that makes it worth doing this way: written in `.s0` it is
assembled by our own committed `stage0-as` and `elf`, so it needs no host
toolchain to produce and does not wait on tcc. It becomes a third committed,
round-trip-verified artifact and `BUDGET_DRIVER` goes empty. Do the
verification-moves-out-of-the-box refactor first -- it measures the exact
command list rather than estimating it, and it is a pure refactor.

**MEASURED, AND THE ESTIMATE ABOVE IS TOO OPTIMISTIC AS THE SCRIPTS STAND.**
`shell-surface.sh` counts what the in-box scripts actually use. The reporting
refactor is real -- it removes 82% of pipelines and 73% of command
substitutions, and commands split about four to one -- but what survives is not
kaem-shaped: 276 conditionals, 209 short-circuits, 161 output redirects, 135
globs, 71 loops, 21 here-documents, 19 `case`.

Driving only as far as **busybox** is a different and much smaller question,
and is the plan. See [`spikes/builder/DESIGN.md`](spikes/builder/DESIGN.md) for
the full measurement, the kaem comparison, the language decision and the
syscall inventory.

**A disassembler of our own.** See the verification chain above: it is a
replacement for binutils and LLVM in the round trip, not a second opinion, and
it is sound only because those two audited the root first. Source only, never
committed -- it is derived like everything else above the seed.

When it lands, the round trip runs on **our assembler, our ELF writer and our
disassembler, and nothing else**. binutils and LLVM stop being a per-push
dependency and become a one-time recorded root audit, pinned to the artifact
hashes they actually examined -- so if `stage0-as` or `elf` change, that audit
no longer covers them and has to be redone. The attestation format in
[`DERIVATIONS.md`](DERIVATIONS.md) carries both lines for exactly that reason:
dropping the root line would make the chart a circle, and running the host
decoders every push would understate what the seed can do on its own.

**A hand-written builder OS.** The end state of the item above: our own shell
and our own tools, in this tree, so that the box is built entirely out of
things this project wrote. Design, including a bare-metal ARM64 image that
boots under QEMU and on hardware, is in
[`spikes/builder/DESIGN.md`](spikes/builder/DESIGN.md).

**A CORRECTION, DATED 2026-08-25, ABOUT WHERE THE ABOVE WAS TRUE.** It was
true of the spike workflows that assembled a box. It was NOT true of the
numbered stage 1-3 jobs: `1-self-assembly-verify`, `2-pico-c-verify`,
`3-micro-c-build` and `3-cross-amd64` ran their scripts on the bare runner,
and the scripts -- extracted from the sealed spike with the seal left
behind -- leaned on GNU patch (with fuzz), GNU tar, GNU sed, coreutils and,
for the x86_64 musl, the runner's `make`, none of it enumerated. The first
host that held the scripts to the stated budget was a Veron image, whose
`patch` is busybox. The fix is structural, not a list of substitutions:
`stages/box.sh` runs each stage script INSIDE `bwrap` with `PATH=/box/bin`
holding busybox and, off-aarch64, `qemu-aarch64-static`, both by hash in
`out/box/BUDGET`; a script that says `make` now fails "not found". musl is
built by hand from its Makefile's own rules (relative paths -- the
make-driven build had written each host's absolute source path into every
object, three hosts, three `libc.a` digests, one compiler). tcc is the
pristine pin plus one strict patch plus two files we write or generate and
re-prove per run; the pre-configured toolbox tarball is gone. Same
`box.sh`, same scripts, same busybox bytes on CI, on Veron and on any
Linux: the records are the proof the host did not matter.

Tier 2 is **substitutable, recorded, non-load-bearing**: the artifacts are
a function of the seed, the pinned sources and the scripts, not of which
busybox moved the bytes, so a foreign busybox is recorded rather than
refused -- a different driver reproducing the same records is the claim,
proven.

**READ THAT LAST SENTENCE CORRECTLY, IN BOTH DIRECTIONS.**

busybox is not a borrowed binary. It is fetched as pinned source, verified
against a recorded sha256, configured explicitly, and COMPILED in the airlock
before the box is sealed. Nothing prebuilt is lifted off the runner.

It is also not the reason tier 1 is empty. Tier 1 is empty because nothing on
the BUILD PATH comes from the host -- every artifact byte is produced by tools
derived from `stage0-as`. busybox is tier 2 because it touches no artifact
byte. Two separate facts, and running them together overstates both.

What busybox IS, precisely: **indirectly host-built.** The source is ours to
choose and pinned; the compiler that turned it into a binary is the runner's.
That is the last thing in this chain of which that can be said, and it is
worth saying plainly rather than leaving a reader to find it -- a budget claim
is only as good as its own account of what it still owes.

The `.s0` driver above closes it by construction, not by argument: assembled
by our own committed `stage0-as` and `elf`, it needs no host toolchain to
produce and becomes a third round-trip-verified artifact. `BUDGET_DRIVER` goes
empty. That is what replacing busybox is for -- not repairing a borrowed
dependency, because there is no borrowed binary, but ending the last indirect
reliance on a compiler this project did not build.

None of these is on the critical path to a working ladder. All three reduce what
has to be trusted. None should start before stage 0 self-hosting closes.

## Where this sits

```
was      as + ld build stage0-as and elf on every run
now      both committed as verified binaries; as + ld have left BUDGET_PATH,
         and every push re-derives them from their own source under two
         independent decoders
```

Each step removed a tier of host tooling, and the round-trip machinery is what
makes the current arrangement trustworthy rather than a leap of faith: a
committed binary nobody can check is exactly the opaque artifact this project
exists to avoid, and a committed binary that reproduces itself from committed
source — disassembled by binutils 2.47 *and* LLVM 22.1.8, diffed against that
source as plain text, with the whole linked ELF reconstructed and compared byte
for byte — is not.

That verification is mechanical and repeats on every push. It is a stronger
property than a one-time human reading, not a substitute for one, and the
boundary this document claims is met by it.

The nine steps are designed as a single citable block in
[`DERIVATIONS.md`](DERIVATIONS.md) -- artifacts, sources, both decoders, both
assemblers, the round trip and the self-host fixpoint, reduced to one twelve
character attestation hash, with `--script` emitting a runnable copy so a third
party can redo it without trusting anything here.
