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

### 2. Contracts — self-contained, testable locally, no runs burned

| | rule |
|---|---|
| env freeze | 2 |
| `[installs]` prefixes | 3 |
| file-list digest | 3 |
| `[undeclarable]` disclosure | 4 |
| `declared ⊆ argv` | 5 |
| `DT_NEEDED ⊆ declared` | 5 |

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

**Still to do:**

- Run `--propose` over all 45, review the drafts, paste them in
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

- **Caching / resume.** A failure at package 33 costs a full 32-package rebuild
  to retest. `dest/` is content-addressable by the `_recipe_sha256` the driver
  already computes. Deliberately not designed yet; it is the load-bearing
  decision under everything below it.
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
