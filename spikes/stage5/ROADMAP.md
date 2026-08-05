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

- Parse `depends=` / `makedepends=` from the PKGBUILD and APKBUILD already
  being downloaded
- Emit unresolvable names — `run_command`, `find_program`,
  `method:'config-tool'`, interpreter `import` — as a first-class output rather
  than silence
- Reconcile all three detectors; unaccounted name is a failure
- Re-probe all 111 with the new fields. Expect llvm, mako, MarkupSafe,
  packaging and PyYAML to surface

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
