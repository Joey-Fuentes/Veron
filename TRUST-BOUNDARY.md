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
