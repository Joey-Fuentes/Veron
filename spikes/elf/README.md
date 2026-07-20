# spikes/elf — SPIKE elf tool, toolkit tool #2 (feasibility tracer)

**Invariants SUSPENDED.** Written in ARM64 assembly, built by GNU `as`. Wraps
raw code bytes in a minimal, runnable, static ELF.

```
program.s | stage0-as | elf OUTPATH        # -> a runnable executable file
```

Reads raw code bytes on stdin, writes a complete ELF executable to the path
given as its argument, and **sets the file executable itself** (`openat` mode
0755 + `fchmod`) — so the output runs with no host `chmod`. This is why it takes
an output *path* instead of writing to stdout: a tool can only set the mode on a
file it creates.

Header = the fixed 120-byte template proven by `elf-proto`; only `p_filesz` and
`p_memsz` are patched at runtime (= 120 + code length). Entry is the constant
`0x400078`.

Run with no output path (e.g. by the generic spike harness) → harmless exit 0.

## See it run

Push under `spikes/elf/**` → the **elf-demo** workflow builds `stage0-as` and
`elf`, pipes an `exit(42)` program through the whole pipeline, and runs the
result — expecting exit 42 and an executable file, with no `chmod` anywhere.

## Where this puts us

The toolkit now goes text -> bytes -> runnable:
`stage0-as` (mnemonics -> code) + `elf` (code -> executable). What's still
missing before real programs: **labels** (jumps / data references) and more
instructions. Those fold into `stage0-as` next.
