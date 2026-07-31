# What stage 4 needs from stage 3's tcc

**The question.** Stage 3's deliverable is one artifact: a tcc binary produced
hermetically from the seed. Stage 4 already goes from a tcc to a booting Linux.
The join is a substitution — stage 4 stops borrowing the host to build its
initial tcc and takes ours instead. So the bar for mc-tcc is not "pass tcc's
test suite"; it is **be substitutable for `$TCC` at the bottom of
`spikes/stage4/chain/rung1.sh`**.

This file measures the distance to that bar. Everything in it is read off the
scripts or probed against the binary; where something is unmeasured it says so.

---

## 1. What the stage 4 box actually is

`chain/box.sh:85`:

```sh
  --ro-bind /usr /usr \
  --ro-bind /etc /etc \
```

with compiler binaries bind-mounted to `/dev/null` (`mask_list`, and
`--show-mask` prints the proof). `chain/env0.sh` records the borrow list:

```
bash binutils bison bzip2 coreutils curl dash diffutils file findutils
flex gawk grep gzip m4 make patch perl-base python3-minimal sed tar texinfo
xz-utils bubblewrap libc6 libc-bin cpio kmod qemu-system-arm
```

**So the guarantee stage 4 currently makes is "no host compiler", not "no host
dependencies".** The whole of `/usr` is bound in read-only: glibc headers under
`/usr/include`, `crt1.o` and `libc.a` under `/usr/lib`, plus binutils, make,
perl, bison and flex as executables. `gcc`, `cc`, `g++` and `cpp` are the only
things removed.

That distinction matters for the goal of no host dependency **at any point**:
removing the host compiler is stage 3's job and is nearly done. Removing the
host *libc, binutils, make and perl* is a separate and much larger project that
no rung currently owns. This file is only about the first one, and says so
rather than letting "hermetic" carry both meanings.

---

## 2. What rung 1 asks of its tcc

From `chain/rung1.sh`. `$TCC -B/work/tccsrc` is passed as `CC` to:

| what | what it exercises |
|---|---|
| `./configure` for gmp, mpfr, mpc | GNU autoconf: hundreds of `conftest.c` cycles — compile, link, **run**, read exit codes. Uses `-E`, `-c`, `-o`, `-I`, `-D`, `-L`, `-l`. |
| `make -j` for each | one `-c` per TU, `ar`/`ranlib` archives, link `.o` + `.a` |
| `configure` + `make` for gcc 4.7.4 | thousands of TUs; the build compiles **and runs** generator programs; `--enable-languages=c,c++` because all of 4.7 is C, including cc1plus |

Every compile resolves `#include <stdio.h>` against `/usr/include` and every
link pulls `crt1.o`, `crti.o`, `crtn.o` and glibc from `/usr/lib`.

**None of that surface has been exercised by stage 3.** Every test to date is
single-file `-nostdlib -static` freestanding compilation, which is the correct
shape for isolating codegen and measures nothing here.

---

## 3. What mc-tcc is today

**It has tcc's compiler and not tcc's command-line driver.** micro-c compiles
`libtcc.c` under `ONE_SOURCE=1`, which pulls in `tccpp.c` (4005 lines),
`tccgen.c` (8917), `tccelf.c`, `tccasm.c`, `tccdbg.c`, `tccrun.c` and the whole
aarch64 backend — 695 functions. That is the compiler, and it is real.

What is missing is `tcc.c` (428 lines of `main` and option parsing) and
`tcctools.c` (651 lines of `-ar`/`-impdef`/`-m`). In their place is a
**175-line hand-written driver**, `micro-c-libc/impl/main-tcc.c`, whose own
header says why:

> tcc.c has its own main, but tcc.c pulls in tcctools.c which micro-c cannot
> yet parse (a string in a constant expression, tcctools.c:60). This is the
> smallest driver that exercises the same path.

That driver knows `-o`, `-I`, `-B`, `-c` and `--version`, and **skips every
other argument**. It holds one input:

```c
    char* input = 0;          /* one pointer */
    ...
    input = argv[i];          /* each file overwrites the last */
```

Probed against the binary (`-B` set, under the emulator):

```
  --version                     rc=1  no input file        (-B consumed first)
  -E (preprocess only)          rc=1  crt1.o not found     (not implemented)
  -c to object                  rc=0  1022 bytes           WORKS
  link that object alone        rc=1  _start not defined
  -print-search-dirs            rc=1  no input file        (not implemented)
  -ar (archive create)          rc=1  crt1.o not found     (not implemented)
  link against system libc      rc=1  crt1.o not found
```

**The "multi-translation-unit bug" is not a compiler fault.** Two files in one
invocation fail because the driver keeps one pointer and the second overwrites
the first, so only one TU is ever compiled and the other's symbols are absent —
which is exactly the `undefined symbol 'main'` the hermetic job reports at step
11. It was recorded in `MICRO-C.md` as a codegen frontier for one round. It is
scaffolding we wrote.

---

## 4. The gap, in order

**1. ~~micro-c must compile `tcc.c`~~ — DONE.** EXPERIMENT-zzzf closed it and
`tcc.c` compiles unmodified: **707 functions against libtcc's 695**. `mc-tcc
--version` answers `tcc version 0.9.28rc (AArch64 Linux)`; `-E`, `-c`,
`-print-search-dirs` and multiple input files all work. It was the only parse
blocker in the entire front end. The blocker was `tcctools.c:60`:

```c
    static const ArHdr arhdr_init = {
        "/               ",
        "0           ",
        ...
```

a `static const` struct initialised with string members. micro-c has a
string-literal path for globals but only when the target is a pointer; a
`char[16]` *member* needs the bytes laid out **inline**, which is a feature it
does not have. Closing it removes the hand driver and with it `-E`, `-ar`,
`-print-search-dirs`, `-l`, `-L`, multiple inputs and correct `--version` **in
one step**, because they are tcc's code and always were. Highest-leverage item
on the list, and a parser gap rather than a codegen one.

**IT CANNOT BE STUBBED.** `tcc -ar` is on the critical path: tcc needs no
binutils to run — it has its own assembler and linker — but **gcc does**, so
binutils must be built by tcc, and building it means creating `libbfd.a` and
`libiberty.a` before any `ar` exists. `tcc -ar` is the answer to that
chicken-and-egg. And the initialiser's contents are format-critical:
`ar_name` is `"/               "` and `ar_fmag` is `ARFMAG`, so zeroing them
produces invalid archives rather than degraded ones.

**2a. `gettimeofday`.** `tcc.c:283` calls it and `libtcc.c` never did, so
nothing needed it until the front end was compiled; M2libc has no time syscall
wrapper. Added to `micro-c-libc/impl/runtime.c` returning a constant zero —
see the comment there for the audit of every clock source in the tcc tree, and
why zero is the right answer rather than a degraded one.

**2b. It links and then SIGBUSes.** With both of the above, `tcc.c` links at
1,564,793 bytes and faults immediately on start. **Not diagnosed.** This is
the next investigation and nothing here should be read as predicting its
cause.

**2c. A separate finding, and it affects the binary shipping today.** The
joined `.M1` carries **80 duplicate `:GLOBAL_` labels**, including
`:GLOBAL_STR_g_0_contents` defined twice. micro-c numbers its generated string
labels from zero *per compilation unit*, so any two units collide when joined.
Checked against the **working** mc-tcc build: it has the identical 80
collisions, so this is neither new nor the SIGBUS cause — but it means a string
reference may bind to another unit's string. Invisible to every test we run,
because the twelve programs and all 87 difftest cases are single-unit.

**2. realloc.** 46 of 57 real failures in tcc's own `tests2` (see
`MICRO-C.md`). gcc 4.7.4 is thousands of TUs; nothing at that scale compiles
while an allocator dies on a 60-line test.

**3. The libc-facing surface, entirely unmeasured.** Header search into
`/usr/include`, `crt1.o`/`crti.o`/`crtn.o` lookup, `-L`/`-l`, linking against
`libc.a`, and whether tcc's own `libtcc1.a` builds and links. The first honest
message from that side is `tcc: error: file 'crt1.o' not found`, which means
the driver logic is right and only the inputs are missing.

**4. Running what it builds.** `configure` compiles a program, runs it, and
reads the exit code. A binary that links but does not start makes configure
draw wrong conclusions silently, which is worse than failing.

**5. Then, and only then,** substituting `$TCC` in `rung1.sh` is worth
attempting.

---

## 5. What is *not* required

Recorded because each was asserted here and was wrong.

* **mc-tcc does not need to build a libc.** Stage 4 owns everything above tcc.
  Deriving a musl rung for stage 3 was re-solving a problem one rung up.
* **Multi-file compilation is not a separate feature to implement.** It arrives
  with tcc's real driver.
* **`-run` is not needed.** tcc's own `tests2` default to it
  (`Makefile:140`), but `rung1.sh` never uses it.
* **Stage 4 does not have a userland to lend.** It builds one. What it has is
  the host's `/usr`, read-only, minus compilers.

---

## 6. The honest summary

Stage 3 has a compiler that emits correct aarch64 for every construct in an
87-case suite and 419 of stage 2's 426-program corpus, and a driver that can
compile one file to one object. Stage 4 needs a compiler driver that autoconf
can drive. Those are different artifacts, and the distance between them is
item 1 above plus item 2 — not the twelve end-to-end programs, which are all
freestanding and all below the threshold where any of this begins.
