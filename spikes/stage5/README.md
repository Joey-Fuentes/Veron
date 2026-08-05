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
| recipes written | **41** | `packages/*/recipe.toml`, ordered by `veron plan` |
| built, installed, staged | **31** | `stage5-spike`, blocked at `glib` |
| artifacts with ≥2 fetch routes | **107** | `sources/MIRRORS.tsv`, 239 routes |
| git-pinned (no tarball exists) | **3** | libsfdo, dinit, libxkbcommon |

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
the backend reports not-found and never enters the trace parser. One line,
global, no recipe changes, and new meson packages inherit it. The cost is that
a dependency discoverable *only* through a CMake config file would now be
missed; nothing in the set is in that position, and a named not-found beats an
unhandled exception regardless. `cmake_backend_used()` fails the build if
meson's log ever shows `Found CMake:` again, because a policy nothing checks
is a belief rather than a fact.

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
