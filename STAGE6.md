# Stage 6 — Verification and Distribution

Stage 6 is the last rung. When it ships, the work stops; stage 7 exists only as
a boundary marker. So its scope is the scope of the project's ending, and this
document is the argument for where that line sits.

Everything below stage 6 answers *"can this be built from a seed."* Stage 6
answers three questions nothing else does:

- **Can a stranger reproduce it?** Not "download our artifact" — build it, on
  their own machine, from the seed, and get the same bytes.
- **Can they trace any file to its origin?** Not a story in a comment; a chain
  of recorded, hash-verified edges from a file in the image back to 3,720 bytes
  of hand-written assembly.
- **Can they boot it on their hardware?** Not one laptop. Arbitrary machines,
  from a USB stick, the way any distribution works.

---

## 0. First: the numbering is wrong, and has been for a while

`ARCHITECTURE.md` numbers the stages 1–7. The directories are numbered 0–5. So
`spikes/stage0-as` is what the architecture calls stage 1, and every
conversation about "stage 3" has to establish which numbering is meant before
it can proceed. That is a tax on every discussion and it compounds.

The numbering below is the one that stays, and it is the architecture's, with
the directories corrected to match and two rungs merged.

| new | name | was (directory) | was (ARCHITECTURE.md) |
|-----|------|-----------------|------------------------|
| **1** | **Self-Assembly** | `spikes/stage0-as`, `spikes/elf`, `spikes/seedas`, `spikes/stage0-arm64` | 1 `seed-as` |
| **2** | **pico-c** | `spikes/stage1-as` + `spikes/stage2-pico-c` | 2 `macro-as` + 3 `pico-c` |
| **3** | **micro-c** | `spikes/stage3` | 4 (first half) |
| **4** | **Toolchain and Kernel** | `spikes/stage4` | 4 (second half) |
| **5** | **User Space** | `spikes/stage5` | 5 |
| **6** | **Verification and Distribution** | — | 6 `release` |

**WHY 1 AND 2 MERGE.** `stage1-as` adds macros, named constants and `.include`
to the stage-0 assembler; `stage2-pico-c` is the C subset written *in* that
macro assembly. They are not separable in practice — the macro assembler exists
only to make pico-c writable, has no other consumer, and nothing is ever built
against it alone. Two rungs that always run together and share a single
purpose are one rung with two files.

**WHY THERE IS NO STAGE 0.** A stage numbered zero reads as "before the
beginning," and the seed assembler is not before anything: it is the first
thing, and everything else is defined in terms of it. Counting from 1 also
removes the off-by-one that made every cross-reference ambiguous.

**WHAT THIS COSTS.** Every path in every workflow, every document
cross-reference, and every release tag. That is a large mechanical change and
it is worth doing exactly once, now, before stage 6 adds more references to the
old names. Doing it after would mean touching the same files twice.

---

## 1. Out of `spikes/`

`spikes/` was honest when each directory was an experiment that might be
thrown away. It is no longer true of any of them: stage 5 has 144 pinned
packages, a build driver, a plan gate and a published image. Calling that a
spike understates it to anyone reading the repository, and it puts the
project's actual work behind a word that means "provisional."

```
veron/
  stages/
    1-self-assembly/       # THE TRUST ROOT. stage0-as.s + the committed
                           # binary, elf.s + elf. Nothing above exists
                           # without these; nothing built them but themselves.
    2-pico-c/
    3-micro-c/
    4-toolchain-kernel/
    5-user-space/
    6-verification-distribution/

  tools/
    veron                  # the driver — stages 1..6, not just 5
    trace/                 # veron-trace, C, runs on the device

  policy/                  # pins, mirrors, expected differences
  docs/                    # ARCHITECTURE, TRUST-BOUNDARY, per-stage docs
```

**THE DRIVER MOVES UP.** `tools/veron` currently lives inside stage 5 and
knows only about stage 5. Every stage needs it — recipes, plans, manifests and
rung records are not a stage-5 idea, they are how the project records what it
did. One driver at the top, `--stage N` where it matters.

**THERE IS NO SEPARATE SEED DIRECTORY, AND PROPOSING ONE WAS AN ERROR.** Stage
1 IS the seed: `stage0-as.s` with its committed binary, and `elf.s` with its
committed binary. Splitting them into a `seed/` above the stages would imply
stage 1 is something built *with* the seed rather than being it, and would put
the trust root in two places. One directory, and it is the first stage.

### Job names

Workflow names should say what they build and for what, in that order, so an
alphabetical list of runs reads as the ladder.

| now | becomes |
|-----|---------|
| `stage0-selfhost.yml` | `1-self-assembly.yml` |
| `stage0-stage4-complete-amd64.yml` | `1-4-chain-amd64.yml` |
| `stage0-stage4-complete.yml` | `1-4-chain-arm64.yml` |
| `stage3-hermetic-arm64.yml` | `3-micro-c-arm64.yml` |
| `stage4-arch-spike-amd64.yml` | `4-toolchain-kernel-amd64.yml` |
| `stage5-spike-amd64.yml` | `5-user-space-amd64.yml` |
| — | `6-release-amd64.yml` |

**`spike`, `complete`, `probe` AND `watchpoint` ALL LEAVE THE NAMES.** They
described a moment in the project's history, not what the job does. A reader
seeing `stage4-arch-spike-amd64` cannot tell whether it is the real build or an
experiment beside it — and at this point it is the real build.

---

### PROPOSED: how the jobs should be structured

**Not decided.** This is the shape argued for below; the open question at the
end has to be answered before any of it is written.

Three constraints drive it, and none of them are preferences:

- **Runner architecture forces a split.** Stages 1-3 must run on aarch64 --
  the seed assembler is ARM64 -- and stages 4-6 run natively on x86_64. That
  boundary exists whether or not the layout acknowledges it.
- **Stages 1-3 are coupled and fast.** They run in one box today, each rung
  feeding the next directly. Splitting them into three workflows would add two
  artifact round-trips for a few minutes of work.
- **Stages 4, 5 and 6 are long and independently re-runnable.** Stage 4 is
  about six hours; stage 5 has a checkpoint system precisely so it does not
  redo everything. These want to be separate files.

```
.github/workflows/
  1-3-seed-<arch>.yml             aarch64: self-assembly -> pico-c -> micro-c
                                  -> the cross to a native x86_64 tcc
  4-toolchain-kernel-<arch>.yml   native: twenty rungs, three kernels
  5-user-space-<arch>.yml         native: the package set, the image
  6-release-<arch>.yml            native: trace, ISOs, signing, publish
  chain-<arch>.yml                calls 1-3 -> 4 -> 5 -> 6 in order
  lint.yml
```

**EACH STAGE IS BOTH `workflow_call` AND `workflow_dispatch`, AND THAT IS THE
POINT.** Called from `chain`, artifacts pass inside the run. Dispatched alone,
the stage downloads the previous stage's published release. Same script either
way; only the source of the input differs. This is what makes it possible to
re-run stage 5 against yesterday's stage 4 without a six-hour rebuild, which
is how the work actually proceeds.

**THE ARTIFACT CONTRACT IS IDENTICAL AT EVERY RUNG.** Each stage publishes:

```
<N>/latest-<arch>
  artifact.tar.zst      what the next stage consumes
  ARTIFACT-SHA256       its digest
  rungs.toml            one record per rung: inputs, builder edge, outputs
```

`rungs.toml` is the only new part, and its content already exists -- the seed
job prints exactly this at the handoff today. Stage 6 concatenates all five
files and walks the edges. A uniform contract is what makes the trace possible
without a special case per stage.

**THE WORKFLOW BECOMES A THIN CALLER.** Each stage's logic moves to
`stages/<N>/build.sh`, running exactly what the YAML runs today:

```yaml
- run: ./veron build --stage 4 --arch ${{ inputs.arch }}
```

so the same command works on a laptop. This single change is what yields the
local build, the rung records, and a file a person can read -- the 4,500-line
inline YAML is the reason none of those exist today.

**THE PROBE AND WATCHPOINT WORKFLOWS SHOULD GO.** Roughly twenty of them are
answered questions kept as history: `stage3-cross-tcc-probe` established that
the cross works, and the cross now runs in production and is marked
`VERON-XTCC-GEN2-OK`. Their findings belong in `docs/experiments/` with the
conclusion recorded; the workflow list should be the ladder and nothing else.
Deleting a workflow that proved something is safe once what it proved is
written down -- and keeping twenty of them means the list no longer says what
the project builds.

**OPEN QUESTION, AND IT CHANGES THE REST.** Is `chain-<arch>.yml` the normal
entry point, or do stages stay dispatched individually? If the chain is
normal, the artifact contract is load-bearing and every stage must publish a
release even when nothing consumes it from there. If individual dispatch stays
normal, the contract is a convenience and intermediate publishing can be
skipped inside a chained run. Answer this before writing any of it.

## 2. What stage 6 actually delivers

### 2.1 The trace

**THE CLAIM THIS PROJECT MAKES IS THAT EVERY BYTE DESCENDS FROM 4 KB OF
AUDITABLE ASSEMBLY, AND NOTHING CURRENTLY CHECKS IT.** Stage 5 can say which
package installed a file and which tarball that package came from. No stage
records *what compiled it*. So the chain from `/usr/bin/gpg` back to
`stage0-as` exists in prose and in no machine-readable form.

Stage 6 closes that with one added fact per rung: **the builder edge.**

Every rung — from the seed forward — emits a record:

```toml
[rung]
id      = "4/11.4/gcc-15.2.0"
inputs  = [
  { role = "source",  name = "gcc-15.2.0.tar.xz", sha256 = "..." },
  { role = "builder", ref  = "4/9/gcc-10.2.0",    sha256 = "..." },
]
outputs = [
  { path = "usr/bin/gcc",  sha256 = "..." },
  { path = "usr/bin/g++",  sha256 = "..." },
]
```

A `builder` input names another rung **and repeats that rung's output hash**.
That duplication is the point: it is a claim that can be falsified. `veron
trace --verify` walks every edge and fails if a builder's recorded hash is not
byte-identical to the output the referenced rung actually produced.

What the user runs, and sees:

```
$ veron trace /usr/bin/gpg

usr/bin/gpg   sha256 82f02d76…  5286568 bytes

  built by  gnupg 2.5.21                        [stage 5]
    source  gnupg-2.5.21.tar.bz2  sha256 e3af2c8c…
            https://www.gnupg.org/ftp/gcrypt/gnupg/gnupg-2.5.21.tar.bz2
    recipe  recipe-sha 116ca69a…
    built with  gcc 15.2.0  →

  gcc 15.2.0        [4/11.4]   built with  gcc 10.2.0  →
  gcc 10.2.0        [4/9]      built with  gcc 4.7.4   →
  gcc 4.7.4         [4/7]      built with  tcc         →
  tcc               [3/2]      built with  micro-c     →
  micro-c           [3/1]      built with  pico-c      →
  pico-c            [2/2]      assembled with  macro-as →
  macro-as          [2/1]      assembled with  stage0-as →
  stage0-as         [1]        3,720 bytes, assembles itself
                               gen1 == gen2 == gen3

  ROOT REACHED — 11 edges, every one hash-verified.

  NOTE: this x86_64 chain crosses architectures at 3/2.
        mc-tcc (aarch64) built x86_64-tcc, which built a musl
        and a native x86_64 tcc. Every rung above 3/2 is native
        x86_64; every rung below it is native aarch64.
```

**THE CROSS IS PRINTED, NOT HIDDEN, AND THAT IS THE WHOLE VALUE OF DOING
THIS.** The x86_64 ladder does reach hand-written assembly — but the assembly
is ARM64, and one compiler crosses at `mc-tcc -> x86_64-tcc`. Today that fact
lives in a workflow comment; a reader of the image has no way to learn it. A
trace that quietly omitted the architecture change would be worse than no
trace, because it would assert something untrue in a format that looks
authoritative.

**THE RECORD FOR THAT EDGE ALREADY EXISTS.** The seed job prints exactly this
at the handoff:

```
tcc-x86_64  090429cf1f1455d29720bb49bfb2683bf31fa9154e9719b12c9efd4db0fc6d39
tcc-src.tar dadf04905ec86756d2b667c45ad40935910f63dd213a1be4c056ded7bcd3e102
mc-tcc      4cc4343ad4d8ce7bc3997a3cde31f7341b957448da13994d83d258bd08593343
built-by    mc-tcc -> x86_64-tcc -> tcc-x86_64
musl        1.2.5 (target libc, built by x86_64-tcc)
```

Output hashes, a `built-by` edge, the source digest, the run and the commit.
That is the rung record, already correct in content — it is written to a log
rather than to a file, and only at this one boundary. So the trace work is not
designing a format. It is **writing what already exists as data, at every rung
instead of one.**

And the reverse, which is the question that matters after a CVE:

```
$ veron trace --forward 3/2/tcc
  1,412 files in the image descend from this compiler
```

**THE RECORDS MUST BE READABLE WITHOUT THE TOOL.** One fact per line, no
nesting that needs a parser, so `grep` and a shell loop can follow the chain.
A provenance format that requires a program to read is one nobody audits — and
the audience for this is exactly the person who does not trust our program.

**A SMALL C TRACER SHIPS ON THE DEVICE.** `tools/trace/` — a few hundred lines
against libgcrypt, which the image already carries. The Python driver is for
building; the device must be able to verify itself without it, since python is
`build_only` and no longer in the image.

### 2.2 The kernel matrix

Stage 4 publishes **one** kernel today, tailored to one laptop. Stage 6 needs
three, all built by stage 4, all consumed by stage 5:

| kernel | for | shape |
|--------|-----|-------|
| `minimal-qemu` | CI, and anyone booting under emulation | virtio only, no firmware, smallest |
| `reference-laptop` | the maintainer's bare-metal machine | the current config, kept as a known-good reference |
| `generic` | **everyone else** | broad driver set, firmware baked in |

**THE GENERIC KERNEL IS MOST OF STAGE 6'S WORK AND IT IS WHERE THE PROJECT'S
POSTURE GETS TESTED.** Booting arbitrary hardware means shipping firmware
blobs: binary files that cannot be built from source, which is the one thing
this project otherwise refuses. They must be pinned by digest, listed
individually with their licences, and excluded from the "built from source"
claim explicitly rather than quietly. `minimal-qemu` and `reference-laptop`
carry none, so the claim survives intact for both — and the generic image says
plainly which bytes it cannot account for.

### 2.3 Boot: EFI stub, initramfs baked in, no bootloader

`CONFIG_EFI_STUB=y` makes the kernel a PE/COFF executable the firmware loads
directly. `CONFIG_INITRAMFS_SOURCE` compiles the initramfs into it. The result
is **one file** at `/EFI/BOOT/BOOTX64.EFI` on a FAT ESP — the removable-media
fallback path, so the same layout works for a USB stick, an installed disk and
a VM without an NVRAM entry, `efibootmgr`, or GRUB.

**DO NOT SET `CONFIG_CMDLINE_OVERRIDE`.** `CONFIG_CMDLINE` for the default is
right; override makes the kernel ignore what is passed at boot, and every test
in this project works by passing `veron.boot=tests`, `veron.selfrebuild=1` or
`rdinit=` on the command line. Setting it would break the entire harness while
the image still booted correctly on real hardware — a failure that looks like
the tests are broken rather than the config.

**THE INITRAMFS IS NOW REPRODUCIBILITY-CRITICAL** because its bytes are inside
the kernel image. The cpio must be built sorted, `mtime=0`, `uid=gid=0`, with
no compression timestamp — the same treatment `sysroot.tar.zst` already gets.

**WHAT BAKING IN COSTS.** Changing the initramfs relinks `vmlinux` rather than
recompiling the kernel, so iteration is cheap — but it is no longer possible to
swap an initramfs without producing a new kernel image. Given the initramfs
holds the FDE unlock path, having it inside the hashed kernel image is the
better default anyway.

### 2.4 Image formats

Four deliverables, two underlying artifacts:

| artifact | covers | root |
|----------|--------|------|
| `veron-<arch>.iso` (hybrid) | CD/DVD, VirtualBox, **Ventoy**, USB `dd` | squashfs + tmpfs overlay, read-only |
| `veron-<arch>.img` | QEMU, direct flash, installed systems | ext4, writable |

**THE CONTAINER IS NOT THE INTERESTING VARIATION — THE ROOT IS.** A hybrid ISO
is bootable from optical media and from a raw-written USB stick with the same
bytes, and Ventoy boots it by virtualising the ISO. All three are one artifact.
What actually differs is whether the root is read-only-with-overlay (live) or a
real writable filesystem (installed), which is the same fork the full-disk
encryption design runs into.

**VENTOY CONSTRAINS THE DESIGN IN ONE SPECIFIC WAY.** Ventoy recreates the
ISO's block device using the kernel's device-mapper once Linux boots. So an
encrypted persistence volume must not stack a second dm device underneath it;
fscrypt on an ext4 `.dat` is the arrangement that avoids the collision.

### 2.5 The installer

Nothing has ever made a machine bootable — the reference laptop borrows a
pre-existing GRUB. Five steps, one new package:

```
fdisk           partition            busybox has it
mkfs.fat        the ESP              dosfstools — already packaged
mke2fs          the root             e2fsprogs — MISSING, must be added
tar             unpack the rootfs    busybox
cp              kernel → ESP         one file, EFI stub
```

**`e2fsprogs` IS THE ONLY MISSING PIECE AND IT IS ALSO WHY `dosfstools` LOOKED
DEAD.** The stage-5 reachability analysis reported `dosfstools` and `iproute2`
as packages nothing reaches, and they were nearly deleted — they are not dead
weight, they are the installer arriving before the installer does. A
reachability tool cannot see a consumer that has not been written yet, which is
a standing caution about acting on its output.

### 2.6 Distribution

- **GitHub Pages** — the site, the trace browser, the per-release manifests.
- **GHCR** — release artifacts and the update channel, content-addressed.
- **Signed ledger** — the audit record stage 6 exists to sign, covering every
  rung record from the seed forward.

**UPDATES ARE NOT AUTOMATIC AND THIS IS UNDECIDED.** The `veron-about` window
already says "rebuild and re-flash." Whether old releases stay updatable
decides whether blobs can ever be pruned from the mirror, and that question has
been open since stage 5. It must be answered here because it constrains what
gets published.

---

## 3. Running it yourself

The property stage 6 is for. Today there is no local build path at all —
`STAGE5.md`'s "Running it on your own machine" downloads *our* artifacts and
boots them, which is consumption, not reproduction.

```sh
git clone https://github.com/Joey-Fuentes/Veron
cd veron
./veron build --from 1 --to 6 --arch x86_64
```

Host requirements, honestly stated:

```
python3, git, bubblewrap, busybox-static, e2fsprogs, file
qemu-system-x86     to boot and test the image
qemu-user-static    to run stages 1-3, which are aarch64  (x86_64 hosts)
unprivileged user namespaces enabled  (Ubuntu 24.04: off by default)
~40 GB disk, several hours, network for the pinned sources
```

**bubblewrap IS THE LOAD-BEARING ONE.** It is what makes the box hermetic —
`--unshare-all`, no network, nothing of the host on the build path. Without it
there is no sandbox and the "nothing borrowed" claim does not hold. It is not
substitutable.

**`binutils` AND `busybox-static` LOOK LIKE THEY CONTRADICT THE SEED STORY AND
DO NOT.** `BUDGET_PATH` is empty; `as` and `ld` are explicitly out of it
because `stage0-as` and `elf` replace them, and the SEAL step fails the run if
either reappears in the box. But a reader who sees "you need binutils" will
reasonably ask why a project that builds its own assembler requires one, and
that deserves an answer here rather than a footnote in a workflow.

**QEMU IS REQUIRED FOR STAGES 1-3 ON x86_64, AND THAT IS ACCEPTED FOR NOW.**
The seed assembler is ARM64; the x86_64 ladder reaches it by building the
aarch64 rungs and crossing one compiler at `mc-tcc -> x86_64-tcc`. On an
x86_64 host that means emulating aarch64 up to tcc, so a user reproducing the
chain needs `qemu-user-static` or equivalent for the lower rungs even though
stages 4-6 run natively. We ship the emulator we test against rather than
leaving the user to match a version.

**THE ALTERNATIVE IS AN x86-64 SEED ASSEMBLER AND IT IS NOT SCOPED HERE.**
Writing `stage0-as.x86_64.s` by hand would let the x86_64 ladder start on
x86_64 with no cross and no emulator, and would make a trace on an amd64 image
terminate in assembly for the machine it runs on. It is real work -- variable-
length encoding makes a hand-written x86-64 assembler materially harder than
the ARM64 one -- and it is the right eventual answer rather than a stage 6
obligation. Recorded here so the emulator dependency is a decision rather than
an oversight.

**THE WHOLE CHAIN MUST BE INVOCABLE, WHICH IS THE REAL WORK.** Stages 1–4 have
their build logic inside GitHub Actions YAML — roughly 4,500 lines of inline
shell. Nothing can run a rung locally because there is nothing to call. Stage 5
is different: `tools/veron` is a real driver. Extracting stages 1–4 into
scripts the workflow merely calls is a prerequisite for both the local build
*and* the rung records, because a rung that only exists as YAML cannot declare
its inputs.

**EXTRACT, DO NOT REWRITE.** Each rung becomes a script running exactly the
commands the YAML runs today, verified by comparing a CI run before and after
byte for byte. Rewriting a working bootstrap to make it prettier is how a
chain that boots stops booting.

---

## 4. Order of work

1. **Renumber and move.** One mechanical pass, before anything else adds
   references to the old names.
2. **Extract stages 1–4 from YAML into callable scripts.** Byte-identical
   output, proven by comparison.
3. **Rung records + `veron trace`.** Once rungs are scripts, they can declare.
4. **Kernel matrix.** Three configs; the generic one is the bulk of the work.
5. **EFI stub + baked initramfs**, and the reproducible cpio that requires.
6. **`e2fsprogs` + `veron-install`.**
7. **Image formats**, hybrid ISO and raw, Ventoy verified on real hardware.
8. **Distribution**: Pages, GHCR, signed ledger.
9. **ARM64 and RISC-V**, once the shape is proven on x86-64.

**STEPS 1 AND 2 GATE EVERYTHING ELSE.** The trace cannot exist without rung
records; rung records cannot exist while the rungs are inline shell. Doing them
first is not tidiness, it is the dependency order.
