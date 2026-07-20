# spikes/elf-proto — SPIKE ELF header prototype (throwaway)

**Invariants SUSPENDED. Throwaway.** This is *not* the real `elf` tool. It is a
one-off whose only job is to pin down the exact bytes of a minimal, static,
AArch64 ELF64 executable and prove the kernel/QEMU runs it. Once green, these
field values become the template for the real `elf` tool, which will emit the
same header in ARM64 assembly.

`elf_proto.py` builds:

```
[ ELF header 64B ][ PT_LOAD program header 56B ][ code payload ]
```

with the single loadable segment mapping the whole file at `0x400000`, so the
entry point is `0x400078`. The payload is `exit(42)`, so the check is
unambiguous.

## See it run

Push under `spikes/elf-proto/**` → the **elf-proto** workflow runs the script,
shows `file` / `readelf -h` output, runs the ELF under `qemu-aarch64`, and
checks the exit code is 42.

Locally the ELF's *structure* is already confirmed valid by `file` and
`readelf` (ELF64, LSB, EXEC, AArch64, entry 0x400078). CI confirms the
remaining unknown: that it also *executes*.

(Job-count note: this has no `*.aarch64.s` file, so the generic **spike**
matrix won't run it as a spike — but a push under `spikes/**` still re-triggers
that matrix over the existing spikes. Harmless.)

## Next

Reproduce this exact header in ARM64 assembly as the real `elf` tool: read raw
code bytes on stdin, prepend the 120-byte header (patching `e_entry`,
`p_filesz`, `p_memsz` for the actual code length), write a runnable ELF to
stdout. Then: `program.s | stage0-as | elf > a.out` and it runs.
