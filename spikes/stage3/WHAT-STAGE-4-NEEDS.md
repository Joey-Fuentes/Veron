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

**It is not tcc.** It is `libtcc.c` compiled by micro-c, linked with M2libc and
a **175-line hand-written driver**, `micro-c-libc/impl/main-tcc.c`, whose own
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

**1. micro-c must compile `tcc.c`, so mc-tcc has tcc's real driver.**
One named blocker, `tcctools.c:60`:

```c
    static const ArHdr arhdr_init = {
        "/               ",
        "0           ",
        ...
```

a `static const` struct initialised with string members. Closing that removes
the hand driver and with it `-E`, `-ar`, `-print-search-dirs`, `-l`, `-L`,
multiple inputs and correct `--version` **in one step**, because they are
tcc's code and always were. This is the highest-leverage item on the list and
it is a parser gap, not a codegen one.

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
