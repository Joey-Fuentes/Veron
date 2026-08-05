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
| artifacts with ≥2 fetch routes | **107** | `sources/MIRRORS.tsv`, 134 routes |
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

**`glib` requires `bash`**, and crashes meson outright without it. A build-time
*tool*, not a library, so again undeclared anywhere.

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

**The pessimistic dependency graph does not close**, and that is expected: a
declared dependency list is the union of every optional feature, so `cairo ↔
pango` and `file ↔ zstd` appear as cycles that our own flag choices remove.
`probe order` proves the useful direction — acyclic there would guarantee
acyclic in reality.

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
