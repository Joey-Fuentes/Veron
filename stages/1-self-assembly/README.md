# stages/1-self-assembly — THE TRUST ROOT

**Stage 1 Self-Assembly.** The first stage of the ladder — not before the
beginning, the beginning. Two artifacts, each committed as source **and** as
a verified binary; nothing above this stage exists without them, and nothing
built them but themselves.

| artifact | source | what it does |
|---|---|---|
| `self-assembler-arm64` | `self-assembler-arm64.s` | two-pass mnemonic assembler: assembly in on stdin, raw ARM64 code bytes out on stdout. Assembles a mechanical translation of its own source: gen1 == gen2 == gen3 |
| `elf-wrapper-arm64` | `elf-wrapper-arm64.s` | wraps raw code bytes in a minimal, runnable, static ELF (one PT_LOAD, two size fields patched). **Not a linker** — no sections, no symbols, no relocation |

The pipeline every later stage stands on:

```
program.s | self-assembler-arm64 | elf-wrapper-arm64 OUT   && ./OUT
```

## The committed binaries are verified, not trusted

Per AGENTS invariant 1 (as amended — "no *unverified* binaries"): the
committed binaries are **gen1/elfgen1**, the ones the ladder builds from its
own translated source — never the `as`+`ld` build, which serves only as the
readable-symbol reference for the bounded diff. `rebaseline.sh verify`
re-derives both on every push (workflow `1-self-assembly-verify`) and fails
if either committed byte differs. `rebaseline.sh derive` is the maintainer's
tool for producing new committed candidates after a deliberate source change
— always its own commit, so a hash change is attributable to exactly that
change (design doc D2, the re-baseline rule).

## Lineage

Redone from `spikes/stage0-as` + `spikes/elf` under design doc §7.0 — the
spike originals are untouched and still guarded by their own workflow. The
only byte-affecting differences from the spike pair are the renamed embedded
strings and their three length immediates (`0x22→0x27`, `0x15→0x1a`,
`0x1d→0x25`); everything else that changed is comments. The spike tree
remains the read-only oracle for the regression gate.

Per-arch siblings (`self-assembler-riscv64.s` — RV64I base only,
`self-assembler-x86_64.s` — canonical encodings pinned by hand) land here
when written; until then, non-aarch64 targets reach Stage 1 through the
declared cross (`policy/arches.toml`, design doc §3.4).

## Two verifications, one mandatory home

| script | needs | when |
|---|---|---|
| `rebaseline.sh` | python3 + (qemu on non-aarch64) — **no toolchain** | **required**: derives and gates the committed binaries; everything stage 1 outputs comes from this path |
| `roundtrip.sh` | one network fetch, ~15 min cold (cached): binutils 2.47 built from source, LLVM 22.1.8 prebuilt release | **optional locally, mandatory in CI** on every change under `stages/1-self-assembly/` — the deep proof that source matches binary under two pinned independent decoders |

The round-trip checks, by their real names (the shared engine still prints
its spike-era letters until cutover): **reassemble** (A — the disassembly
denotes the same machine code), **reconstruct** (A2 — the whole ELF rebuilds
from its own disassembly), **readback** (B — a reader of the disassembly
reads the source), **crosscheck** (C — the two decoders agree with each
other), **plain-diff** (E — canonical source equals canonical disassembly
under plain `diff`).
