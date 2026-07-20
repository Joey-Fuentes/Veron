# seed/ — the readable trust root (per architecture)

The only hand-authored root of the entire system: the stage-0 assembler
(`seed-as`), written in readable, **bijectively-encoded** assembly, one file
per CPU architecture. **No binaries are committed here or anywhere in the
repo** — the seed binary is *derived* by an (untrusted) assembler and confirmed
against this source by round-trip disassembly.

- `aarch64/` — reference arch; fixed 4-byte encoding, cleanest round-trip. **Written first.**
- `riscv64/` — seed restricted to **RV64I base** (no compressed); the OS target is **RV64GC**.
- `x86_64/`  — canonical encodings pinned by hand (variable-length ISA).

Each arch dir will hold:
- `seed-as.S`      — the committed root: commented, one-instruction-per-line assembly
- `seed-as.hash`   — pinned digest of the derived binary (reproducibility target)
- `roundtrip.sh`   — assemble → disassemble → diff against `seed-as.S`
- `AUDIT.md`       — signed source-read + round-trip audit record

See `ARCHITECTURE.md` §2 (ladder), §7 (trust boundary).
