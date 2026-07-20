# spikes/stage0-as — SPIKE stage-0 assembler, tool #1 (feasibility tracer)

**Invariants SUSPENDED.** This is the first tool of a small stage-0 *toolkit*.
Rather than one monolithic assembler, stage 0 is being built as several tiny,
independently-testable programs that pipe together:

```
program.s0  --[stage0-as]-->  raw code bytes  --[labels]-->  resolved  --[elf]-->  runnable
             (this tool)                        (next)                  (next)
```

## stage0-as (this tool)

Reads a line-oriented assembly program on stdin, emits the raw 4-byte
little-endian machine word for each instruction to stdout. Supported now:

```
mov x<reg> <decimal-imm>     # MOVZ
svc                          # SVC #0
# lines starting with '#' are comments; leading spaces are fine
```

No labels and no ELF wrapper yet — those are the next two tools. This one just
proves *text mnemonics -> correct machine-code bytes* on our setup.

## See it run

Push anything under `spikes/stage0-as/**` and the **stage0-as-demo** workflow
builds it, feeds it a small `mov`/`svc` program, and checks the output bytes are
byte-identical to the encodings we hand-derived in the round-trip work. It also
disassembles the output so you can see it decode back to the instructions.

(Job-count note: a push here also triggers the generic **spike** matrix, which
runs `stage0-as` with no stdin — it reads EOF and exits 0, a harmless build
check. The **stage0-as-demo** run is the one that proves the assembler works.)

## Next

- `labels` tool — resolve `:label` / references (the gap the `adr` line exposed).
- `elf` tool — wrap raw bytes in a minimal static ELF so output runs directly.
- then higher stages get *written* in this language instead of hand-encoded.
