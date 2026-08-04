# The derivation phase — design

Everything works. This is the phase that makes it *provable*: every file on the
built system traceable to a derivation, every derivation traceable to a hashed
input, every input traceable to this repository or to a named external root.

`ARCHITECTURE.md` §3 defines the seven audit criteria and `ledger/README.md`
names the record fields. `lib/README.md` leaves one decision open — build on
Nix/Guix or implement the model here. This file resolves that, defines the
schema concretely, and sequences the work.

Nothing here changes what the ladder builds. It changes what the ladder
*records* while building it.

---

## The four goals, and why they are one problem

1. **One script, two environments.** `sh veron build` on a laptop and on the
   runner do the identical thing.
2. **Content-addressed derivations.** Inputs hashed, outputs hashed, the pair
   recorded, the cache keyed on it.
3. **Reproducibility, checked.** Two independent runs compared byte for byte,
   with expected differences declared rather than discovered.
4. **Traceable provenance.** For any file on the final system: the path back to
   the seed, viewable.

They are one problem because 4 is a query over the records 2 produces, 3 is 1
run twice and diffed, and 2 cannot be recorded honestly until 1 removes the
build logic from YAML.

---

## Decision 1 — the numbering, first, because everything keys on it

`README.md` records the disagreement plainly: `ARCHITECTURE.md` §2 numbers the
ladder 1–7 with no fork line; `AGENTS.md` §4 numbers it 0–5 with the flavor fork
between 3 and 4. The spike track carries a third numbering of its own (rungs
0–16 plus 3.5 and 4.5, then B0–B8).

A content-addressed store keys derivations by stage identity. Migrating spike
work into `stages/` under two competing schemes bakes the ambiguity into every
record and every path. **This has to be resolved before any record is written**,
and it is the cheapest item on the list.

Recommendation: keep `AGENTS.md` §4's 0–5 with the fork between 3 and 4 as
canonical — it is the one the directory layout already reflects — and rewrite
`ARCHITECTURE.md` §2 to match, with a note that the spike track's rung numbers
are a separate, local scheme that maps into it rather than competing with it.

---

## Decision 2 — implement the model, do not adopt Nix

`lib/README.md` leaves this open. The recommendation is to implement it, for
reasons specific to this project rather than general:

**What Nix would give:** a derivation engine, a store, a sandbox, a binary
cache, and a large body of existing work.

**What it would cost here:** Nix is a substantial host tool with a daemon, its
own store, and its own bootstrap. It would sit outside the box the way
`bubblewrap` does, so the tier-1 budget stays empty and the claim survives —
but it becomes another opaque thing to trust at exactly the layer this project
has worked hardest to keep legible. "Every file traceable to the Veron repo"
reads poorly if the tracing engine is 100k lines nobody in this project audited.

**What is actually missing is small.** The hard parts are done: bubblewrap
sealing, `--unshare-all`, `SOURCE_DATE_EPOCH 0`, pinned inputs with sha256, an
empty tier-1 budget, and a SEAL step that enforces the box contents against a
declared list. The remainder is bookkeeping — hash the inputs, hash the outputs,
write the pair down, key a cache on it. That is a few hundred lines against a
model already designed in `ARCHITECTURE.md` §5.

**Nix's format is still worth stealing**, specifically: content-addressed
outputs, a derivation as a pure function from hashed inputs, and the
store-path-as-identity idea. Take the model, not the dependency.

---

## Decision 3 — extract the build from YAML first

`stage0-stage4-complete.yml` is 3589 lines. The box assembly, the airlock
steps, the SEAL enforcement, the tarball repacking and the boot verification
all live in the workflow. Only `rungs.sh` runs inside the box.

So "the same script locally" does not exist yet. The first change is mechanical
and behaviour-preserving:

```
tools/veron            the entry point, runs anywhere
  build <stage>        one stage, or all
  verify               second run + diff
  why <file>           provenance query
  roots                every external input

.github/workflows/…    becomes: checkout, install airlock deps, `tools/veron build`
```

This is the same refactor `TRUST-BOUNDARY.md` already names as a prerequisite
for the `.s0` driver — "move the checking outside the box" — and it should be
one pass, not two.

**It also fixes a measured problem.** `shell-surface.sh` shows the in-box
scripts are roughly four to one reporting against building. Moving reporting
out of the box is what makes the driver tractable *and* what makes the
derivation boundaries visible, because what remains inside is exactly the pure
function being recorded.

---

## The schema

A derivation is a pure function from hashed inputs to an output. One record per
output, extending the fields `ledger/README.md` already names.

```json
{
  "name": "gcc",
  "version": "4.7.4",
  "stage": 4,
  "flavor": "glibc",
  "output_hash": "sha256:…",
  "short": "07184a9f2b6c",
  "inputs": {
    "sources": [
      { "url": "…/gcc-4.7.4.tar.bz2", "sha256": "…", "sig": "…", "spdx": "GPL-3.0-or-later" }
    ],
    "derivations": [ "sha256:…(binutils)", "sha256:…(musl)", "sha256:…(mc-tcc)" ],
    "patches":  [ { "path": "spikes/…/0001-….patch", "sha256": "…" } ],
    "recipe":   { "path": "stages/4/gcc.sh", "sha256": "…" },
    "env":      { "SOURCE_DATE_EPOCH": "0", "nproc": 4, "kernel": "…", "TZ": "UTC" }
  },
  "builder": "sha256:…(the compiler that ran)",
  "files":   "sha256:…(manifest of installed paths)",
  "repro":   [ { "run": "…", "output_hash": "sha256:…", "match": true } ],
  "deferred": []
}
```

Two fields beyond the existing list, both required for the graph:

- **`builder`** — the hash of the compiler that produced this output, not just
  the sources. This is what makes "which gcc built this" answerable, and it is
  the field that distinguishes the mc-tcc arm from the reference arm.
- **`files`** — a manifest of installed paths with per-file hashes, which is
  what turns a derivation graph into a *file* graph.
- **`short`** — the first twelve hex characters of `output_hash`, resolved by
  prefix the way git resolves a short commit: unambiguous or an error, never a
  guess. This is the node's name in every query, in the tree output, in
  `ledger/` filenames and in the cache key, so a hash read off a chart can be
  pasted straight into `veron show` without a lookup step.

### What counts as an input

Anything that can change the output. The ones that leak silently:

- **`nproc`** — already noted in the logs as an undeclared input. Parallelism
  changes link order and archive member order.
- **kernel version** — `uname` reaches configure scripts.
- **clock** — `SOURCE_DATE_EPOCH 0` covers most of it; `__DATE__`/`__TIME__`
  and `ar` mtimes need explicit handling.
- **locale and `TZ`** — sorting and date formatting.
- **the airlock's own compiler** — busybox is compiled by the runner's gcc.
  Indirect, but it is an input and the record should say so.

### What is allowed to differ

Declared, not discovered. **Measured across four reference runs**, not
theorised:

```
byte-identical every run    gcc  ld  as  libc.so.6  busybox  cc1#1  cc1plus#1
different every run         cc1#2  cc1plus#2  Image  initramfs.cpio.gz
```

Three findings from that:

- **Same size, different hash** (cc1#2, cc1plus#2, Image) means nothing
  structural changed -- no reordering, no different inputs. Something wrote
  different values into fixed-width slots. That is a small, enumerable set of
  causes, and `repro-diff.sh` localises it by byte offset and ELF section.
- **The kernel confessed in its own boot banner**: `Linux version 7.1.5
  (@runnervma9114) ... Mon Aug 3 09:46:45 UTC 2026`. Build user, host and
  timestamp, embedded. Fixed with `KBUILD_BUILD_TIMESTAMP/USER/HOST`.
- **initramfs varied in SIZE as well** -- 11945418 / 11945925 / 11945457 /
  11945530 -- which points elsewhere: `cpio` records mtimes, `find` emits
  directory order, and `gzip` without `-n` embeds a timestamp and filename.
  Different mtimes compress to different lengths. Fixed by normalising mtimes
  to the epoch, sorting the file list, and `gzip -9n`.

### Reproducibility: where it stands

```
all four compilers  cc1, cc1plus, cross and native      IDENTICAL
ld  as  libc.so.6  busybox                              IDENTICAL
Image                                                   IDENTICAL
initramfs.cpio.gz                                       fix now RUNS -- one run so far
```

Measured by `repro-compilers`, most recently across runs `30873921583` and
`30874357692`. **Everything the ladder produces is now byte-identical between
two runs of the same commit except the initramfs**, and that one is a harness
fault rather than an open question.

Three causes were found, and each was one field:

| artifact | cause | fix |
|---|---|---|
| `cc1`, `cc1plus` | gcc's MD5 self-checksum, computed over `ar` archives whose member headers carry mtimes | `--enable-deterministic-archives` |
| `Image` | build timestamp in the kernel's **built-in** initramfs cpio headers | `KBUILD_BUILD_TIMESTAMP` in a form the box's `date` can parse |
| `initramfs.cpio.gz` | the **inode** field in newc headers | `gen_init_cpio` |

**The `Image` non-determinism was self-inflicted, and the hashes prove it.**

```
b4a145a6…   early runs, KBUILD_BUILD_TIMESTAMP="@0"        stable
39442a32…   after the change to "Thu Jan  1 00:00:00 UTC 1970"   varying
b4a145a6…   once the parse check fell back to "@0"          stable again
```

`@0` was the original value and it worked. It was changed to a long date string
**purely so the boot banner would read as a date rather than `@0`** -- a
cosmetic change to a log line. busybox's `date -d` cannot parse the long form,
`gen_initramfs.sh` swallowed the failure with `|| :`, and the built-in
initramfs went back to stamping wall-clock time. Four rounds to find again.

The lesson is not "check your date formats". It is that **a change made for
legibility altered behaviour in a component nobody associated with it**, and
the only visible effect was in an artifact hash nobody was comparing yet. The
fix now tries three forms in order -- long, ISO 8601, `@0` -- and says which
one took, so the banner is legible when it can be and correct always.

**The initramfs fix was written and did not run.** The lookup for the kernel
source hardcoded `$W/src/linux-$KERNEL`; `fetch` unpacks to `$SRC/linux/<dir>`.
The test failed, the fallback path ran, and the archive came back with 419
six-byte differences in exactly the same places as before -- identical evidence,
which is what made it obvious the fix had not executed rather than not worked.

**A wrong hardcoded path fails exactly like a missing tool**, and the only
signal was one line in a log nobody re-read. It now searches for the file and
reports which of the three states it is in -- found and compiled, found and
failed to compile, or not found -- because "gen_init_cpio unavailable" covered
all three.

**With the search in place it runs**, and the log says so:

```
gen_init_cpio built from /build/src/linux/linux-7.1.5 -- deterministic inodes
initramfs spec: 418 entries
initramfs: 11945869 bytes
```

and the result still boots: `VERON-BOOT-OK`, `VERON-TESTS pass=8 fail=0`,
`VERON-GCC-IN-GUEST`. Whether it is byte-identical needs a second run to
compare against; one run cannot answer that, and the previous three attempts
all failed at exactly that step.

**initramfs -- diagnosed.** `cpio -H newc` records an **inode number** in every
file header, and it comes from the filesystem's allocator. mtimes were
normalised and the list sorted; inodes were not, and could not be -- GNU cpio
has `--reproducible` for exactly this and busybox's cpio does not.

The header is fixed-width, so a varying field cannot change the archive's
length. What changes is its content, and gzip then compresses it to a different
length -- which is why the SIZE moved (11945631, 11946088, 11946040) and looked
like content varying when it was one 8-hex field per file.

Fixed with the kernel's own `usr/gen_init_cpio.c`: a deterministic inode
counter and a fixed mtime, built from a generated spec with uid and gid forced
to 0. It is what kbuild uses for `CONFIG_INITRAMFS_SOURCE`, the source is
already unpacked because B6 built the kernel from it, and it costs one gcc
invocation. The old path stays as a fallback that says out loud that it is not
reproducible.

**initramfs -- diagnosis CONFIRMED by measurement, not inference.** The
decompressed cpio comparison landed exactly where the header layout predicts:

```
SAME SIZE, 2514 differing bytes in 419 contiguous runs
    9    14    6
  121   126    6
  237   242    6      one 6-byte run per archive entry
```

419 runs of 6 bytes, one per file, at offsets 8-13 -- inside `ino`, which
occupies bytes 6-13 of the newc header. Nothing else in a 27 MB archive
differs. `gen_init_cpio` replaces the field with a counter.

**Image -- 32 bytes in 4 runs, and the shape is suggestive.**

```
  34301121  34301140   20 bytes
  36884559  36884562    4
  36884675  36884678    4
  36884799  36884802    4
```

A 20-byte run is SHA-1-shaped; three 4-byte runs nearby are not. No section
mapping printed, because a raw arm64 `Image` has no ELF section table -- and
the tool said nothing at all about that, which reads as "no sections differed".
Both fixed: `repro-diff.sh` now prints **the differing bytes themselves** for
runs under 64 bytes, and says outright when a file has no section table.

That byte dump is the lesson from the compiler round. Sixteen bytes of entropy
in `.rodata` were identified only after downloading a 400 MB artifact and
running `dd` by hand. Twenty bytes of entropy is a SHA-1, sixteen is an MD5,
four that decode as an epoch is a timestamp, and printable bytes name
themselves -- so print them, and skip the artifact round entirely.

**Image -- FIXED AND CONFIRMED.** `repro-compilers` reports `IDENTICAL` across
runs `30873921583` and `30874357692`. What it was:

**A timestamp in the kernel's own built-in initramfs.**

Two 43 MB kernels differed in 32 bytes, four runs. Three of them were printable
ASCII, and the surrounding context named the whole thing at once:

```
070701 000002D1 000041ED 00000000 00000000 00000002 6A7131EF 00000000 … dev
magic  ino      mode     uid      gid      nlink    mtime    filesize
                                                    ^^^^ 6A71|31EF -> 6A71|4B3C
```

The Image contains a **cpio archive** -- the kernel's built-in initramfs, with
`dev`, `dev/console` and `root` -- and `0x6A7131EF` is 1786773487, wall-clock
build time. The differing four characters are the low half of the mtime, in
three headers. The fourth run, twenty bytes of entropy, is a build-id derived
from the content: the mtime was the cause and the digest followed it.

**Why `KBUILD_BUILD_TIMESTAMP` did not stop it.** `usr/gen_initramfs.sh` does
roughly

```
timestamp="$(date -d"$KBUILD_BUILD_TIMESTAMP" +%s || :)"
```

and `|| :` swallows the failure. busybox's `date -d` does not parse
`Thu Jan  1 00:00:00 UTC 1970`, so `timestamp` came out empty, no `-t` reached
`gen_init_cpio`, and it used the current time. **The banner worked because the
banner uses the string verbatim and never parses it** -- which is why the fix
looked confirmed for three rounds while half of it was silently failing.

Fixed by checking, inside the box, that the box's own `date` parses the value
to 0, falling back to `@0` if not, and saying which form took. `SOURCE_DATE_EPOCH`
is exported too, since newer kbuild prefers it and it needs no parsing at all.

**The general lesson, and it has now cost three rounds twice.** A setting that
feeds two consumers can be confirmed working by one of them while failing in
the other. `|| :` on a parse is the specific hazard: it converts "this box
cannot read your date" into "no timestamp requested", which is indistinguishable
from not having asked.

### The native gcc WAS not reproducible. It was sixteen bytes, and they are not code.

**Found, diagnosed, fixed.** `repro-compilers` compared two runs' artifacts and
localised it immediately:

```
cross    cc1, cc1plus       IDENTICAL
native   cc1        16 bytes differ, ONE run, offset 32071232, .rodata
native   cc1plus    16 bytes differ, ONE run, offset 34267680, .rodata
ld  as  libc.so.6  busybox  IDENTICAL
```

Sixteen bytes out of 397 MB, contiguous, in `.rodata`. `nm` names it:

```
0000000002295e40 R executable_checksum
cb ed 28 fc 13 9c 52 fa 3a 53 9e 1e 07 f8 90 a3
```

gcc's MD5 of its own components, used to decide whether a precompiled header
matches the compiler reading it.

**Why only that byte range could differ.** `genchecksum` hashes the object
files **and the archives** -- `libbackend.a`, `libcommon.a`, `libcpp.a`,
`libiberty.a`. An `ar` member header carries an mtime, uid, gid and mode, so
the archives differed run to run even though every object inside them was
byte-identical. The linker copies object *contents* into the executable and
never the archive headers -- so the binary came out identical everywhere except
a digest computed over data that never entered it.

That also explains why the *cross* compiler was always stable: rung 11 builds
it through a different path.

**The fix is one flag, at the right place.** `--enable-deterministic-archives`
on binutils -- rung 4, rung 10 and B3 -- makes `ar` zero mtime, uid, gid and
mode. Set at the binutils that builds everything above it rather than as
`AR_FLAGS` per package, so it holds for every archive the system ever creates
instead of the ones somebody remembered to flag.

**What this was not.** Not codegen, not `-frandom-seed`, not debug info, not a
timestamp in the binary. **Every byte that affects what the compiler compiles
was already identical between runs.** The ladder was reproducible; its
self-description was not.

**And the method is the transferable part.** Six runs of log-reading produced a
list of suspects. One artifact comparison produced a byte offset, a section
name, and a symbol. The instrument that mattered was the one that needed no
expected values -- compare two things that should be equal, and let the
disagreement point at itself.

### What was ruled out along the way, and how

Two runs of the mc-tcc arm, compared:

```
cc1  aarch64-unknown-linux-gnu (cross, rung 11)   3e905d2f == 3e905d2f   stable
cc1plus  unknown-linux-gnu                        7772daae == 7772daae   stable
cc1  aarch64-veron-linux-gnu (native, B4)         f31f0cd9 != 24de3e05   DIFFERS
cc1plus  veron-linux-gnu                          7ac160d5 != f5a2b578   DIFFERS
```

Same size both times -- 397,720,192 bytes -- so nothing structural changed;
values differ in fixed slots. And it is specific: the compiler built by gcc 10
at rung 11 is byte-identical, the one built by gcc pass 2 at B4 is not.

**Ruled out by inspecting a single artifact**, which is worth recording so
nobody repeats it:

- **no `__DATE__`/`__TIME__`** -- the only date-shaped string is a SARIF schema
  URL
- **no build-id** -- neither binary has a `.note.gnu.build-id` at all
- **build paths are constant** -- 1,590 occurrences of `/work/src/gcc-15.2.0`,
  the same fixed path inside the sealed box every run
- **`comp_dir` is fixed** -- `/work/src/glibc-2.44/csu`, from `.debug_str`
- **the artifact transfers intact** -- the downloaded `cc1` hashes to
  `24de3e05…`, matching the run log exactly. The `SHA256SUMS` check earned its
  place.

**Where it probably is.** `cc1` is 397 MB, of which `.debug_info` alone is
225 MB and `.text` is 25 MB:

```
225,326,203  .debug_info        57%
 59,865,249  .debug_loclists
 36,774,760  .debug_line
 25,558,288  .text               6%
 16,896,227  .debug_str
```

Debug metadata is ~85% of the binary. A difference is an order of magnitude
more likely to land there than in code by volume alone, and debug info carries
line tables and DWARF strings, historically the least reproducible part of any
build. **`.debug_*` and `.text` are a metadata bug and a codegen bug
respectively**, and `repro-diff.sh` now reports differing bytes per section so
the two are never confused.

**And it suggests a cheaper move than chasing it.** Every producer line carries
`-g`. Nobody debugs the bootstrap compiler; `-g0` or a strip would take `cc1`
from 397 MB to roughly 50 MB and remove most of the surface where this can
hide. Worth doing regardless -- but not as the *answer*, because a compiler
that is not byte-reproducible is telling us something real even when the
evidence sits in a section we do not ship.

**The first attempt at settling it measured the wrong thing**, and is worth
recording because the failure is a general one. `REPRO_GCC=1` ran and reported:

```
A  /usr/libexec/gcc/.../cc1     397720192   installed
B  /work/gcc-repro2/gcc/cc1     397339896   build tree
SIZES DIFFER by -380296 bytes
```

Two variables moved at once -- a different build **directory**, and
**installed** against **build tree** -- so the 380 KB says nothing about
reproducibility. **A comparison that alters what it is measuring is worse than
no comparison, because it manufactures a number** that then has to be
investigated and dismissed. The same shape as `${f##*/}` printing two `cc1`
lines with no way to tell them apart.

Fixed by keeping build one's binaries, deleting its tree, and rebuilding in the
**same path** with the same flags, then comparing build tree against build
tree. The only difference left is that the build happened twice.

**What settles it: `repro-compilers`.** Every completed run already uploads its
compilers as `veron-toolchain`, so the comparison needs no build at all. The
workflow resolves the last two successful runs, downloads both artifacts, and
diffs every `cc1` and `cc1plus` pair. Minutes, no compute, and it works
retroactively on runs that have already happened.

Two things it does that the earlier attempts did not:

- **Pairs by full path, not basename.** There are two `cc1` binaries under
  different triplets; pairing by name would compare the cross compiler against
  the native one and report a difference that is only "these are different
  compilers".
- **Prints both commits.** Two runs of different commits can differ for
  ordinary reasons, and a comparison that does not record which commits it used
  cannot be read later -- which is exactly how an `Image` difference was nearly
  blamed on non-determinism when the cause was a `KBUILD_BUILD_TIMESTAMP`
  change between the two commits.

`REPRO_GCC=1` remains for the case where two runs are not available or the
question is about one run in isolation: it builds the final gcc a second time
in the same box, same path, same flags, and diffs build tree against build
tree.

**The cc1 question turned out not to be a defect at all.** With full paths
printed, the two are:

```
/usr/libexec/gcc/aarch64-unknown-linux-gnu/15.2.0/cc1   397051128
/usr/libexec/gcc/aarch64-veron-linux-gnu/15.2.0/cc1     397720192
```

Different **triplets** -- the cross compiler from rung 11 and the native one
from B4. Two different compilers correctly having different bytes. The basename
`${f##*/}` printed both as `cc1`, and for four runs that read as a
reproducibility failure. **A report that cannot distinguish two artifacts is
worse than no report**, because it manufactures a defect that has to be
investigated before it can be dismissed.

**And nothing here has actually been measured for reproducibility yet.** Every
comparison so far has been across different commits, and in one case across
different arms. Two runs of the *same commit* have never been compared. The
`KBUILD_BUILD_*` fix is confirmed working -- the banner went from
`(@runnervma9114) ... Mon Aug 3 09:46:45 UTC 2026` to `(veron@veron)` -- but
whether `Image` is now stable is unknown and will stay unknown until two runs
of one commit are diffed. That is what the artifacts below are for.

### Per-rung inputs and outputs

Until now a rung reported its work in prose:

```
=== RUNG 4.5 -- rebuild make PROPERLY, now that binutils exists ===
    make 4.4: configured NATIVE (-static was enough)
    make: 1378984 bytes
```

A size and no hash -- enough to notice something changed size, useless for
noticing it changed content, and impossible to trace. And the input list at the
top of the run printed each tarball's **first four bytes**:

```
gcc-15.2.0.tar.xz     101056276   fd 37 7a 58
linux-7.1.5.tar.xz    158401920   fd 37 7a 58
```

`fd 37 7a 58` is xz's magic number. It is identical for every xz file in the
list, so it says the file is xz and nothing about *which* tarball arrived. A
format check standing where a hash belongs.

Both are fixed. `/in` now prints the full sha256 of every input, and each rung
declares what it consumed and produced:

```
=== RUNG 4.5 -- rebuild make PROPERLY, now that binutils exists ===
    make 4.4: configured NATIVE (-static was enough)
    -> /work/prefix/bin/make            1378984  9f3c…64 hex chars…
```

with the manifest carrying both sides, separated:

```
IN.4.5    /in/make-4.4.tar.gz          2382023   40980ac4…
OUT.4.5   /work/prefix/bin/make        1378984   9f3c1d2e…
```

Two details that matter more than the format:

- **The rung label is derived from `head1`, not passed by hand.** Twenty call
  sites asked to remember a label is twenty chances to attribute an artifact to
  the wrong rung, silently.
- **`consumed` is hooked into `untar`, not called per rung.** Every rung
  reaches its upstream through that one function, so no rung can forget to
  declare its input.

### What each run now publishes

```
veron-boot            Image + initramfs.cpio.gz + SHA256SUMS      ~55 MB
veron-toolchain       gcc ld as libc.so.6 busybox, and both
                      gcc installs as libexec-gcc.tar.gz
sysroot-manifest      manifest.tsv -- one line per file:
                      label, path, exact size, full sha256
buildlogs-…           every build log
```

and the same four from the reference arm under `-reference` names, so the two
arms are comparable rather than merely both green.

Three things this enables that were not possible before:

- **Boot it somewhere else.** `Image` and `initramfs.cpio.gz` were hashed in
  the log and discarded with the runner. Nobody outside could boot them or
  check the sha256 the log claimed.
- **Compare two runs without log archaeology.** `diff` two `manifest.tsv`
  files and every differing artifact is named. The step also prints a **sysroot
  digest** -- one sha256 over the sorted manifest -- so two runs can be
  compared by quoting one value before downloading anything.
- **Compare the two arms.** Does the seed-built toolchain produce the same
  system as the host-built one? That is the sharpest question this project can
  ask about itself, and until both arms published manifests it could only be
  answered by grepping two logs for a handful of curated hashes.

And one worth keeping in mind when choosing what to hash: **`/usr/bin/gcc` was
stable while `cc1` was not.** The driver is a thin wrapper; the compiler proper
is behind it. A check against a curated list of binaries would have called this
reproducible. That is the argument for manifesting the whole sysroot rather
than a chosen few.

The usual offenders, in general:

- `ar` archive member timestamps — normalise with `D` (deterministic mode)
- ELF build IDs — pin or strip
- `__DATE__` / `__TIME__` — `SOURCE_DATE_EPOCH`
- embedded build paths — a fixed build prefix
- parallel-build ordering inside archives

Each one is either **normalised** or **recorded as an expected difference with
a reason**. A run that differs in a way not on the list is a failure.

---

## The provenance graph

The deliverable behind "every file traceable back to the Veron repo".

### Capturing file ownership

Each stage installs into the sysroot. Ownership is captured by manifesting the
sysroot before and after a stage and attributing the delta:

- new path → owned by this derivation
- modified path → owned by this derivation, previous owner kept in history
- unchanged → untouched

**The honest limit:** last-writer-wins is wrong for anything built twice — gcc
pass 1 then pass 2 both install `bin/gcc`. So the record keeps the full
sequence, and `why` reports the chain, not a single answer. That is more useful
anyway: "built by pass 2, which was built by pass 1, which was built by 4.7.4"
is the interesting shape.

### Command capture — the level below the graph

The derivation chain answers *which compiler built this*. The requirement is
stronger: expand any edge and see **the exact commands**, all the way down to
the seed. So a derivation records not just a recipe hash but the argv of every
command it executed.

**Two hooks already exist.** `rungs.sh` has eighteen `START JOE: THIS IS THE
COMMAND IM ABOUT TO DO` lines — a hand-rolled command log for the commands that
cost rounds. And `TRACE_APPLETS` already wraps every busybox applet in a script
that appends its own name to `/out/applets-used.txt`. Neither is complete, but
both prove the shape works inside the box.

**The driver is the right place to do it completely.** Everything in the box is
`execve`'d by the shell. A driver we write emits a structured record per exec
for free — no wrapper scripts, no `LD_PRELOAD`, no doubling the run the way
`TRACE_APPLETS` does. This is where the driver design and the provenance design
meet, and it is an argument for doing the driver before the ledger rather than
after.

Record per exec, appended to the derivation's command log:

```
seq  cwd  argv[]  exit  duration  outputs-touched
```

**Volume is tractable.** A gcc bootstrap is order 10⁴ compile commands; the
whole ladder is plausibly 10⁵–10⁶ execs. At ~200 bytes each that is tens to
hundreds of MB raw, and it compresses hard because argv is highly repetitive.
Store it per derivation, compressed, content-addressed like everything else.

**Honest limits, stated so they are not discovered:**

- **`make -j` ordering is not stable** across runs. The command *set* is
  deterministic; the sequence is not. So compare command logs as sets, not as
  sequences, or the reproducibility check fails on scheduling noise.
- **Commands inside `make` are `make`'s**, not the driver's — `make` forks its
  own children. Capturing those needs `make` to be run under the driver's
  tracing, or `make SHELL=` pointed at the driver. The latter is cheap and
  worth designing for, since almost every rung above 3.5 goes through `make`.
- **A command log is evidence, not proof.** It records what ran; the hashes
  record what came out. Both are needed and neither replaces the other.

### The queries

```
veron why /usr/bin/gcc

  /usr/bin/gcc                                          8f21c0d4e7a9
   └─ gcc 15.2.0        stage 5  glibc                  8f21c0d4e7a9
      ├─ builder: gcc 10.2.0                            c3d4a91b6e02
      │  └─ builder: gcc 4.7.4 pass 2                   e5f60b2c8d13
      │     └─ builder: gcc 4.7.4 pass 1                07184a9f2b6c
      │        └─ builder: mc-tcc                       29ab7c1e5f30
      │           └─ builder: micro-c                   3bcd8e0a4172
      │              └─ builder: stage2 pico-c          4def91a35b28
      │                 └─ builder: stage1 macro-as     5e012b46c839
      │                    └─ builder: stage0-as        6f123c57d94a
      │                       COMMITTED, round-trip verified
      ├─ source:  gcc-15.2.0.tar.xz                     6f12aa03b8e1
      │           GPL-3.0-or-later
      ├─ patches: none
      └─ inputs:  binutils 2.47      a71bc2d09e4f
                  glibc 2.44         b82cd3e10f50
                  gmp mpfr mpc       c93de4f21061
```

**Every node carries a short hash**, twelve hex characters of its output hash,
resolved by prefix the way git resolves a short commit — unambiguous or an
error, never a guess. That hash is the node's name everywhere: in the tree, in
`ledger/`, in the cache key, and as the argument to every other query.

### Expanding a node

Any line in that tree expands by its short hash. No need to name the
derivation, and no need to have run `why` first:

```
veron show 07184a9f2b6c

  gcc 4.7.4 pass 1                                      07184a9f2b6c
  stage 4  glibc   built by mc-tcc (29ab7c1e5f30)
  output   /work/out/gcc-4.7.4-pass1                    43,248,128 bytes
  source   gcc-4.7.4.tar.bz2                            1a2b3c4d5e6f
  patches  gcc47-aarch64-changed.patch                  7f8e9d0c1b2a
           gcc47-aarch64-newfiles.tar.gz                2c3b4a5968d7
  env      SOURCE_DATE_EPOCH=0  nproc=4  TZ=UTC
  commands 11,204                                       run `--commands`

veron show 07184a9f2b6c --commands

  [    1] cd /work/bld
  [    2] /work/src/gcc-4.7.4/configure --target=aarch64-unknown-linux-gnu \
            --prefix=/work/out --without-headers --with-newlib \
            CC=/work/mc-tcc                              rc=0    18.4s
  [   47] /work/mc-tcc -c -o libiberty/regex.o -I. -I../include \
            ../../src/gcc-4.7.4/libiberty/regex.c        rc=0     0.8s
  [   48] /work/mc-tcc -c -o libiberty/cplus-dem.o …     rc=0     0.4s
  …
  [11204] /work/mc-tcc -o gcc/xgcc gcc/gcc.o libbackend.a \
            libcommon.a ../libcpp/libcpp.a                rc=0     2.1s

veron show 07184a9f2b6c --commands --grep regex.c
  [   47] /work/mc-tcc -c -o libiberty/regex.o … regex.c  rc=0     0.8s

veron show 6f123c57d94a --commands
  stage0-as                                             6f123c57d94a
  COMMITTED ARTIFACT -- verified, not produced. No build commands.
  Attestation 2e7f04ba91c6 -- `veron attest stage0` for the nine steps,
  `--script` for a runnable copy of them.
```

The seed node terminates the walk, and it terminates it with an **attestation**
rather than with build commands — the correct answer for an artifact that was
verified rather than produced. That attestation is designed below.

### The seed attestation — the terminus, in one screen

The walk ends at `stage0-as` and `elf`, which were **verified rather than
produced**. That verification is the load-bearing claim of the project, so it
needs a form someone can read in one screen, check by hand, and reproduce.

**The chart shows our tools, not the host's.** The steady state is our
assembler and our disassembler doing the round trip, with nothing from binutils
or LLVM in it. Host decoders appear exactly once, historically, in the ROOT
AUDIT line — see below for why that line must stay and why it is not a
weakening.

```
veron attest stage0

  ARTIFACT   stage0-as                     6f123c57d94a    53,248 B
  SOURCE     stage0-as.s0                  a19f4b2c7e08     3,328 lines
  ARTIFACT   elf                           8c04e1d9f273    12,912 B
  SOURCE     elf.s0                        b57d20c8a4e6     1,104 lines
  ARTIFACT   disasm                        f30b6d24e5a1    21,504 B
  SOURCE     disasm.s0                     0e9a71c48b35     2,190 lines

  ROUND TRIP                    tools: stage0-as, elf, disasm  -- ours, all of them
   1  disasm     stage0-as      → asm     7a8b9c0d1e2f
   2  diff       stage0-as.s0     asm                          identical
   3  stage0-as  stage0-as.s0   → obj     3d5e7f9a1b0c
   4  elf        obj            → bin     6f123c57d94a         == ARTIFACT
   5  disasm     disasm         → asm'    5c1e8a03f6d2
   6  diff       disasm.s0        asm'                         identical
   7  stage0-as  disasm.s0      → bin'    f30b6d24e5a1         == ARTIFACT

  SELF-HOST
   8  stage0-as  stage0-as.s0   → gen1    91c7e0a3b5d2
   9  gen1       stage0-as.s0   → gen2    91c7e0a3b5d2         gen1 == gen2
  10  gen2       stage0-as.s0   → gen3    91c7e0a3b5d2         fixpoint
  11  gen1       stage1.s0      → stage1  c4a8f13e6072         == reference

  CROSS-CHECK  same steps, external decoders            8b40e27fc1a5
  ATTESTATION                                            2e7f04ba91c6
```

Every hash on that chart is ours: our artifacts, our sources, our assembler,
our ELF writer, our disassembler. `BUDGET_PATH` is empty here in the same sense
it is empty for the ladder.

### Why the CROSS-CHECK line stays

Steps 1–11 are self-referential on purpose: our disassembler audits our
assembler, and our assembler built our disassembler. On its own that is a
Thompson circle.

`TRUST-BOUNDARY.md` explains what defuses it, and it is **the order**, not the
tools: two independent external decoders verified `stage0-as` and `elf` against
their source *first*, before anything of ours built anything. A subverted
assembler would have had to carry its subversion visibly in a disassembly that
was character-identical to the source under two decoders from different
vendors. It could not have passed that step while hiding anything, so a
disassembler it later builds is not subverted by construction.

So the external decoders are run **every push, alongside ours** -- not as a
dependency of the chain, but as an independent second opinion on the same
artifacts. Ours prove the chain needs no host tools; theirs prove ours are
telling the truth. Neither is load-bearing for the other, and a disagreement
between them is the most interesting failure this project could produce.

```
veron attest stage0 --cross-check

  CROSS-CHECK                                            8b40e27fc1a5
  the same assertions, re-run every push against these artifacts:
    stage0-as                   6f123c57d94a
    elf                         8c04e1d9f273
  by two decoders sharing no code:
    binutils objdump   2.47     d4e5f6a70b19
    llvm-objdump      22.1.8    1b2c3d4e5f60
  asserting:
    both disassemblies identical to each other
    both identical to the committed source under plain diff
    the whole linked ELF reconstructed from disassembly, byte for byte
```

It is pinned to those artifact hashes, so it always states exactly what it
covers.

That is the honest structure, and it is stronger than either half alone. The
chain runs on our tools, so `BUDGET_PATH` is empty and a third party needs no
toolchain to reproduce it. The cross-check runs on two decoders sharing no code
with ours or with each other, so the chain cannot be self-consistently wrong.
Presenting only ours would be a circle; presenting only theirs would understate
what the seed does unaided.

### Reproducing it without trusting the tool

`--script` emits the exact commands with the artifact hashes inline, as a
runnable file depending on nothing here except the artifacts and sources it
names:

```
veron attest stage0 --script > verify-seed.sh
```

Steps 1–11 need only our three binaries, so a third party reproduces the chain
with no toolchain at all. `--cross-check --script` emits the external version
for anyone who would rather use decoders they already trust. Both are offered
because they answer different questions, and CI runs both on every push.

**A human never audits an encoding.** They read `stage0-as.s0`, judge whether
that program is correct, and let the steps carry the judgement to the bytes.
That is the only part of the job a human is good at; the attestation exists so
the rest is one command.

### The rest of the queries

```
veron why /usr/bin/gcc --expand=all --format=json
  every node, every command, machine-readable

veron roots
  every external input, with hash and license — the complete trust surface

veron diff <run-a> <run-b>
  the reproducibility check: first derivation whose output hash differs

veron deps 29ab7c1e5f30 --forward
  what breaks if mc-tcc changes
```

`veron why` terminating at a committed, round-trip-verified artifact is the
whole point. That is the sentence the project exists to be able to print.

### Presentation

- **Default: text tree**, as above. Readable in a terminal and in a log.
- **`--format=dot`** and **`--format=mermaid`** for rendering. Mermaid means it
  embeds directly in the README and in GitHub step summaries.
- **`--format=json`** so it is machine-readable and diffable.
- The ledger is plain files under `ledger/`, one per output hash, so the graph
  is greppable without the tool.

An HTML view is optional and last. The text tree is what gets used.

### It has to be verifiable, not merely recorded

Every hash in the graph is checkable against the artifact it names. `veron
verify --graph` re-hashes each node and each edge and reports mismatches. A
provenance graph nobody can check is the same failure mode as a committed
binary nobody can disassemble.

---

## How this relates to Nix

The model is Nix's and the mapping is close:

| Nix | here |
|---|---|
| derivation | derivation record in `ledger/` |
| store path `/nix/store/<hash>-name` | `output_hash`, short form `07184a9f2b6c` |
| `inputDrvs` | `inputs.derivations` |
| `inputSrcs` | `inputs.sources`, with sha256 and SPDX |
| `nix why-depends` | `veron why` |
| `nix derivation show` | `veron show` |
| `nix-store --query --tree` | the `why` tree |
| sandboxed builder | the bwrap box, `--unshare-all` |
| binary cache keyed on input hash | `lib/cache` |

So the question is not whether the model fits — it does — but whether to run on
Nix's implementation of it.

### The reason not to, and it is structural

**Nix would see the ladder as one derivation, or force it to be twenty.**

A Nix derivation is a black box: inputs in, output out, nothing observable in
between. The interesting content here is *inside* — rung 0 builds mc-tcc, rung
6 builds gcc 4.7.4 with it, rung 8 rebuilds gcc with itself. Expressing that as
one derivation makes the provenance graph exactly one node wide and throws away
everything this design is for.

Expressing each rung as its own derivation is the alternative, and it fights
the current shape: the box is assembled once, sealed once, and every rung runs
inside it against the sysroot the previous rung left. Nix would tear that down
and rebuild it per rung, re-entering the sandbox twenty times and materialising
a full sysroot per step. That is a different build, and the one property most
worth protecting -- `SEAL` enforcing box contents against a declared list -- is
ours, not Nix's.

### Three things Nix does not have

- **Command capture.** Nix records the derivation -- builder, args, env -- not
  the argv of every exec inside the build. Expanding a node to its 11,204
  compile commands is outside the model and would live alongside regardless.
- **`builder` as a first-class field.** In Nix the compiler is just another
  input. It is recoverable, but "which gcc built this, and which gcc built
  that one" is a filtered view we would have to write anyway.
- **The seed attestation.** A round trip with a self-hosting fixpoint and an
  external cross-check is not a build, and there is no derivation shaped like
  it.

### Two things worth being explicit about

**Nix is input-addressed by default**; content-addressed derivations are still
experimental. This design keys on the *output* hash, which is what makes
"independent rebuilders diff their outputs" work as `lib/README.md` describes.

**Nix's own bootstrap is a binary tarball.** It sits outside the box, so the
tier-1 budget survives -- but using a prebuilt binary as the engine that proves
no prebuilt binaries were used is an awkward sentence to have to write, and
this project has been careful about exactly that kind of sentence.

### The objection is about the ladder, not about stage 5

The black-box argument above applies to stages 0–4 and does not extend upward.
The two halves have opposite shapes:

| | ladder, stages 0–4 | package set, stage 5+ |
|---|---|---|
| nodes | ~20 | hundreds to thousands |
| shape | strictly sequential | wide, mostly independent DAG |
| what matters | what happens *inside* a rung | the graph *between* packages |
| build style | one sealed box, incremental sysroot | one sandbox per package |
| variants | none | musl/BusyBox vs glibc/GNU, per package |
| frequency | rarely, hours | constantly, cached |

**For stage 5, black-box is the correct abstraction**, not a loss. A package
genuinely is sources in, files out; nobody needs to expand `zlib` to its
compile commands the way they need to expand gcc 4.7.4 pass 1. And the flavor
fork this project already has — musl/BusyBox against glibc/GNU, parameterised
rather than duplicated — is precisely what a derivation language with overrides
is for.

So the boundary is natural, and it is the one the architecture already draws:
**stage 4 produces a toolchain; stage 5 consumes it.** That is exactly the
interface a Nix or Guix bootstrap expects, with our output standing where
`bootstrap-tools` normally does — a well-trodden pattern, and the same thing
Guix's reduced binary seed work is aimed at.

**What such an engine would and would not give us.** It would not give us
packages: nixpkgs assumes its own bootstrap, so the definitions get written
here either way. What it would give is the language for expressing variants and
overrides, and the store, garbage collection, profiles and rollback — which for
a distribution is not incidental, it is most of the product, and it is a great
deal to reimplement well.

**The requirement that must survive the boundary is `veron why`.** If stage 5
runs on a different engine, the provenance walk has to cross from that engine's
graph into the ladder's and terminate at the seed attestation. That is the
strongest argument for `veron export --nix`: one graph format spanning both
halves, so a query about an installed file does not stop at the toolchain.

### The stage-5 decision: cross-consumption, with a visible boundary

**Nix runs alongside Veron. It does not build on Veron, and Veron does not
evaluate it.** Users get both `veron` and `nix`. Everything Veron installs is
traceable to the seed; everything Nix installs is not, and the system says so.

The reasoning is not that Veron-built packages are traceable -- it is that
**the boundary is visible and countable**. A user can ask which half of their
system is verified and get an exact answer. That is worth more than a system
where everything is nominally traceable but the chain quietly passes through a
`stdenv` and a nixpkgs bootstrap nobody here audited. Two honest halves beat
one dishonest whole.

The two routes not taken, and why:

- **Veron as a nixpkgs bootstrap** (our stage-4 toolchain replacing
  `bootstrap-tools`). Best user experience -- `nix build nixpkgs#hello` just
  works -- and it makes `veron why` worse, not better: the chain would run
  through `stdenv`, bash setup hooks and a bootstrap we did not audit. True,
  and far less meaningful than the chain we have.
- **Veron evaluating nixpkgs recipes and running them itself.** Looks simpler
  than it is. nixpkgs derivations are meaningless without `stdenv` -- take them
  without it and the builder is a pointer into machinery we did not import.
  That is reimplementing setup hooks and phase machinery against a moving
  target we do not control.

### What makes it work rather than merely coexist

**`veron why` answers for Nix-installed files. It does not fail on them.**

```
veron why /nix/store/…-firefox-…/bin/firefox

  NOT VERIFIED BY VERON -- installed via nix
  nixpkgs rev   a3f91c…
  toolchain     nixpkgs stdenv, not Veron's
  traceable to  nixpkgs' own bootstrap, which Veron does not audit
```

Refusing to answer looks like a bug. Answering *not covered, and here is what
it was built by* is the feature -- same query, honest result.

**The split is countable.**

```
veron status
  4,182 files  verified to seed attestation 2e7f04ba91c6
    611 files  installed via nix -- not verified
      3 files  opaque -- vendor firmware, no source
      0 files  unknown
```

A number that can go down over time, and an `unknown` category that should
always be zero. Anything in none of the other categories is a real problem, and
this is what surfaces it.

**`opaque` is for things that cannot be built at all**, principally WiFi
firmware -- see [`STAGE5.md`](./STAGE5.md). They are declared with their hash
and license and counted separately, because a system with three firmware blobs
and 4,182 verified files is an honest description and one that omits them is
not. An Ethernet-only install has zero, which is worth being able to state.

**Store paths are disjoint.** Nix owns `/nix/store`; Veron owns its own prefix.
No shared `/usr/lib`. That is what makes attribution exact rather than
heuristic, and it is the part that is painful to retrofit.

### Nix packages use nixpkgs' own libc, not ours

The consequence that decides the shape: **which half owns the C library.**

Veron owns the system libc and the kernel -- that is the entire ladder. If Nix
packages linked against a glibc our chain built, every nixpkgs substituter
would be useless, because their binaries are built against nixpkgs' glibc.
Users would compile everything from source, and the pitch becomes "Nix works
here, and it compiles."

So Nix packages use **nixpkgs' own glibc from its own store, fully
self-contained, touching nothing of ours.** Two libcs on the system, each
owning its own half.

It is uglier, and it is the right trade:

- the binary cache works, so Nix is genuinely usable rather than nominally
  supported
- the boundary stays exact -- no Nix package links against a Veron artifact, so
  no Veron artifact's verification status depends on a Nix one
- `veron status` stays honest, because there is no partially-verified category
  to invent a name for

The alternative -- sharing our libc -- buys a smaller disk footprint and costs
both the cache and the clean split. Not worth it.

### What this leaves open

Whether Veron eventually grows its own package set large enough that Nix
becomes unnecessary. Cross-consumption is deliberately a *first* step: it makes
nixpkgs available on day one and shows which packages users actually reach for,
which is the evidence needed before committing to writing recipes for them.
The records designed here are the right shape either way.

### The recommendation for the ladder: emit Nix, do not run on it

Implement the model here, and add `veron export --nix` producing `.drv` files
from the ledger. That gives:

- our records as the source of truth, at rung granularity, with command logs
  and the attestation
- a Nix view for anyone who already has that tooling and wants `why-depends`,
  a store, or a cache
- no runtime dependency, and no argument about which engine is authoritative

The export is a serialiser over records that already exist. If it later turns
out that running on Nix is worth it, the records are already the right shape.

## Order of work

1. **Resolve the numbering.** Cheap, blocking, no code.
2. **Extract the build into `tools/veron`.** Behaviour-preserving; the workflow
   becomes a thin caller. Do the reporting-out-of-the-box move in the same pass.
3. **Hash inputs and outputs; write records.** Schema above, one file per
   output under `ledger/`.
4. **Capture file manifests and command logs** per stage — file manifests make
   the graph reach individual files, command logs make each edge expandable.
   The driver emits the command log natively, which is why it belongs before
   the ledger rather than after.
5. **`veron why` / `roots` / `deps`.** Queries over records that already exist.
6. **`veron verify`** — second run, diff, expected-difference list. This is
   cheap only because 2 made a second run one command.
7. **Cache keyed on input hash.** Last, because it is an optimisation and it is
   the step most likely to hide a reproducibility bug behind a cache hit.

Steps 5 and 6 are what turn the existing green run into an auditable one. Steps
1–4 are the work that makes them possible.

---

## What this does not do

It does not change the ladder, the fork, or the boot. It does not remove
`bubblewrap` or the airlock's compiler. It does not make the spike track's
suspended invariants apply retroactively — migrating that work into `stages/`
under the invariants is a separate phase, and this design is what it will
migrate *into*.
