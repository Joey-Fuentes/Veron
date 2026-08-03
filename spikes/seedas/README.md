# spikes/seedas — SPIKE seed-as (feasibility tracer)

**Invariants SUSPENDED.** `seed-as.aarch64.s` is a throwaway spike: a hex0-style
loader written in one shot in ordinary ARM64 assembly and built by the GNU
assembler. It is **not** the audited, bijectively-encoded seed. It exists only
to prove that a program *we* wrote in ARM64 assembly can read input and emit a
runnable binary on our qemu-user CI setup.

## What it does

Reads stdin, keeps only hex digits (`0-9 a-f A-F`), ignores whitespace, treats
`#` as a line comment, packs each hex pair into a byte, writes the bytes to
stdout. So it turns a commented hex dump into raw bytes:

```
echo '48 65 6c 6c 6f 0a  # Hello + newline' | ./seed-as     # -> Hello
```

## See it run

Push anything under `spikes/seedas/**` and the **seedas-demo** workflow builds
it and feeds it the hex for "Hello\n", checking the output. The result is in
that run's job summary.

(Heads up on job count: a push here also triggers the generic **spike** matrix,
which will run `seed-as` with no stdin — it just reads EOF and exits 0, a
harmless build check. The **seedas-demo** run is the one that actually proves
the decoding.)

## Where this goes next

The `seed-as` that `seed/aarch64/` would carry with invariants ON is
bijectively encoded and round-trip-verified, and emits a full ELF wrapper
rather than raw bytes. That verification is the property that matters, and
`stage0-as` and `elf` already have it: committed, re-derived from their own
source on every push under two independent disassemblers, with the whole
linked ELF reconstructed and compared byte for byte. This spike deliberately skips all of that to answer one
question: *can we build an input-consuming, binary-emitting program in ARM64
assembly on this setup?* If the demo prints `Hello`, the answer is yes.
