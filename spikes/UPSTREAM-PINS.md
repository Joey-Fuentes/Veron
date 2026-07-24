# Upstream pins — why they moved off `master`

## Change

| upstream    | was (unreleased `master`)                  | now (stage0-posix set)                     |
|-------------|--------------------------------------------|--------------------------------------------|
| M2-Planet   | `34fbd5c2a9b6eb634a4f6ad95158dcd1efcf19e0` | `bd2fe4b0659fd0ad3f476a5ad0ef801bd134665d` |
| M2libc      | `ca023d8dc855171fd0618951add5817e0e568fca` | `68a23cfd05d5a355ba7a30c770d684cbe86fcc4e` |
| mescc-tools | branch tip (unpinned)                      | `5adfbf3`                                  |

`bd2fe4b` is M2-Planet **Release 1.13.1** (2025-08-17), the newest tagged
release. The three commits above are the set `stage0-posix` pins together, and
that set is what GNU Guix's `aarch64-linux` full-source bootstrap builds on.

## Why

Our pin was a post-1.13.1 `master` checkout, which carries the **unreleased**
1.13.2 change. M2-Planet's `CHANGELOG.org` describes it as:

> 1.13.2 - YYYY-MM-DD / Changed / Use buffers to speed up reads/writes.

That change introduced `write_to_out_buffer`, `flush_output_buffer` and the
`output_file_buffer` / `OUTPUT_FILE_BUFFER_SIZE` globals. None of it exists in
1.11, 1.12, 1.13 or 1.13.1.

We independently landed on that exact code before knowing it was new. Building
an aarch64 M2-Planet from the upstream source with upstream's own tools produced
a 366,726-byte binary that segfaulted, and resolving the fault address against a
label map reconstructed from the `.hex2` (verified to zero drift against the
final image size) gave:

```
PC   0x403b38 -> FUNCTION_string_length + 0
X30  0x420e9c -> FUNCTION_write_to_out_buffer + 64
```

`recursive_output()` walks the emitted token list calling
`write_to_out_buffer(i->s, out)`; that function's first statement is
`string_length(s)`. One token has a NULL `s`, and it is dereferenced
immediately. The binary parses fine — ~156 syscalls, opens the input, reads it —
and dies only while **writing output**, which is precisely the new code path.

Ruled out along the way:

- **Not size.** A 466,329-byte synthetic binary built the same way runs fine;
  M2-Planet is 366,726.
- **Not the ELF layout or `_start`.** Header verified sound offline (one PT_LOAD
  at 0x400000, entry 0x400078 inside the image); the reference aarch64 **M1**
  (51,346 bytes) uses the identical `libc-core.M1` `_start` and works, producing
  byte-identical output to the host M1.
- **Not the build recipe.** The plain header and the `--debug` + `blood-elf` +
  `ELF-aarch64-debug.hex2` recipe from upstream's own
  `test/test1000/hello-aarch64.sh` fault at the *same instruction*.
- **Not the C source.** gcc builds a working M2-Planet from it, and so does our
  own stage 2 — our stage-2-built M2-Planet (327,692 bytes) runs correctly on
  the same inputs that kill the upstream-built one.

So the fault is in M2-Planet's aarch64 code generation for the new buffering
code, visible only when M2-Planet compiles *itself* for aarch64.

## Why upstream did not catch it

`test/test1000/hello-aarch64.sh` gates execution of the artifact on
`get_machine` reporting aarch64, so on x86 CI the aarch64 self-build is
assembled and linked but never run. live-bootstrap's upper half is x86
throughout. The aarch64 self-host **execution** path is effectively untested
upstream, which is how a codegen regression in newly added code lands on
`master` with CI green.

## Status of this claim

The pin change is the recommended experiment, not a proven fix. What is
documented: the CHANGELOG text, the release dates, and the stage0-posix pin set.
What is inference: that the 1.13.2 buffering change is the specific cause. It
rests on the backtrace landing exactly in that code, the code being new in the
unreleased 1.13.2, and its absence from 1.13.1. No upstream issue names this
fault. If `reference-first` goes green on this pin, the inference is confirmed.

aarch64 is a **supported self-hosting target**, not cross-compile-only —
M2-Planet's README claims self-hosting across platforms and stage0-posix's
Phase 14 rebuilds M2-Planet with M2-Planet on aarch64. The problem was the
version, not the architecture.

## Consequences for our tree

- `spikes/reference/` still vendors the **old** sources (M2-Planet `34fbd5c`,
  M2libc `ca023d8`, mescc-tools at the tip we cloned). It is now out of sync
  with CI. Re-vendor at the new pins when convenient; until then, local bench
  work reproduces the *old* upstream, which is fine for stage-2 bugs but not for
  anything upstream-version-sensitive.
- The m72/m73/m74 fixes are unaffected. All three reproduce with self-contained
  C programs and are bugs in stage 2's own code generation, independent of which
  M2-Planet source we feed it.
- `TARGET-SUBSET.md` §1 still records the old pins as the C-subset spec source.
  The subset itself is unlikely to have moved between 1.13.1 and `master`, but
  the table should be updated and §2's derivation re-run against `bd2fe4b`
  before it is relied on again.

---

# Results at the new pin

## The reference is proven

Upstream's own `test/test1000/hello-aarch64.sh`, run with qemu binfmt registered
and `GET_MACHINE_OVERRIDE_ALWAYS_RUN=1`, **passes**:

```
./test/results/test1000-aarch64-binary --architecture x86 -f ... -o proof
sha256_check test/test1000/proof.answer
out=test/test1000/proof: OK
exit 0
```

The 643,257-byte aarch64 M2-Planet it builds runs, compiles M2-Planet's entire
source for x86, and matches upstream's published checksum. Compiling a small
program with it gives output **byte-identical** to the gcc-built host compiler:

| compiler                       | output for `c.c` |
|--------------------------------|------------------|
| refM2P (aarch64, 643,257 B)    | 2813 B, `5ead19ee…` |
| host M2-Planet (x86, gcc)      | 2813 B, `5ead19ee…` |

That confirms the diagnosis: **aarch64 self-hosting works at 1.13.1**, and the
segfault we chased was the unreleased 1.13.2 buffering change on `master`.

`--architecture x86` also works on this pin, at every level: the full x86 chain
runs a program to `rc=45`, and test1000's proof step *is* the aarch64 binary
invoked with `--architecture x86`.

**Rule going forward: do not reconstruct upstream's recipe.** Run their script
and take the binary it produces — it is verified against their own checksum.
Four hand-written `-f` lists in a row were wrong.

## 1.13.1's M2libc is laid out differently

`aarch64/linux/bootstrap.c` at this pin is the **entire mini-libc** — `fgetc`,
`fputc`, `fputs`, `fwrite`, `open`, `fopen`, `close`, `fclose`, `brk`, `malloc`,
`strlen`, `memset`, `calloc`, `free`, `exit` — with `asm()` in only six of them.
There is no generic `M2libc/bootstrap.c`; that split is newer. The constants
M2-Planet needs (`NULL`, `TRUE`, `FALSE`, `EOF`, `EXIT_*`, `stdin`/`stdout`/
`stderr`) are enums at the top of that same file.

So m71's substitution — omit the whole arch file — cannot apply here: it would
discard the plain-C half we need.

## The substitution, redone at function granularity

`tools/drop_asm.py` removes exactly the `asm()`-bodied functions and compiles
everything else unpatched. Structural scanning runs on a copy with comments and
strings masked, so a `;` inside the licence header cannot mis-slice the file.

Measured at this pin: 6 dropped of 19 top-level blocks, `asm()` blocks
remaining 0, and stage 2 compiles the result cleanly —

```
bootstrap.c upstream 3463 B -> patched 2402 B
m2.c (translation unit)      213,297 B
stage2 rc=0, emitted         1,259,524 B
unresolved                   fgetc fputc
M2-Planet (ours)             313,608 B
```

`open`/`close`/`exit` come from m53 and `brk` from m69, so only `fgetc` and
`fputc` were left — they sit a level above the raw syscalls. `spikes/stage2-mini-c/m2libc-shim.c`
supplies both in ten lines of C over our `read`/`write` builtins. That is a
smaller substitution than m71's and it states its own rule rather than relying
on a coincidence of upstream's file layout.

## Still open at this pin

- **Stage 2 hangs on `M2libc/stdlib.c`** (rc=124) and **segfaults on
  `M2libc/stdio.c`** (rc=139, faulting within the first 62 lines — the
  `#include`/`#define` preamble). Neither file is needed once the patched
  `bootstrap.c` supplies the libc, so this is not blocking, but both are real
  stage-2 defects worth their own rungs. `string.c`, `ctype.c`, `fcntl.c` and
  `bootstrappable.c` all compile fine.
- **`#define` object-like macros** are still unsupported (m75). `stdio.c` and
  `hex2.h` both need them; `--bootstrap-mode` does not expand them either, so
  hex2 cannot be built in bootstrap mode by anyone.
- **Our M1 segfaults on `--architecture x86`** where upstream's returns rc=0 and
  632 bytes.
- **Our hex2 writes byte-identical output and then crashes on exit.**
- `spikes/reference/` still vendors the OLD sources; `TARGET-SUBSET.md` §2's
  mechanical derivation has not been re-run against `bd2fe4b`.
