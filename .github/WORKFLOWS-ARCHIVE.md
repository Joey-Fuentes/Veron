# Archived workflows

These are in `.github/workflows-archive/`. GitHub only executes
`.github/workflows/`, so they no longer run -- but they are still here, still
readable, and one `git mv` from being restored.

## Why they were archived

Most were spikes: built to answer one question, kept running long after it was
answered. Fifty-five workflows fired on a `spikes/**` push, thirty of them on
every commit to the seed, and **three of them carried the signal**. A CI board
that is mostly red for reasons nobody is acting on is worse than no CI board,
because a real regression arrives looking exactly like the noise -- which is
what happened: thirteen of these had been failing on a stale
`M2libc/bootstrap.c` path for weeks and nobody was reading them.

**The finding is the artifact, not the YAML.** An experiment that has produced
its answer does not need to keep running; it needs its answer written down.

## Still running

| workflow | what it gates |
|---|---|
| `stage3-hermetic-arm64.yml` | the whole ladder, sealed box, native ARM64, byte-matched against upstream M2-Planet |
| `stage0-selfhost.yml` | the committed seed binaries: round-trip disassembly under two decoders, whole-ELF reconstruction, form probes, staleness gate |
| `spike.yml` | the generic spike runner |

Plus twelve upper-rung workflows (gcc, tcc, mes) that do not fire on
`spikes/**` and belong to stages not yet on the critical path.

## Archived, and what each one established

- **`aarch64-reference.yml`** -- SPIKE. ARE WE CHASING A GHOST? Everything we have blamed on stage 2 assumes the setup underneath works. That
- **`armhf-probe.yml`** -- Probe: can GitHub's arm64 runners execute 32-bit ARM (armhf / AArch32 EL0) NATIVELY? Why this matters: the "armhf-Mes detour" to reach a native-ish aa
- **`bench-codegen.yml`** -- SPIKE (invariants suspended). WHERE IS THE 1000x GOING? Our stage2-built M1 processes ~50 input bytes/sec: 768 read syscalls in 15s,
- **`borrow-m2-demo.yml`** -- SPIKE (invariants suspended). Proof-of-concept that the known no-host bootstrap toolchain runs on THIS setup, targeting aarch64:
- **`borrow-tcc-demo.yml`** -- SPIKE (invariants suspended). Re-cut of Part A on the NON-DEBUG path. The previous cut built an aarch64 M2-Planet with --debug + blood-elf + the
- **`borrow-tcc-native.yml`** -- SPIKE (invariants suspended). Self-host M2-Planet on aarch64 and run the result on a NATIVE arm64 runner (no QEMU). The qemu-user run segfaulted
- **`elf-demo.yml`** -- SPIKE elf demo (invariants suspended). Proves the whole toolkit pipeline: mnemonics --[stage0-as]--> code bytes --[elf OUTPATH]--> runnable file
- **`elf-proto.yml`** -- DIAGNOSTIC run. The hand-built ELF exited 1 with no signal; this workflow finds out why by (1) running a real ld-linked exit(42) binary to prove QEMU
- **`gcc-backend-backport-probe.yml`** -- SPIKE. CAN gcc 4.8's AARCH64 BACKEND BE MOVED BACK INTO gcc 4.7? WHAT gcc-entrypoint-probe SETTLED. On aarch64 the two boundaries coincide:
- **`gcc-chain-probe.yml`** -- SPIKE. HOW MANY gcc STEPS DOES THE CHAIN ACTUALLY NEED? WHAT IS ALREADY SETTLED (tcc-aarch64-probe):
- **`gcc-entrypoint-probe.yml`** -- SPIKE. WHERE CAN OUR CHAIN ENTER gcc ON AARCH64? WHAT gcc-chain-probe TURNED UP. Building gcc 4.7.4 on aarch64 dies at
- **`hermetic-enumerate-host.yml`** -- ============================================================================ WHAT DOES THE HOST STILL SUPPLY?  An enumeration, not a rung.
- **`hex2-bisect.yml`** -- SPIKE (invariants suspended). Isolate the construct in mescc-tools' hex2_linker.c that segfaults stage 2.
- **`livebootstrap-pass1.yml`** -- SPIKE (invariants suspended). Runs the FIRST stage of the established no-host bootstrap (live-bootstrap) on our runner, under bubblewrap, on amd64.
- **`livebootstrap-pins-probe.yml`** -- SPIKE. WHICH live-bootstrap commit pairs with OUR M2-Planet pin? We pinned M2-Planet to 1.13.1 (bd2fe4b) and mescc-tools to 5adfbf3 for the
- **`m1-loop.yml`** -- SPIKE. Correcting the previous diagnostic. WHAT WE KNOW. Our M1 opens tiny.M1, reads its six bytes one at a time, and
- **`m2-tcc-gap-probe.yml`** -- WHAT C DOES tcc NEED THAT M2-PLANET DOES NOT HAVE? This is leg 1's measurement spike, and it exists because the roadmap's own
- **`m2libc-113-bisect.yml`** -- SPIKE. Our stage 2 at the 1.13.1 pin -- BOTH ARMS, on the same artifact. THE COMPARISON IS SELF-COMPILATION, not a sample program. Upstream's
- **`mes-rung-recon.yml`** -- SPIKE. WHAT DOES BUILDING MES ACTUALLY REQUIRE? The pins are settled (livebootstrap-pins-probe, outcome 1): live-bootstrap
- **`mescc-tools-full.yml`** -- SPIKE (invariants suspended). RUNG B: our three tools work as a TOOLCHAIN. no-host-chain proved stage 2 can build M1 and hex2. This goes one further a
- **`no-host-chain.yml`** -- SPIKE (invariants suspended). THE FIRST NO-HOST-GCC ROUND TRIP. borrow-m2 built M2-Planet, M1 and hex2 with the HOST gcc; it only ever proved
- **`qemu-mmap-probe.yml`** -- SIDE PROBE (not a gate). Two diagnostics, run on the real CI host (qemu-user + aarch64), both isolated from the compiler ladder:
- **`qemu-probe.yml`** -- SPIKE (invariants suspended). Diagnostic: isolate qemu-user aarch64 behaviors stage 1 depends on. Each probe is a tiny stage0-as program (spikes/qemu-
- **`reference-first.yml`** -- SPIKE. THE REFERENCE IS PROVEN -- now build ours against the same pin. Phase 1 result at M2-Planet 1.13.1 (bd2fe4b) + M2libc 68a23cf:
- **`reference-m2p-fault.yml`** -- SPIKE. WHY DOES THE REFERENCE aarch64 M2-Planet SEGFAULT? Established by reference-first:
- **`seedas-demo.yml`** -- SPIKE seed-as demo (invariants suspended). Builds the hand-written ARM64 hex-loader and feeds it a commented, whitespaced hex dump of "Hello\n" to
- **`selfhost-demo.yml`** -- SPIKE (invariants suspended). EVERY OPERATION IS RUN TWICE. Rule for this workflow: nothing runs without a reference doing the SAME thing
- **`stage0-as-adrnum-demo.yml`** -- SPIKE (invariants suspended). Verifies the numeric PC-relative adr added to stage0-as: adr xR @<pos>, where <pos> is an absolute OUTPUT byte-position 
- **`stage0-as-brnum-demo.yml`** -- SPIKE (invariants suspended). Verifies the numeric PC-relative branch added to stage0-as: b/b.eq/b.ne @<pos>, where <pos> is an absolute OUTPUT byte-p
- **`stage0-as-demo.yml`** -- SPIKE stage0-as demo (invariants suspended). Shot B — three checks: 1) RUNTIME memory: a program stores a byte, reads it back, and exits with it
- **`stage0-as-ext-demo.yml`** -- SPIKE (invariants suspended). Verifies the primitives added to stage0-as to make stage 1 (macro-as) writable:
- **`stage0-as-ldrx-demo.yml`** -- SPIKE (invariants suspended). Verifies 64-bit load/store added to stage0-as: ldr x<t> x<n>   = 0xF9400000|(n<<5)|t
- **`stage0-as-mul-demo.yml`** -- SPIKE (invariants suspended). Verifies the arithmetic ops added to stage0-as for stage 2's expression codegen:
- **`stage0-roundtrip.yml`** -- EXPERIMENTAL stage 0 round-trip demo (spike zone — invariants suspended). Assembles the hand-encoded ARM64 proof-of-concept, RUNS it (proves the bytes
- **`stage1-as-demo.yml`** -- SPIKE (invariants suspended). Stage 1 = macro-as: a TWO-PASS NUMERIC LABEL RESOLVER, written in stage0-as's OWN language (subroutines + shifts + brk) 
- **`stage2-mini-c-demo.yml`** -- SPIKE (invariants suspended). Stage 2 = mini-c. Supports: one-or-more  int name(params){ ... }  functions; a body has
- **`stage3-m2-demo.yml`** -- SPIKE (invariants suspended). THE HANDOFF: our stage-2 compiler builds M2-Planet from M2-Planet's own source, and the resulting binary compiles C.
- **`struct-reverse-probe.yml`** -- SPIKE. REDUCER for the fault m2libc-113-bisect located. Our stage-2-built M2-Planet compiles a small program byte-identically to
- **`tcc-aarch64-probe.yml`** -- SPIKE. IS tcc's AARCH64 BACKEND REAL ENOUGH TO BUILD ON? THE QUESTION THIS DECIDES. The Mes path forces a cross-architecture detour and
- **`tcc-arm64-asm-gap.yml`** -- SPIKE. WHICH INSTRUCTIONS DOES musl NEED THAT tcc's arm64 ASSEMBLER LACKS? WHY THIS EXISTS. tcc-userland-arm64 run 3 established that mob HEAD

## Restoring one

    git mv .github/workflows-archive/NAME.yml .github/workflows/

Before doing that, check whether the thing it tests is already covered by
`stage3-hermetic-arm64` or `stage0-selfhost` -- most of the stage demos are
strict subsets of those two now.

