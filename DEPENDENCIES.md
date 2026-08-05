# The dependency model

Three detectors, none of them sufficient, and one rule that binds them.

The rule is not that they agree — they measure different things and are not
expected to. It is that **no dependency name is unaccounted for**: every name
any detector can see is declared in a recipe, declined with a reason, or
disclosed as undeclarable. Silence is what let seven packages into a set
described as complete.

---

## What each one measures

| | reads | authority | blind to |
|---|---|---|---|
| **static** | this tarball's build files | what upstream *asks for* | anything not in a machine-readable form |
| **corroborative** | Arch and Alpine `makedepends` | what another packager *declares* | our configure flags, which differ |
| **observed** | `DT_NEEDED` after a build | **what actually linked** | static archives, `dlopen`, build tools |

`spikes/stage5/tools/probe.py reconcile` runs the first two.
`veron linked` runs the third.

**None of them is the ground truth on its own**, and the project has a finding
from each:

- **static** found `wlroots` composing a green build with no DRM backend,
  because `backends=['auto']` stays a literal string and every backend's
  dependency is then `required: false`.
- **corroborative** found `python-mako` in Arch's mesa — the module mesa
  discovers with `run_command(python3, '-c', 'import mako')`, which no `.pc`
  file can express and which was in no group list.
- **observed** found `readline` linking `libncursesw.so.6` with `deps.link`
  empty. Both other detectors read *intent*, and the recipe's intent was
  wrong.

---

## The three states a name can be in

**Declared** — in `deps.build`, `deps.link` or `deps.runtime`. The build needs
it and the ledger says so.

**Declined** — in `deps.optional_off`, with the reason in a comment. This is
the state that distinguishes *"we chose not to need this"* from *"nobody
looked"*, and those were the same silence before. 21 of the current declines
came from the corroborative detector: Arch builds expat with cmake and we use
autotools; Arch enables harfbuzz's utilities and we do not.

**Disclosed** — in `[undeclarable]`, when the lookup is one no `.pc` name can
answer. 66 entries across 12 packages. These are the class that cost the
project llvm and mako, and they are a *required* field rather than a detector
output precisely because no scanner can be trusted to find them all.

A fourth state existed and no longer does: **unmentioned**.

---

## Declared how strictly

**`deps.build` and `deps.link` are direct.** A package does not get to reach
something because a package it depends on happened to need it.

**A declared dependency brings its runtime closure.** This is not the same
claim, and the distinction is the one the isolate spike exists to test. glib
does *not* see zlib because pcre2 needed zlib to build. glib *does* see zlib
because it declares python and python needs zlib to run. **A build tool you
cannot execute is not a build tool.**

That rule was learned rather than designed: the first isolate sweep failed 17
of 48, and every dominant cause was `ImportError: libz.so.1`,
`cmake: error while loading shared libraries: libcurl.so.4`, or
`libncursesw.so.6, needed by libreadline.so, not found`. The recipes were
already correct; the composition rule was not.

---

## The case this was built for, when it happened

`elfutils` entered the set at rung 20, for mesa's sake. `glib` builds at rung
41. Nothing in glib's recipe changed. Both measuring detectors reported the
same event independently:

```
linked-undeclared    glib links elfutils (libelf.so.1 via usr/bin/gresource)
install-set-changed  glib: gresource 75808 -> 76768 bytes
```

glib's `libelf` is a **feature defaulting to `auto`** — off for sixty-one
builds because nothing provided libelf, silently on the moment something did.
**A package added twenty rungs earlier changed what glib is.**

That is the direction no static scan and no distro comparison can reach: both
read intent, and nobody's intent changed.

**And the checkpoint would not have caught it.** A package's key is its recipe
plus its **declared** dependencies; elfutils was not declared, so glib's key
did not move and a cached glib would have been reused with different build
inputs. That is the soundness caveat recorded below, occurring for real — and
the concrete reason `stage5-isolate` is load-bearing rather than tidying.

## What no detector can see

Written down because a gate that passes over an unchecked set is worse than no
gate:

- **Static archives.** bzip2 builds only `libbz2.a`, so cmake, libarchive and
  python link it with no `DT_NEEDED` to show for it. Nine of the eleven
  findings in the first observed sweep have this cause.
- **`dlopen`.** Invisible to all three, permanently.
- **The stage-4 sysroot.** It is in every build root, so bison, gcc, perl and
  m4 cannot be isolated. libxkbcommon genuinely requires `bison >= 3.6` and
  cannot declare it, because bison has no stage-5 recipe — that is what its
  `[undeclarable]` block records, with the run that measured `bison 3.8.2`
  cited rather than asserted.

---

## Where each gate runs

| gate | workflow | mode |
|---|---|---|
| `probe.py reconcile` | `stage5-reconcile` | **fail** — 0 unaccounted across 48 |
| `veron linked` | `stage5-spike` | warn |
| `veron installs` | `stage5-spike` | warn, until the digests are seeded |
| `veron isolate` | `stage5-isolate` | never a gate — the list is the deliverable |

**`warn` first is a rule, not a hedge.** A gate whose output nobody has read
is a gate that gets switched off the first time it is inconvenient. The
reconciler ran in warn for four sweeps — 151 findings, then 82, then 21 — and
each round removed a class of noise that would otherwise have been silenced
along with the signal: meson's own test fixtures, pango's vendored subprojects,
Arch's `git` in every package it builds from a checkout.

It moved to `fail` when the count reached zero and every remaining name had an
answer written by a person.
