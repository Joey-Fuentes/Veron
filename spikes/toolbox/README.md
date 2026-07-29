# spikes/toolbox — committed development tools

Two binaries that a sandbox cannot fetch for itself, committed so that stage-3
work can be done outside CI. Read the **What this is not** section before
assuming anything about them.

## What is here

| file | bytes | sha256 (first 16) |
|---|---|---|
| `qemu-aarch64-static` | 6,245,816 | `bfcd46c842441912` |
| `tcc-5ec0e6f8-arm64-configured.tar.gz` | 1,019,196 | `2e441f5c6b73cf01` |

`SHA256SUMS` carries the full digests. Verify with `sha256sum -c SHA256SUMS`.

---

## `qemu-aarch64-static`

**What it is.** QEMU's *user-mode* aarch64 emulator: it runs an aarch64 Linux
ELF on a non-aarch64 host by translating instructions and forwarding syscalls.
It is not a machine emulator and boots nothing.

```
qemu-aarch64 version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.17)
ELF 64-bit LSB pie executable, x86-64, static-pie linked, stripped
BuildID[sha1] 6c2f342fd4968ac4a578fc652864bb62693764bf
```

**Where it came from.** `apt-get install qemu-user-static` on `ubuntu-24.04`,
copied from `/usr/bin/qemu-aarch64-static` by
[`.github/workflows/local-toolbox.yml`](../../.github/workflows/local-toolbox.yml).
That workflow is the reproduction recipe: run it and you get this file again.

**It is an x86_64 binary on purpose.** A `qemu-aarch64-static` built *for*
aarch64 emulates aarch64 *on* aarch64, which is useless to an x86_64 host. The
workflow asserts `uname -m` is `x86_64` and fails otherwise, because that
mistake produces a file that looks correct and helps nobody.

**Why we need it.** Veron's target is aarch64. `stage0-as`, `elf`, `stage1`,
`stage2` and everything micro-c emits are aarch64 binaries, and a development
machine generally is not. Without an emulator the only way to *run* any of it
is a CI round of about three minutes; with it, locally, about a second.

The concrete difference: `05-struct-assign` sat red for the entire life of the
case suite and could not be reproduced locally at all. Under this emulator it
reproduced immediately, and the cause turned out to be three wrong instruction
encodings in M2libc's macro table — not a compiler bug.

**How to use it.** Invoke it explicitly. No `binfmt_misc` registration, no
root:

```sh
spikes/toolbox/qemu-aarch64-static ./some-aarch64-binary
```

The whole spike ladder runs this way:

```sh
Q=spikes/toolbox/qemu-aarch64-static
$Q spikes/stage0-as/stage0-as < prog.s | $Q spikes/elf/elf a.out && $Q ./a.out
```

**Licence.** QEMU is GPLv2. This is an unmodified Debian/Ubuntu build; the
source is `qemu` `1:8.2.2+ds-0ubuntu1.17` from Ubuntu 24.04.

---

## `tcc-5ec0e6f8-arm64-configured.tar.gz`

**What it is.** tinycc at pin `5ec0e6f84b47ebd8c269b581712666313f5edaef`
(version `0.9.28rc`), with `spikes/stage3/patches/tcc-arm64-asm/` applied and
`./configure --cpu=arm64` already run. 546 files, `.git` removed.

**Why it is *configured* and not a plain checkout.** `tcc.h:27` includes
`config.h`, which does not exist in the repository — `./configure` writes it.
`tccdefs_.h` is generated from `include/tccdefs.h` by a `c2str` helper that has
to be compiled first. A raw clone has neither, and that is exactly what
`tcc-two-ways` tripped over on its first run. Both are present here:

```
config.h        present
tccdefs_.h      13,286 bytes
```

**Why we need it.** It is the input to the whole stage-3 exercise: micro-c
compiles `libtcc.c` from this tree. Without it the sandbox can build micro-c
but has nothing to point it at, so every question about how far tcc gets costs
a CI round.

**Why the pin.** See [`sources/tcc.toml`](../../sources/tcc.toml). `mob` is a
moving target and its own arm64 assembler rejects instructions musl needs;
`5ec0e6f8` is the tree the Feb-2026 assembler series was written against,
located by matching pre-image blob hashes in the patches rather than by date.

**Licence.** tinycc is LGPL-2.1-or-later.

---

## What this is not

- **Not on any build path.** Nothing in `stages/`, `seed/`, `lib/` or any
  hermetic workflow reads this directory. `BUDGET_PATH` is unaffected, the
  `SEAL` step in `stage3-hermetic-arm64` does not see it, and no byte of any
  artifact comes from here. These are tools for *looking at* the work.

- **Not a trust root, and not verified.** Everything under `seed/` and
  `spikes/stage0-as/` is committed *derived* and checked against its own
  source by round-trip disassembly under two independent decoders. **These two
  files get none of that.** `qemu-aarch64-static` is an opaque 6 MB binary from
  a distribution package and we have not disassembled it. That is a deliberate
  exception to "nothing opaque is committed", and it is acceptable only because
  of the point above: it cannot influence an output, only what we observe about
  one.

- **Not required.** Delete the directory and every workflow still passes. What
  you lose is the local loop.

- **Not a substitute for CI.** amd64 hides an entire class of bug — unaligned
  access faults on ARM and is tolerated on x86 — and four bugs in this work
  were invisible on amd64 and fatal on aarch64. The emulator narrows that gap
  but does not close it: qemu is not silicon, and `tcc-two-ways` still runs on
  a real `ubuntu-24.04-arm` runner. Local results are a filter, not a verdict.

## Refreshing them

Run `.github/workflows/local-toolbox.yml` (`workflow_dispatch`), download the
`veron-local-toolbox` artifact, replace these files, and update `SHA256SUMS`
and the table above. That workflow proves the emulator works before uploading
it — it cross-compiles a real aarch64 binary and runs it under the copy it is
about to ship, rather than asserting that a version string looks right.

## The third piece, already committed elsewhere

M2-Planet at pin `bd2fe4b` (tag `Release_1.13.1`) lives at
[`spikes/reference/m2-planet/`](../reference/m2-planet). micro-c is that tree
plus `spikes/stage3/patches/`. It sat 56 commits past the pin for weeks, which
meant the patch series would not apply and micro-c could not be built outside
CI at all — see that directory's README for the check that would have caught
it.
