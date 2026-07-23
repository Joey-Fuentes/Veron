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
