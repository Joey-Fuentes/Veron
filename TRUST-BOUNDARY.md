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
