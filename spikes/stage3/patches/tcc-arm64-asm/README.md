# tcc arm64 integrated assembler — recovered patch series

Aleksi Hannula, posted to `tinycc-devel` on **5 Feb 2026**, three patches:

| | |
|---|---|
| `0001` | `arm64-link`: implement `R_AARCH64_TSTBR14` / `R_AARCH64_CONDBR19` relocs |
| `0002` | `asm`: pass `ASMOperand` to the `subst_asm_operand` backend hook |
| `0003` | the assembler itself — `arm64-asm.c` +2579, new `arm64-tok.h` |

Author's own summary: *"Partial implementation, but enough to compile musl
1.2.5."* That is exactly the claim `tcc-userland-arm64` is testing, so this is
the patch that spike is written around.

## Why these files are not the posted text

The `lists.nongnu.org` archive **hard-wraps long lines**. Every wrapped line's
continuation loses its leading `+`/`-`/space marker, so `git apply` rejects the
posted text with `patch fragment without header`. The wrap is greedy at ~76
columns, and a token longer than the column budget gets emitted on a line of its
own, which means some lines are split into **three** fragments — e.g. this one
in `arm64-asm.c`:

```
+/* https://github.com/ruby/ruby/blob/…/bitmask_imm.rs */
```

came back as `+/* ` / `https://…bitmask_imm.rs` / ` */`, and the third fragment
begins with a space, so it reads as a context line rather than a continuation.

These files are the unwrapped series.

## How the unwrap was verified

Nothing here rests on eyeballing. Three independent checks, all exact:

1. **Every hunk balances.** For all 20 hunks, the counted `-`/`+`/context lines
   equal the `@@` header's declared counts, with **no unclaimed lines** between
   the end of a hunk and the next header. A continuation wrongly left as its own
   line inflates a count; a context line wrongly absorbed deflates one. Both
   show up here, and neither does.
2. **`git apply --stat` parses all three** and reports, for `0003`:
   `5 files changed, 2843 insertions(+), 19 deletions(-)` — byte-for-byte the
   diffstat in the patch's own header.
3. **The series matches the cover letter.** `10 files, +2868 / -26`, identical
   to `[PATCH 0/3]`.

No join in the series merges an alphanumeric character onto another
alphanumeric character, so no wrap dropped the space it broke at.

## Applying

Order is load-bearing: `0003` carries the post-`0002` signature
`subst_asm_operand(…, ASMOperand *op)` as **context**, so it will not apply to a
tree that has not had `0002` applied first.

```sh
for p in spikes/stage3/patches/tcc-arm64-asm/000*.patch; do
    git -C tccsrc apply --3way "$p" || exit 1
done
```

`--3way` needs the blobs, so clone tinycc at full depth (the workflow does).

## Is it already upstream?

Check for **`arm64-tok.h`**, which `0003` creates. Do *not* check for
`arm64-asm.c` — that file exists in mob regardless; unpatched it is titled
`ARM64 dummy assembler for TCC` and its `asm_opcode` is a single
`tcc_error("ARM asm not implemented.")`. `tcc-aarch64-probe`'s
`inline asm on arm64: $( [ -f arm64-asm.c ] && echo yes …)` therefore reports
`yes` on a tree with no assembler at all.

## Error strings, for log-scraping

The two versions fail differently, and neither emits the string
`instruction 'X' not implemented` that `tcc-userland-arm64` currently greps for:

| tree | message on an opcode it cannot handle |
|---|---|
| unpatched mob | `ARM asm not implemented.` |
| patched | `unrecognized opcode X`, `unrecognized unary opcode X`, `unrecognized nullaryopcode X` |

The patched assembler's other failure classes are worth counting separately,
since they are *partial-implementation* misses rather than missing mnemonics:
`unsupported extend/shift specifier`, `unexpected operand`,
`immediate %ld out of range`, `invalid bitmask`, `shift amount out of range`,
and `expect()` diagnostics such as `vector operand with arrangement`.

`bic` **is** implemented by `0003` (`TOK_ASM_bic`, both the register and
bitmask-immediate forms), which is the single opcode run 1 died on.

---

## Correction — mob has its OWN arm64 assembler (2026-07-24)

The first attempt to use this series skipped it, on the reasoning that
`arm64-tok.h` being present in mob meant the series was already upstream. That
reasoning was wrong, and the run that exposed it is worth recording:

```
mob HEAD: 85ba3ae8f1e22044255d54c28be04e5fc3e88ae0   2026-07-24 19:27:21 +0200
arm64-tok.h PRESENT -- the series is already upstream; not patching
tcc version 0.9.28rc 2026-07-24 mob@85ba3ae8 (AArch64 Linux)
/tmp/probe.s:5: error: ARM64 instruction 'bic' not implemented
```

Two things follow. **`ARM64 instruction '%s' not implemented` is mob's wording**
— the string appears nowhere in this series, whose unknown-opcode path says
`unrecognized opcode %s`. And this series **does** implement `bic` with an
immediate: `asm_opcode_imm_sh` inverts the operand (`op3.e.v = ~op3.e.v`) and
encodes it as an AND-bitmask, and `~1` is a valid bitmask immediate.

So mob carries a *different* arm64 assembler, which knows the mnemonic well
enough to name it in an error and has no handler behind it. On this instruction
the vendored series is stronger than upstream. `arm64-tok.h` does not
discriminate between them; nothing short of measurement does, which is what
`.github/workflows/tcc-arm64-asm-gap.yml` is for.

The series cannot simply be applied on top of mob — 0003 creates `arm64-tok.h`,
which now exists. To measure it, rewind to the commit before mob's own
assembler landed and apply there:

```sh
FIRST=$(git -C tccsrc log --reverse --format=%H -- arm64-tok.h | head -1)
git -C tccsrc checkout "${FIRST}^"
for p in spikes/stage3/patches/tcc-arm64-asm/000*.patch; do
    git -C tccsrc apply --3way "$p" || exit 1
done
```

## Files here

| | |
|---|---|
| `000{1,2,3}-*.patch` | the unwrapped series |
| `SERIES-COVERAGE.txt` | the 67 instruction mnemonics 0003 implements, one per line — the input to the gap job's bucketing |
| `arm64-tok.h` | 0003's new file, extracted whole; useful if the series is ported forward as files rather than as a diff |

## If the series is ported forward rather than rewound to

`arm64-asm.c` (+2579) and `arm64-tok.h` (+247) are effectively whole new files;
everything else in the series is ~50 lines of hooks —
`arm64-link.c` relocs (18), the `subst_asm_operand` signature across five
backends plus `tcc.h`/`tccasm.c` (7), `tccasm.c` (26), `tccpp.c` (4),
`tcctok.h` (6). Mob's own assembler will already have made equivalent hook
changes, so a forward port is mostly a question of which `arm64-asm.c` you
want, not a merge.

---

## Measured — the series covers 20 of 20 (2026-07-24, runs 81636079843 / 81636079908)

`tcc-userland-arm64` at `variant: mob` ran musl's own build with `make -k` and
enumerated every mnemonic mob's assembler rejects. Twenty:

```
adrp   bic    cmp    dup    fabs   fcvtas fmadd  fmaxnm fminnm frinta
frinti frintm frintp frintx frintz fsqrt  ldaxr  rbit   svc    uxtw
```

**All twenty are in `SERIES-COVERAGE.txt`.** Not most — all. Mob's assembler
also produced 50 `unsupported system register` errors, and the series is the
thing that adds `fpsr`, `fpcr`, `tpidr_el0` and `dczid_el0`, along with `zva`
for `dc zva`. That combination — `dc zva` plus `dczid_el0` — appears in musl's
`memset` and essentially nowhere else, which is what "enough to compile musl
1.2.5" looks like from the inside: the series was developed against this exact
build.

So the musl version was never the problem. `MUSL_VER` is `1.2.5`, the version
the series names. What had not happened was applying the series.

### A second blocker, unrelated to the assembler

The same run turned up **66 `_Complex is not yet supported` errors**. That is
tcc's **C front end**, not its assembler, so no amount of assembler work touches
it. The errors are confined to `src/complex/`, which nothing in busybox or a
PID-1 shell references, so `tcc-userland-arm64` now drops that directory as a
named PASS 3 substitution. The resulting `libc.a` is not a complete musl and
must not be described as one.

### And one that is not a compiler problem at all

`make -k` still got **917 objects** built. The `.s` files that failed all have
C fallbacks in musl's own tree — `fenv`, `tlsdesc`, `vfork`, `longjmp`,
`restore`, `__set_thread_area`, `__unmapself`, `clone`, `syscall_cp` — which
corrects an earlier note here that `setjmp`/`clone`/`syscall_cp` had none. After
PASS 2 dropped those nine, only `adrp` (in `crt_arch.h`, so no crt links) and
`svc` (in `syscall_arch.h`, so no syscall compiles) remained. Both are in the
series.

---

## Base selection (2026-07-24, second attempt)

`variant: mob-plus-series` rewound to `FIRST^` — the commit before mob's own
assembler landed — and 0003 failed:

```
error: patch failed: tccasm.c:1178
error: tccasm.c: patch does not apply
```

`FIRST^` is not the author's tree. Mob's assembler landed months after the
series was posted, so `tccasm.c` had already drifted past the two-line hunk
0003 adds there. Guessing a commit by ancestry was the mistake, not the
specific guess.

`apply-series.sh` replaces the guess. Every `index <pre>..<post>` line in a
git-formatted patch records the blob hash of the file the author had, so the
correct base is the commit whose blobs equal those pre-images — findable, not
estimated. The series' base blobs are:

```
arm-asm.c 2f9cca46   arm64-asm.c a97fd642   arm64-link.c cfdd95ea
i386-asm.c 64e44ce9  riscv64-asm.c 63aa468e tcc.h 1c2f6949
tccasm.c 523cbab0    tccpp.c e19e8504       tcctok.h b7cc9d40
```

Two things to notice. `arm64-tok.h` has no entry — it is created by 0003, so
its pre-image is all zeroes and there is nothing to match. And `arm64-asm.c` is
`a97fd642`, not the `e95de34f` in 0003's header: a file touched by more than one
patch in a series has a different pre-image in each, and only the **first** is a
real repository blob. The later ones are intermediate states that exist nowhere
in history. Keying on the wrong one finds nothing.

The script scores all nine files against the chosen base and prints match/drift
per file, so a partial match is visible before the first `git apply` rather than
surfacing as a conflict three patches in.

---

## Testing the series without an arm64 machine

`fetch-base.sh` packages the two things needed to settle the assembler question
off-CI: tinycc at the series' base commit (found by blob hash, not by date), and
every aarch64 `.s`/`.S` file in musl 1.2.5 plus the arch headers — about 3 MB
total.

An arm64 host is **not** required. tcc's integrated assembler is target code,
not host code, so on any machine:

```sh
tar xzf tcc-arm64-asm-base.tar.gz
cd tinycc && bash ../apply-series.sh .
./configure --enable-cross && make -j"$(nproc)"      # builds arm64-tcc
./arm64-tcc -c ../musl-asm/src/string/aarch64/memcpy.S -o /tmp/o.o
```

`arm64-tcc` assembles arm64 input exactly as a native tcc would. Only *running*
the resulting objects needs aarch64, and nothing about the assembler question
requires running them — the 20 missing mnemonics are all assemble-time failures.

This is the cheap way to iterate: a CI round trip is minutes and a runner slot,
whereas the loop above is seconds and can be repeated against every musl asm
file at once.

---

## Resolved — the archive expanded tabs (verified locally, 2026-07-24)

The blob search found the right base first try:

```
base: 5ec0e6f84b47ebd8c269b581712666313f5edaef  2025-12-21  "some reverts & fixes"
      6 of 9 blobs match; i386-asm.c, riscv64-asm.c and tcctok.h drifted
```

and 0003 **still** failed at `tccasm.c:1178`. The base was not the problem. The
file has tab-indented continuation lines:

```
\t\t*str == 'q' || *str == 'l' ||
#ifdef TCC_TARGET_RISCV64
\t\t*str == 'z' ||
```

and the patch's context for the same lines is spaces. **The patch files contain
zero tab characters; `tccasm.c` alone contains 163.** The mailing-list archive
expanded tabs along with wrapping long lines. Added lines are unharmed — C does
not care about indentation — but context lines must match byte for byte, and
tab-indented context never can.

`git apply --ignore-whitespace` is therefore required, not defensive, and
`apply-series.sh` now passes it.

### Verified end to end, off-CI

Applied to the base above on an **x86_64** host, then built as a cross
assembler (`./configure --enable-cross && make arm64-tcc`):

```
series applies                    3 of 3 patches, clean
musl 1.2.5 aarch64 asm files     16 of 16 assemble
  crti crtn fenv dlsym tlsdesc vfork longjmp setjmp restore
  sigsetjmp memcpy memset __set_thread_area __unmapself clone syscall_cp
the 20 mnemonics mob rejects     19 of 20 direct, 20 of 20 in real musl forms
adrp via arch/aarch64/crt_arch.h      ok
svc  via arch/aarch64/syscall_arch.h  ok
```

No arm64 hardware was involved. tcc's integrated assembler is target code, so a
cross `arm64-tcc` assembles arm64 input identically; only running the objects
needs aarch64.

### One real limitation found

Vector arrangement specifiers are **case-sensitive, uppercase only**:

```
dup v0.16B, w1    ok
dup v0.16b, w1    error: vector operand with arrangement expected
dup v0.8H, w1     ok
```

musl's `memset.S` writes `v0.16B`, so musl is unaffected — which is exactly how
a gap like this survives in something "enough to compile musl 1.2.5". Lowercase
is the more common style in hand-written arm64 asm, so anything beyond musl is
likely to hit it. Worth a one-line fix in the arrangement parser if this series
becomes ours rather than a borrowed rung.

---

## Script verified end to end (2026-07-24)

`apply-series.sh` shipped once with `VERIFIED_BASE` referenced but never
assigned — the edit that added the assignment targeted a line that exists in
`fetch-base.sh`, not this one, and nothing checked that the replacement matched.
Under `set -u` that is a fatal `unbound variable` after the base search has
already succeeded, which makes it look like a base-finding failure when it is
not.

The script is now run end to end before shipping, against the real base tree:

```
tccasm.c blob 523cbab0 -> base located
6 of 9 blobs match (i386-asm.c, riscv64-asm.c, tcctok.h drifted; all applied)
0001, 0002, 0003 applied
arm64-tok.h 247 lines, arm64-asm.c 2651 lines
./configure --enable-cross && make arm64-tcc
musl 1.2.5 aarch64 asm: PASS=16 FAIL=0
```

The three drifted files apply anyway. In a full clone `--3way` has the real
blobs; in a shallow or synthetic tree it falls back to direct application, and
both routes succeed.

---

## 0004 — the series does not build natively without it (2026-07-24)

The series applied 3/3 in CI and then failed to **compile**:

```
libtcc.a(arm64-asm.o): in function `asm_opcode':
arm64-asm.c:(.text+0xff4): undefined reference to `assert'
```

`arm64-asm.c` calls `assert(0)` at two sites and never includes `<assert.h>`.
Whether that is fatal depends on the build shape:

| build | how arm64-asm.c is compiled | result |
|---|---|---|
| cross target (`make arm64-tcc`) | inside the single `tcc.c` translation unit, whose include chain already pulls in `<assert.h>` | links; resolves `__assert_fail` |
| native (`make tcc`) | separately, into `libtcc.a` | implicit declaration, `undefined reference to 'assert'` |

**This is why the local verification missed it.** The off-CI test built only
`arm64-tcc`, the cross target — enough to prove the assembler assembles, and
structurally incapable of exposing a native-link problem. "Applies and
assembles" was verified; "builds the way CI builds it" was not, and the two were
reported as if they were the same thing.

Reproducing it off-CI needs `./configure --cpu=arm64`, which selects the
`libtcc.a` structure even on an x86_64 host. With that, the failure appears
identically, `0004` fixes it, and the result still assembles 16/16.

The check that would have caught this is not "did it build" but "did it build
**both ways**" — the amalgamated unit and the separate object are different
compilations of the same file, and only one of them is what the runner does.

---

## 0005 — why the tcc-built musl SIGILLs (2026-07-24)

musl built (1277 members), tcc linked a static aarch64 ELF, and it died with
SIGILL. The ladder localised it to rung B — crt + libc, `main` returning
immediately — and gdb named the instruction:

```
Program received signal SIGILL
=> 0x400dac:  udf  #0
   0x400db0:  add  x3, x3, #0x40
   0x400db4:  dc   zva, x3
#1 __init_libc   #2 __libc_start_main   #3 _start_c
```

`udf #0` is a **zero word**. tcc pads `.align`/`.p2align` with zero bytes
unconditionally (`v = 0; memset(ptr, v, size)`), which on x86 is inert filler
and on arm64 is a permanently-undefined instruction. musl's `memset.S` puts
`.p2align 4` directly in a fall-through path:

```
    sub     count, count, 128
    .p2align 4
.Lzva_loop:
    add     dst, dst, 64
```

so the padding executes. `0005` fills implicit alignment padding in
`SHF_EXECINSTR` sections with `NOP` (0xd503201f), as GNU as does, only when
offset and size are whole instructions, and leaves an explicit `,fill`
argument alone.

**This is a tcc bug, not a bug in the series** — `asm_parse_directive` is
generic code, untouched by the arm64 patches.

### Why "enough to compile musl 1.2.5" was true and still produced a broken libc

The `.Lzva_loop` path is guarded by `mrs zva_val, dczid_el0; cmp zva_val, 4`,
so it only executes on CPUs whose ZVA block size is 64 bytes. Compiling musl
never touches it. Running it on this hardware does. Compiling and running were
never the same claim, and only one of them had been tested upstream.

### Verified from a clean tree

Fresh extract, all five patches applied by `apply-series.sh`, native build
path (`--cpu=arm64`), then reassembled: `memset.o` has **no** UDF words, its
`.text` is unchanged in length, and all 16 musl aarch64 asm files still
assemble.

---

## A tcc-built musl runs (2026-07-24)

With 0001-0005 applied, the runtime ladder is clean:

```
A nolibc   ok (exit 7)     raw _start + exit syscall -- codegen and ELF
B startup  ok (exit 7)     crt1 + libc -- __libc_start_main, TLS, auxv
C malloc   ok (exit 7)     + malloc/free, string.h
D stdio    ok (exit 7)     + printf
ALL RUNGS PASS
```

`libc.a` is 2,794,560 bytes across 1,277 members, built by tcc, running on a
gcc-built kernel. The five patches that got there:

| | |
|---|---|
| 0001-0003 | the Feb-2026 series, unwrapped from the mailing-list archive |
| 0004 | `#include <assert.h>` -- the series does not build natively without it |
| 0005 | NOP-fill executable alignment padding -- without it musl SIGILLs in memset |

0004 and 0005 are ours. Neither is an arm64-assembler bug: one is a missing
include, the other a generic tcc directive-handling bug that only shows on an
architecture where a zero word is an illegal instruction.

---

## busybox: two invocation fixes and one config choice

Neither of the busybox blockers was an assembler or codegen problem.

**`-Wp,-MD,<depfile>`** — kbuild's dependency-generation flag. tcc's
`TCC_OPTION_Wp` calls `insert_args(..., ',')`, splitting on commas and
re-parsing each piece as its own argv entry, so the depfile lands as a second
INPUT FILE: *cannot specify output file with -c many files*. tcc spells the
same request `-MD -MF <file>`. Handled by
`spikes/stage3/probes/tcc-cc-wrapper.sh`, a CC shim, so busybox itself is
unmodified.

**`__GNUC__` undefined** — `include/platform.h` does:

```c
#if !__GNUC_PREREQ(2,7)
#  define __attribute__(x)
#endif
```

tcc does not define `__GNUC__`, so every attribute in busybox was silently
discarded, `PACKED` structs got natural alignment, and busybox's own size
assertions failed as *invalid array size*. Fixed with
`-D__GNUC__=4 -D__GNUC_MINOR__=0`.

**4.0 exactly.** At `__GNUC_PREREQ(4,1)` busybox enables
`_Pragma("GCC visibility push(hidden)")`, which tcc rejects with *identifier
expected* and which the libiproute headers use. Verified by preprocessing
platform.h at each version and checking which constructs survive:

| claim | `PACKED` | visibility pragma |
|---|---|---|
| undefined | discarded | not emitted |
| 4.1 | works | emitted -- tcc cannot parse |
| **4.0** | works | not emitted |

**`tc` disabled** — a config choice, not a compiler gap. `networking/tc.c`
references `TCA_CBQ_MAX` and `TCA_CBQ_RATE`, removed from the Linux uapi when
the CBQ qdisc was dropped; busybox 1.36.1 predates that. **GCC fails on the
same file with the same error**, which is what makes this a
busybox-vs-kernel-headers version mismatch rather than anything about tcc.

### Caveat for the glibc flavor

`-D__GNUC__` is safe against musl and **is not against glibc**. glibc gates
transparent unions on it -- `__SOCKADDR_ARG` becomes
`union { struct sockaddr *...; } __attribute__((__transparent_union__))` --
and tcc has no transparent unions, which produces
*cannot convert 'struct sockaddr *' to 'union <anonymous>'* at every socket
call. glibc's `limits.h` and `floatn.h` also change behaviour. If the glibc
flavor is ever built with tcc, this flag does not carry over.

### busybox link: `--start-group`

Every busybox object compiled; only the final link failed:

```
tcc: error: unsupported linker option '--start-group'
```

`scripts/trylink` wraps all 28 archives in `-Wl,--start-group ...
-Wl,--end-group` so the linker re-scans them until symbols stop resolving. tcc
has no such option, and it does **not** re-scan -- an archive listed before the
object needing it is simply missed. Measured with a three-deep chain:

```
liba.a libb.a libc.a                 -> links (dependency order)
libc.a libb.a liba.a                 -> undefined symbol 'bar'
libc.a libb.a liba.a (repeated once) -> undefined symbol 'baz'
```

so repeating the list buys one extra pass, not N.

tcc **does** support `--whole-archive`, which loads every member regardless of
demand and makes ordering irrelevant; the same chain links in either order with
it. The shim translates `--start-group`/`--end-group` to
`--whole-archive`/`--no-whole-archive`.

For busybox this is close to semantically neutral: the archives hold the objects
for the applets the config selected, and the final binary is meant to contain
all of them. The change can make the binary larger; it cannot make it wrong.

---

## A pin that could drift silently (2026-07-24)

One run built **busybox 1.37.0.git instead of the pinned 1.36.1**, and nothing
said so. The fetch chain degraded step by step:

```
1. busybox.net tarball        -> SSL connection timeout (transient)
2. mirrors.kernel.org/gentoo  -> 404 (wrong path)
3. git clone --branch 1.36.1  -> "Remote branch not found"
                                 busybox git tags use UNDERSCORES: 1_36_1
4. git clone <no branch>      -> master == 1.37.0.git
```

The last fallback had no branch argument at all. The compile error it produced,
`'sha1_process_block64_shaNI' undeclared`, was master-only code -- 1.36.1 keeps
both the declaration and its use inside
`#if defined(__GNUC__) && (defined(__i386__) || defined(__x86_64__))`, and had
compiled cleanly in the previous run.

That error was a symptom. The bug was that a run could measure a different
source tree than the one recorded and report it as if it were the pinned one --
in a project whose stated thesis is hermetic, reproducible, pinned builds.

Fixed three ways, and the third is the one that matters:

1. the git tag is derived correctly (`tr . _`), so path 3 works;
2. the unpinned bare clone is gone -- the GitHub fallback now takes the same
   tag, and a GitHub tag tarball replaces the dead gentoo mirror;
3. **both musl and busybox now assert their version after fetch and fail the
   run on mismatch.** Every fetch path can succeed with the wrong thing; only
   the assertion catches it. Verified against a real 1.36.1 tree (passes) and a
   simulated 1.37.0 one (fails).

### Correction: `--whole-archive` was the wrong translation

The first attempt at busybox's `-Wl,--start-group` mapped it to
`--whole-archive`, on the reasoning that busybox's archives hold exactly the
applets the config selected so loading all of them "can make the binary larger,
it cannot make it wrong."

That was wrong. Forcing every member in produced:

```
4020 error: Unknown relocation type for got: N
  ~20 error: undefined symbol '__aarch64_cas4_acq', '_Unwind_Resume',
             '__gcc_personality_v0', 'sun_write_table', 'delete_eth_table',
             'run_nofork_applet', '__ehdr_start', '__unordtf2', ...
```

Two separate consequences. Objects for excluded features reference symbols that
genuinely are not in the link. And objects that had never been linked before
carry relocation types `gotplt_entry_type()` does not enumerate, so
`build_got_entries` fails on each one. Loading more than the link needs is not
harmless.

The faithful emulation is **objects first, then archives repeated**. Objects
link unconditionally, so moving them earlier changes nothing; archives are
demand-loaded, so each repeated pass resolves one more level of cross-archive
reference. Measured on a 3-deep chain in reverse order:

```
1 pass  -> undefined symbol 'bar'
2 passes-> undefined symbol 'baz'
3 passes-> links
```

`GROUP_PASSES` defaults to 5 for headroom; a re-pass over an archive whose
members are already linked contributes nothing.

### The musl sysroot needs kernel UAPI headers

Once the CC shim started passing `-nostdinc` (correctly, to keep glibc's headers
out of a musl build), busybox failed on ~40 missing headers: `linux/types.h`,
`asm/types.h`, `linux/fs.h`, `linux/netlink.h`, `mtd/mtd-user.h` and so on.

musl ships the **libc** headers and nothing else. The kernel's user-facing
headers live in `/usr/include/linux`, `/usr/include/<triple>/asm` and
`/usr/include/mtd`, and were previously being picked up incidentally from the
host because nothing excluded them. Excluding glibc correctly also excluded
these.

They are now copied into `muslroot/include` after `make install`, which is what
a real musl sysroot looks like -- musl-cross-make installs kernel headers into
the sysroot the same way. Verified that all 17 distinct headers the failing
build asked for resolve after the copy.

**This is a borrowed input and belongs in the ledger as one.** They come from
the host distro's `linux-libc-dev`. The principled source is
`make headers_install` from the pinned kernel tree, which leg 3 of the roadmap
will have; until then the dependency is real and should be named rather than
absorbed.
