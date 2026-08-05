# Stage 5 — the rules, and what remains

[`STAGE5.md`](../../STAGE5.md) is the plan. [`README.md`](./README.md) is what
has been established. [`PACKAGES.md`](./PACKAGES.md) is what reading the
tarballs found. This file is the design rules the driver enforces and the
ordered work that follows from them.

---

## The rules

### 1. A package's peculiarity stays in its recipe

Every package has something odd about it. graphite2 predates cmake 3.5. glib
reaches for a CMake backend on optional lookups. hwdata's Makefile shells out to
`rpm`. None of that is a reason to change anything outside those packages.

**A fix whose blast radius exceeds its audience is a fix waiting to be blamed
for something unrelated.** The recipe is the unit: it names the tarball, the
flags, the patches, the environment and the reason. A reader of one recipe
should be able to see everything strange about that package without reading any
other file.

This rule is written from getting it wrong. The CMake-backend crash was glib's,
and the fix put `$CMAKE` into `policy/[env]` — handing a meson-specific variable
to every process in the build, including cmake's own `./bootstrap` and every
autotools `configure`. It bought nothing for forty packages and a paragraph of
hedging about the one it might have broken. The narrower `[tool_env.meson]`
version was still cross-package contagion. **Neither belongs in policy; it
belongs in glib.**

The corollary: "a patch per package does not scale" was the wrong argument.
Per-package *is* the unit. What does not scale is a fix per *call site* inside a
package, which is a different thing.

### 2. Global policy is a closed set

`policy/[env]` holds what is true of the entire build and nothing else:
`SOURCE_DATE_EPOCH`, `LC_ALL`, `LANG`, `TZ`, `TERM`, `PATH`. A selftest fails if
a sixth key appears. Not a convention — a gate, because conventions are how
rule 1 gets violated one convenient exception at a time.

### 3. Every package declares what it installs

```toml
[installs]
prefixes = ["usr/bin", "usr/lib", "usr/share/hwdata", "usr/share/pkgconfig"]
```

After install, the DESTDIR is walked and anything outside the declared prefixes
fails the package by name. On top of that, a committed digest of the sorted file
list, so an upstream that starts installing something new is a decision rather
than quiet growth of the image.

This is the "know exactly what it is installing" requirement made mechanical. It
would have caught hwdata dropping a `modprobe.d` file nothing reads and harfbuzz
installing three utilities nobody asked for.

### 4. Non-declarative dependencies must be disclosed per package

Static analysis of build files **cannot be complete**, and mesa proves it:
`import mako` lives inside a Python string inside a `run_command`. No parser
short of executing the build finds that.

So the system does not pretend to find everything. It refuses to build a package
whose undiscoverable dependencies have not been written down by a human:

```toml
[undeclarable]
"python:mako"  = "run_command(python3, '-c', 'import mako'). Not a pkg-config
                  name, not a find_program. Arch declares python-mako in
                  makedepends; we carry it as a real package."
"llvm-config"  = "dependency('llvm', method:'config-tool'). LLVM ships no .pc."
```

When the probe finds a `run_command`, a `method: 'config-tool'`, or an
unresolvable `find_program` that the recipe does not disclose, that is a **hard
failure naming the file and line** — not a warning. Arbitrary code execution in
a build system is exactly the case that must fail loudly and be handled by hand.

### 5. Declarations are checked in both directions

- `[declared].configure_flags` ⊆ the argv that actually runs. Four of four
  recipes read this session drift.
- `DT_NEEDED` ⊆ `deps.link`. `probe linked` already reads this and nothing runs
  it against the declarations. fontconfig declares `libxml2` and links expat.

### 6. Evidence survives the run

Done, and recorded in [`README.md`](./README.md): `veron collect`, uploaded
unconditionally, with a build-step budget strictly smaller than the job's so a
timeout is an ordinary step failure rather than a job cancellation that skips
`if: always()`.

---

## Detection has three sources, and each names its own blind spot

No single detector is complete. The design is to run all three and require that
**no name is unaccounted for** — declared, explicitly declined with a reason, or
the build fails. Same `unknown = 0` shape `veron status` uses for files, applied
to dependencies. Today the failure state is silence, which is how llvm and mako
escaped.

| detector | sees | blind to |
|---|---|---|
| **static** — the tarball's own build files | pkg-config, cmake, cargo, `.pc` Requires | config-tools, interpreter modules, tools invoked not linked |
| **corroborative** — Arch `makedepends`, Alpine APKBUILD | what two independent packagers declare | their flag choices, not ours — a superset to explain, not adopt |
| **observed** — `DT_NEEDED` after a build | what actually linked | anything not linked; needs a successful build |

The corroborative one is the cheapest win in the design and is currently thrown
away: `probe.py` downloads the PKGBUILD and APKBUILD for every package and
extracts only `pkgver`, source URLs and digests. **Arch's mesa PKGBUILD lists
`python-mako` in `makedepends`.** The data was in hand and discarded.

---

## The work

### 0. Waiting on run 53

- Does `$CMAKE` do anything — `probe/meson-cmake.txt` settles it verbatim
- Does glib compile, and where the run actually stops
- Whether the cmake-4 fallback recurs in pixman, harfbuzz, fontconfig, cairo,
  pango

### 1. Undo the contagion

- Move `$CMAKE` out of `policy/` into glib's recipe — env-var or native file
  decided by run 53's evidence, not by recollection
- Rewrite the cmake check as a real gate once **both** the found and not-found
  strings are known, printing its evidence when it fires

### 2. Contracts — BUILT

| | rule | state |
|---|---|---|
| env freeze | 2 | **enforced** — `[env]` is a closed set of 5 |
| declared flag is passed | 5 | **enforced** — 48/48 clean |
| a decline is recorded | 5 | **enforced** — found 3, fixed 3 |
| `[installs]` prefixes | 3 | **warn** — needs one build to seed |
| `[undeclarable]` disclosure | 4 | **done** — 66 entries, 12 packages |
| `DT_NEEDED ⊆ deps.link` | 5 | **warn** — `veron linked` |
| file-list digest | 3 | not built |

### 3. Probe work

**Done — both detectors are in `probe.py` and covered by its selftest.**

- `packager_deps()` parses `depends` / `makedepends` / `checkdepends` from the
  PKGBUILD and APKBUILD that were already being downloaded and read for
  `pkgver` alone. Version constraints, alternates and Alpine's `so:` / `cmd:` /
  `pc:` provider prefixes are stripped, and multi-line arrays are handled.
  Reported as **a superset to explain, not a list to adopt**: their lists
  follow their configure flags.
- `_unresolvable()` reports the three shapes no `.pc` name can answer —
  `method:` naming a non-pkg-config backend, `run_command` invoking an
  interpreter (with the imports pulled out), and `find_program` on a tool not
  shipped in the tarball — each with `file:line`.

**The scanner needed a real parser, and a fixture is what proved it.** The
first version found call bodies with `[^)]`, which terminates on the first
nested paren — so `host_machine.system()` and `sys.exit(2)` cut both of mesa's
lookups short. It reported 34 findings for mesa and **missed the only two the
scanner exists for**: `dependency('llvm', method: … 'config-tool')` and the
`run_command` that imports `mako`. It looked like it worked. Depth counting
with quote awareness is a dozen lines and is simply correct.

The second bug was subtler: mesa writes
`method : host_machine.system() == 'windows' ? 'auto' : 'config-tool'`, and
taking the first quoted token reported `method:'windows'` — a name that means
nothing and sends the reader to the wrong line. Every literal in the expression
is reported now, because which branch is taken is not a static fact.

Current sweep over the tarballs read so far:

| | unresolvable |
|---|---|
| mesa | 35 — incl. the llvm config-tool and 3 interpreter imports |
| glib | 11 |
| fontconfig | 10 — incl. the `method:'cmake'` freetype rescue |
| harfbuzz | 6 |
| cairo | 3 |
| wlroots | 2 |
| libdisplay-info | 0 |

**Reconciliation is built — `probe.py reconcile`.** The rule is not that the
three detectors agree; they measure different things and are not expected to.
It is that **no name is unaccounted for**: declared in `deps`, declined in
`optional_off`, disclosed in `[undeclarable]`, or the run says so.

The strictness is narrow on two axes, and both were chosen deliberately:

- **`makedepends` only.** A distro's runtime `depends` describes *their*
  package's install closure and has almost nothing to do with what this build
  needs. Including it would bury the signal.
- **Only names that resolve to our packages.** Arch's mesa lists `libx11`,
  `rust`, `clang`, `glslang` — none of which exist here, and none of which are
  decisions anybody needs to record. Arch listing `zlib` when we build zlib and
  did not declare it *is* a decision.

**`[undeclarable]` is strict with no such filter**, because those are lookups
in our tarball on our build path, and they are the class that already cost this
project llvm and mako. Keys are canonical — `config-tool:llvm`, `python:mako`,
`program:flex` — **not `file:line`**, because a version bump moves a line and a
required field that needs editing every release is one people delete.

**`--mode warn` is the default, and not as a softening.** The first sweep over
the whole set has to be *read* before it blocks anything; turning a gate on
before anyone has seen its output is how a gate gets disabled a week later.
`--mode fail` exits non-zero once the output is understood.

A third accuracy bug turned up while reading real output, the same shape as the
ternary one: treating anything without `required: false` as REQUIRED. fontconfig
writes `find_program('xgettext', required: opt_nls)` and cairo writes
`required: get_option('tests')` — neither is a literal, and labelling them
REQUIRED fills the report with alarms about tools that are never looked for.
Three states now: `REQUIRED`, `optional`, `conditional on <expr>`. **A report
full of false alarms is one nobody finishes reading.**

**The first full sweep ran in CI — 45 packages, 151 findings — and most of it
was not about these packages.** This is the argument for `warn` first, made
concrete: read what the gate measures before letting it block anything.

Four classes, each fixed at the cause rather than filtered by name:

**`git` ×20 of the 36 corroborative findings.** Arch builds many packages from
a checkout — `source=("git+https://…")` — so git is in their makedepends as a
*fetch mechanism*. Veron pins tarballs. **A dependency of their packaging is
not a dependency of the software.** Their `source=` is read now, and VCS tools
are dropped only when the source really is a checkout, so a project that
genuinely needs git at build time still surfaces.

**meson's own test fixtures.** meson ships thousands of `test cases/*/
meson.build`, including deliberately exotic ones — `dependency('OpenAL',
method:'cmake')`, `method:'dub'`, `method:'extraframework'`. The walk excluded
`test` and `tests` but not `test cases`, so meson reported lookups from
fixtures written to exercise meson itself.

**Vendored subprojects.** 15 of pango's findings were *fontconfig's* build
file, from sources pango vendors under `subprojects/`. We never build a
subproject — refusing them is what `--wrap-mode` is for — so a vendored tree is
not this package's dependency surface.

**And the tool lied about eight packages.** It reported them as "neither Arch
nor Alpine packages", which is false: Arch calls glib `glib2`, freetype
`freetype2`, graphite2 `graphite`, PyYAML `python-yaml`. Looking up only our
own name and reporting absence as *not packaged* is the tool asserting
something it never checked — the exact failure this reconciler exists to
remove. Recipes now carry `[declared].packaged_as`, and the message says *no
file under this name* rather than *not packaged*.

Guessing the aliases was the alternative and it is worse: `glib → glib2` and
`graphite2 → graphite` move the digit in **opposite directions**, so any rule
that gets one right gets the other wrong.

**A dependency of their packaging is not a dependency of the software.** The
fix reads their `source=` and drops VCS tools only when the source really is a
checkout, so a project that genuinely needs git at build time still surfaces —
rather than blacklisting a name, which would hide that case forever.

Two smaller things the same sweep exposed:

- The findings were read with `grep unaccounted`, which drops the `== name`
  headers, so 36 lines arrived with no way to tell which package any belonged
  to. **A line that is only meaningful in context is a line that will be read
  out of context** — the package name is on every finding now.
- "36 findings" says nothing about shape. A tally by name is printed, which is
  what made `git ×20` visible as a class rather than as twenty separate
  puzzles.

**Second sweep: 151 -> 77, and all 45 corroborated** — the `packaged_as`
aliases closed the eight false absences. 16 corroborative findings, 61
undisclosed.

**And one of the 16 was corroboration against different software.** Arch's
`mako` is emersion's **Wayland notification daemon**, built with meson. Ours is
the Python template engine. Trying our own name before the declared alias found
that package and reported

```
mako: arch makedepends 'meson' -> our 'meson', absent from deps
```

about a recipe that uses no meson at all. **A name collision is not a fallback;
it is a wrong answer wearing the shape of a right one.** A recipe that declares
`packaged_as` is saying *our name is not their name*, so the bare name is no
longer tried, and every finding now names which of their packages it came from
— `arch(python-mako)` rather than an unqualified `arch`.

Worth recording how close that came to landing wrong: patching the same
function four times in one sitting left it referencing a variable that was
never assigned, and the selftest passed because nothing in it calls that
function over the network. It was rewritten whole rather than patched again.

**The remaining 16 are all real and all explainable** — Arch builds expat,
libwebp and zstd with cmake where we use autotools; libxml2 and pkgconf with
meson; harfbuzz with libpng, zlib and python enabled where we disable them.
Each is one `optional_off` line with a reason.

**Third sweep: 82, up from 77, and up is right.** The alias fix made eight
previously-invisible packages visible — `freetype2` and `graphite` were never
being looked up at all — so five new corroborative findings appeared and mako's
false one disappeared. Every finding now names what it corroborated against:
`arch(freetype2)`, `arch(glib2)`, `arch(python-mako)`.

One of the new five is the mesa/mako shape again: `glib: arch(glib2)
makedepends 'python-packaging'`. It is an **empirical** decline rather than a
guess — glib built green in run 54, before a `packaging` recipe existed in the
set at all, so glib's build does not need it.

**`--propose` drafts the declines that can be derived.** Three rules, each
citing evidence the reader can check in the recipe in front of them:

- the finding is in a build file this recipe never invokes — `pkgconf` and
  `libxml2` ship `meson.build` and are built with `./configure`, so every
  finding from those files is about a build that does not run
- the finding is conditional on an option the argv disables — `gs (conditional
  on get_option('tests'))` against `-Dtests=disabled`
- the program is a busybox applet, so it is present

Anything else is left blank with `TODO`, deliberately: **a generated reason
that is merely plausible reads like a decision somebody made, and nobody did.**
On cairo and harfbuzz it derives 4 of 9 and leaves 5 for a person.

**And it shipped disabled for one commit's worth of testing.** The branch was
gated on `if propose:` while the caller passes a dict that starts *empty* — and
an empty dict is falsy, so it could never fire on the first finding and
therefore never at all. `--propose` printed an ordinary report and exited 0,
which is indistinguishable from a set with nothing to propose. Fixture added.

**The test-directory exclusion was verified against a fixture I wrote, and the
real tarball showed it incomplete.** meson 1.10.1 contains **1421**
`meson.build` files and every one is under a test directory — but one of those
directories is `manual tests`, which does not *start* with "test", so it
survived the prefix match and contributed a `find_program` plus five
pkg-config names (`lua`, `sdl2`, `libpng`, `zlib`, `threads`) that meson does
not need at all.

Matching "test" as a **word** rather than a prefix takes meson to zero
findings, while leaving `latest` and `attestations` alone — both contain the
substring and neither is a test directory. Verifying a parser against input
you designed for it is the same mistake as a gate that agrees with the bug.

**`--propose` had no way to be switched on.** It existed on the CLI and the
workflow had no input for it, so the sweep everyone was running could never
emit a draft. Added.

**And the sweep was silently checking nothing for the three git-pinned
packages.** `stage5-reconcile` was written from the spike's tarball fetch step
and inherited only half of it — no `fetch-git.sh` call — so their archives were
never generated. On top of that, `cmd_tarball_names` still derived a filename
from the URL, which for a git remote is the REPOSITORY:

```
no tarball for libsfdo (libsfdo.git)
3 package(s) had NO UNPACKED SOURCE
```

`cmd_fetch` had been fixed to use `source_filename()` and this call site was
missed. One helper, every caller.

**Two scanner false positives, both from libxkbcommon.** It calls
`find_program('scripts/map-to-def')` and `find_program('scripts' / 'x.py')` —
the first is a path with no extension and no `./`, the second is meson's path
JOIN operator, so the scanner reported a program named `scripts`. Three of
that package's eight findings were its own files. Names containing a separator
are in-tree; the join idiom is skipped.

**The first real disclosure block is written, and it found something.**
libxkbcommon requires **bison >= 3.6** to generate its keymap parser, and the
recipe cannot declare it: bison has no stage-5 recipe, it comes from the
stage-4 sysroot. A REQUIRED tool satisfied silently by the base image is a
genuine gap in the audit story rather than a false alarm — fine today, and
exactly what breaks if that sysroot is trimmed further, which `stage5-entry`
already does six times.

**The disclosures are written: 66 entries across 12 packages, no TODOs left.**
`--propose` derived **42 of 60** and left 18 for a person, which is close to
the split that made the feature worth building — the derivable ones are
mechanical (a build file the recipe never invokes, an option the argv
disables, a busybox applet) and the rest genuinely needed the tarball read.

Four of the eighteen are worth carrying up here:

- **glib's `xgettext` is load-bearing.** It is `required: get_option('nls')`,
  a feature defaulting to `auto` — so xgettext being *absent* is the only
  reason `subdir('po')` is skipped, and therefore the only reason a set with
  no `gettext` recipe gets through glib at all. `-Dnls=enabled` would make
  gettext a hard dependency.
- **glib's `gi-docgen` reports REQUIRED and is unreachable.** The lookup is
  `required: true`, but it sits inside
  `if get_option('documentation') and enable_gir` — and `subdir('docs/
  reference')` is entered unconditionally. The guard is one line above the
  call and invisible to a per-call scan, which is the general limit of this
  detector stated concretely.
- **glib's `dtrace` is off by absence, not by decision.** A feature defaulting
  to `auto`, listed in `optional_off` with no flag behind it. Worth converting
  to `-Ddtrace=disabled`.
- **fontconfig's two `config-tool` entries are rescue paths.** It is the only
  package in the set naming a non-pkg-config method at all, and it names both
  as fallbacks behind a pkg-config lookup that succeeds.

**And the propose checkbox could not be identified in the UI.** GitHub's
dispatch form shows an input's *description*, never its name, and the
description never said "propose". Every description now leads with the input
name.

**Confirmed by the sweep: undisclosed 60 -> 0.** 82 findings became 21, all of
them corroborative, and all 48 packages were read this time -- the git-pinned
three included, which the previous run had silently skipped.

**And that run proved the tar-not-gzip pin was right, on hardware.** For
libxkbcommon the runner reported

```
tar    ffc7e2c3...   <- THE PIN, compressor-independent
tar.gz 58c4d004...   <- varies with gzip
```

The tar digest matched the recipe exactly -- pinned from a phone, verified on a
CI runner -- while the compressed digest differed from the one that phone
produced. Two machines, same tree, same tar, different gzip. That is the
measurement the earlier failure predicted.

**One thing the run also showed: the same step ran twice.** stage5-reconcile
generated the git-pinned sources at step 6 and again at step 7, identical names
and bodies, because one edit was applied to two copies of the tree and both
were merged forward. Nothing failed -- `fetch-git.sh` caches, so the second
call printed "cached" and exited 0. **A duplicate that is merely wasteful is
the kind that survives**, because the only symptom is a step nobody reads
twice.

The selftest now rejects a repeated step name **within one job**. Scoped that
way deliberately: the first version scanned whole files and flagged five
correct cases in `stage0-stage4-complete.yml` and `stage3-hermetic-arm64.yml`,
where the same name appears once per job on purpose. A gate that fires on
correct code is one people switch off.

**Three git-pinned artifacts never mirrored, and the job reported success.**
`gh` needs `GH_TOKEN` and the env block sits on the *upload* step, not on the
git-pinned step added beside it. So `gh release create` failed on an auth
error rather than the "already exists" a normal second run produces, mirror.py
correctly refused to record a route it had not written, and the workflow
discarded that refusal with `|| echo "  ADD FAILED"`.

The next step then printed **"no new routes -- table unchanged"**, which is
exactly what a run with nothing to do prints. Three artifacts stayed on one
route, the job went green, and the only evidence was three `ADD FAILED` lines
in the middle of a passing log.

**Both upload steps now fail the job when an upload fails.** mirror.py had
already done the right thing — it refuses to record a route it could not
write. A workflow that turns that refusal into an echo is the same defect as
the collector that printed "collected 32 log files" and preserved none, and as
`fetch-git.sh` printing "wrote" into a directory it then deleted. **This is the
third instance of the same shape and the first where two steps had it at
once.**

**The observed detector is wired: `veron linked`.** DT_NEEDED against
`deps.link`, both directions, after the build. It is the only one of the three
that measures what happened rather than what a file says, and the only one
that can see the direction the others structurally cannot -- **a library
picked up from the sysroot by a configure script nobody told to look**, now a
real runtime dependency that no record mentions, in a build that is green.

**The ELF reader is pure Python, deliberately.** `probe linked` shells out to
`readelf`, which is fine on a runner and wrong in the two places that matter:
the build sandbox is busybox with no binutils, and `guest/selfrebuild.sh` runs
inside the booted image where the same is true. A check on what the system
actually links must not need a tool the system does not have. Validated
against `readelf` on **300 real binaries: 246 with a dynamic section, 246
matching, 0 mismatches**, and the selftest re-checks it against the running
interpreter -- because a parser that silently returns nothing would make every
package look clean.

Both directions verified on a fixture built for the purpose: one package
linking another's `.so` without declaring it, and one declaring a name it
links nothing of. `libc.so.6` is reported as **from the stage-4 sysroot**
rather than as a gap -- a separate count, the way `veron status` treats opaque.

**What it cannot see, stated so the absence is not read as a clean bill:**
static archives leave no DT_NEEDED, `dlopen` is invisible to every detector
this project has, and build-time tools are not linked at all -- those live in
`deps.build`, which this does not check.

**A producer gained a column and one of its three readers was left behind.**
`veron git-sources` grew a fourth field -- the pinned tar digest -- and the
spike's own fetch step still read three. Shell `read -r a b c` puts THE REST
OF THE LINE into the last variable, so `$url` became

```
https://github.com/davmac314/dinit.git<TAB>d33a44bb...
```

and git failed with *"URL rejected: Malformed input to a URL function"*, which
names the symptom and not the cause. The spike died at step 10, before
building anything.

**Shell `read` fails at this silently by design** -- absorbing the remainder is
its documented behaviour, so there is no error to notice. That makes adding a
column a change to *every* reader, and the mirror and reconcile workflows were
updated while the spike was not. The same miss as `cmd_tarball_names` after
`cmd_fetch` was fixed: **one producer, three consumers, two updated.**

The selftest now samples each list subcommand for its real field count and
checks every shell `read` in every workflow against it. Verified it fails on
exactly the line that broke this run.

**Still to do:**

- Read the first `veron linked` sweep, then `--mode fail`
- The 21 corroborative declines
- Write the 21 corroborative declines
- Then `--mode fail`, which is the point of the exercise
- Write the `[undeclarable]` blocks that sweep calls for, per recipe
- Re-probe all 111 with the new fields, so the output is recorded rather than
  computed ad hoc
- `DT_NEEDED ⊆ deps.link` — the observed detector. Needs a successful build
  first, so it belongs with the §2 contracts rather than here.

### 4. Missing pins

- **llvm** — not mirrored, no digest. `llvm-timing.yml` curls upstream and
  *prints* the sha256 rather than verifying it
- **mako, MarkupSafe, packaging, PyYAML** — mesa needs all four at build time
- **How Python libraries install without pip** — open design question; the
  `meson` recipe's copy-into-site-packages is the only precedent
- **hwdata, libdisplay-info** — pinned and mirrored, absent from every
  STAGE5.md group list

### 5. Recipe fixes, all from [`PACKAGES.md`](./PACKAGES.md)

- **wlroots**: `-Dbackends=drm,libinput -Dsession=enabled`, `-Dexamples=false`,
  state `xwayland` rather than inherit it
- **mesa**: pin `vulkan-drivers` explicitly; `auto` includes nouveau on x86-64
  and that forces Rust
- **harfbuzz**: `-Dchafa=disabled`; decide on `utilities`
- **cairo**: three argv flags missing from `[declared]`; `lzo` undeclared
- **fontconfig**: declares `libxml2`, links expat
- **hwdata**: `--disable-blacklist`; never `make download` or `make check`
- **Open decision — `wrap-mode=nofallback`.** Cairo ships seven wrap fallbacks
  and only `--unshare-all` stops them, while `selfrebuild.sh` runs the same
  recipes inside a booted image that may have a network. This one is genuinely
  cross-cutting, so under rule 1 it is a policy call and needs deciding rather
  than assuming.

### 6. Seventeen recipes, none written

`libdrm`, `llvm`, `mesa`, `libinput`, `libevdev`, `mtdev`, `libxkbcommon`,
`xkeyboard-config`, `seatd`, `libudev-zero`, `hwdata`, `libdisplay-info`,
`wayland`, `wayland-protocols`, `wlroots`, `labwc`, `dinit` — plus the four
Python ones. Two of the five giants are in here.

**Not before §2 and §3 exist**, or seventeen recipes get written against
unchecked declarations.

### 7. Deferred by decision

- **~~Caching / resume~~ — BUILT.** See below.
- **Per-package build roots** — compose each build from the base sysroot plus
  only its declared DESTDIRs, making an undeclared dependency *impossible*
  rather than merely detected. Right end state; needs cheap retest first,
  because it will find real breakage across many packages at once.
- **Restore G3** once the set is complete.
- **B5.5** — dinit service definitions, the `/etc` skeleton, getty autologin,
  the kernel installed into the image, the EFI stub. Not packages, do not exist,
  and the biggest unknown in the project. Nothing measures progress toward it.

### 8. Docs

- STAGE5.md group lists disagree with `MIRRORS.tsv` — hwdata and
  libdisplay-info are pinned and unlisted
- **"111 pinned" needs its boundary stated**: complete over declared
  pkg-config/cmake/cargo names read from tarballs, with the three classes it
  cannot see named the way `BUDGET_PATH` names what is on it

---

## Where the count actually stands

41 recipes written, 31 built as of run 52, 111 pinned. A login is ~57 packages,
so roughly 16 more — **of which zero have recipes**, two are among the five
giants, and one (llvm) is not even pinned. Adding hwdata, libdisplay-info and
the four Python packages makes ~22 the honest number.

And the last stretch is not packages at all. The 41 are most of the count and
perhaps a third of the effort.


---

## Resume: prefix checkpoints in Releases

**The key is a rolling hash over the plan, not a per-package hash.**

```
h(0) = sha256(sysroot sha256 + policy)
h(i) = sha256(h(i-1) + recipe_sha256(i))
```

`veron plan` already produces a **total order** derived from the dependency
graph, so "everything before package i" *is* the closure package i was built
against. Hashing the prefix subsumes the dependency closure with no graph walk
and therefore no chance of getting the walk wrong.

Measured on the real set: editing harfbuzz — package 43 of 48 — changes **6
keys**, harfbuzz and the five after it, and leaves the other 42 untouched. A
different base image changes all 48. That is exactly the invalidation a build
cache needs, and it falls out of the ordering rather than being computed.

**Releases, not the Actions cache.** The cache is 10 GB per repository with LRU
eviction; `dest/` is ~3.3 GB uncompressed for 48 packages and the set is
heading for 111, so the cache would thrash precisely when the build got long
enough to need it. Releases are separate storage, already used by the mirror,
and content-addressing means a prefix built once is never uploaded again.

**Three things that make it safe rather than merely fast:**

- **`--clean` no longer wipes `dest/` when resuming.** It would have deleted
  the checkpoint the previous step had just downloaded, then rebuilt
  everything while reporting that a checkpoint was accepted. The build tree is
  still always wiped — reusing object files is what makes a "second build"
  compare itself.
- **The base comes from the run, never from the marker.** The first version
  recomputed the key using `marker["base"]`, which made the check **circular**:
  a checkpoint built against a *different sysroot* was internally consistent
  and therefore accepted. A gate that verifies a document against itself
  agrees with every forgery. `--resume` now requires `--base` and refuses a
  marker naming any other image.
- **The ledger records it.** A run that restored a checkpoint did not build
  those packages, so `attestations` drops to **0** with a note naming the key.
  A checkpoint is a cache and must never be evidence; `use_checkpoint` is an
  input precisely so a reproducibility run can turn it off.

**What it does not cover, stated:** the driver itself is not in the key.
Hashing `tools/veron` would invalidate every checkpoint on every comment edit,
which makes the cache useless during the work that needs it. So a change to
*how* a step runs — not what it runs — will not invalidate. That is what
`use_checkpoint: false` is for.


---

## The contracts, and what each one found

**Env freeze.** `policy/[env]` is now a closed set of five keys, checked rather
than agreed. It grew a `$CMAKE` once — a meson-specific setting handed to
cmake's own bootstrap and every autotools configure — and nothing would have
stopped that happening again. `[tool_env]` is deliberately *not* frozen: a
per-tool setting is scoped by construction.

**A declared flag must actually be passed.** All 48 clean. This is the
direction cmake failed in for its whole life: the deferral note claimed
*"DESTDIR is passed through ninja install"* while the step did not do it, and
the package went missing from the manifest entirely.

**A decline must be recorded — and this one found three.** m4 passes
`--without-libsigsegv-prefix`, `--without-libiconv-prefix` and
`--without-libintl-prefix`; pkgconf passes `--disable-static`; zstd passes
`HAVE_ZLIB=0`, `HAVE_LZMA=0`, `HAVE_LZ4=0`. **zstd's are the interesting
ones**: all three of those libraries *are* in this set, so without those flags
zstd would link them and the recipe would understate its own dependencies. m4's
are the `auto` failure in waiting — gnulib probes for all three and links what
it finds, so the flags stop m4 acquiring a dependency the day one arrives for
another package's sake.

**Scoped to declines deliberately.** Requiring `argv ⊆ declared` outright would
force `--prefix`, `-DCMAKE_BUILD_TYPE` and `--bootstrap` into the field and
turn a record of *decisions* into a second copy of the command line — and a
field that is mostly boilerplate stops being read. What must be recorded is
what the build declines.

**The file list is file-level: size and sha256 per path.** `installs.txt` sits
beside each recipe and the recipe carries the count and one digest over it:

```
f 5891b5b5...be03  6      usr/bin/dinit
l dinit                   usr/bin/dinitctl
```

**The first version of this hashed only the path SET**, on the argument that
content hashes churn on any rebuild that is not bit-reproducible and that
reproducibility is G3's job. That reasoning does not survive contact with what
this project has already measured:

```
VERON-IMAGE-REPRO-OK  two builds, identical bytes
```

Per-file digests are therefore **stable**, and one that moved would be either
a real change or a **reproducibility regression** — both worth stopping for.
Leaving contents out would have discarded the strongest property the build
already has.

**It was also already computed.** `file_manifest` has recorded sha256 per file
and the target per symlink since n=2; it was simply never pinned where a
recipe could carry it.

**And it is cheaper than G3.** G3 builds everything a *second* time in the same
run and compares, which is why it was switched off — it doubles every build.
Comparing this run's bytes against a digest a previous run committed is
per-package reproducibility across *time*, for the cost of hashing files that
were just written.

Symlinks record their target rather than a hash: the target is what a symlink
*is*, and hashing what it points at would make a link's identity depend on a
file that may belong to another package.

When the digest moves the check **names the files**, because "the digest
moved" is a fact nobody can act on:

```
install-set-changed  dinit: 2 path(s) now, digest 391c96e1, recipe pins bff8e7bd
    + f 83ced3e4...8d76 14 usr/bin/dinit
    - f 5891b5b5...be03  6 usr/bin/dinit
```

**`[installs]` prefixes**, at directory depth 3. `usr` alone says nothing;
full paths would list ten thousand files and move on every release.
`usr/share/hwdata` and `usr/lib/modprobe.d` are the level at which somebody
looks and says yes or no — which is exactly the level hwdata's stray modprobe
config sits at. `--propose` emits the current prefixes from a real build,
because writing 48 of these from memory is how they end up wrong.

The count of **unchecked** packages is printed alongside the count of
problems: a zero over an unchecked set is the reassuring number this project
keeps catching.


---

## The isolate spike

**`stage5-isolate.yml` — can each package build from its declared dependencies
alone?**

Each package gets the stage-4 sysroot plus the DESTDIRs of the packages it
**declares**, stacked as bubblewrap `--overlay-src` layers, and nothing else.
An undeclared dependency stops being a *finding* and becomes a build failure
that names itself.

**Direct dependencies, not the closure.** glib sees pcre2 because it declares
pcre2; it does not see zlib because pcre2 happened to be built after zlib.
That is the strict reading and it is the one that finds things — a failure
that turns out to be *"we should have declared this"* is the finding, not
noise.

**It keeps going and it is never a gate.** The main spike stops at the first
failure because its job is a working image. This one's deliverable is the
*list* of packages that cannot build in isolation and why, so it exits 0 with
a report.

**It builds our own bubblewrap rather than taking apt's.** bubblewrap 0.11.0
is already pinned and mirrored here with two routes, and the entire result
depends on whether `--overlay-src` exists — which is a property of the
*version*. Taking the runner's binary would make the answer depend on what
Ubuntu happened to ship. The job fetches it through the same mirror every
other source comes through, builds it, and **checks that `--overlay-src` is
present** rather than assuming.

What remains from apt is bubblewrap's own build surface — meson, ninja,
libcap headers, pkg-config — which is smaller and more declarable than an
opaque binary, and stated rather than implied.

**Overlay rather than copying** means nothing is duplicated and no build can
mutate the shared sysroot even by accident: `stage_into`'s whole mutation
model is absent here rather than merely unused.

**What it cannot isolate**, so the result is not over-read: the stage-4
sysroot is in every root, so bison, gcc, perl and m4 stay reachable by
everything. This tightens stage 5 against itself, not against its base — which
is exactly what `[undeclarable]` exists to record.

**Untested locally.** There is no bwrap in the environment these recipes are
written in, so the layer stack was verified by inspecting the composed argv
(sysroot plus glib's seven declared deps, nothing else) and the overlay
mechanics are the first run's experiment. Unprivileged overlayfs is a kernel
property; the job prints `uname -r` so a failure there is attributable rather
than looking like a bubblewrap bug.


---

## Two failures, and what each cost

**libxkbcommon cannot build its own tools without xkeyboard-config.**

```
tools/info.c:89: error: 'DFLT_XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH' undeclared
```

That macro is set at `meson.build:180` only `if
XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH != ''`, which is empty unless a
*versioned* xkeyboard-config is found by pkg-config. `tools/info.c` references
it unconditionally. **An upstream bug in 1.13.2**, not a configuration
mistake, and one that only appears in a system that genuinely lacks the
package.

I read this tarball's options, turned five off, judged `xkbcli` "small" and
left `enable-tools` at its default. Nothing here wants xkbcli — wlroots links
the **library** — so `-Denable-tools=false` removes the failure at its cause
rather than patching a source file around a missing dependency. The runtime
gap on xkeyboard-config was already recorded in `[undeclarable]`; it turns out
to be a build-time gap for the tools as well.

**And the diagnostics did not contain the error.** The driver log had the argv
and `rc=1 (6s)`; `BUILD_LOGS` collects meson's *configure* log, which was clean
because configure succeeded. The one line explaining the failure existed only
in the GitHub job log, which is not the artifact anyone is handed. Step output
now goes into the per-package log, and the last 40 lines print on failure.

**That change broke the step timeout three times before it worked.** Teeing
through `subprocess.PIPE` means reading blocks until EOF, EOF waits for every
*grandchild* that inherited the pipe, and a 2-second limit on
`sh -c 'sleep 30'` took the full thirty and left `sleep` running. A pump
thread did not fix it. A process-group kill did not fix it, because the join
happened before the kill. **The timeout is not decorative** — a run once sat
sixty-six minutes on one line of m4's gnulib suite.

Handing `subprocess.run` a real file descriptor instead of a pipe keeps its
timeout handling exactly as it was and still puts every byte in the log. The
console loses live output; the heartbeat already exists to keep the job alive
without it. Verified: `rc=124` at 2.0s, and both streams in the file.

**Worth being plain about the shape of that**: four consecutive patches to one
function, each looking correct and each failing the same test. It is the same
failure as `packager_deps`, which was eventually rewritten whole rather than
patched again — and it was only caught because the timeout path was tested
rather than assumed.


---

## The 21 corroborative declines — and `--mode fail`

All 21 written, verified against the sweep's own findings: **21 of 21 now
accounted for.** With the 61 disclosures already in place, every one of the
sweep's 82 findings has an answer, so `stage5-reconcile` defaults to
**`--mode fail`**. A gate whose output has been read and acted on should
block; one left on warn past that point is decoration.

They fall into four kinds, and two of them are more than bookkeeping:

**Build-system differences (10).** Arch builds expat, libwebp and zstd with
cmake, libxml2 and pkgconf with meson, ninja with cmake, freetype with meson.
Upstream ships both in every case. **Two of these are forced rather than
chosen**: pkgconf cannot use meson because meson is built *later* in the plan,
and ninja cannot use cmake because cmake is built *after* ninja and needs it.
The bootstrap order decides those, not preference.

**Features we disable (5).** harfbuzz's `libpng`, `zlib` and `python` are the
utilities and the test suite; freetype's `cairo` is the ftview/ftbench demos.
**All of them are in this set**, so these are real choices — enabling the
utilities would make them dependencies. freetype's is also a cycle: cairo is
rung 45 against freetype's 40, which is why upstream keeps the demos separate.

**Test tooling (4).** m4's `gperf` and `python` drive gnulib's suite, icu's
and graphite2's `python` the same. Upstream suites are not run here.

**And one answered empirically.** Arch's glib2 lists `python-packaging` —
the same shape as mesa's `import mako`, which no `.pc` file can see and which
cost this project a missing package once already. It is not needed here, and
the evidence is a build rather than a reading: **glib built green in run 54,
before a `packaging` recipe existed anywhere in the set.**


---

## The build console: evidence instead of narration

The console used to carry every line every compiler emitted — hundreds of
thousands, in which the facts worth keeping were invisible. Sending step
output to `driver/<pkg>.log` fixed that and created the opposite problem: a
thirty-minute build printed its preamble and **nothing else**, because the
driver's own `print()` calls were sitting in Python's block buffer with no
child output to force them out. **A build that shows no progress cannot be
told from a hung one**, which is what the heartbeat exists to prevent. Line
buffering is now set explicitly at startup.

What replaces the compiler output is what the build **decided** and what it
**produced** — the things the manifest, the ledger and G3 all read:

```
[27/48] python 3.14.0    group toolchain
    source   Python-3.14.0.tar.xz  sha256 9c1a2f4b7e03
    + ./configure --prefix=/usr --enable-shared ...
    + make -j4
    + make install
    steps    configure 34s · build 252s · install 8s
    links    zlib bzip2 xz libffi ncurses readline expat sqlite   (+3 from the sysroot)
    prefixes usr/bin usr/include/python3.14 usr/lib
    3021 path(s), 118.4 MiB, digest 9f2e1a34c8b70d51   [pinned: matches]
      f a948904f… 12 usr/bin/demo
      l demo usr/bin/democtl
```

Every line is measured by this run rather than narrated.

**`links` is the one that earns its place.** `DT_NEEDED` resolved to packages,
printed **at the package that produced it**. `veron linked` already does this
across the whole set afterwards, which is the right place for a *gate* and the
wrong place to *read* — an undeclared link surfaces in a summary forty
packages after the one responsible. Here it appears as
`zlib(UNDECLARED)` on the build that caused it, and `declared-not-linked`
catches the reverse, which is the shape fontconfig carried for its whole life.

**`[pinned: matches]`** appears once `[installs].digest` is seeded, and makes
every build a per-package reproducibility check against a previous one — for
the cost of hashing files that were just written, rather than G3's second full
build.

The full argv still prints. It is one line per step and it is the honest
record of what ran.


---

## The isolate spike ran: 31 of 48 built from their declared dependencies

And the 17 failures were **not** missing declarations. Every dominant cause was
one shape:

```
ImportError: libz.so.1: cannot open shared object file
cmake: error while loading shared libraries: libcurl.so.4
libncursesw.so.6, needed by libreadline.so, not found
```

`meson` declares `python`. python was in the root. **python could not start**,
because python's own runtime closure was not. And the recipes were already
right — `python runtime=[zlib, …]`, `cmake runtime=[curl, …]`,
`readline runtime=[ncurses]`.

**The composition rule was wrong.** A build tool you cannot execute is not a
build tool. Each declared dependency now brings its **runtime closure**,
transitively.

**This is not the transitive-build-deps reading, and the distinction is the
whole point of the exercise.** glib still does not see zlib because pcre2
needed zlib to *build*. It sees zlib because it declares python and python
needs zlib to *run*. Build closure stays strict; runtime closure travels with
the thing that has it — which is what declaring a dependency has to mean if it
means anything.

Verified on the real set: fribidi declares only `meson` and `ninja`, and its
root composes to meson, ninja, python (meson's runtime) and python's runtime
closure. The code never reads a dependency's `build` list, so a transitive
*build* edge cannot leak.

**And the spike's own bubblewrap worked**: `bubblewrap 0.11.0`,
`--overlay-src present`, built from the pinned tarball in this repository
rather than apt's. The whole result depends on that flag existing, and taking
the runner's binary would have made the answer depend on what Ubuntu shipped.


---

## The checkpoint key was wrong, and a run proved it

`no usable checkpoint -- building everything`, with a 55-package checkpoint
published and every source unchanged.

**The prefix hash conflated position with dependency.** `h(i) = sha256(h(i-1)
+ recipe_sha(i))` is right about edits and wrong about insertions. Editing
package 43 of 48 moved 6 keys — that was measured and quoted as evidence the
design worked. Adding wave 1, wave 2 and wave 3 then moved **53 of 62**,
because the first new package landed at rung 10 and every `h()` after it
shifted. The checkpoint was correctly refused; the key was just too coarse.

```
key(p) = sha256(base + policy + recipe_sha(p) + each dep's key)
```

Measured on the real set: inserting a package with no dependents now moves
**0 of 62** keys. Editing zlib moves **38** — everything that transitively
depends on it, which is the answer. A different base still moves all 62.

**And the marker is per package now.** A checkpoint was all-or-nothing; it
carries `{package: key}`, and `--resume` keeps the subset that still matches
and **deletes the DESTDIRs that do not** — a left-behind `dest/` from a
different recipe is exactly what a resume must never build on top of.

**The soundness argument changed with it, and that is worth stating rather
than burying.** A prefix hash was sound under *any* declarations: everything
earlier was in the hash whether declared or not. A dependency key assumes a
package is affected only by what it declares — and `stage_into` puts every
earlier package in the shared build root, so an **undeclared** dependency is
an input this key does not cover.

That is exactly what `stage5-isolate` measures, and it is why that spike is
not tidying: **it is the thing that validates this cache key.** glib needing
an undeclared `pkgconf` was found there. Until that sweep is clean, a stale
hit is possible in principle — which is why `use_checkpoint` is off by
default and the ledger records `attestations=0` when one is used.
