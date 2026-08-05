# What reading the tarballs found

Nine packages read source-first, before building them. Every digest below was
verified against the recipe pin or `sources/MIRRORS.tsv` before the tarball was
opened, so these are findings about **the exact bytes this set will build**, not
about the project in general.

**Why read rather than build.** graphite2 is rung 34. A run that discovers its
problem by hitting it spends thirty rungs and half an hour getting there, and
learns one fact. Reading the tarball costs a minute and finds the same fact
plus everything behind it. Six of the nine packages below turned out to have
something that would have cost a run, and three of those would have cost a run
each *in sequence*, because each is behind the last.

**What this file is not.** None of it is a substitute for building. Static
reading finds what a build system asks for; it cannot tell a hard requirement
from an optional one that happens to be satisfied, and it cannot see anything
decided at runtime. Where a finding is inference rather than measurement it
says so.

---

## The pattern underneath most of these

**`required: false` almost never means "optional".** It means "fails later, and
worse". Four packages here use it for something that is genuinely required:

| package | lookup | what actually happens when it is missing |
|---|---|---|
| glib | `libinotify`, `libelf` | falls to meson's CMake backend, which crashes on cmake 4.x trace output |
| fontconfig | `json-c` | same |
| libdisplay-info | `hwdata` | falls back to a hardcoded absolute path and dies on a missing file |
| wlroots | `hwdata`, `libdisplay-info`, `libseat`, `libudev`, `libinput` | **builds green with the DRM backend silently omitted** |

The wlroots one is the worst kind: no error at all, and the missing capability
is exactly the one B5.5 exists to prove.

**`auto` options make missing dependencies invisible.** Same shape: harfbuzz's
`chafa`, cairo's `lzo`, wlroots' `backends`, mesa's `vulkan-drivers`. Each is
"off" only because the thing is absent, which is not a decision anybody made
and not a decision anybody can read.

---

## glib 2.86.4

`d4e2b5d791d5015ffd8c6971ad8e975a0a55c1a14926cdb25cf843ff00682260` — matches
the recipe pin.

**Three CMake-backend crash sites, not one.** The patch in `packages/glib/
patches/` fixes `meson.build:2549` (`bash-completion`). Run 51 then died at
`gio/inotify/meson.build:32` (`libinotify`). Reading the tarball found a third
waiting behind it: `gio/meson.build:978`, `dependency('libelf', required:
false)`, and libelf is not in the set. **A patch per call site is not a smaller
problem than a patch per package.**

`libinotify` is `required: file_monitor_backend == 'libinotify-kqueue'`, which
is false on Linux, so it is a clean not-found once the backend is out of the
way.

**Nothing glib REQUIRES routes through that backend.** Checked, not assumed,
across all 49 `dependency()` calls:

- `iconv` and `intl` use meson's builtin handlers — on glibc both live in libc
- `gvdb` resolves from the subproject glib ships; no network
- `libffi`, `zlib`, `libpcre2-8` come from pkg-config under exactly the names
  their own guest tests already check

**`nls` defaults to `auto`, and that is load-bearing.** `find_program(
'xgettext', required: get_option('nls'))` is therefore not required, so
`subdir('po')` is skipped. That is the only reason a set with no `gettext`
recipe gets through glib at all. **Anyone setting `-Dnls=enabled` makes gettext
a hard dependency**, and it is not in the 111.

meson `>= 1.4.0` (we ship 1.10.1). `tools/gen-visibility-macros.py` is a
required `find_program`, so python is needed at configure.

**Run 52 got `meson setup` to succeed** for the first time. Everything past
that — roughly 2,500 C files at `jobs=1` — is unexplored.

---

## graphite2 1.3.14

`f99d1c13aa5fa296898a181dff9b82fb25f6cc0933dbaa7a475d8109bd54209d` — matches.

**It cannot be configured by cmake 4.x without a flag.** Line 1 of
`CMakeLists.txt`:

```cmake
CMAKE_MINIMUM_REQUIRED(VERSION 2.8.0 FATAL_ERROR)
```

cmake 4.0 removed compatibility below 3.5 as a **hard error**, raised before
anything else is read. graphite2 1.3.14 is from 2018 with no release since, so
the pin cannot move forward. `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` is the escape
hatch cmake 4.0 shipped for exactly this, and it is now in the recipe.

Worth noting how nearly this was missed: the call is **uppercase**, so a
case-sensitive grep for `cmake_minimum_required` returns nothing and the file
looks like it declares no minimum at all.

Everything else is benign. `find_package(PythonInterp 3.6)` is not `REQUIRED`,
so the module's removal in cmake 4 yields a not-found rather than an error, and
the block it guards only disables some tests. `add_subdirectory(tests)` and
`add_subdirectory(doc)` are unconditional but degrade — the doc targets are all
behind `if(A2X)` / `if(DOXYGEN)`. `GRAPHITE2_COMPARE_RENDERER` is declared in
`tests/CMakeLists.txt` via `CMAKE_DEPENDENT_OPTION`; passing it on the top-level
command line is fine, it lands in the cache. `LIB_SUFFIX` is empty by default,
so the library and `graphite2.pc` install under `lib/`, which is where pkgconf
looks.

---

## harfbuzz 12.3.2

`6f6db164359a2da5a84ef826615b448b33e6306067ad829d85d5b0bf936f1bb8` — matches.

**No Rust.** 12.x adds two Rust backends, `fontations` and `harfrust`. Both
default to `disabled`, and both are gated on `.enabled()` — which is false for
`auto` as well as `disabled` — so Rust activates only on an explicit request.

**Every version constraint clears**, all four checked:

| harfbuzz wants | we provide |
|---|---|
| `freetype2 >= 12.0.6` | 27.6.1 |
| `icu-uc >= 49.0` | 78.2 |
| `glib-2.0 >= 2.30.0` | 2.86.4 |
| `graphite2 >= 1.2.0` | 1.3.14 |

The freetype numbers look wrong until you know `freetype2.pc` carries the
libtool version rather than the release version. The recipe's guest test already
expects `27.6.1` for freetype 2.14.1, so that was known.

**Upstream agrees with our bootstrap shape.** harfbuzz passes `default_options:
['harfbuzz=disabled']` to its own `freetype2` lookup, with a comment naming the
`harfbuzz -> cairo -> freetype2 -> harfbuzz` cycle it is avoiding. The recipe's
`build`/`link` on `freetype-bootstrap` and `runtime` on `freetype` matches that
reasoning exactly.

With `-Dcairo=disabled` the whole cairo block is skipped — `if not
get_option('cairo').disabled()` is false — so those two `required: false`
lookups never run.

**Two undeclared behaviours.** `chafa` defaults to `auto` and no flag is passed,
so meson searches for it and misses; `optional_off` lists it as off when nothing
turns it off. `utilities` defaults to `enabled` and is not in the flags at all,
so hb-view, hb-shape and hb-subset get built — harmless, since `cairo_dep` is a
null dependency and the utils tolerate it, but it is build time and three
installed binaries nobody asked for.

No configure-time `find_program`, because the release ships pre-generated ragel
output. meson `>= 0.60.0`.

---

## cairo 1.18.4

`445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb` — matches.

**Every version constraint clears:**

| cairo wants | we provide |
|---|---|
| `pixman-1 >= 0.40.0` | 0.46.4 |
| `freetype2 >= 23.0.17` | 27.6.1 |
| `fontconfig >= 2.13.0` | 2.17.1 |
| `libpng >= 1.4.0` | 1.6.55 |
| `glib-2.0 >= 2.14` | 2.86.4 |

`pixman` is the only lookup with no `required:` kwarg, so it is mandatory —
satisfied, rung 33 before rung 40. Cairo's source comments confirm the freetype
libtool-versioning story independently (`'>= 23.0.17' # Release version 2.10`),
and 27.6.1 also clears `25.0.19`, so COLRv1 support switches on.

**Seven wrap fallbacks, and the guarantee against them is currently the
sandbox.** `expat`, `fontconfig`, `freetype2`, `glib`, `libpng`, `pixman` and
`zlib` each name a subproject fallback. Under meson's default wrap mode a failed
pkg-config lookup does not produce "not found" — it produces an attempt to
download and build a bundled copy.

Only `bwrap --unshare-all` stops that today. But `guest/selfrebuild.sh` runs
**the same recipes inside the booted image**, which is the tier-1 self-hosting
claim, and a booted system with a network has no such isolation. A missing `.pc`
there would silently vendor an unpinned pixman into a system whose premise is
that every byte traces to a recorded source, with no ledger record describing
it. See `ROADMAP.md` §5 — this is a policy decision, not a recipe peculiarity.

**Declared drifts in both directions at once.** `[declared].configure_flags`
omits `-Dtests=disabled`, `-Dspectre=disabled` and `-Dsymbol-lookup=disabled`,
all three of which *are* in the argv. `optional_off` lists `gtk2-utils` and
`quartz`, which default to disabled anyway, while omitting `lzo`, which defaults
to `auto` and is genuinely searched for and absent.

`find_program('version.py')` runs inside `project()`, so python is needed before
anything else happens. meson `>= 1.3.0`.

---

## fontconfig 2.17.1

`9f5cae93f4fffc1fbc05ae99cdfc708cd60dfd6612ffc0512827025c026fa541` — matches.

**The `json-c` crash site is real and unconditional.** Line 57,
`dependency('json-c', required: false)`, gated on nothing — not on `tests`, not
on anything. It would have crashed configure exactly like glib's libinotify.

**And fontconfig is the honest counterexample to the CMake-backend policy.**
Lines 38–44:

```meson
freetype_dep = dependency('freetype2', method: 'pkg-config', ..., required: false)
if not freetype_dep.found()
  freetype_dep = dependency('freetype', method: 'cmake', ...)
endif
```

An *explicit* CMake-method lookup — the only genuine consumer of that backend in
the set. Harmless here because the pkg-config path succeeds (27.6.1 against a
`>= 21.0.15` requirement), but it narrows the claim: nothing depends on the
CMake backend as its **primary** path. Fontconfig would have used it as a
rescue, and that rescue is gone.

**It declares a dependency it will not use.** `link` and `runtime` both list
`libxml2`. With `xml-backend=auto`, line 64 finds expat via pkg-config, so the
libxml2 branch at line 73 — guarded by `not xml_dep.found()` — never runs.
fontconfig links expat and not libxml2.

That is worse than flag drift, because `link` and `runtime` feed the ledger and
the image: the record asserts a linkage that does not exist. Nothing breaks —
libarchive genuinely wants libxml2, so it stays in the set for a real reason.
**And unlike flag drift this is measurable**: `probe linked` reads `DT_NEEDED`
and nothing runs it against the declarations.

gperf is found and takes the first branch; python is required via
`import('python').find_installation()`; `nls=disabled` keeps both `libintl` and
`xgettext` optional. `fontations` is Rust and defaults to `disabled`. meson
`>= 1.6.1`.

**Credit where due:** fontconfig's `configure_flags` and `optional_off` are the
only pair read this session that match the argv exactly. Which is the argument
for checking rather than trusting — hand-maintained prose is right about half
the time and you cannot tell which half without comparing.

---

## mesa 26.1.6

`5296b88a0f1e012e2cb9ada150a2bbadf728ca81e5a4fb2ab43c83a4d2158606` — matches
`sources/MIRRORS.tsv`.

**Open question 5 is answered: mesa builds without Rust on aarch64.** The
trigger is one line, `meson.build:835`:

```meson
if with_gallium_rusticl or with_nouveau_vk or with_tools.contains('etnaviv') or with_virtgpu_kumquat
  add_languages('rust', required: true)
```

`gallium-rusticl` and `virtgpu_kumquat` default to `false`, `tools` to `[]`. And
`with_nouveau_vk` comes from `vulkan-drivers`, which defaults to `auto` — where
the expansion is **per architecture**:

```
x86      ['amd', 'intel', 'intel_hasvk', 'nouveau', 'swrast']   <- Rust required
aarch64  ['swrast', 'intel', 'panfrost', 'freedreno', 'asahi']  <- no nouveau
```

So the answer is architecture-dependent and we are safe by accident. **Pin
`vulkan-drivers` explicitly** rather than inherit that; upstream adding nouveau
to the aarch64 list would otherwise turn the no-Rust policy off silently.

The `*-rs.wrap` files in `subprojects/` are the Rust crates the earlier probe
saw. They are the union of every optional feature, not what our flags need.

**The real blocker is Python, and it is not budgeted.** mesa requires three
modules at configure time, none of which are in the 111 and none of which can
arrive via pip:

- **`mako` >= 0.8.0** — hard error: *"Python (3.x) mako module >= 0.8.0
  required to build mesa"*. Pulls **MarkupSafe** with it.
- **`packaging`** — the check falls back to `distutils`, which was **removed in
  Python 3.12**, and stage 5 builds 3.14. So `packaging` is required outright.
- **`yaml`** (PyYAML) — and this one fails badly. A python lacking yaml causes
  `continue`, so the loop moves to the next candidate; when the list is
  exhausted the error raised is **`Python <version> not found`**, which is not
  what went wrong.

**How Python libraries install without pip is an open design question.** The
only precedent in the tree is the `meson` recipe, which copies `mesonbuild/`
into site-packages directly. All four of these are pure-Python or have
pure-Python fallbacks, so the same approach should work.

**And llvm arrives by a route the probe cannot see:** `dependency('llvm',
method: 'config-tool')`. LLVM ships no `.pc` file, so the name-to-package
resolution `probe.py` is built on has nothing to match. That is why llvm — one
of the five packages STAGE5.md names as most of the work — is absent from
`MIRRORS.tsv` entirely.

---

## wlroots 0.19.1

`f6bace4eac8708010430411a64f42055249ee7742cac29efa1a4036988291b2b` — matches
`sources/MIRRORS.tsv`.

**The most consequential finding of the session: `backends=auto` silently
produces a compositor that cannot drive a display.**

The trace, in four steps:

1. `backends` defaults to `['auto']`. The expansion to `['drm','libinput','x11']`
   happens only `if 'auto' in backends and get_option('auto_features').enabled()`
   — and `auto_features` defaults to `auto`, not `enabled`. **So `backends`
   stays literally `['auto']`.**
2. Therefore `'drm' in backends` is **False**, which makes `hwdata`,
   `libdisplay-info`, `libseat`, `libudev` and `libinput` all `required: false`.
3. But `subdir('drm')` *is* entered, because the loop tests `backend in backends
   or 'auto' in backends`.
4. Inside: `if not (hwdata.found() and libdisplay_info.found() and
   features['session'])` → `subdir_done()`.

With any of those missing, wlroots configures green, compiles green, installs
green, and ships **no DRM backend, no libinput backend and no session support**.
It would run nested inside another compositor and nowhere else. Nothing in the
log says a capability was dropped.

**The fix is to stop using `auto`:** `-Dbackends=drm,libinput -Dsession=enabled`.
That flips `'drm' in backends` to True, every one of those dependencies becomes
genuinely required, and a missing one is a loud configure error.

**Two required packages that appear in no STAGE5.md group list:** `hwdata` and
`libdisplay-info`. Both are already in `MIRRORS.tsv` with two routes each — so
`stage5-probe-required` found them and pinned them, and the planning document
never learned. The plan and the pinned data disagree, and the pinned data is
right.

Version requirements, for the recipes that do not exist yet: `pixman-1 >= 0.43.0`
(have 0.46.4), `libdrm >= 2.4.122` (mirror carries 2.4.134),
`wayland-protocols >= 1.41`, `libseat >= 0.2.0`, `libinput >= 1.19.0`,
`gbm >= 17.1.0`, `egl >= 1.5`, `vulkan >= 1.2.182`.

Smaller notes: `examples` defaults to `true` and its dependencies use
`disabler: true`, so the examples degrade silently — worth `-Dexamples=false`.
`xwayland=auto` is off only because xcb is absent, which under the no-X11 policy
should be stated rather than inherited. `color-management=auto` reaches for
`lcms2`, which STAGE5.md has in group 7 while wlroots wants it in group 6.

---

## hwdata 0.410

`2864b061b179b8ad8cb6a7339ca07678240a183d9cedce8677a4950acaf798e0` — matches
`sources/MIRRORS.tsv`.

Data only. No compiler, no autotools — a 47-line BSD-licensed shell `configure`
that writes `Makefile.inc`.

**The recipe must be `./configure --prefix=/usr` then `make install
DESTDIR=$D`.** A bare `make` first fails by design: `Makefile.inc: configure`
runs `./configure`, prints "Run the make again", and `exit 1`.

**A network fetch sits one dependency edge away.** `install` depends only on
`Makefile.inc hwdata.pc`, **not** on `IDFILES`, so make never evaluates the
`pnp.ids:` rule. That matters, because `pnp.ids` depends on `pnp.ids.orig`,
which is not in the tarball, and whose rule downloads `pnp.ids.csv` from
uefi.org — which upstream's own Makefile admits is behind Cloudflare and cannot
be automated. The prebuilt `pnp.ids` (63,481 bytes) ships, and it is the file
both libdisplay-info and wlroots consume.

Secondary protection is thin: `pnp.ids` and `pnp.ids.patch` carry identical
mtimes, because GitHub archive tarballs stamp everything with the commit time,
and make rebuilds only on strictly *newer*. **Never run `make download` or
`make check`.**

**Two `$(shell)` calls print errors that are not errors.** `RELEASE=$(shell rpm
-q --specfile ...)` and an `ifeq` on `git rev-parse` both evaluate at parse time
on every make invocation. `rpm` is not in the sandbox and there is no `.git` in
the tree, so both write to stderr and yield empty. Make does not fail on a
failing `$(shell)`, and both variables feed only RPM tag names — but
`step_context` prints stderr, so this noise will appear in a log and cost
somebody time.

**The one thing that could have broken wlroots is already handled.** hwdata
installs its `.pc` to `$(datadir)/pkgconfig` — `/usr/share/pkgconfig`, not
`lib`. The pkgconf recipe pins
`--with-pkg-config-dir=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig`, so it
resolves. That was written as a hermeticity control and paid off somewhere else.

`VERSION` comes from a single `Version: 0.410` line via awk, so `hwdata.pc` gets
a clean version; wlroots imposes no constraint on it. `blacklist` defaults to
`true` and installs `dist-blacklist.conf` into `$(libdir)/modprobe.d` — there is
no kmod or modprobe here, so `--disable-blacklist`.

**For the ledger this is a genuine `OR`:** LICENSE states the data is available
under *either* GPL-2.0-or-later *or* XFree86-1.0, distributor's choice. It is
the case that exercises the AND-vs-OR distinction `license.py` reports on — and
what is licensed is data, not code.

---

## libdisplay-info 0.4.0

`43b180baa143e2035654759d84e2b2f5ee77d5fe817c423838c7fe59c0d68459` — matches
`sources/MIRRORS.tsv`.

MIT, C11, meson `>= 0.57`, no Rust, and the only Python script imports `sys` and
nothing else. After mesa's mako requirement that is worth stating.

**The build-order chain is `hwdata -> libdisplay-info -> wlroots`**, and
`pnp.ids` is consumed twice by different mechanisms: libdisplay-info compiles it
into a C search table via `gen-search-table.py`, and wlroots separately runs
`gen_pnpids.sh` over the same file.

**`required: false` hiding a hard requirement, again:**

```meson
dep_hwdata = dependency('hwdata', required: false, native: true)
if dep_hwdata.found()
  pnp_ids = files(hwdata_dir / 'pnp.ids')
else
  pnp_ids = files('/usr/share/hwdata/pnp.ids')
endif
```

The else branch is a hardcoded absolute path, so a missing hwdata produces a
file-not-found on a path that reads like it has nothing to do with a dependency
lookup. Both branches land on the same file here, because our hwdata recipe
installs the `.pc` *and* that exact path.

**`wrap_mode=nodownload` is set in `project()` default_options** — upstream
stating in the build configuration exactly the guarantee cairo leaves to
`bwrap`. It is not an exotic hardening; it is what a careful upstream already
does.

**There are no options at all** — no `meson.options`, and both
`subdir('di-edid-decode')` and `subdir('test')` are unconditional. Tests cannot
be disabled. They degrade cleanly: the `v4l-utils` subproject and the reference
`edid-decode` are both `required: false`, and `nodownload` stops the wrap. Three
in-tree shell scripts are `find_program`'d as *required*, so the executable bit
surviving extraction is load-bearing at configure time.
