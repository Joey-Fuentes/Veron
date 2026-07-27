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

## Deferred, and deliberately so

Three pieces are understood, scoped, and **not** being built yet. They are
recorded here so that "not done" is never mistaken for "not thought about".

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

**A disassembler of our own.** See the verification chain above: it is a
replacement for binutils and LLVM in the round trip, not a second opinion, and
it is sound only because those two audited the root first. Source only, never
committed -- it is derived like everything else above the seed.

**A hand-written builder OS.** The `spikes/seedas/` end state, where the
committed artifact is hex and `stage0-as` itself becomes derived.

None of these is on the critical path to a working ladder. All three reduce what
has to be trusted. None should start before stage 0 self-hosting closes.

## Where this sits on the road to the real seed

```
was      as + ld build stage0-as and elf on every run
now      the same, but both are verified byte-for-byte against their source
next     both committed as verified binaries; as + ld leave BUDGET_PATH
end      one hand-encoded hex seed; stage0-as and elf become derived too
```

Each step removes a tier of host tooling. The round-trip machinery is what makes
the middle step trustworthy rather than a leap of faith: a committed binary
nobody can check is exactly the opaque artifact this project exists to avoid,
and a committed binary that reproduces itself from committed source, under two
independent decoders, is not.

At the end state the committed artifact is hex with the mnemonic in a comment on
each line, so there is no source-to-binary transformation left to verify and no
disassembler in the trust path at all. What remains is a human reading a few
hundred lines — which is the boundary this document has always claimed, made
literal.
