# tcc userland — the userland half of the Linux leg

**Status: PROVEN, 2026-07-24.** A musl + BusyBox userland compiled entirely by
tcc boots as PID 1 under a GCC-built arm64 kernel.

```
==== VERON USERLAND ALIVE ====
uname : Linux (none) 6.17.0-1020-azure ... aarch64 GNU/Linux
pid1  : /bin/busybox
shell and busybox: compiled by tcc
kernel under them: compiled by gcc
arithmetic check: 42
==== VERON BOOT OK ====
[    1.974041] reboot: Power down
```

Gated by `.github/workflows/tcc-userland-arm64.yml`. Native aarch64 throughout —
`ubuntu-24.04-arm`, no cross-compiling, no emulation of the build.

## Why this is a real claim and not a compatibility hack

The kernel and the userland are independent artifacts. Linux's syscall ABI is
the contract between them and it is deliberately stable, so a GCC-built kernel
neither knows nor cares which compiler produced the static binaries issuing
`svc #0` against it. Splitting the Linux leg at that boundary banks the half
that is reachable today, and the half that is not — a modern arm64 kernel needs
`asm goto` **with outputs** for `get_user()`, jump labels, and linker scripts,
none of which tcc has — is left clearly unclaimed.

## What was built

| | |
|---|---|
| tcc | `5ec0e6f8` + 5 patches → `0.9.28rc (AArch64 Linux)` |
| musl | 1.2.5, `libc.a` 2,794,560 bytes, 1,277 members |
| BusyBox | 1.36.1, 2,908,400 bytes static, **401 applets** |

Pins, hashes and per-package substitutions are in `sources/{tcc,musl,busybox}.toml`.

## The evidence chain

Each rung is checked, not assumed:

1. **The assembler covers musl.** 16 of 16 aarch64 `.s`/`.S` files assemble; the
   20 mnemonics mob's own assembler rejects are all implemented by the series.
2. **musl runs.** A four-rung ladder — raw `_start` + exit syscall, crt+libc
   startup, malloc/string, stdio — all exit 7 as expected. The rungs isolate the
   layer, so a failure names it.
3. **BusyBox links.** `Final link with: <none>` — trylink found every candidate
   library unnecessary, meaning tcc resolved every symbol from musl and
   BusyBox's own archives.
4. **It boots.** Marker reached as PID 1, clean power down.

## The one real compiler gap

**tcc has no dead-code elimination.** BusyBox deliberately writes a runtime `if`
on a compile-time constant rather than `#if`, and lets the optimiser drop the
branch:

```c
#if ENABLE_FEATURE_CLEAN_UP
static void delete_eth_table(...) { ... }
#else
void delete_eth_table(...);          /* declared, NEVER defined */
#endif
    if (ENABLE_FEATURE_CLEAN_UP)     /* constant 0 */
            delete_eth_table(ch);    /* gcc deletes this call */
```

gcc folds the branch away so the call never reaches the linker. tcc does not, so
the link fails on a function that genuinely does not exist. Fixed by enabling
the features, which makes the functions real — enabling capability rather than
disabling the applets that expose it.

**This matters for leg 3.** The kernel uses `if (IS_ENABLED(CONFIG_FOO))`
pervasively for exactly the same reason, and will hit this far harder.

## Everything else was plumbing

Worth separating, because the roadmap's thesis is precisely that incidental and
forced complexity arrive together and get conflated:

| category | items |
|---|---|
| **compiler capability** | no dead-code elimination *(one item)* |
| **invocation** | `-Wp,-MD` splitting; `__GNUC__` undefined so `__attribute__` was nulled out; `--start-group`; no `-L`/`-nostdlib` so the link silently used system glibc; `INFO_OPTS()` linker diagnostics |
| **sysroot** | kernel UAPI headers, which musl does not ship |
| **version skew** | `tc` needs CBQ enums dropped from the uapi headers — **gcc fails identically** |
| **our own bugs** | the assembler series missing `#include <assert.h>`; tcc zero-filling executable alignment padding |
| **host/qemu** | kernel image unreadable; missing virtio option ROM; `-cpu max` asserting inside qemu |

One row is about what tcc can do. That ratio is the useful output.

## Borrowed inputs, named

- **The kernel** is Ubuntu's — which is the point for the ABI claim, but it is a
  distro artifact: EFI-signed, 65 MB decompressed, version-coupled to the runner
  image. All three boot-step failures came from that.
- **Kernel UAPI headers** come from the distro's `linux-libc-dev`, copied into
  the musl sysroot. The principled source is `make headers_install` from a
  pinned kernel tree.
- **musl is incomplete**: `src/complex` is dropped (tcc has no `_Complex`), and
  nine `.s` files fall back to musl's own portable C.

Building `arch/arm64/configs/defconfig` from a pinned kernel with the host gcc
closes the first two at once, and is leg 3's first spike.

## What this does not show

- tcc building a **kernel**. Not attempted; the research reasons are above.
- Anything about **gcc** — *unchanged by this result, but no longer open.*
  `gcc-entrypoint-probe` found the gap: 4.7 has no aarch64 backend, 4.8 has one
  but its `gcc/` subdirectory configure hard-requires a C++ compiler. It was
  closed separately by backporting 4.8.5's backend into 4.7.4 and building that
  with this same tcc — see `GCC-BACKPORT.md`. The userland result below is
  independent of it.
- **Reproducibility.** The build is pinned and hashed but has not been rebuilt
  byte-for-byte twice. That is the natural next gate, and cheap now.
