# stage5 — the package set, and what has actually been established

A feasibility tracer for the **ecosystem stage**: does the designed shape —
recipes, a generated plan, gates, a manifest, a ledger record, a deterministic
image — hold as the set grows? Invariants are suspended here as everywhere
under `spikes/`; the production shape is in [`scratch/LAYOUT.md`](./scratch/LAYOUT.md).

**This file was written when nothing had run.** It said so, and said to expect
the first several runs to find harness bugs rather than compiler bugs. That
prediction held, and this is the rewrite.

---

## Where it is

| | count | established by |
|---|---|---|
| packages pinned | **111** | `probe batch` — digest, signature, licence and declared dependencies read from each tarball |
| recipes written | **48** | `packages/*/recipe.toml`, ordered by `veron plan` |
| built, installed, staged, booted | **48 — all of them** | `VERON-BUILD-OK`, `VERON-STAGE5-BOOT-OK`, `pass=51 fail=0` |
| build from declared dependencies alone | **31 of 48** | `stage5-isolate`, per-package overlay roots |
| artifacts with ≥2 fetch routes | **115 — all of them** | `sources/MIRRORS.tsv`, 255 routes, nothing THIN |
| git-pinned (no tarball exists) | **3** | libsfdo, dinit, libxkbcommon |
| dependency names unaccounted for | **0** | `stage5-reconcile --mode fail` across 48 |
| `[undeclarable]` disclosures | **66** across 12 packages | lookups no `.pc` name can answer |

**What is proven, not asserted:**

- **Reproducibility.** At twelve packages, `VERON-G3-OK  4299 files identical
  across two independent builds` — the second from a restored build root, so
  it compared two builds rather than a build against itself.
- **The image reproduces byte-identically**, twice, and boots under the kernel
  this chain built.
- **The guest tests pass** — one per package, generated from the recipes, run
  against the booted image.

G3 was then removed. It doubles every build, which is the wrong trade while the
set grows and most runs exist to find out whether a new recipe works at all.
Restoring it is putting the step back; `veron compare` and the `--mark`
plumbing are untouched.

**`[installs].digest` is the cheaper half of the same question.** It pins a
per-package listing — `f <sha256> <size> <path>` for every file, symlink
targets recorded rather than hashed — so comparing this run's bytes against a
digest a previous run committed is per-package reproducibility **across time**,
for the cost of hashing files that were just written. G3 compares two builds in
one run; this compares every run against the last one that was pinned.

- **Every dependency name is accounted for.** `stage5-reconcile` runs in
  `--mode fail` and reports 0 across 48. Three detectors feed it and none is
  sufficient alone — see [`DEPENDENCIES.md`](../../DEPENDENCIES.md).
- **31 of 48 build from their declared dependencies alone**, in overlay roots
  composed of the stage-4 sysroot plus only what the recipe declares, on a
  bubblewrap built from this repository's own pinned tarball rather than the
  runner's.

---

## The tools, and the question each answers

| tool | question |
|---|---|
| `tools/veron` | what does this set build, in what order, and did it produce the same bytes |
| `tools/probe.py` | what IS this package — version, digest, signature, licence, declared dependencies, and where else can it be fetched |
| `tools/license.py` | what licence does it actually carry, matched against the SPDX guidelines rather than guessed from a filename |
| `tools/lfs.py`, `tools/blfs.py` | what do the books say, so a route is read rather than invented |
| `../../tools/mirror.py` | every route to an artifact, verified before it is recorded |
| `../../tools/fetch-git.sh` | a commit turned into a tarball we generate, for upstreams that publish none |

**Patches are applied by the driver, not by a recipe step.** `packages/<pkg>/
patches/*.patch` run in sorted order straight after the unpack, and a patch
that does not apply is fatal — the source is not what the recipe was written
against, and building anyway produces something nobody described. `PLAN.txt`
records which patches apply, not where they live: a step would have to name
the patches directory, and that path differs between a laptop and a runner,
which broke `plan --check` before anything built.

Python 3.11+ (`tomllib`), standard library only.

```sh
cd spikes/stage5
python3 tools/veron selftest        # the tools honour what callers depend on
python3 tools/veron plan --check    # regenerate and diff against PLAN.txt
python3 tools/veron build --clean
python3 tools/probe.py selftest     # the parsers, against real HTML shapes
python3 tools/probe.py order probed-all.tsv
```

---

## What the runs found, and what each cost

Every one of these was found by building or by reading a tarball. None was
predicted.

**A dependency nothing declares.** `zstd`'s test suite invokes `file(1)`.
Invisible to BLFS (which does not carry zstd), to Arch (which lists what zstd
*links*), and to `probe linked` (which reads `DT_NEEDED`). Only running the
tests finds a test-suite-only build dependency — which is the argument for
keeping suites on when they are affordable.

**`glib` requires `bash`** — and that was only half of it. With bash present
it still crashed, and the console said nothing but *"This is a Meson bug and
should be reported!"*. The cause was in `_b/meson-logs/meson-log.txt`, which
nothing printed: glib looks up `bash-completion`, it is absent, meson falls
back to its **CMake dependency backend**, and dies parsing cmake 4.2.3's trace
output. Three runs went into theories about bash before that log was visible.

The fix is a one-kwarg patch — `method: 'pkg-config'`, which says where to
look rather than whether to require — and it is safe because the dependency
only picks an install directory and glib already has a fallback. **There is no
option for it**; `-Dbash_completion=disabled` was shipped as a fix and was
wrong, which reading the tarball settled.

**This one will recur.** Every meson package reaches that backend the moment an
optional dependency is missing, and most of what remains is meson: mesa,
wlroots, pango, cairo, harfbuzz, gstreamer, foot, fuzzel. A patch per package
does not scale, and whether meson 1.10 and cmake 4.x can coexist is unanswered.

**It recurred inside the same package, one run later.** Run 51 applied the
glib patch cleanly — the busybox `patch` fix worked — got past
`meson.build:2549`, and died at `gio/inotify/meson.build:32` looking up
`libinotify`, with the identical unhandled exception. Two call sites in one
`meson.build`, and no reason to think there were only two. **A patch per call
site is not a smaller version of a patch per package; it is a larger one.**

**The answer is that they do not have to coexist.** meson resolves
`dependency()` with pkg-config first and its CMake backend second, and looks
for cmake in the machine file, then `$CMAKE`, then `PATH` — its own log says
so. `policy/defaults.toml` now sets `$CMAKE` to a path that cannot exist, so
the backend reports not-found and never enters the trace parser. One line, no
recipe changes, and new meson packages inherit it. `cmake_backend_used()`
fails the build if meson's log ever shows `Found CMake:` again, because a
policy nothing checks is a belief rather than a fact.

**Reading glib's tarball afterwards found a third site and closed the
question.** `gio/meson.build:978` looks up `libelf`, which is not in the set —
the next crash, waiting behind inotify. It also settled what the fix could
break: **none** of glib's *required* dependencies route through that backend.
`iconv` and `intl` use meson's builtin handlers, `gvdb` resolves from the
subproject glib ships, and `libffi`, `zlib` and `libpcre2-8` come from
pkg-config under exactly the names their own guest tests check. Separately,
`nls` defaults to `auto`, so `xgettext` is optional and `po/` is skipped —
which is the only reason a set with no `gettext` recipe gets through glib at
all, and worth knowing before someone sets `-Dnls=enabled`.

**That setting was global first, and it should not have been.** `$CMAKE` began
in `[env]`, which handed it to every process in the build — cmake's own
`./bootstrap`, every autotools `configure` — for no benefit to any of them,
and bought a paragraph of hedging about whether `./bootstrap` reads it. **A
question that only exists because of where a setting was put is answered by
moving the setting.** Policy now separates the two cases: `[env]` is what is
true of the whole build, `[tool_env.<prog>]` is what is true of one tool and
reaches only steps whose `argv[0]` is that tool. Seven meson steps carry
`CMAKE`; nothing else does, and PLAN.txt shows both facts.

The same distinction decided where graphite2's fix goes — see below.

**graphite2 1.3.14 cannot be configured by cmake 4.x.** Line 1 of its
`CMakeLists.txt` is `CMAKE_MINIMUM_REQUIRED(VERSION 2.8.0 FATAL_ERROR)`, and
cmake 4.0 removed compatibility below 3.5 as a hard error raised before
anything else is read. The package is from 2018 with no release since, so the
pin cannot move. `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` is the escape hatch
cmake 4.0 shipped for it.

**It is declared in the recipe, not in policy, and that is the rule.** `$CMAKE`
is global because it states something about *this system*: pkg-config is how
dependencies are discovered. This is a fact about *one old tarball*. Hoisting
it would quietly configure every future pre-3.5 package the same way instead
of making each one say so — **the set should have to name its antiques.**

Found by reading the tarball rather than by building: at rung 34 it would have
cost a run that spends thirty rungs getting there.

**cmake installed nothing, and everything worked.** Its install step was
`ninja install` with no `DESTDIR`, so it installed to `/usr` — which inside
the sandbox *is* the build root. cmake ran, its guest test passed, packages
built against it, and `dest/cmake/` stayed empty: absent from the manifest,
described in the ledger as a package that installed no files, and trivially
"reproducible" under G3 because both sides were empty directories. The run
printed `staged 0 paths into the build root` and carried on.

The recipe's own deferral note had said *"DESTDIR is passed through ninja
install"* since it was written. **The prose and the step disagreed and nothing
compared them** — which is the same shape as the three decorative gates below,
and the argument for deriving `[declared]` from the argv rather than authoring
it beside them. A zero-path staging is now fatal, and the selftest fails
statically on any recipe that never references `$D`.

**`deps.build` was decoration.** Each package installed into its own DESTDIR
and nothing put that on `PATH`, so an edge ordered the build correctly and did
nothing. Twelve packages went by before a package needed a neighbour.

**Staging destroyed busybox.** `shutil.copy2` follows symlinks on the
destination, and `/usr/bin` is almost entirely symlinks to busybox — so
installing bzip2 wrote *through* them and over busybox itself. `tar` then *was*
the bzip2 binary. Several rounds went into theories about archive formats while
the extractor had been overwritten.

**Four packages need `libudev` and nothing provided it.** busybox does not
cover this: `mdev` creates device nodes, while libinput, mesa, wlroots and
yambar link `libudev.so`. No libudev means no input, which means no
compositor. Found by reading declared dependencies, not by planning.

**`patch` is busybox, not GNU.** The glib patch applied cleanly on a laptop
every time and failed on the runner, because busybox's patch takes only
`-p -i -R -N -E -f` and rejected `--batch --forward --dry-run` as unknown
options — which the driver then read as *"the patch does not apply"*. A build
was failed against a tree the patch fitted perfectly. The sandbox is busybox
throughout, and GNU-flavoured options are a recurring way to be wrong in it:
`timeout -v`, `test -ot`'s second granularity, the absent `file` applet, and
now this.

**The pessimistic dependency graph does not close**, and that is expected: a
declared dependency list is the union of every optional feature, so `cairo ↔
pango` and `file ↔ zstd` appear as cycles that our own flag choices remove.
`probe order` proves the useful direction — acyclic there would guarantee
acyclic in reality.

**Three gates were decorative.** `ok subcommand present: …` printed for every
name in a hardcoded list and checked nothing — renaming a subcommand in the
parser left it reporting ok, while a workflow calling `veron git-sources` died
with `invalid choice`. A plan-path check printed `ok … not runnable here` on
every run. A `sources` check split on whitespace where the format is tabs, so a
four-word status line passed it. Each now fails when it should, and the
subcommand list is derived from what the workflows actually call rather than
maintained by hand.

**A gate that cannot fail is worse than no gate**, because it occupies the
place where a real one would go.

**And a gate built out of the assumption it exists to test is worse still.**
The CMake-backend check was keyed on the substring `Found CMake:`, taken from
one line of run 51's log and never compared against what meson prints when the
lookup *fails*. Run 52 is what that cost: glib's `meson setup` succeeded for the
first time — full summary, `gvdb` resolved, ninja located — and the gate failed
the package anyway, printing no evidence, ending the run. It now reports the
lines verbatim and lets the build continue; a verdict can be written once both
strings are known, and not before.

**Nothing was preserving the evidence.** Three separate holes, found while
trying to read run 52:

- `stage5-spike.yml` had **no `upload-artifact` step at all**. The collector
  copied 32 files into `out/logs/`, printed `collected 32 log files`, and the
  runner was destroyed with them.
- It was `if: failure()`, so the run that most needed reading — a `meson setup`
  that succeeded and was failed afterwards by the driver — collected nothing,
  because nothing had failed in the shape the condition expected.
- **`logs/` had never been collected, printed or uploaded.** The driver writes a
  per-package log with every argv, every env var, every rc and every duration.
  It is created in the workflow, bound into the sandbox and written on every run
  the driver has ever made. Nobody had read one.

`veron collect` now owns collection, because the driver owns `BUILD_LOGS` — the
workflow's `find` list was a second copy of it with nothing comparing them,
which is the same defect as `[declared]` drifting from the argv. It records
absence as well as presence, since "config.log missing" distinguishes dying
before configure from dying during it. The upload is `if: always()`, and the
build step now has a budget strictly smaller than the job's: **a job timeout is
a cancellation and skips `if: always()` steps**, so without that the diagnostics
work would have been defeated by the one failure mode it exists to prevent.

**The probe cannot see three whole classes of dependency, and said nothing.**
`probe.py` resolves names to packages through `.pc` files — its own docstring
says so. That is complete over what a tarball declares in a machine-readable
dependency syntax, and blind to everything else:

| escaped | why |
|---|---|
| `llvm` | mesa finds it via `method: 'config-tool'`; LLVM ships no `.pc` |
| `mako`, `packaging`, `PyYAML` | interpreter modules; mesa checks them with `run_command(python3, '-c', 'import mako')` |
| `file(1)`, hwdata's `rpm` | tools invoked at build time, not linked |

The third class was already recorded here as a zstd finding. The first two mean
**one of the five packages named as most of the work is absent from
`MIRRORS.tsv` entirely**, and mesa needs four Python packages that are not in
the 111.

Worse, the corroboration was already in hand: `probe.py` downloads Arch's
PKGBUILD and Alpine's APKBUILD for every package and extracts only `pkgver`,
source URLs and digests. **Arch's mesa PKGBUILD lists `python-mako` in
`makedepends`.** See [`ROADMAP.md`](./ROADMAP.md) for the three-detector design
that follows from this.

**48 PACKAGES, FULLY GREEN, END TO END.** No step errored:

```
VERON-BUILD-OK        every package built
VERON-MANIFEST-OK     14228 paths
VERON-LEDGER-OK       48 record(s)          VERON-STATUS-OK  unknown = 0
VERON-IMAGE-REPRO-OK  two builds, identical bytes
VERON-STAGE5-BOOT-OK  the packages ran under the kernel
VERON-STAGE5-TESTS    pass=51 fail=0 none=1
```

**`python: modules ok`** settles the sqlite question: `import zlib, bz2, lzma,
ctypes, sqlite3` succeeds inside the booted image. sqlite was built, installed
and used by nobody for as long as python preceded it in the plan; declaring
the edge moved it to rung 25 and the module exists.

dinit, libsfdo and libxkbcommon all built and tested for the first time.

**`veron linked` ran for the first time — 11 mismatches — and one is real.**

```
linked-undeclared  readline links ncurses (libncursesw.so.6 via usr/lib/libhistory.so.8.3)
```

readline declared ncurses under `build` and `runtime` and left **`link` empty**,
so the ledger understated what that library actually needs. **This is the
direction no static scan and no distro comparison can reach**: both read
intent, and this reads the ELF.

**And one was my own false positive.** harfbuzz was reported as linking
`freetype` undeclared when it declares `freetype-bootstrap` — the same tarball
built twice to break the freetype/harfbuzz cycle, so **both install
`libfreetype.so.6`**. The sweep recorded one provider per soname and walked
`dest/` alphabetically. A soname's providers are a set now, resolved against
what the package declares: an ambiguity the build never had should not become
a finding.

The remaining nine are `declared-unlinked`, and most have the same cause:
**bzip2 builds only `libbz2.a`**, so cmake, libarchive and python link it
statically and leave no `DT_NEEDED`. That is the documented blind spot rather
than a fault — worth recording per recipe rather than silencing.

**IT BOOTS, AND THE IMAGE REPRODUCES.** At 48 packages:

```
VERON-IMAGE-REPRO-OK  two builds, identical bytes
VERON-STAGE5-TESTS    pass=46 fail=2 none=1
```

Two independent image builds byte-identical, the kernel comes up, `init` runs,
and the generated guest tests execute *inside the booted system*. That is the
whole spike shape working end to end for the first time on a complete set.

**Both failures were the test being wrong, not the package** — and both are the
same mistake: **a `.pc` Version is an ABI version, not a release version.**

- `graphite2` reports **3.0.1**, set at `CMakeLists.txt:91` as
  `set(version 3.0.1)`. The release number 1.3.14 appears nowhere in the
  `.pc` file.
- `freetype` reports **26.4.20** — freetype2.pc carries the libtool version.
  The `27.6.1` in that field had never been measured, and it was then quoted
  *elsewhere in this work as evidence*, including in the reading of harfbuzz's
  and cairo's version constraints.

Those conclusions survive — harfbuzz needs `>= 12.0.6`, cairo `>= 23.0.17` and
`>= 25.0.19`, and 26.4.20 clears all three — but that is luck, not method. **A
wrong number that happens to satisfy every constraint is the kind of error that
survives for a long time**, and only a booted image running the full set found
it.

**The three git-pinned packages have recipes: 48.** libxkbcommon 1.13.2,
libsfdo 0.1.4 and dinit 0.22.1, each read from the tree `fetch-git.sh`
generated rather than from a guess.

Three things came out of resolving them that a tarball would never have shown:

- **Two of the three tags are annotated and one is not.** `v0.1.4` and
  `xkbcommon-1.13.2` resolve to a TAG OBJECT; the commit is the `^{}`
  dereference. `v0.22.1` is lightweight and resolves straight to the commit.
  Pinning the first hash for either annotated one fails `fetch-git.sh`'s
  rev-parse check — loud, but only after a full clone.
- **`git ls-remote` sorts lexicographically, and that hid twelve releases.**
  A `tail` of the tag list gave dinit `v0.9.1` and libxkbcommon
  `xkbcommon-1.9.2`; the real newest are `v0.22.1` and `1.13.2`, because
  `0.22` sorts before `0.9` as a string. `--sort=-v:refname` fixes it.
  **`probe.py`'s `latest_tag()` has the same shape** — it returns whatever
  order the forge API gives, unsorted, for exactly the packages it exists to
  serve.
- **`gap-urls.txt` says libxkbcommon "moved to freedesktop GitLab" and the
  opposite is true.** That path carries two tags and stops in 2013; GitHub is
  the live repository. Found by asking the forge — which the same file already
  warns about: *"four of the last six URL failures in this project were
  invented paths, not missing packages"*.

And three defaults that would each have cost a run: libxkbcommon's `enable-x11`
and `enable-wayland` are **true**, and `meson.build` calls `error()` when their
dependencies are absent rather than degrading; `enable-xkbregistry` is true and
does `dependency('libxml-2.0')` with no `required:false` at all. dinit's
configure probes pkg-config for libcap and links it if found — the `auto`
failure again, so `--disable-capabilities` is stated rather than inherited.

**The git-pinned pin was over the wrong bytes, and the first mirror run said
so.** `fetch-git.sh` hashed the compressed archive, and dinit failed with the
commit verifying and the digest not:

```
wanted a464bff6…   414836 bytes   (a phone, Termux's gzip)
got    3ad317bc…   414922 bytes   (the runner, gzip 1.12)
```

Decompressing the phone's tarball and recompressing it with a different gzip
reproduced the runner's file **exactly** — same size, same digest. So
`git archive --format=tar` **is** reproducible across machines and gzip **is
not**. Hashing the compressed file made a portable artifact look unportable
and would have forced a repin every time a runner image changed its gzip.

The pin is the **uncompressed tar** now; the gzip is packaging. `veron fetch`
decompresses before hashing for git sources, and all three verify against the
archives generated on a completely different machine.

**Git-pinned sources were never stored anywhere.** `libxkbcommon`, `dinit` and
`libsfdo` publish no tarball; `fetch-git.sh` clones the pinned commit and
generates one, and every run threw it away. `stage5-mirror-upload` had zero
references to `git-sources`, so those three had exactly one route — a clone of
the forge — and a deleted repo or force-pushed tag left nowhere to go.

**What we generate is better provenance than a forge archive, not worse.** The
commit is a Merkle hash over the whole tree; `git archive` with a fixed prefix
and `gzip -n` is byte-identical across runs, which two generations here
confirm. A forge archive is synthesised on request with that forge's git and
gzip, and GitHub moved every one of theirs once already. So the generated
tarball is uploaded and mirrored like anything else, with the pin still the
commit and the sha256 recorded as of *our* derived artifact.

**Two bugs surfaced while wiring it, both latent because no recipe uses a
commit pin yet.**

`fetch-git.sh` used `$DEST` after `cd "$WORK/r"`, so a relative `--dest` — and
the spike passes `dl` — resolved *inside the temporary clone*, which the EXIT
trap then deleted. It printed `wrote <name>.tar.gz (N bytes)`, exited 0, and
left nothing on disk. **The same shape as the collector that printed "collected
32 log files" and preserved none:** a step that reports success and produces
nothing, invisible until something downstream cannot find a file nobody thinks
is missing. Each of the three would have failed at unpack, three rungs later.

And `cmd_fetch` derived the filename from the URL's last path component, which
for a git remote is the repository — `libxkbcommon.git`, not
`libxkbcommon-1.13.0.tar.gz`. `source_filename()` now answers for both kinds.

**fetch-git.sh also verifies the digest it prints**, which it had only been
printing — the llvm mistake exactly. `git archive` is deterministic for a given
git and gzip, and both are the *runner's*, so a change in either moves the
bytes while the commit stays identical. That is the drift a recipe's sha256
exists to catch and it can only be caught there.

**45 packages built at the time** — the four Python modules landed and mesa's configure-time
requirement is satisfied before LLVM's 27 minutes are ever spent. The run then
died three steps later on a malformed command line:

```
veron: error: unrecognized arguments: --dest dest --sysroot sysroot
```

`--dest` and `--sysroot` are registered on the top-level parser and must
precede the subcommand. Every other call in the workflow already had the order
right; the new one was written from memory rather than copied.

**The selftest asserted the subcommand existed and could not have caught it.**
Existing and being called correctly are different claims, and only argparse
knows the second one. `build_parser()` is now separate from `main()`, and the
selftest hands **every `veron …` line in every workflow** to the real parser —
17 of them today. Lines carrying shell substitution are counted as skipped
rather than quietly passed. Verified it fails on exactly the run-56 line.

**Two dependency declarations were wrong in opposite directions, and neither
came from the reconciler.**

`fontconfig` declared `libxml2` in `link` and `runtime` and links **expat**.
The cause was `xml-backend=auto`: fontconfig tries expat first and only reaches
libxml2 if that lookup fails, so expat won because it was *found*, not because
anyone chose it. `-Dxml-backend=expat` makes it a decision — a failed expat
lookup is now a loud error rather than a silent switch that would have made the
declaration accidentally correct. libxml2 stays in the set for libarchive.

`python` declared `sqlite3` in `optional_off` with the note *"sqlite arrives in
the next batch"*. **It arrived and nothing noticed.** python built at rung 25
and sqlite at 26, so configure could never find it — and nothing else in the
set declared sqlite at all, so it was built, installed and shipped in the image
for nobody. The recipe was accurate and the intent behind it was never
completed, which is harder to notice than a wrong declaration because nothing
is false. Declaring the edge moves sqlite to rung 25 and python to 27, and the
guest test asserts `import sqlite3` rather than the library's presence.

**The ledger and the manifest now pass on a full set.** Run 55 got past both
for the first time — `VERON-MANIFEST-OK 14082 paths`, `VERON-LEDGER-OK 41
record(s)`, `unknown = 0` — and then died in the merge:

```
merging bash
cp: cannot create regular file 'sysroot/./usr/bin/bashbug': Permission denied
```

Not the runner's permissions — the *file's*. `stage_into()` had already copied
bash's 121 paths into the build root during the build, so the merge was writing
over files that already existed, and `cp` opens the destination rather than
replacing it, which fails on any mode that is not user-writable.

**The driver had fixed this once already.** `stage_into()` has unlinked before
writing ever since staging bzip2 wrote *through* `/usr/bin`'s busybox symlinks
and destroyed the binary `tar` resolved to. **The workflow held a second
implementation of staging, and it was the one without the lesson** — the same
defect as the `find` list that duplicated `BUILD_LOGS` and as `[declared]`
drifting from the argv. There is one implementation now, `veron merge`, and it
honours `build_only` there rather than by a name check in YAML.

Reproduced as a non-root user before and after: `cp -a` fails exactly as run 55
did, `veron merge` replaces the file.

**The set closed.** Run 54 built all 41 packages of the time — glib, pixman, graphite2,
libjpeg-turbo, harfbuzz, libwebp, freetype, fontconfig, cairo and pango, seven
of which had never been built here. The three fixes that got it there were each
found by reading rather than by hitting them: `$CMAKE` out of meson's
dependency path (confirmed verbatim in `probe/meson-cmake.txt` —
`Found CMake: NO`, `libinotify … NO (tried pkgconfig and cmake)`),
`-DCMAKE_POLICY_VERSION_MINIMUM=3.5` for graphite2's 2018 `CMakeLists`, and one
`#include <cstdint>` gcc 15 no longer supplies transitively.

**And then the manifest refused it, correctly.**

```
veron: path collision: usr/bin/freetype-config
       claimed by freetype and freetype-bootstrap
```

Both are freetype 2.14.1 at the same prefix — one `--without-harfbuzz` so
harfbuzz has something to link, one `--with-harfbuzz` for the system — so
*every* path collides and the manifest reported the first alphabetically.

**The collision was the smaller problem.** The merge step is `for d in
dest/*/`, which the shell sorts, so `dest/freetype/` copies first and
`dest/freetype-bootstrap/` copies straight over it. **The image would have
shipped the freetype built without harfbuzz, under a manifest naming the other
one, with every gate green.** The manifest gate stopped the run one step before
that merge — a gate earning its keep at n=41 exactly as its comment predicted it
would at n=200.

The fix is a declared category rather than an exception: `build_only = true`
says a package is built and staged so later rungs can link it, and then
superseded. It is recorded in `PLAN.txt`, excluded from the manifest and the
image, declared in the guest tests as *nothing ships*, and the workflow asks
the recipes which packages those are rather than keeping a second list in YAML.

**Four Python packages, and four different layouts.** mesa requires `mako`,
`packaging` and `PyYAML` at configure time — checked with
`run_command(python3, '-c', 'import mako')`, which no static dependency scan
can see — and mako pulls `MarkupSafe`. With no pip, all four install the way
`meson` does: copy the package tree onto the interpreter path.

The copy path is the whole risk, and it is different in each one: `mako/` at
the top level, `src/markupsafe/`, `src/packaging/`, `lib/yaml/`. A wrong path
installs *nothing* and surfaces as an ImportError inside mesa's configure
several rungs later, so all four were read from the tarball and every
`verify-install` probe was run against the extracted trees before shipping.

Three things that came out of reading rather than assuming:

- **Neither C extension is built and neither needs to be.** markupsafe guards
  `_speedups` with an `ImportError` fallback to `_native.py`, which ships;
  pyyaml guards `cyaml` the same way and reports `__with_libyaml__ = False`
  honestly. Both verify steps assert the pure-Python path took, so a missing
  fallback cannot pass.
- **`lib/_yaml/` is deliberately not installed.** It is a compatibility stub
  that, without libyaml, does nothing but
  `raise ModuleNotFoundError("No module named '_yaml'")`. Installing it would
  put a module in site-packages that can only ever raise.
- **`packaging` is a genuine `OR`** — `Apache-2.0 OR BSD-2-Clause`, stated in
  its SPDX expression, in two licence files, and in prose. The AND-vs-OR case
  STAGE5.md names, met for the first time.

`packaging` is also not optional: mesa falls back to `distutils`, which Python
3.12 removed and stage 5 builds 3.14.

**Nine tarballs were read source-first**, before building them, and six had
something that would have cost a run — three of them in sequence, each behind
the last. Including a wlroots configuration that builds green while silently
omitting the DRM backend. See [`PACKAGES.md`](./PACKAGES.md).

### The boot ran the package tests and never reported them

`boot_system=true` was fixed once already — the harness boot had been
*replaced* by the system boot, so a run reported `VERON-STAGE5-LOGIN-OK` and
said nothing about the packages. The fix made the harness boot run again. It
did not make it report, and the difference was invisible because the run was
green either way.

Three faults in one step, and all three are the same shape as ones already in
the record:

- **The reporting sat after an `exit 0`.** The `boot_system` branch ended by
  exiting, so the DRM/evdev probe, the per-package dump, `VERON-STAGE5-BOOT-OK`
  and the selfhost gate were all unreachable. Two boots ran; one was described.
- **`cp boot-system.log boot.log` overwrote the evidence** before anything read
  it, so the harness console did not survive the step, let alone the runner.
- **The second boot's timeout was applied to the first.** `QEMU_TIMEOUT=180`
  was chosen for dinit-which-never-exits and then used on the *harness*
  invocation, which runs 65 tests under TCG. The system boot has its own
  literal `timeout 180`, so the variable never reached the boot it was written
  for — it cut the harness window from 900s to 180s and bought nothing.

And the harness `rc` was captured, printed, and never read, so a qemu that
timed out after printing its markers passed.

Both boots now write their own log, both are reported in full, both logs reach
the diag bundle, and one verdict at the end covers both. `pass=65` in the
console is the **native** run under the merged sysroot; the number under the
kernel is a different measurement and now appears beside it.

**The shell gate could not have caught any of it**, because it skipped every
`run:` block containing a `${{ }}` expression — 72 of 531, and not a random 72:
a block has an expression exactly when it branches on an input, which is the
code most likely to be restructured and least likely to run by default.
Substituting each expression for one metacharacter-free token makes the block
checkable without changing its structure. All 72 parse today, so this was
coverage with no noise attached, and an injected stray `fi` in the boot step is
now caught where before it would have shipped.

### The loginkit could not boot anything, and the panic proved it

Booted locally against the stage-4 kernel under qemu, with the published
`loginkit.tar.gz` as the root and `veron.boot=system`:

```
VERON-OVERLAY-OK    lower=9p (ro)  upper=tmpfs
VERON-SWITCHROOT-EXEC  /usr/bin/dinit
switch_root: can't execute '/usr/bin/dinit': No such file or directory
Kernel panic - not syncing: Attempted to kill init!
```

dinit was present, at that exact path, with the executable bit set. **The
ENOENT names the interpreter.** The kit copied seven binaries and no libraries
at all; four of the five that landed are dynamically linked, so exactly one
program in it could run — the static busybox. The step printed
`(dinit, busybox, a shell and /etc)`, which is true about the file list and
false about everything it implies.

Three faults, and each one is separately load-bearing:

- **`-x` is not loadability.** `guest/init` tested the executable bit and
  exec'd. Nothing anywhere read `PT_INTERP`.
- **The fallback was fiction.** The comment promised that a failure here
  "falls back rather than leaving a kernel with no shell". `exec switch_root`
  replaces the script, so after it fails there is no init left to fall back
  *to* — what actually happened was a panic. The check has to precede the
  exec, because after it there is nothing to check with.
- **The kit had no closure.** A hand-written list of file names cannot express
  "and everything these load", and no amount of care makes it able to.

`veron loginkit` now resolves `PT_INTERP` and the transitive `DT_NEEDED`
closure out of the sysroot with the driver's own pure-Python ELF reader,
follows each soname to the versioned file behind it, drops the sysroot's
`ld.so.cache` (it names paths the kit does not reproduce), and **refuses** to
write a kit whose programs cannot be loaded from it. Run against the kit as
published: `VERON-LOGINKIT-FAIL 24 unresolved name(s)`.

With the ordering fixed, the same broken kit now produces a diagnosis instead
of a panic, and the harness fallback genuinely runs.

### An absence manufactured by the order of two blocks

The first version of that check sat *after* the loop that `mount --move`s
`/proc`, `/sys` and `/dev` into the overlay. Correct when switch_root
succeeds; ruinous when it does not, because the fallback harness then runs in
a root with no `/dev`. The graphics probe duly reported

```
VERON-DRM-ABSENT    no /dev/dri/card0
VERON-EVDEV-ABSENT  no /dev/input/event*
```

on a kernel whose own embedded config says `CONFIG_DRM_VIRTIO_GPU=y`,
`CONFIG_INPUT_EVDEV=y`, `CONFIG_VIRTIO_INPUT=y`, and which has a live
`/dev/dri/card0` and two event nodes — confirmed by booting a diagnostic
initramfs and reading `/proc/config.gz`. Nothing is moved now until the exec
is known to be worth doing, and the probe reports `VERON-DRM-OK` again.

Worth stating plainly: that finding was manufactured by the fix, not found by
it. It is in the record because a probe that reports a capability as absent
when it is present is exactly as expensive as one that misses a real absence.

### /etc/profile and /etc/hostname were shipped and had no readers

Measured on the booted console:

```
PATH=[/sbin:/usr/sbin:/bin:/usr/bin]     busybox's built-in default
PS1=[\w \$ ]                             busybox's built-in default
hostname=[(none)]                        /etc/hostname says veron
```

`busybox getty -n -l /bin/sh` execs the shell with `argv[0]=/bin/sh`. A shell
sources `/etc/profile` only when `argv[0]` begins with `-`, so it never ran.
**The PATH difference is not cosmetic:** busybox puts `/sbin` and `/bin`
first, `/etc/profile` puts `/usr/bin` first *deliberately*, because that is
the build's PATH. Reversed, every busybox applet in `/bin` shadows the real
binary in `/usr/bin` — so the booted system resolves busybox's tools in
preference to the sixty-two packages this project builds, and the file whose
own comment says it "mirrors policy/defaults.toml's build PATH" was achieving
the opposite of that.

`-l` now names `scripts/console-shell`, which sources the file and then
becomes the shell; `exec -a -sh` was not used because it is a bashism and
busybox ash does not take it. `early-filesystems` applies `/etc/hostname`.
Both verified on the real kernel:

```
veron# echo "PATH=[$PATH]"
PATH=[/usr/bin:/usr/sbin:/bin:/sbin]
PROFILE-SOURCED-OK
HOSTNAME-OK
```

That prompt is a real login session on the stage-4 kernel, taking typed
commands. `veron-system`'s `[installs]` digest and `installs.txt` were
re-measured by `veron installs --propose --write` rather than edited, and
`PLAN.txt` regenerated.

---

Measured from the last green run's own timestamps:

```
harness boot    34.0s    exits by itself, powers off
system boot    180.0s    <- the timeout, to the hundredth
```

dinit as PID 1 does not exit, so `timeout 180` was the *normal* ending — the
step paid the full 180s whatever happened. Three services come up in seconds
and the remaining ~165s was pure waiting. That is the whole reason the boot
went from seconds to minutes.

It now waits for the marker rather than the clock. `boot` is `type = internal`
with `waits-for.d = boot.d`, so dinit reports it only once every service in
`boot.d` is up; it is the last line the gate reads and there is nothing after
it worth waiting for. The 180s stays as the *failure* ending, and TERM
escalates to KILL so no qemu can outlive the step. Measured against a stub
that hangs like a real getty: **3s instead of 180s**, and the failure path
still gives up and still names the missing service.

### Nothing is truncated. Not logs, not records, not ever.

`veron collect` kept the last 512 KiB of each file. The diag bundle from a
green run showed what that costs:

```
[TRUNCATED -- showing the last 524288 of 2192405 bytes]
d08f556e6a9	3081
```

`files.tsv` shipped as **4815 of 17531 paths — 27%** — keeping the
*alphabetical tail*, so `a` through `t` were discarded and `u` through `z`
survived, for a file that is one line per installed path and cannot run away.
The first surviving line was half a sha256 with no path: the boundary record
did not even parse.

And `installs/cmake.txt` was at **518285 bytes against a 524288 cap** — 1.1% of
headroom, silently, on every run since the listings were added. About sixty
more files in cmake and it would have gone the same way, with the run still
printing OK.

**Where 512 KiB came from: nowhere.** It is a round number typed into an
argparse default in `72e45d8`. That commit argues carefully for per-file caps
over a total cap — real reasoning about the *shape* — and never says why 512.
It is `ZSTD_CLEVEL=19`, the `< 1024 MB` trim guard and qemu 9.2.4 again: a
value that reads as considered and was never measured.

**The argument for capping does not survive contact.** A runaway log is a fault
to diagnose, not a thing to hide, and truncating it removes the evidence of the
runaway along with everything else. The whole bundle is 4.7 MB, so there was
never a size cost to trade against.

Removed everywhere:

- `keep()` copies whole files with `shutil.copyfile`. There is no cap and no
  `whole=` parameter to forget to pass, because a knob that can hide evidence
  eventually will.
- `--max-bytes` is **deleted**, not defaulted to zero.
- `cmp -l | head -20` on a failed image reproduction — the only copy of that
  comparison — now writes every differing byte to `repro/image-diff.txt` and
  the console reports the count. Twenty samples cannot show the pattern in the
  offsets that distinguishes a timestamp from a UUID from a build path, which
  is the entire diagnosis.
- `tail -40` on a harness log that never reached userspace kept the panic and
  threw away the boot that led to it. Whole log.
- `head -20` on the dinit markers, `tail -2` on a failed service. Whole.

Verified at real sizes: a 17531-line `files.tsv`, the actual 518285-byte
cmake listing and a 900 KB log all arrive intact, no truncation marker
anywhere, first line parses.

A gate now reads `cmd_collect`'s **executable code** — `ast.unparse` of the
parsed body, docstring dropped — and fails on `max_bytes`, `TRUNCAT` or a
`seek(`. Its first version flagged the words "NOTHING IS TRUNCATED" in its own
docstring, which is the checkpoint-marker gate reading its own comment as code,
for the second time in this tree. Comments are not in the AST at all.

### The CI loginkit boots, and the control socket was being hidden

The kit built by CI — the whole closure this time, `bash` with `libreadline`
and `libncursesw` included — was booted as the root over 9p with
`veron.boot=system`:

```
VERON-SWITCHROOT-EXEC  /usr/bin/dinit
[  OK  ] early-filesystems
[  OK  ] console
[  OK  ] boot
veron# echo "PATH=[$PATH]"
PATH=[/usr/bin:/usr/sbin:/bin:/sbin]
veron# echo "host=[$(hostname)]"
host=[veron]
veron# /usr/bin/dinit --version
Dinit version 0.22.1.
veron# bash -c 'echo $BASH_VERSION'
5.3.0(1)-release
```

`lib -> usr/lib` and `bin -> usr/bin` both survive the tar, so the merged-usr
layout reaches the artifact.

**`dinitctl` could not connect, and the cause was ordering.** dinit creates its
control socket at startup, before it runs a single service. `/etc/fstab` asks
`early-filesystems` for a tmpfs on `/run` — which runs *after* dinit is already
up, so the mount lands on top of the socket and hides it. Measured both ways:

```
veron# ls -la /run/          (as shipped)      veron# ls -la /run/   (/run out of fstab)
total 0                                        srw------- 1 root root 0 dinitctl
veron# dinitctl list                           veron# dinitctl list
dinitctl: connecting to socket:                [[+]     ] boot
/run/dinitctl: No such file or directory       [{+}     ] early-filesystems
                                               [{+}     ] console (pid: 89)
```

So the system booted and could not be inspected, controlled or shut down
cleanly. `[  OK  ] boot` was true and said nothing about it — a service manager
with no control channel still reports every service started.

`guest/init` now mounts the tmpfs on `/run` before exec'ing dinit. **Mounted
there rather than dropped from fstab:** removing the entry also works, because
the overlay's upper is a tmpfs and `/run` is writable regardless — but that
makes `/run`'s writability a property of one boot path rather than of the
system. Mounting it early gives dinit a real tmpfs whichever way the root
arrived, and `early-filesystems` skips it, because that script mounts what is
missing rather than running `mount -a`. Verified against the untouched CI kit:
one `tmpfs /run` in `/proc/mounts`, the socket present, `dinitctl list`
answering.

**And one non-finding, recorded because it looked like one.**
`dinit-check /etc/dinit.d/boot` reported `error reading dependencies from
directory boot.d: No such file or directory`. That is not a defect: `boot.d`
resolves relative to the working directory, and from `/etc/dinit.d` the same
command says `No problems found` across all three services. Checked before
reporting, which is the only reason it is not in the list above.

### The size column broke the ledger, and the failure proved the point

Adding a fourth field to `file_manifest` broke `cmd_ledger`, which died at step
19 after every package had built:

```
ValueError: too many values to unpack (expected 3)
```

Two call sites were updated by searching for readers of `files.tsv`.
`cmd_ledger` calls the function directly and writes no tsv, so that search
could not find it — **one producer, several consumers, not all updated**, which
is `cmd_tarball_names` after `cmd_fetch` and the shell `read` gate, for the
third time in this repository.

Then the gate written for it missed too. The first version matched
`for ... in file_manifest(` with a regex, caught that site, and **missed a
second one four lines later in the same function** because that one unpacks a
*variable* the result was assigned to. A pattern that has to anticipate how
callers spell themselves is the same mistake as the search that started it.

The gate now builds a one-file DESTDIR and **runs `veron manifest` and
`veron ledger`**. An unpack that does not match cannot survive being executed,
however it is written. Verified against both sites individually:

```
FAIL  `veron manifest` raised ValueError: too many values to unpack (expected 3)
FAIL  `veron ledger` raised ValueError: too many values to unpack (expected 3)
VERON-SELFTEST-FAIL
```

A third thing was caught only by reading the output: the edit that added the
first gate **deleted the `VERON-SELFTEST-OK` print**, so the selftest ran every
check and ended silently. It was noticed because a `FAIL` line appeared with no
marker after it — the exit code was still correct, and a marker-driven CI step
would have gone green on a run that printed no verdict.

**And the failure demonstrated the thing it interrupted.** The run died at step
19 and the evidence still shipped:

```
VERON-COLLECT-OK  65 entries (0 failed) -> out/diag
  installs/     62 file(s),   1974.4 KiB  autoconf.txt, automake.txt, +60 more
  manifest/      1 file(s),    512.1 KiB  files.tsv
  probe/         1 file(s),      0.1 KiB  meson-cmake.txt
```

62 per-package listings — every path with its sha256 and exact size, ~2 MB —
plus the whole-image manifest, from a run that failed. `boot/` is empty and
says so, because the boot step never ran. That is the guarantee working on a
real failure rather than a simulated one.

`veron manifest` also now reports the total: **17531 paths, 3638.4 MiB**.

### Every file, its sha256 and its exact size — on pass or fail

Two records, and they did not carry the same facts.

**`installs/<pkg>.txt`** — one per package, over the DESTDIR, `f <sha256>
<size> <path>` and `l <target> <path>` for symlinks. This is the 14,632 lines
that used to scroll past on the console, moved to a file instead of deleted.
62 packages, ~765 KB in the last run.

**`manifest/files.tsv`** — every path in the *merged* image, which is a larger
set: the 62 DESTDIRs plus the stage-4 sysroot underneath them. It recorded
path, owning package, kind and sha256 — **and no size**, while the listings
beside it recorded size for the same files. Two records of one fact
disagreeing about what the fact includes. It was also written to `out/` and
collected by nothing, so the single file answering "what is actually in this
image" did not survive the runner.

Both fixed. `files.tsv` gains a fifth column, *appended* rather than inserted,
because `veron compare` reads `parts[0..3]` behind a `len(parts) >= 4` guard
and `selfrebuild.sh` uses `cut -f2` — both verified still working against a
regenerated manifest. `veron manifest` also now prints the total size, so
"where did 619 MB go" is answerable from the log rather than by walking a
filesystem that may no longer exist.

Where they end up, and when:

| record | written by | covers | survives a failed build |
|---|---|---|---|
| `installs/<pkg>.txt` | `veron build`, per package as it finishes | that package's DESTDIR | **yes** — whatever built is kept |
| `installs/<pkg>.txt` | `veron installs` | packages a checkpoint restored | yes, if the gate ran |
| `installs/<pkg>.txt` | `veron collect` backfill | anything neither wrote | **yes** — collect is `always()` |
| `manifest/files.tsv` | `veron manifest` | the whole merged image | only if the build got that far |

`veron collect` is `if: always()` and the diag upload is `if: always()` with
`if-no-files-found: error`, so the per-package listings ship on pass or fail
unconditionally. `files.tsv` describes a merged image, so it exists only when
there was one to merge — that is a real limit and is stated rather than
papered over.

### The kit reported OK and still could not load

With the closure resolver in place the kit built clean —
`VERON-LOGINKIT-OK`, 8 library files, 17 MB — and the guest still said:

```
/usr/bin/dinit: error while loading shared libraries:
libstdc++.so.6: cannot open shared object file
```

with the file present, readable, and 21 MB of it sitting on the mount.
`LD_LIBRARY_PATH=/lib:/usr/lib` then printed `Dinit version 0.22.1.`, which
cleared the bytes and convicted the path.

**The sysroot is merged-usr: `/lib` is a symlink to `usr/lib`.** The copy step
called `os.makedirs` on the kit side and turned that symlink into a real
directory, so every library landed at `kit/lib/...` while `kit/usr/lib/`
stayed empty — and this glibc's built-in search path is `/usr/lib`. The check
searched both `lib` and `usr/lib`, found the files, and passed. **A false
green, which is the worst kind, and it shipped one round before it was
caught.**

Two fixes, because the copy bug and the check that missed it are different
faults:

- The kit now **reproduces the sysroot's layout**, recreating any path
  component that is a symlink rather than materialising it, and ensuring the
  realpath directory behind it exists.
- The check resolves each soname on **both** sides and compares where it
  lands. Against a deliberately flattened kit it names all five:
  `libstdc++.so.6 resolves to lib/... in the kit but usr/lib/... in the
  sysroot`.

A layout is part of what makes a root work. A tree holding every required file
in the wrong shape contains everything and runs nothing.

Verified by booting the real dinit as PID 1, over 9p, against the stage-4
sysroot plus the stage-5 dinit:

```
VERON-SWITCHROOT-EXEC  /usr/bin/dinit
[  OK  ] early-filesystems
[  OK  ] console
[  OK  ] boot
veron# /usr/bin/dinit --version
Dinit version 0.22.1.
veron# echo "PATH=[$PATH]"
PATH=[/usr/bin:/usr/sbin:/bin:/sbin]
```

Also `dinitctl list` answers `connecting to socket: /run/dinitctl: No such
file or directory` — dinit is not started with `--socket-path` and does not
place one where dinitctl looks. Recorded, not fixed.

### The collect report hid the two entries worth reading

`VERON-COLLECT-OK 67 entries (0 failed)` was true and useless. Entries are
added driver-logs first, then 62 install listings, then the boot consoles — so
the boot logs ranked 64th and 65th and the console said
`... and 42 more (see INDEX.txt)`. They *were* collected; nothing on screen
said so, and confirming it meant reconciling a count by hand against an
artifact nobody had downloaded.

A count that has to be checked by arithmetic is not a report. Collect now
walks the bundle it just wrote and says what is in each directory:

```
VERON-COLLECT-OK  14 entries (0 failed) -> out/diag
  boot/          2 file(s)   boot-harness.log, boot-system.log
  driver/        1 file(s)   veron-system.log
  installs/      8 file(s)   cairo.txt, cmake.txt, curl.txt, git.txt, +4 more
  probe/         1 file(s)   meson-cmake.txt
```

Failures print first and unconditionally. The summary is read back **off
disk** rather than accumulated as the copies are attempted, because those two
disagreed once already — which is the entire reason this section exists.

### The install listings, and where they go

Every installed path with its size and sha256 used to go to the console —
14,632 lines across 62 packages — and was replaced by a one-line digest, which
was the right call. The listing was supposed to move into a file that gets
uploaded. It did not, and it took three separate faults to make that true:

- **`veron collect` wrote them nowhere.** `keep()` was handed
  `installs/<pkg>.txt` — a *relative* path, resolved against `spikes/stage5`
  where no such directory exists — while every other call passes an absolute
  path under `diag`. `"installs"` was also missing from the `makedirs` tuple.
  So all 62 copies raised `FileNotFoundError`, were recorded as `FAILED` in an
  index nobody reads, and the step printed `VERON-COLLECT-OK`. That is
  `cp boot/Image .` from a step that had already `cd`'d into `out/`, again: a
  path written as though the code ran elsewhere, behind an error path quiet
  enough to look like success.
- **The gate is not a safe place to keep evidence.** `veron installs` runs
  after the build, so a build that died at package 40 never reached it — the 39
  that *did* install had their listings computed for the digest line and thrown
  away, in exactly the run someone needs them for.
- **`veron build` did not write them either**, though it already computes them:
  `report_package` produces `(lines, digest)`, prints the digest, and dropped
  the lines.

Three writers now, one directory, and the listing is computed once:

| writer | covers | cost |
|---|---|---|
| `veron build` → `report_package` | every package as it finishes, so a partial build keeps what it built | none — already computed for the digest |
| `veron installs` | packages a **checkpoint restored** rather than built, which the build step never sees | already paid by the gate |
| `veron collect` | backfills anything neither wrote | only for what is missing |

That last row matters more than it sounds: in the last green run **all 62 were
restored**, so the build wrote nothing, and had the gate not run there would
have been no listings at all.

`veron collect` runs `if: always()` and the diag upload is `if: always()` with
`if-no-files-found: error`, so **the listings ship on pass or fail**. They land
in `veron-stage5-diag-<run>-<attempt>` under `installs/<pkg>.txt`, one line per
path:

```
f <sha256> <size> <path>
l <target> <path>
```

Both boot consoles ship beside them under `boot/`, in full rather than the
capped dump the step prints. The marker now distinguishes
`VERON-COLLECT-INCOMPLETE` from `VERON-COLLECT-OK` and prints failures first
rather than truncating them away behind the successes.

---

## Decisions this set encodes

| decision | why |
|---|---|
| **WPE WebKit**, not Ladybird | Ladybird now needs Rust 1.96+, Qt6, dbus and ~46 vcpkg dependencies. WPE needs no Rust and no X11. |
| **labwc + wlroots**, not Qt | a compositor, not a desktop environment |
| **no Rust anywhere** | the bootstrap story ends at a Rust compiler nobody can build from this chain |
| **no pip** | pip fetches unpinned code at runtime into a system whose premise is that every byte traces to a recorded source, and ensurepip ships vendored wheels the ledger cannot itemise |
| **bash alongside busybox**, `/bin/sh` stays busybox | glib requires bash; pointing `/bin/sh` at it would admit bashisms into scripts claiming to be POSIX |
| **stage 5 builds its own python** | stage 4 is a *toolchain*; its python has 48 modules and no zlib, bz2, lzma, ssl or ctypes because those libraries did not exist at that rung. Correct for a toolchain, insufficient for a system. |
| **kernel EFI stub**, no bootloader | zero bootloader packages for ARM64 UEFI |

---

## Where to read next

- [`PACKAGES.md`](./PACKAGES.md) — nine tarballs read source-first, digests
  verified, before building them. What each actually requires and what breaks.
- [`ROADMAP.md`](./ROADMAP.md) — the rules the driver enforces (a package's
  peculiarity stays in its recipe; global policy is a closed set; declare what
  you install; disclose what static analysis cannot find) and the ordered work.

## What is not done

**Nothing here boots to a login.** `dinit` is pinned; service definitions, the
`/etc` skeleton, getty autologin, kernel installation into the image and the
EFI stub are not packages and do not exist. `guest/init` is a test harness that
mounts, checks and exits.

**The browser shell does not exist.** WPE renders; MiniBrowser has no URL bar.

**mesa without Rust is unproven.** `rustc`, `zerocopy` and `syn` appear in
mesa 26's declarations. Configure returned `rc=0` with our options — but
configure succeeding is not compiling.

**WPE has never rendered a page.** 136 minutes and `rc=0` measured; nothing
drawn.

**Licences are measured, not applied.** 19 matched, 14 probable, 9 composite —
and none of it is in a recipe. `crosschecked_against` is empty on all 41.
