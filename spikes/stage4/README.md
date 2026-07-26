# Stage 4 — tcc to a booting Linux

**Scope: everything above tcc.** Stage 3 owns reaching tcc from M2-Planet
(`spikes/stage3/README.md`); this stage owns what tcc is then used to build —
gcc, a userland, a kernel, and a QEMU boot. It also owns removing the host
borrowing that stage 3's results were allowed to keep.

**Read this file first.** The forward plan is `ROADMAP.md`; the two finished
results have their own full records in `GCC-BACKPORT.md` and `TCC-USERLAND.md`.

---

## The jobs, and where each stands

Six workflows carry this stage. Each triggers on its own file only; none starts
another.

| job | question it owns | state |
|---|---|---|
| `gcc47-aarch64-backport` | can 4.8.5's aarch64 backend live in 4.7.4? | **ANSWERED** — full build, libgcc, xgcc runs |
| `gcc47-libgcc-ice` | why did libgcc never build? | **ANSWERED** — one missing `#include` |
| `tcc-builds-gcc-arm64` | can *our tcc* build that same compiler? | **nearly** — builds it; g++ link unproven |
| `hermetic-gcc10` | a gcc 10.2.0 box, and can it reach 15 and 16? | in progress, chapter 6 |
| `hermetic-gcc15` | a gcc 15.2.0 system that boots | kernel config rewritten, awaiting a run |
| `hermetic-gcc16` | a gcc 16.1.0 system that boots | glibc patches added, awaiting a run |
| `hermetic-enumerate-host` | what does the host still supply? | not a rung; enumeration only |

---

## THE RESULT THIS STAGE TURNED ON

**The ICE that blocked the gcc leg since it opened was one missing `#include`.**

`gcc47-libgcc-ice` found it on 2026-07-26 after four runs, three of which were
lost to faults in the harness rather than the thing under test.

```
4.7.4   get_hard_reg_initial_val declared in gcc/integrate.h:21
4.8.5   ...declared in gcc/function.h:770
```

The aarch64 backend was written for 4.8, so `aarch64.c` includes `function.h`
and not `integrate.h`. Transplanted into 4.7 nothing declares it, and C89 then
assumes an `int` return:

```
aarch64.c:3941: warning: implicit declaration of function
  'get_hard_reg_initial_val' [-Wimplicit-function-declaration]
```

— the **only** implicit declaration in the entire compiler build. On LP64 the
returned `rtx` is truncated to 32 bits and sign extended back:

```
tem    = 0xfffffffff6b46500     <- low half preserved, high half sign bits
fndecl = 0x0000fffff78b6800     <- a valid pointer in the same frame
```

Non-null, so it passed `if (tem == NULL)` at `builtins.c:4568`, and `REG_P(tem)`
dereferenced it at 4581. That is the SIGSEGV, a hundred objects into libgcc,
with nothing on its face connecting it to a header.

**It is a warning, not an error.** The build reported *"0 errors, 471 warnings"*
and nobody read them. With the include added, `libgcc.a` built at 992,532 bytes.

The fix graduated to `tools/port_gcc47_api.py` as a **fourth rule kind**,
`include`, alongside drop / add / rename. It is the most dangerous of the four
because it does not fail at compile time.

### How that answer was reached, and what it cost

Worth recording, because the shape recurs:

- **The suspect named at the start was wrong.** The workflow hypothesised
  `__builtin_init_dwarf_reg_size_table` and `DWARF_FRAME_REGISTERS`. The
  backtrace put the fault in `expand_builtin_frame_address` — a different
  builtin on a different path. The *shape* of the guess was right (a 4.8 backend
  meeting a 4.7 middle-end at the frame surface); the target was not.
- **The ucontext theory was falsified, not merely dropped.** It predicted the
  ICE was environmental, so `hermetic-gcc47` was built on LFS 7.5 with glibc
  2.19 to test it. The box verified its own premise — `typedef struct ucontext`
  present — and the compiler died anyway, same file, same line, same column.
  A libc where the theory cannot apply.
- **The control was read at last**, and the two arms fail *differently*:
  vanilla 4.8.5 gives a clean `field 'uc' has incomplete type` at 129 objects;
  the transplant takes SIGSEGV at 104. Two different faults, so the control's
  failure never explained the transplant's.

---

## What is proven

**The gcc entry point, completely.** `gcc47-aarch64-backport`, host tools:

```
configure rc=0    build rc=0    (full make, through libgcc)
cc1        BUILT
libgcc.a   648,788 bytes
xgcc       BUILT   ->  fib(10) compiled, linked, ran, exit 55
implicit declarations in the whole build: 0
```

Until 2026-07-26 this arm ran `make all-gcc`, which stops before the runtime —
not a choice but a consequence of the ICE. The full build is new, and so is the
gate that **fails the arm on any implicit declaration in the backend**, because
that is now known to be a truncated pointer rather than a style complaint.

**tcc builds that compiler too — including its C++ front end.**
`tcc-builds-gcc-arm64`:

```
make rc=0    (full build, --enable-languages=c,c++)
libgcc.a   989,540 bytes
xgcc       BUILT
cc1plus    BUILT
implicit declarations: 0
```

**What is not yet shown** is that the resulting g++ 4.7 can *link*. The gate ran,
the compile failed, and the diagnostic was destroyed by errexit before it
printed — see the method notes. That is the single open question on this job.

**The userland half of the Linux leg.** A musl + BusyBox userland compiled
entirely by tcc boots as PID 1 under a GCC-built arm64 kernel. Gated by
`tcc-userland-arm64`; full record in [`TCC-USERLAND.md`](./TCC-USERLAND.md).
The one real compiler gap it found: **tcc has no dead-code elimination**, so
BusyBox's `if (ENABLE_FEATURE_X)` idiom leaves references to functions never
defined. The kernel uses the same idiom via `IS_ENABLED()`.

---

## Why LFS and not live-bootstrap

They solve different problems and both halves are needed.

- **LFS** builds a temporary toolchain *to isolate from a host*. Chapters 5–6
  build tools that are deliberately thrown away; chapter 7 enters an environment
  containing nothing else.
- **live-bootstrap** never has a host to isolate from. It starts at a 357-byte
  seed and every byte above it was produced by something below.

Veron's lower half is live-bootstrap-shaped and its upper half is LFS-shaped.
**The seam is tcc, and it is also the stage 3 / stage 4 boundary**: below it,
provenance; above it, isolation.

The isolation is **not static linking** — three runs were lost to that before
the book was read properly. It is a triplet the host does not have
(`aarch64-veron-linux-gnu`), `--with-sysroot`, and a libc cross-compiled into
the sysroot so the tools find their loader inside it.

## The ladder, and the box that owns each rung

```
tcc  →  gcc 4.7.4 + 4.8.5's aarch64 backend      last gcc written in C
     →  g++ 4.7                                  built FROM that C
     →  gcc 10.2.0                               C++98 ceiling is "prior to 10.5"
     →  gcc 15.2.0 / 16.1.0                      needs C++14, which 10.2 has
     →  kernel + userland + QEMU boot
```

| box | book | builds | then attempts | boots? |
|---|---|---|---|---|
| `hermetic-gcc47` | LFS 10.0 | gcc 4.7.4 + backend, libgcc, libstdc++ | gcc 10.2.0 | no |
| `hermetic-gcc10` | LFS 10.0 | gcc 10.2.0 | gcc 15.2.0 **and** 16.1.0 | no |
| `hermetic-gcc15` | LFS 13.0 | gcc 15.2.0 + userland | — | **yes**, linux 7.1.5 |
| `hermetic-gcc16` | LFS dev r13.0-156 | gcc 16.1.0 + userland | — | **yes**, linux v7.2-rc4 |

Only gcc15 and gcc16 build a kernel. The lower two are about reaching the next
compiler.

**These boxes are LFS-shaped scaffolding, and that is temporary.** In the end
state tcc builds rung 1 and there is no host compiler anywhere. What carries
over is the *sysroot discipline* — no `/usr`, every input declared — not the
cross-triplet trick, which exists only because there is a host to isolate from
today.

**`hermetic-gcc47` used to be a period box** (LFS 7.5, gcc 4.8.2, glibc 2.19),
built solely to test the ucontext prediction. That prediction is falsified, so
the period environment buys nothing and the whole 4.8.2 cross toolchain is
deleted. It now shares the LFS 10.0 base with `hermetic-gcc10`, which means
every fix one earns, the other inherits.

---

## The boxes in flight

### hermetic-gcc10 (gcc 10.2.0, glibc 2.32) — chapter 6

The one doing the most work, and the newest file. It is the only box that must
support **C++ inside the box**, because its job is to build another compiler:
LFS chapter 7, libstdc++ pass 2, and bison. gcc15 and gcc16 have no chapter 7 —
their job ends at a kernel, and a kernel is C.

It is also **2020 software on a 2026 host** (gcc 10.2.0, glibc 2.32, binutils
2.35) where gcc15/16 are contemporary-on-contemporary, so it meets every era
bug the others cannot: `_IO_ftrylockfile` removed in glibc 2.28, `MB_LEN_MAX`
against a freestanding `limits.h`, `config.guess` moved into `build-aux/`. And
**LFS 10.0 has no `/usr` merge**, so every path assumption inherited from the
13.0-derived code was subtly wrong.

Resolved so far:

- **the cache was poisoning itself.** `actions/cache` saves on failure, so a run
  that died half way published a half-built sysroot under the same key and the
  next run built on top. Three consecutive failures were plausibly the same
  poisoned tree presenting differently. A `.sysroot-complete` marker is now
  written as the last act of chapter 7; without it the restored tree and all
  `b-*` directories are deleted and the run starts clean. It caught a 4.8 GB
  unmarked sysroot on its first outing.
- **m4 was built in the wrong chapter.** LFS 10.0 lists it **first** in chapter
  6; this workflow had it in chapter 7, after gcc pass 2. Moved.
- **the full `limits.h` went to one directory of three.** The book writes
  `install-tools/include`, which is what fixincludes reads — correct, and not
  sufficient, because the pass-1 compiler cross-builds chapter 6 packages before
  anything regenerates `include-fixed`. Hence
  `bits/stdlib.h:91: "Assumed value of MB_LEN_MAX wrong"`. Now all three.
- **make keeps `config.guess` in `build-aux/`**, as the book says. The top-level
  path failed silently and configure ran with an empty `--build=`.

Open: the m4 block, when it moved, left the shell inside `m4-1.4.18/` and the
next command could not find its tarball. Contained in a subshell.

### hermetic-gcc15 (gcc 15.2.0, glibc 2.43) — kernel config rewritten

The sysroot is complete and self-sufficient: shell, coreutils, sed/grep/awk,
make 4.4.1, as and ld 2.46.0, gcc 15.2.0, and **compile-and-run inside the box
returns 42**. It builds m4, bison, flex and perl natively, then linux 7.1.5 and
a 626,575-byte initramfs.

**The kernel config was rewritten to what the book actually says**, after
several runs spent fighting `CONFIG_SYSTEM_TRUSTED_KEYRING`:

> *"A good starting place for setting up the kernel configuration is to run
> `make defconfig`."* … *"Be sure to enable/disable/set the following features
> or the system might not work correctly or boot at all:
> `[ ] Compile the kernel with warnings as errors [WERROR]`"*

That is the **first** item on the book's list and this workflow never did it.
`CONFIG_WERROR` defaults to `y`, so any warning from a toolchain the kernel was
not tested against becomes a hard error.

And what the book never says, searched across all eleven chapters:

```
extract-cert       0 occurrences
TRUSTED_KEYRING    0
MODULE_SIG         0
certs              0
```

LFS builds this kernel from `defconfig` and never touches the certs machinery.
The openssl justification was inherited from a comment, not from the book, and
several runs went into satisfying it — a seven-symbol disable list, a four-round
hunt for whichever symbol selected `SYSTEM_TRUSTED_KEYRING`, an evidence dump
when the hunt found nothing. **All of it is deleted.** The step is now
`defconfig`, `WERROR` off, verify, build. If `extract-cert` genuinely needs
openssl here, the build will say so, and that is worth one run.

**QEMU has never loaded an image from this box.** Every attempt failed on
`failed to find romfile "efi-virtio.rom"` — the runner's QEMU packaging, not the
image. And on one run the kernel step failed while the initramfs and boot steps
ran anyway, because **any `if:` drops GitHub's implicit `success()`** — so QEMU
was handed a nonexistent kernel and the log read "DID NOT REACH USERSPACE",
which sounds like a kernel that boots badly rather than one never built. Both
fixed.

### hermetic-gcc16 (gcc 16.1.0) — the book required two patches

binutils 2.46.1 and gcc 16.1.0 pass 1 both build, 1,003 kernel headers install,
and glibc's configure selects the cross compiler correctly. glibc 2.43 then
failed on `misc/umount.o` with `cc1: all warnings being treated as errors`.

**The version set was never wrong.** The dev book pins exactly gcc 16.1.0,
glibc 2.43, binutils 2.46.1, linux 7.1.3 — checked against the vendored copy.
What was missing was a *step*. Its chapter 5 says, in as many words:

> Now fix glibc to build against Linux 7:
> `patch -Np1 -i ../glibc-2.43-upstream_fixes-1.patch`

The workflow applied **neither** that patch nor `glibc-fhs-1.patch`. Both are
now fetched from the development patch directory and applied in the book's order.

---

## The verification we are deferring, on purpose

Every box builds each compiler in **one pass**, with `--disable-bootstrap`. That
is a **deferral, recorded as one** — the `deferral` field of the audit record
exists for this — and not a judgement that the checks are unnecessary. There is
nothing to fixpoint until a single pass completes, and the gate costs ~3x. Both
lower boxes take `bootstrap: yes` as a dispatch input.

1. **Fixpoint, per builder.** `make bootstrap` requires stage2 and stage3 to
   compare **byte-identical**. `ROADMAP.md` already calls this out: *"gcc insists
   on exactly the property we would want to prove, using its own machinery.
   Free, and strong."* Nothing in this tree has ever run it.
2. **Builder-independence.** The same source built by our tcc and by the LFS gcc
   will **not** produce identical generation-1 binaries and never can:
   `genconditions` folds insn conditions only when the compiler building it is
   GCC, so a tcc-built tree keeps 2,082 patterns where a gcc-built one keeps
   2,078. Measured, understood, benign. The claim that *is* available: both legs
   reach a fixpoint and the fixpoints **agree on behaviour** — compile a fixed
   corpus with each stage3 and diff the emitted assembly.
3. **Safety of each handoff is not a separate experiment.** If our 4.7
   miscompiles gcc 10's stage1 in any way that survives, gcc 10's own
   stage2/stage3 comparison fails. A green bootstrapped build **is** the proof.

Neither 1 nor 2 is worth much alone — a consistently miscompiling compiler is a
perfectly stable fixpoint, which is the whole shape of the Thompson attack. It
is the conjunction that carries the argument.

**Only 4.7 needs two builder arms.** tcc enters the chain there; above it both
legs have converged and a single bootstrapped build per rung suffices. That is
what makes this affordable.

---

## Open, in the order they block things

1. **Does the tcc-built g++ 4.7 link?** `cc1plus` and `xgcc` exist; the compile
   failed and the diagnostic was lost to errexit. One run answers it.
2. **`hermetic-gcc10` through chapter 7** — libstdc++ pass 2 and bison in the
   box, then the gcc 15 and gcc 16 attempts, neither of which has ever run with
   a working box beneath it.
3. **`hermetic-gcc47` on the LFS 10.0 base** — it inherits gcc10's fixes and is
   the rung that hands off to gcc 10 in the real chain.
4. **g++ 4.7 → gcc 10.2.0 has never been attempted**, and it is the single
   assumption the entire upper ladder rests on. "Requires an ISO C++98 compiler"
   is a floor, not a compatibility guarantee across thirteen years.
5. **Nothing has been rebuilt twice.** No box has been shown byte-identical
   across two runs — cheap, and the natural gate for a project whose thesis is
   "rebuild and diff rather than trust".
6. **The kernel is still borrowed** in `tcc-userland-arm64`, which boots
   Ubuntu's kernel. Correct for the ABI claim, but a distro artifact.
7. **QEMU's missing option ROMs** on the runner — nothing to do with any image.

## What is still borrowed

The host gcc builds the cross toolchain, exactly as LFS chapter 5 does.
Removing that is stage 3's job — seed → tcc — not this directory's.

- **Kernel UAPI headers** are copied in as content.
- **The transplant needs python3**, which no bootstrap chain has until very
  late. `expand_int_iterators.py` and `port_gcc47_api.py` run outside the box.
  `gcc47-libgcc-ice` emits `transplant-4.7.4.patch` as an artifact — the frozen
  form that removes the dependency and satisfies the reviewed-delta criterion.
- **binutils and make are not known to be tcc-buildable.** gmp/mpfr/mpc are
  (`tcc-builds-gcc-arm64`); `as` and `ld` are what gcc actually needs and every
  box borrows them.

---

## Method notes worth keeping

Every one of these cost at least one run, and most were faults in the harness
rather than in the thing under test. The recurring shape is worth naming:
**each failed silently in the direction of looking successful.**

### Shell and CI

- **A reporting step needs `set +e`.** GitHub runs `run:` blocks with
  `bash -e {0}`, so the first non-zero command kills the step. The C++ gate
  printed its header and the step died with `exit 1` and nothing else — the
  driver was found and invoked, the compile failed, and errexit deleted the one
  diagnostic the run existed to produce.
- **Any `if:` drops the implicit `success()`.** A failed kernel config still ran
  the initramfs and boot steps, against a kernel that did not exist.
- **A pipeline exits with its LAST command's status.** `grep … | head || echo
  "none"` never fires the fallback, so an absent symbol prints nothing at all
  and looks like a broken grep. Hit three times.
- **`grep -c` prints the count AND exits 1 on zero matches.** `$(grep -c … ||
  echo 0)` yields `"0\n0"` and the next comparison is a syntax error.
- **`--include` is a GNU grep extension.** The box runs BusyBox, whose grep does
  not implement it — so a Kconfig search that had "never found a selector" had
  in fact never run. Every grep in the same block that used `--include` came
  back blank; the one that did not, worked. That was the tell.
- **A moved block inherits the cwd assumptions of where it lands.** m4 ended
  with `cd m4-1.4.18`; harmless as the last thing in a step, fatal at the head
  of the next one. Wrap in a subshell.
- **Check where an insertion landed, not just that it applied.** An awk-writer
  intended for a step went inside the `box15.sh` heredoc and ran on every box
  invocation.
- **A string replacement that silently matches nothing ships an unchanged
  file.** Assert the anchor exists. One zip went out with none of its changes in
  it because the indentation was off by two spaces.
- **Verify the artifact, not the working tree.** Same reason.
- **`actions/cache` saves on failure.** A build tree is only meaningful
  complete; mark it, and discard an unmarked one.

### Diagnostics

- **Prefer the compiler's message over make's.** make prints several
  `*** [target] Error 1` lines per real failure, so a `head` limit fills with
  summary lines and the actual `error:` never appears.
- **Do not discard stderr on a step that can fail.** `2>/dev/null` on a `diff`
  made three runs unable to say why a patch came out empty.
- **Classify on the whole output, not `head -1`.** The first line of a gcc
  failure is `In function 'foo':`; six ICEs read as six unknowns.
- **A check that cannot fail is not a check**, and a summary must distinguish
  *never ran* from *ran and failed*. A fetch failure once printed three
  confident "no"s about experiments that never started.
- **Name the failing input.** `get()` echoed a basename *before* fetching, so
  the reader had to infer which URL was in flight when curl died.

### Upstream and books

- **Take versions from a book, never from memory.** Three runs, three composed
  sets.
- **And take the *steps* from the book too.** The gcc16 glibc failure was not a
  bad version pairing — the pins were exactly the dev book's. Two required
  patches were simply never applied.
- **Read what the book does not say.** `certs`, `MODULE_SIG` and
  `TRUSTED_KEYRING` appear zero times in all of LFS 13.0. Several runs went into
  a problem the book does not have.
- **Layout details are not portable between books.** LFS 10.0 has no `/usr`
  merge and keeps headers in `/usr/include` while 7.5 keeps everything under
  `/tools`. Carrying `--with-native-system-header-dir` across recreated the
  identical failure with the directories swapped.
- **A flag silently ignored looks exactly like a flag that did not work.**
  BusyBox reads `CONFIG_EXTRA_CFLAGS`, not `EXTRA_CFLAGS`.
- **Do not name a variable something a build system already owns.** `M4`,
  `BISON`, `FLEX`, `GMP` are autoconf's names for the *programs*.
- **`tail` on a `-j` log is not the error.** The last lines are whatever
  finished last.
- **Configure first, then modify, then verify.** `oldconfig` re-derives symbols
  and silently undid the same edit three runs running.

### And one about hypotheses

- **A well-reasoned mechanism is still a guess until something prints a frame.**
  The ICE suspect was named confidently at the start, repeated for weeks, and
  was the wrong builtin on the wrong path. The backtrace took four runs to
  obtain because three separate harness faults stood between the workflow and
  its own payload — and each of those was found only by testing the harness
  rather than reasoning about it.

---

## Where things live

```
spikes/stage4/                  this folder -- everything above tcc
spikes/stage4/ROADMAP.md        legs 2 and 3: gcc, and real Linux
spikes/stage4/GCC-BACKPORT.md   the gcc 4.7 + 4.8-aarch64 result, in full
spikes/stage4/TCC-USERLAND.md   the tcc userland result, in full
spikes/stage4/probes/           the transplant, the CC shim, the C probes, PID 1
spikes/stage4/books/            the vendored LFS books the ladder is drawn from
spikes/stage3/                  M2-Planet, and reaching tcc -- BELOW this stage
sources/{gcc,musl,busybox,lfs}.toml   url + hash + license + declared substitutions
tools/port_gcc47_api.py         the transplant's rule table -- four kinds now
tools/fetch-pinned.sh           pinned fetch, shared with stage 3
.github/workflows/hermetic-*    one box per rung; each triggers on itself only
```
