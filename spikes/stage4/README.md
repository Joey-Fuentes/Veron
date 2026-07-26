# Stage 4 — tcc to a booting Linux

**Scope: everything above tcc.** Stage 3 owns reaching tcc from M2-Planet
(`spikes/stage3/README.md`); this stage owns what tcc is then used to build —
gcc, a userland, a kernel, and a QEMU boot. It also owns removing the host
borrowing that stage 3's results were allowed to keep.

**Read this file first for anything above tcc.** The forward plan is
`ROADMAP.md`; the two finished results have their own full records in
`GCC-BACKPORT.md` and `TCC-USERLAND.md`.

---

## What is proven

**The gcc entry point.** gcc 4.7.4 — the last release written in C — with
`gcc/config/aarch64` from 4.8.5 spliced in, builds a `cc1` that emits correct
aarch64 code, under both the host gcc and our own arm64 tcc.

```
configure rc=0   build rc=0   cc1 BUILT
cc1 emits   stp x29, x30, [sp, -48]! / cmp w0, 1 / ble .L4
assembled   ELF 64-bit LSB relocatable, ARM aarch64
ran         exit=55                (fib(10) = 55)
```

That was the leg's whole question, because it makes the gcc route native **and**
C-only. Total adaptation: **0 target hooks, 3 config case arms, 34 `.md`
definitions expanded, 7 qualified attribute refs, 3 functions at 24 call
sites** — nothing structural, and within the ~148 lines the vax control
predicted. Full record in **[`GCC-BACKPORT.md`](./GCC-BACKPORT.md)**. Gated by
`.github/workflows/gcc47-aarch64-backport.yml` and
`.github/workflows/tcc-builds-gcc-arm64.yml`.

**tcc did not miscompile it**: 333 of 333 of gcc's own translation units and 16
of 16 of libgcc's are identical between the host-gcc and tcc builds
(`tcc-gcc-miscompile-check.yml`).

**The userland half of the Linux leg.** A musl + BusyBox userland compiled
entirely by tcc boots as PID 1 under a GCC-built arm64 kernel.

```
==== VERON USERLAND ALIVE ====
pid1  : /bin/busybox        shell and busybox: compiled by tcc
                            kernel under them: compiled by gcc
==== VERON BOOT OK ====
```

Gated by `.github/workflows/tcc-userland-arm64.yml`. Full record, evidence chain
and named substitutions in **[`TCC-USERLAND.md`](./TCC-USERLAND.md)**.

The single real compiler gap it found: **tcc has no dead-code elimination**, so
BusyBox's `if (ENABLE_FEATURE_X)` idiom leaves references to functions that were
never defined. Everything else was build plumbing. The kernel uses the same
idiom via `IS_ENABLED()`, so the kernel leg will meet this again.

## Why LFS and not live-bootstrap

They solve different problems and we need both halves.

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
(`aarch64-veron-linux-gnu` against `aarch64-unknown-linux-gnu`), `--with-sysroot`,
and a libc cross-compiled into the sysroot so the tools find their loader
inside it.

## The ladder, and the box that owns each rung

```
tcc  →  gcc 4.7.4 + 4.8.5's aarch64 backend      last gcc written in C
     →  g++ 4.7                                  built FROM that C
     →  gcc 10.2.0                               C++98 ceiling is "prior to 10.5"
     →  gcc 15.2.0 / 16.1.0                      needs C++14, which 10.2 has
     →  kernel + userland + QEMU boot
```

Each rung has one box. A box builds its own compiler hermetically **and
attempts the next one**, so every link is proven inside a single job — there is
no artifact to hand between workflows, and a broken link tells you immediately
whether the *handoff* failed or the *box* failed.

| box | environment | builds | then attempts | boots? |
|---|---|---|---|---|
| `hermetic-gcc47` | LFS 7.5, glibc 2.19 | gcc 4.7.4 + backend, **libgcc**, libstdc++ | gcc 10.2.0 | no |
| `hermetic-gcc10` | LFS 10.0, glibc 2.32 | gcc 10.2.0 | gcc 15.2.0 **and** gcc 16.1.0 | no |
| `hermetic-gcc15` | LFS 13.0, glibc 2.43 | gcc 15.2.0 + full userland | — | **yes**, linux 7.1.5 |
| `hermetic-gcc16` | LFS dev r13.0-156 | gcc 16.1.0 + full userland | — | **yes**, linux v7.2-rc4 |
| `hermetic-enumerate-host` | host bound | nothing | — | no — it traces what the host supplies |

Only the gcc15 and gcc16 boxes build a kernel. The lower two are about reaching
the next compiler; booting is what the top two exist for.

**These boxes are LFS-shaped scaffolding, and that is temporary.** In the end
state tcc builds rung 1 and there is no host compiler anywhere. LFS is being
used now to get each rung standing hermetically on its own, so that when tcc
is swapped in underneath, everything above already works with no host
dependency. What carries over is the *sysroot discipline* — no `/usr`, every
input declared — not the cross-triplet trick, which exists only because there
is a host to isolate from today.

`10.2.0` rather than live-bootstrap's `10.4.0` for one reason: 10.2.0 has a
book, so the whole surrounding set is a combination somebody has already built
end to end. Both are inside the C++98 range.

**Each box triggers on its own file only.** Editing one never starts another;
concurrency groups, cache keys, artifact names and the in-box helper script are
all namespaced per box, so two of them running at once cannot touch each
other's state.

**This supersedes the `-> gcc 4.8 -> modern` sketch** the earlier roadmap
carried. 4.8 was the entry point when the problem was crossing the C-to-C++
boundary; once 4.7 could target aarch64 and yield g++ 4.7, the next rung became
"the newest gcc a C++98 compiler can build", and that is 10.2.0.

## Status, 2026-07-26

### hermetic-gcc15 (gcc 15.2.0, glibc 2.43) — box green, kernel config stopped it

The sysroot is complete and the box is self-sufficient. Every ladder rung
passes: shell, coreutils, sed/grep/awk, make 4.4.1, as and ld 2.46.0,
gcc 15.2.0, and **compile-and-run inside the box returns 42**.

It then builds software rather than merely running it. Inside, natively:

```
m4 1.4.21, bison 3.8.2, flex 2.6.4, perl 5.42.0    built and installed
linux 7.1.5                                        Image built
initramfs                                          626,575 bytes
```

**The later run did not build a kernel at all.** It stopped in the config step:

```
CONFIG_SYSTEM_TRUSTED_KEYRING came back after olddefconfig
```

The check was right and the disable was not. `SYSTEM_TRUSTED_KEYRING` has no
prompt of its own here — it is turned on by another symbol that `select`s it
(`INTEGRITY_SIGNATURE`), so `olddefconfig` faithfully puts it back every time.
Adding it to a longer disable list would not have helped; the **selector** is
what has to go.

Rather than guess which symbol that is, the step now asks the source: every
selector is a literal `select <SYM>` line in a `Kconfig` file, and the enclosing
`config <NAME>` block names the symbol doing it. It disables, normalises,
verifies, and on failure extracts the *enabled* selectors and disables those
too, up to four rounds — then fails with the symbol named if no enabled selector
exists, because at that point the symbol is on for a reason the search cannot
see and that is a finding rather than something to retry.

Also gone: `yes "" | make olddefconfig`. `olddefconfig` answers new symbols with
their defaults and reads nothing from stdin, so the pipe contributed only
`yes: Broken pipe` to the log.

**An earlier run did build the kernel**, and QEMU then refused to start:

```
qemu-system-aarch64: failed to find romfile "efi-virtio.rom"
```

That is the host's QEMU packaging — `qemu-system-arm` on this runner does not
pull in the option ROMs — so nothing was learned about the kernel. A kernel that
builds and is never loaded is a different open question from one that builds and
panics, and the log distinguishes them.

### hermetic-gcc47 — THE ucontext PREDICTION IS FALSIFIED

The previous version of this box built a `cc1plus` and reported "g++ 4.7
exists". That was `make all-gcc`, which stops before the runtime, so **libgcc
was never built and that g++ could not link a program.** A compiler that cannot
link is not a rung.

The rewrite changes what the box is for:

- full `make`, through **libgcc and libstdc++** — libgcc is the gate
- the gate is a C++98 program that **compiles, links, runs and returns 47**,
  exercising templates, virtual dispatch, `std::string`/`std::vector` and
  `operator new` — not `g++ --version`
- the ucontext prediction is answered *first*, and the verdict step reports
  **NOT TESTED** rather than an answer when the build did not reach it
- the premise itself is checked: the box confirms `struct ucontext` is present
  in glibc 2.19 before claiming a pass means anything
- then it attempts gcc 10.2.0 with that g++
- gcc 4.8.2 is labelled **disposable scaffolding** throughout — it exists only
  because gcc 4.7.2 has no aarch64 backend and so cannot be the cross compiler
  of a sysroot targeting aarch64. tcc replaces it and it never appears in the
  real chain.

It also emits the transplant as `transplant-4.7.4.patch` in its artifacts —
the frozen form that removes the python3 dependency, ready to review and commit.

**Run 1 (2026-07-26) got the whole period sysroot up and built both front
ends**, then died arranging headers:

```
configure rc=0     cc1 65,939,181     cc1plus 71,663,068
make rc=2
The directory that should contain system headers does not exist:
  /usr/include
Makefile:4204: recipe for target 'stmp-fixinc' failed
```

The compiler was fine; the build failed on `fixincludes`. gcc defaults its
system header directory to `/usr/include`, and this box puts everything under
`/tools`. **LFS 7.5 passes `--with-local-prefix=/tools` and
`--with-native-system-header-dir=/tools/include` to both of its own gcc passes,
this file already carried them on the 4.8.2 steps, and the 4.7.4 step did not.**
Fixed, plus a `/usr/include -> tools/include` symlink, because the configure
flag tells the *compiler* where headers are and does not stop a Makefile rule
from checking that `/usr/include` exists.

Two smaller things run 1 exposed:

- **The gate reported the right answer for the wrong reason.** `g++ 4.7 links a
  program: no` — but the diagnostic was `fatal error: string: No such file or
  directory`, i.e. `make install` never ran, so libstdc++ headers were absent.
  Not a linking failure. The gate was honest that nothing linked; it could not
  say the cause was upstream of it.
- **The freeze step emitted an empty patch and shrugged.** `transplant-4.7.4.patch:
  0 lines, 0 files` immediately after the same step proved `config.gcc` gained
  11 aarch64 mentions. An empty diff there is impossible, so 0 meant the
  comparison never happened. It now checks the pristine tree unpacked, and calls
  a suspiciously small diff what it is.

For the record, the handoff step still ran and got gcc 10.2.0 through
`configure rc=0` before gmp stopped it on `C++ preprocessor "/lib/cpp" fails
sanity check` — a missing `/lib/cpp` in the box, not a compiler limit. Moot
until libgcc exists, but it is the next thing in that path.

**Run 2 (2026-07-26) reached the question and answered it. The answer is no.**

With the header fix in place the build got past `fixincludes` and into libgcc
for the first time. The premise was checked before the experiment ran:

```
47:typedef struct ucontext
PREMISE HOLDS: the struct tag exists at this glibc.
```

and the compiler died anyway, unpatched, in exactly the same place:

```
configure rc=0     cc1 65,939,229     cc1plus 71,663,068
/work/g474/libgcc/unwind-dw2.c:1490:44: internal compiler error: Segmentation fault
STILL ICEs at glibc 2.19.  ==> The TRANSPLANT is implicated.
```

**This is the most useful result the leg has produced, and it is a negative
one.** The hypothesis was that the ICE was environmental — glibc 2.26 renamed
`struct ucontext` to `ucontext_t`, so a libc predating the rename should build
libgcc unpatched. Same file, same line, same column, on a libc where the theory
cannot apply. The ICE is **not** the era. It is the transplant.

Three things follow.

1. **The period box has spent its reason for existing, and is gone.** LFS 7.5
   and its gcc 4.8.2 were built to put this one question; the question is
   answered. `hermetic-gcc47` now uses **the same LFS 10.0 sysroot as
   `hermetic-gcc10`** — proven green, one era closer to 2013 than LFS 13.0, and
   a shared recipe so a fix in one box is a fix in both. The gcc 4.8.2 build is
   deleted.

   Two things moved with it, and both were caught by reading rather than by a
   run:

   - **`struct ucontext` → `ucontext_t` is now unconditional**, as a declared
     compatibility patch rather than an experiment. glibc 2.32 is past the
     rename, so 2013 source needs it to compile at all. It prints the number of
     references it rewrote, so it appears in review and not only in a diff.
   - **`--with-native-system-header-dir=/tools/include` had to be dropped.**
     LFS 7.5 kept everything under `/tools` and gcc's default `/usr/include`
     did not exist, which is what broke `fixincludes`. **LFS 10.0 is laid out
     the other way**: the cross toolchain lives in `/tools` and the system
     headers go to `/usr/include`. Carrying the flag across would have
     recreated the identical failure with the directories swapped. The step now
     asserts `/usr/include/stdio.h` and `/usr/include/asm/unistd.h` exist
     *before* the build, because `fixincludes` reports a missing directory only
     after `cc1` and `cc1plus` have already been built — an hour in.

   Also inherited from the gcc10 box, and needed here for the same reason:
   **chapter 7**. gcc 4.7 builds gmp in-tree too, so it would have hit the same
   `gmp/demos/calc: Error 127` for want of bison.
2. **`gcc47-libgcc-ice`'s step 2 is no longer a hypothesis**, it is a way to get
   *past* the fault and reach the rungs above. Its header now says so, and a
   green step 2 is a workaround, not a diagnosis.
3. **The next measurement is the backtrace**, which that workflow already
   builds for: both compilers with `-g`, reproduce from the right directory,
   `gdb --batch -ex run -ex 'bt 25'`. Its own named suspect is the one to check
   first — a 4.8 backend describing its DWARF frame registers one way
   (`DWARF_FRAME_REGISTERS`, `DWARF_FRAME_REGNUM`, the return-column macros)
   against a 4.7 middle-end sizing an array another way, writing past the end.
   If that is it, it is a `port_gcc47_api.py` row rather than anything
   structural.

The freeze step is still emitting an empty patch, and **my own `2>/dev/null` on
the diff is why three runs could not say why.** A missing `diffutils` would look
exactly like this. Stderr is now kept, the exit code printed, and a control diff
run against `config.gcc` — the one file the step above proves changed.

### hermetic-gcc10 (gcc 10.2.0, glibc 2.32) — box green, chapter 7 was missing

Built from the vendored LFS 10.0 book rather than from memory. What that book
does differently from 13.0, each of which would have cost a run:

- **no `/usr` merge** — 10.0 creates real `/bin`, `/lib`, `/sbin`
- `libc_cv_slibdir=/lib`, not `/usr/lib`, for the same reason
- `--enable-kernel=3.2`, `--with-glibc-version=2.11`
- glibc 2.32 needs the LFS FHS patch
- gcc pass 1 takes `--enable-initfini-array` and no PIE/SSP defaults
- binutils 2.35 rejects 13.0's gprofng/dtags/hash-style flags outright

It attempts **both** gcc 15.2.0 and gcc 16.1.0, and runs the second even if the
first fails — 15.2 landing and 16.1 not would mean the stable branch works and
the bleeding one needs a newer sysroot under it, which is a decision rather than
a bug, and running only one attempt would hide it.

**Run 1 (2026-07-26) never built anything.** It died 27 seconds into
`linux-5.8.3.tar.xz`:

```
curl: (92) HTTP/2 stream 1 was not closed cleanly: PROTOCOL_ERROR (err 1)
```

Nothing was learned about gcc 10. Three defects, all in the harness:

- **`--retry` never fired.** curl retries timeouts, 5xx, 408 and 429. Exit 92 is
  a transport-layer HTTP/2 stream error and is not on that list, so `--retry 3`
  was decoration. `--retry-all-errors` is what covers it.
- **HTTP/2 was the failure mode**, not a symptom. `--http1.1` removes it rather
  than retrying into it — cheaper than a bigger retry budget.
- **The summary then lied.** It printed `box compiles and runs: no`,
  `gcc 15.2.0 built: no`, `gcc 16.1.0 built: no` — three confident negatives
  about experiments that never started, which reads as "gcc 10 cannot build
  gcc 15". Both summaries now key on whether the *input* to each step exists and
  report **NOT REACHED** against **FAILED** separately. This is the third time
  this project has paid for a check that cannot distinguish absence from
  failure.

All four fetching boxes got the same hardening, plus mirror fallback for
`cdn.kernel.org` and the real curl error printed on the way out — the old
`get()` in the gcc16 box discarded stderr, so a failure there named no cause.

**Run 2 built the entire LFS 10.0 sysroot** — binutils 2.35, gcc 10.2.0,
glibc 2.32, libstdc++, BusyBox, make, both pass-2 builds — and the ladder passed
every rung including compile-and-run returning 42. Both gcc attempts then failed
within a minute, identically, and **neither failure is about gcc 10**:

```
/work/src-15.2.0/libcody/cody.hh:24:10: fatal error: memory: No such file or directory
gmp/demos/calc: make[5]: *** [Makefile:456: calc.c] Error 127
```

Both are the box being unfinished. **The workflow went chapter 5 → 6 → "use
it", skipping chapter 7 entirely**, and chapter 7 is where LFS installs exactly
these two things:

- **`gcc-libstdc++-pass2`.** gcc pass 2 is configured `--disable-libstdcxx`
  *because* chapter 7 rebuilds libstdc++ natively into `/usr`. Skip it and the
  box has a C++ compiler with no C++ headers — enough to fail on the first C++
  source file any modern gcc contains, and `<memory>` in libcody is that file.
- **`bison`.** Error 127 is "command not found": `calc.c` is a yacc grammar.
  m4 (chapter 6, cross-built, with the book's `_IO_ftrylockfile` sed that glibc
  2.28+ requires) comes with it.

**The ladder had no C++ rung, and that is why this cost a run.** It proved the
box could compile and run C, and the cheapest possible C++ check sat one line
away and was not written — so a missing libstdc++ was reported forty minutes
later by gcc's build system instead of immediately by the rung designed to
catch it. There is now a rung 10 that compiles and runs a program using
`<memory>`, `<string>` and `<vector>`, and it says in as many words that the
attempts below are not worth running if it fails.

### hermetic-gcc16 (gcc 16.1.0) — glibc stops it

binutils 2.46.1 and gcc 16.1.0 pass 1 both build, 1,003 kernel headers install
from linux 7.1.3, and glibc's configure selects the cross compiler correctly.
glibc 2.43 then fails:

```
make[2]: *** [sysd-rules:111: misc/umount.o]  Error 1
make[2]: *** [sysd-rules:111: misc/umount2.o] Error 1
```

Worth noting precisely because **the same glibc 2.43 builds cleanly in
hermetic-gcc15**. Three things differ: `--enable-kernel=5.10` against 5.4, linux
7.1.3 headers against 6.18.10, and gcc 16.1 against 15.2. Which of the three is
responsible is not yet known.

The mpc substitution worked — 1.3.1 in place of the dev book's unmirrored 1.4.1.

### Where that leaves the ladder

| rung | state |
|---|---|
| tcc → gcc 4.7.4 + backend | **proven**, host tools — `GCC-BACKPORT.md` |
| gcc 4.7.4 → libgcc | **the gate, and it has never been reached** |
| libgcc → g++ 4.7 that links | not shown — the old box only built `cc1plus` |
| g++ 4.7 → gcc 10.2.0 | never run — queued behind libgcc |
| gcc 10.2.0 → 15.2 / 16.1 | never run — `hermetic-gcc10` is new |

## The verification we are deferring, on purpose

Every box currently builds each compiler in **one pass**, with
`--disable-bootstrap`. That is a **deferral, recorded as one** — the `deferral`
field of the audit record exists for exactly this — and not a judgement that the
checks are unnecessary. There is nothing to fixpoint until a single pass
completes, and the gate costs ~3x. Both lower boxes take `bootstrap: yes` as a
dispatch input; turning it on is one click when the rungs are green.

What gets turned on, and why each part is needed:

1. **Fixpoint, per builder.** `make bootstrap` builds stage1 with the incoming
   compiler, stage2 with stage1, stage3 with stage2, and requires stage2 and
   stage3 to compare **byte-identical**. The roadmap already calls this out:
   *"gcc insists on exactly the property we would want to prove, using its own
   machinery. Free, and strong."* Nothing in this tree has ever run it.

2. **Builder-independence.** The same source built by our tcc and by the LFS gcc
   will **not** produce identical generation-1 binaries, and never can:
   `genconditions` folds insn conditions at compile time only when the compiler
   building it is GCC, so a tcc-built tree keeps 2,082 patterns where a gcc-built
   one keeps 2,078 and every later insn code shifts by four. Measured in
   `tcc-gcc-miscompile-check`, understood, and benign — those conditions are
   false at run time too.

   The claim that *is* available: both legs reach a fixpoint, and the fixpoints
   **agree on behaviour**. Compile a fixed corpus with each stage3 and diff the
   emitted assembly — the same shape as the 333/333 result. Behavioural identity
   is the claim; byte identity of the stage3s is evidence for it, worth
   reporting and not worth gating on until it has been seen to hold once.

3. **Safety of each handoff is not a separate experiment.** If our 4.7
   miscompiles gcc 10's stage1 in any way that survives, gcc 10's own
   stage2/stage3 comparison fails. A green bootstrapped build **is** the proof.

Neither 1 nor 2 is worth much alone — a consistently miscompiling compiler is a
perfectly stable fixpoint, which is the whole shape of the Thompson attack. It
is the conjunction that carries the argument: for both legs to be silently
broken, tcc and gcc 4.8.2 would have to introduce the same defect independently.

**Where the two arms are needed.** tcc enters the chain at 4.7, so 4.7 is the
only rung that needs building twice. Above it both legs have converged and a
single bootstrapped build per rung is sufficient — which is what makes this
affordable at all.

## Open, in the order they block things

1. **libgcc — the gate for the entire chain.** No libgcc means no linking g++,
   which means no gcc 10, no gcc 15/16, nothing. Two obstacles, not one:
   - The **ICE**: `unwind-dw2.c:1490: internal compiler error: Segmentation
     fault` in `uw_init_context_1`, after 104 libgcc objects compile. Reproduced
     identically under the host gcc *and* under tcc, so it is the transplant,
     not the compiler building it. Hypothesis in `gcc47-libgcc-ice.yml`: glibc
     2.26 renamed `struct ucontext` to `ucontext_t`, and glibc 2.19 predates it.
   - **No run has ever reached the test.** Earlier attempts died at
     `fixincludes` with no `/usr/include`, at configure with no in-tree mpfr,
     and at `python3: not found`. `hermetic-gcc47` is ordered so the question
     is put as early as it can be, and says NOT TESTED when it is not.
2. **g++ 4.7 → gcc 10.2.0 has never been attempted**, and it is the single
   assumption the entire upper ladder rests on. "Requires an ISO C++98 compiler"
   is a floor, not a compatibility guarantee across thirteen years; worth
   checking against the pinned tree's own `install.texi` rather than the book.
   `hermetic-gcc47`'s handoff step attempts it from below and `hermetic-gcc10`
   builds gcc 10 from a host-built toolchain above, so the link is covered from
   both sides and a failure says which side it was.
3. **glibc 2.43 under gcc 16.1 with 7.1.3 headers** — three variables,
   unbisected.
4. **The kernel is still borrowed** in `tcc-userland-arm64`, which boots
   Ubuntu's kernel. That is correct for the ABI claim but is a distro artifact.
   Building `arch/arm64/configs/defconfig` from a pinned tree with the host gcc
   replaces it and supplies the UAPI headers currently taken from
   `linux-libc-dev` — two open items, one build.
5. **Nothing here has been rebuilt twice.** The userland and both sysroots are
   pinned and hashed but have not been shown byte-identical across two runs.
   Cheap, and the natural gate for a project whose thesis is "rebuild and diff
   rather than trust".
6. **QEMU's missing option ROMs** on the runner — nothing to do with the image.

## What is still borrowed

The host gcc builds the cross toolchain, exactly as LFS chapter 5 does.
Removing that is stage 3's job — seed → tcc — not this directory's.

Two smaller ones, both recorded rather than hidden:

- **Kernel UAPI headers** are copied in as content.
- **The transplant needs python3**, which no bootstrap chain has until very
  late. `expand_int_iterators.py` and `port_gcc47_api.py` still run outside the
  box. `hermetic-gcc47` now emits `transplant-4.7.4.patch` as an artifact — the
  frozen form that removes the dependency *and* satisfies the reviewed-delta
  criterion, since nobody can review what a generator did without re-running it.
  Committing that patch and applying it instead of running the generators is the
  remaining half.
- **binutils and make are not known to be tcc-buildable.** gmp/mpfr/mpc are
  (`tcc-builds-gcc-arm64`); `as` and `ld` are what gcc actually needs and every
  box currently borrows them. That belongs on this list from day one, or rung 1
  looks closer to done than it is.

## Method notes worth keeping

Every one of these cost at least one run.

- **Take versions from a book, never from memory.** gcc 13.2 + glibc 2.39,
  BusyBox 1.36.1 under gcc 15, m4 1.4.20 — three runs, three composed sets.
- **A check that cannot fail is not a check.** A `grep -q "^CONFIG_TLS=y"` that
  finds nothing reports "off" whether the symbol is disabled or misspelled.
- **A flag silently ignored looks exactly like a flag that did not work.**
  BusyBox reads `CONFIG_EXTRA_CFLAGS`, not `EXTRA_CFLAGS` or `CFLAGS_EXTRA`;
  three runs produced an identical error before the compile line was checked.
- **Do not name a variable something a build system already owns.** `M4`,
  `BISON`, `FLEX`, `GMP` are autoconf's names for the *programs*; setting them
  to version strings broke the first build in the workflow.
- **`tail` on a `-j` log is not the error.** The failure is wherever it happened;
  the last lines are whatever finished last.
- **Configure first, then modify, then verify.** `oldconfig` re-derives symbols
  and silently undid the same edit three runs running.

## Where things live

```
spikes/stage4/                  this folder -- everything above tcc
spikes/stage4/ROADMAP.md        legs 2 and 3: gcc, and real Linux
spikes/stage4/GCC-BACKPORT.md   the gcc 4.7 + 4.8-aarch64 result, in full
spikes/stage4/TCC-USERLAND.md   the tcc userland result, in full
spikes/stage4/probes/           the transplant, the CC shim, the C probes, PID 1
.github/workflows/hermetic-*    one box per rung; each triggers on itself only
spikes/stage4/books/            the vendored LFS books the ladder is drawn from
spikes/stage3/                  M2-Planet, and reaching tcc -- BELOW this stage
sources/{gcc,musl,busybox,lfs}.toml   url + hash + license + declared substitutions
tools/fetch-pinned.sh           pinned fetch, shared with stage 3
```
