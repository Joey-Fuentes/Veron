# The driver and the builder — design

Two related pieces, neither built yet, both scoped here so the decisions are
recorded rather than re-derived.

1. **The driver** — the shell that replaces busybox's shell role inside the box.
2. **The builder** — a bare-metal ARM64 image that boots, provides a minimal
   POSIX surface, and runs the driver with no Linux underneath.

They are separable. The driver is useful on its own under Linux. The builder is
what makes the driver's environment ours as well.

---

## Part 1 — the driver

### What it is for, stated precisely

**Not** to replace busybox. The ladder needs busybox's applets — `sed`, `grep`,
`tar`, `head` appear throughout `rungs.sh` — and a hand-written shell cannot
substitute for those.

It exists to remove the **host compiler** from busybox's provenance. busybox is
already not a borrowed binary: pinned source, explicit config, compiled in the
airlock. But the compiler that compiles it is the runner's. The driver's job is
to run early enough that `mc-tcc` builds busybox instead:

```
stage0-as → elf → driver(.s0) → mc-tcc → busybox → the rest of the ladder
```

After that the chain has no host compiler at any point.

### How big the surface is — measured

`spikes/stage4/bridge/shell-surface.sh` counts constructs in the in-box scripts
with comments stripped. Strip comments first: these files are 6396 lines of
which 3049 are code, and raw counting scored 177 backticks that collapsed to 9
once prose was removed.

A construct on a line mentioning a reporting command counts as reporting, so
the last column is a **lower bound** on what a driver must implement:

```
construct                      all  reporting  REMAINING
conditionals   if              304     28        276
logical        && ||           295     86        209
redirect out   >               202     41        161
glob           *               191     56        135
fd redirect    2>&1            154     34        120
loops          for/while        74      3         71
pipelines      |               380    310         70
cmd subst      $( )            217    158         59
subshell       ( )              35      5         30
here-doc       <<               22      1         21
case           case             19      0         19
arithmetic     $(( ))           24     10         14
```

Commands split about four to one — 1353 reporting invocations against 307
building ones. `say` alone is 546.

**Conclusion: driving the whole ladder is not kaem-shaped.** The reporting
refactor removes 82% of pipelines and 73% of command substitutions, but 135
globs, 71 loops, 19 `case` and 21 here-documents survive. Writing that in `.s0`
means implementing a substantial shell in assembly.

**Driving only as far as busybox is a different question**, and that is the
plan. Compiling a fixed list of C files needs: run a program with args,
redirect stdout/stderr, run in sequence, abort on non-zero. Rung 2 already
builds musl this way with no make at all, and make 3.82 by 27 literal commands.

### kaem as the reference point

`spikes/reference/mescc-tools/Kaem/kaem.c` is 1504 lines of ordinary C.

- **Syscalls used:** `fork`, `execve`, `waitpid`, `chdir`, `write`, `exit`. Six.
- **Builtins:** `cd`, `pwd`, `set`, `unset`, `echo`, `alias`, `exec`, and
  `if`/`then`/`else`/`fi`.
- **Not present:** redirection, pipes, globbing, command substitution, loops,
  `case`.

Measured against our residual: `if` and `cd` fit; redirection, pipes, globs,
loops, `case` and `$( )` do not. Redirection is the cheap gap — `openat` +
`dup3` + `close`, roughly forty lines. Loops and globs vanish if the command
list is **generated flat**, which is how live-bootstrap works and how the repo
already builds make 3.82.

### Language: `.s0` or C

The `.s0` route buys removing `mc-tcc` from the driver's provenance. `mc-tcc`
is already seed-derived, so the gain is small and the cost is large.

**Recommendation: C first, `.s0` only if it proves necessary.** A kaem-shaped
driver in C is ~1500 lines that `mc-tcc` compiles today. If it is later written
in `.s0`, it is assembled by our own committed `stage0-as` and `elf`, becomes a
third round-trip-verified artifact, and `BUDGET_DRIVER` goes empty.

### Syscall vocabulary — status

Of the twelve a driver needs, **eleven are already encoded** in
`m2libc/aarch64`:

```
mkdirat 34   unlinkat 35  chdir 49   openat 56  close 57  read 63
write 64     exit 93      clone 220  execve 221 wait4 260
dup3 24 ....................................................... MISSING
```

Note the `at`-suffixed forms. aarch64 has no bare `open`, `mkdir` or `access`;
handlers take `AT_FDCWD` as an argument x86's do not.

`fork` may not be needed at all. It exists so a shell can outlive a child. A
flat command list with no error recovery can `execve` in place — no process
table, no `waitpid`, no address-space copy.

---

## Part 2 — the builder

### What builder-hex0 actually is

The x86 reference (`rick-masters/builder-hex0`), read rather than recalled:

- A bootable disk image under 4K, ~2600 lines of commented hex.
- A minimal 32-bit x86 POSIX kernel with a memory filesystem.
- An internal shell with three builtins: `src`, `hex0`, `f`.
- Loads and runs 32-bit ELF programs.

**Its fourteen syscalls**, plus one rule:

```
exit  fork  read  write  open  close  waitpid  execve
chdir lseek brk   access mkdir getcwd
+ unimplemented syscalls return success
```

That last line does the most work in the design — it is how fourteen handlers
pretend to be a kernel.

### What does not port

A large fraction of that image is x86 legacy with no ARM64 equivalent:
`setcs`, the GDT block, `check_a20`/`init_no_a20`, `e820lp`, `setup_32bit`, the
16-bit console and disk routines on BIOS `int 0x10`/`int 0x13`, and the MBR
alignment around `past_MBR`. ARM64 starts in 64-bit mode with no BIOS and no
descriptor tables.

Two of the three shell builtins also go: `src` reads source off disk into the
memfs, and `f` writes `/dev/hda` back. Neither is meaningful when the source
arrives in memory.

**So the ARM64 image is smaller in scope than the x86 one**, not larger.

### The single design constraint: parse the DTB, hardcode nothing

QEMU `-kernel` and U-Boot `booti` both implement the Linux ARM64 boot protocol:
a 64-byte header with magic `ARM\x64` at offset 56; entry with MMU off and
D-cache off; **x0 = physical address of the DTB**; secondaries parked.
Implement that header and one image loads under emulation and on hardware.

Read from the DTB rather than assumed:

- **RAM base and size** — `/memory` `reg`. `virt` is `0x40000000`; boards differ.
- **UART base** — `/chosen` `stdout-path`, or the first `compatible = "arm,pl011"`.
  `virt` is `0x09000000` and is that nowhere else.

FDT is big-endian: header, struct block, strings block. Finding two nodes and
one property is a few hundred instructions. That is the price of "one image,
both worlds".

### Three things that will bite

**EL level differs by target.** `virt` enters at EL1; `virt,virtualization=on`
and most U-Boot setups enter at EL2. Read `CurrentEL` and drop to EL1 if
needed — about 20 instructions, and skipping it means working on exactly one
of the two targets.

**MMU off is not a viable steady state.** With the MMU off all memory is
Device-nGnRnE: uncached, and **unaligned accesses fault**. For a system running
a compiler that is not "slower", it is unusable, and the alignment faults will
present as random corruption in the hex parser. Bring up a minimal identity
map early — one L1 table with a few 1GB block descriptors marking RAM as Normal
cacheable, roughly 40 instructions.

**Cache maintenance becomes mandatory once the MMU is on.** The builder
compiles code into memory and jumps into it. x86 has a coherent instruction
cache and gets this free; ARM64 does not. Every buffer written and then
executed needs `dc cvau` / `dsb ish` / `ic ivau` / `dsb ish` / `isb`. Omitting
it produces intermittent stale-instruction faults, which are expensive to
diagnose because they look like miscompilation.

### Source language: `.s0`, not hex

builder-hex0 is written in hex0 because stage0-posix's trust root **is** hex —
its assembler reads hex. Veron's root is readable ARM64 assembly with mnemonics
and labels, verified by round-trip disassembly under two independent decoders.

`TRUST-BOUNDARY.md` already makes the comparison: builder-hex0's README
concedes you must trust that the hex represents the opcodes in the comments —
the correspondence there is **assumed**; here it is **verified**, and once the
disassembler lands it is verified by our own tools with no host decoder in the
loop.

Writing the ARM64 builder in hex would discard the one place this project is
already ahead. It should be `.s0`, assembled by `stage0-as`.

### Test targets

Two emulated machines, chosen so a hardcoded assumption fails immediately:

| | `-M virt` | `-M raspi3b` |
|---|---|---|
| RAM base | 0x40000000 | 0x00000000 |
| UART | PL011 @ 0x09000000 | PL011 @ 0x3F201000 |
| entry EL | EL1 | EL2 |

That covers low-vs-high RAM, two UART addresses, and both entry levels. Cheaper
variants for narrower checks: `-m 512M` vs `-m 4G` for size assumptions,
`-M virt,virtualization=on` to flip entry to EL2 with one flag, `-smp 4` if
secondaries are ever touched.

**Hardware: Raspberry Pi 4B or Pi 400.** SoC UART memory-mapped directly at
`0xFE201000`; boots to EL2 from SD via `config.txt` + `kernel8.img`; no signing.
Pi 3B+ is a reasonable first target since QEMU models `raspi3b` most
faithfully.

**Not the Pi 5.** It boots through RP1, a separate southbridge over PCIe that
owns the peripherals including the UART. Bare metal there means bringing up a
PCIe link before printing a character.

**Alternative: Rockchip RK3399** (RockPro64, Pine64). U-Boot `booti` is exactly
the boot protocol above, with no Pi-specific `kernel8.img` convention, and
`tftpboot` avoids reseating an SD card per iteration.

**Not VirtualBox.** No ARM64 guest support on x86 hosts; the Apple-silicon
builds run x86 guests. It never runs the image.

### Practical ordering

1. Serial first — USB-TTL adapter and a terminal, before anything else. On the
   Pi that is GPIO 14/15 plus `enable_uart=1`. Without it, debugging is by LED.
2. Network or TFTP boot early. Moving an SD card per iteration dominates
   iteration time within a day.
3. `virt` until the DTB parse and EL drop are solid, then a second machine, then
   hardware.

---

## What this does and does not claim

The builder addresses a **different trust axis** from the budget. Tier 1 being
empty is a statement about the build path — no host compiler touches an
artifact byte. The builder removes the kernel and userland from the trust base
as well. Neither subsumes the other, and the budget claim does not depend on
the builder existing.
