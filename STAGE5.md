# Stage 5 — the package set

The target: a system that browses the web, on Wayland, that can rebuild itself
from source with no host.

**The estimate was 130–150 upstreams, with 200+ as the honest budget. The
measured set is 111.** That is smaller than planned for a reason worth keeping:
every optional feature this system declines removes a dependency tail, and the
declines are numerous — no X11, no Rust, no systemd, no Qt, no GTK, no pip, and
a codec set chosen for what a browser plays rather than for completeness.
Dropping `gst-plugins-ugly` alone removed `x264`, the one package in the set
with no release tarball at all.

| | count |
|---|---|
| pinned — digest, signature, licence, declared dependencies all read from the tarball | **111** |
| recipes written | **41** |
| built, installed and staged | **31** |
| artifacts with two or more verified fetch routes | **107** |

Counts below that are not in that table are still from reading dependency
graphs rather than building them. Treat those as planning numbers.

**And 111 is complete over a narrower thing than it sounds.** The table header
says it: *declared dependencies read from the tarball*. `probe.py` resolves a
dependency name to a package through the `.pc` files each tarball ships, so the
set is complete over names expressible in a machine-readable dependency syntax
and blind to three classes that are not:

- **config-tool discovery.** mesa finds LLVM with `dependency('llvm', method:
  'config-tool')`, and LLVM ships no `.pc` at all — so there was no name for
  the graph to match and nothing reported a gap. **`llvm` was the one package
  in the set with no pin anywhere**: absent from `sources/MIRRORS.tsv`, absent
  from every URL list, and fetched by `llvm-timing.yml` straight from upstream
  while merely *printing* the sha256.

  **Now closed, and on a better route than the one it was on.**
  `llvm-project-22.1.8.src.tar.xz` is pinned at `922f1817…5888`, with its
  detached GPG signature pinned beside it at `052eeebd…5910` — LLVM is one of
  the few packages in this set that publishes one at all.

  The route matters as much as the pin. `llvm-timing.yml` had been fetching
  the **split** component tarballs, where `llvm-<v>.src.tar.xz` does not build
  without `cmake-<v>.src.tar.xz` and the companion was fetched inside an
  `if curl … 2>/dev/null` that swallowed its own failure — a missing download
  that would have surfaced as an LLVM build error. The monorepo archive is
  what upstream's release page documents, is self-contained, and is what BLFS
  builds. Three other downloads on that same page are traps: the
  `LLVM-<v>-Linux-ARM64` tarball is **prebuilt binaries**, the
  `/archive/refs/tags/` URL is GitHub's auto-generated archive whose digest is
  not guaranteed stable, and `test-suite-<v>.src` is a different repository.

  `llvm-timing.yml` now verifies both digests instead of printing one, and the
  monorepo URL is in `remaining-urls.txt` so the mirror covers it.

  Two things remain: the digests are **reported by GitHub, not yet measured
  here** — which is why they are checked on every run rather than trusted —
  and BLFS carries a required upstream patch for 22.1.8 fixing *"a bug causing
  wrong code on some conditions"*. A miscompilation in the compiler that builds
  mesa belongs in the recipe as a declared patch.
- **interpreter modules.** mesa requires `mako`, `packaging` and `PyYAML` at
  configure time, checked with `run_command(python3, '-c', 'import mako')`.
  None are pinned. Nothing short of executing the build can find that
  statically, which is why the design in
  [`spikes/stage5/ROADMAP.md`](./spikes/stage5/ROADMAP.md) requires them to be
  *disclosed per recipe* rather than detected.
- **tools invoked rather than linked.** zstd's suite calls `file(1)`; hwdata's
  Makefile shells out to `rpm` and `git`.

The corroboration was already being downloaded and thrown away: `probe.py`
fetches Arch's PKGBUILD and Alpine's APKBUILD for every package and reads only
`pkgver`, source URLs and digests. Arch's mesa PKGBUILD lists `python-mako` in
`makedepends`.

---

## What exists now, and what each job answers

This file was written as a plan. Several of its open questions have since been
turned into measurements, and the jobs are the current source of truth where
they disagree with the estimates below.

| job | the question it answers |
|---|---|
| `sysroot-inventory` | where the 5.6 GB is, without re-running the ladder |
| `stage5-entry` | **the entry contract** — does the trimmed sysroot still compile C, C++ and `-flto`, and still boot? Cutting is easy; a 500 MB sysroot that cannot compile is worse than a 5.6 GB one that can |
| `stage5-probe` | what a package actually is — version, digest, signature, licence, declared dependencies — instead of guessing |
| `stage5-probe-remaining` | the same, for every package that does not yet have a recipe |
| `stage5-probe-required` | the packages the dependency scan says are required and absent, **and what those in turn require** |
| `stage5-order` | does the build order **close** across the whole set, with edges derived from the `.pc` names each tarball ships |
| `stage5-spike` | the recipes built on the proven entry contract, merged, imaged, booted |
| `stage5-closure` | the package set mapped **backwards**: name what the system must do, and let the closure say what it costs |
| `stage5-mirror-upload` | every artifact fetchable from more than one place, verified and committed |
| `stage5-license` | what licence each package actually carries, matched against the SPDX guidelines rather than guessed from a filename |
| `wpe-timing`, `llvm-timing` | how long the two expensive builds take — stopwatches, deliberately not hermetic |

Two of those change how this document should be read.

**`stage5-closure` supersedes the group list below.** The groups were written by
reading dependency graphs by hand. A forward list discovers what it is missing
when a build fails, one package at a time, at the bottom of a stack. Backwards
is cheaper, and it prices the *deliberate exclusions* too — which is the number
nobody had. Arch's and Alpine's dependencies follow their configure flags, and
Veron disables more, so the real closure should be smaller than the estimates
here. Every difference is a flag decision not yet made.

**`stage5-entry` is the precondition for all of it.** Of the six sysroot cuts,
exactly one was already proven — phase B runs with `/tools` off `PATH`, so
every green ladder run is that experiment. The other five were reasoned rather
than measured, and the job measures them with two tests that fail differently:
a bwrap smoke test that compiles inside the trimmed root, and a real qemu boot.

---

## The shape

```
tier 1   self-hosting CLI system          ~55 upstreams   the real milestone
tier 2   Wayland + graphics               ~30             a demo
tier 3   WPE WebKit + media               ~26             one hard package
```

**Tier 1 is the goal that matters.** A system that rebuilds itself, on itself,
from source, closes the loop this project is about. Tiers 2 and 3 are
demonstrations that the toolchain is real.

### Five packages are most of the work

`llvm`, `qtbase`, `mesa`, `icu`, `skia`. Each rivals gcc. The other ~140 are
mostly an afternoon each, and estimating by package count badly misleads.

**`llvm` arrives through mesa, not by choice** — llvmpipe for software
rendering. If a target has a driver that does not need it, or software
rendering is acceptable without llvmpipe, one of the five giants disappears.
Worth establishing early: it is the difference between the plan above and the
plan above minus a month.

---

## Dependency order

Each group depends only on groups above it.

### Already built by stage 4

```
binutils  gcc  glibc  musl  linux  busybox  make  gmp  mpfr  mpc
m4  bison  flex  perl  python  gawk  openssl  bc
```

### 1 — build substrate

```
pkgconf  autoconf  automake  libtool  gettext  texinfo
zlib  xz  bzip2  zstd  libffi  ncurses  readline  expat  pcre2  libxml2
ninja  meson  cmake  git
```

`cmake` is a large C++ build and needs bootstrapping; `meson` needs python.
Both are required before anything in tier 2.

### 2 — system

```
dinit  dosfstools  tzdata  tzcode  make-ca
libgpg-error  libgcrypt  libtasn1  nettle  gmp  gnutls  p11-kit
nspr  nss  brotli  libidn2  nghttp2  libpsl
```

**`dinit`, decided.** `s6` is three packages and a different model; both avoid
systemd, which would pull dbus, kmod and a large policy surface. dinit is one
package and the smaller commitment.

**`gmp` is here because of `nettle`.** nettle builds `hogweed` — its public-key
half — against gmp, and gnutls needs hogweed. No gmp, no TLS. That edge was
found by reading declared dependencies, not from any package list.

### 3 — networking

```
iproute2  dhcpcd  curl  wpa_supplicant
```

See the networking section below — this group is small and carries the
project's sharpest unresolved question.

### 4 — graphics substrate

```
libdrm  llvm  mesa
libinput  libevdev  mtdev  libxkbcommon  xkeyboard-config  seatd
hwdata  libdisplay-info
```

`seatd` is what makes logind — and therefore systemd — avoidable. `labwc`,
`cage` and `sway` all support it.

**`hwdata` and `libdisplay-info` were missing from this list and are required.**
wlroots' DRM backend needs both — `hwdata` is not even a library, it is a data
package whose `pnp.ids` gets compiled into a C table by libdisplay-info's
`gen-search-table.py` *and* separately fed to wlroots' own `gen_pnpids.sh`. The
build order is `hwdata → libdisplay-info → wlroots`.

Both were already pinned in `sources/MIRRORS.tsv` with two routes each, so
`stage5-probe-required` found them and this document never learned. **The plan
and the pinned data disagreed, and the pinned data was right.**

### 5 — text and rendering

```
freetype  fontconfig  harfbuzz  brotli  graphite2  fribidi
libpng  libjpeg-turbo  pixman  glib  cairo  pango
a font (dejavu or noto)
```

`glib` is a heavier dependency than its position suggests and arrives via
cairo/pango.

### 6 — Wayland

```
wayland  wayland-protocols  wlroots  labwc
foot  fcft  tllist
```

`foot` is the terminal even though Qt is present later: C, Wayland-native, no
toolkit, and one of the smallest serious terminals there is.

### 7 — session and desktop

```
dinit  labwc  foot  fcft  tllist  fuzzel  yambar  swaybg  nnn  dejavu-fonts
libsfdo  libutf8proc  lcms2  graphene  alsa-lib  libudev-zero
```

**Qt is gone, and so is SDDM.** This group was written as conditional on
Ladybird needing Qt; that condition resolved the other way. The login is
`getty --autologin` with `exec labwc` from the profile, `nnn` in `foot` as the
file manager. Much the smaller system, and it was the recommendation even then.

`foot` is the terminal: C, Wayland-native, no toolkit, one of the smallest
serious terminals there is.

**`libudev-zero` is the entry nobody planned.** libinput, mesa, wlroots and
yambar all link `libudev.so`, and busybox does not provide it — `mdev` creates
device nodes, which is the daemon half, not the library. No libudev means no
input, which means no compositor. It was found by reading declared dependencies
across the whole set, not by planning.

### 8 — the browser: WPE WebKit

```
bubblewrap  libhyphen  opus  libvpx  dav1d  ffmpeg  ogg  vorbis
gstreamer  gst-plugins-base  gst-plugins-good  gst-plugins-bad  gst-libav
wpewebkit
```

**Chosen over Ladybird, and the reason changed.** Both are C++ and both avoid
Rust, so both sit outside the mrustc bootstrap problem that rules out Firefox.
The decision turned on what Ladybird has become: it now requires **Rust 1.96+**,
Qt6, dbus and roughly 46 vcpkg dependencies. The thing that made it attractive
— an ordinary hard package rather than a second bootstrap problem — is no
longer true.

WPE renders the real web today, needs no Rust and no X11, and its cost is
measured rather than estimated: **136 minutes, `rc=0`, on a hosted runner with
107 GB free.** That number decided something larger than a package. Combined
with LLVM's 27 minutes it is 163 against a 360-minute cap, so **self-hosted
runners are not needed** — which had been the open question this whole
measurement existed to answer.

**`gst-plugins-ugly` is dropped.** Reading what it declares showed `dvdread`
and nothing on a browser's path: H.264 *decoding* comes from ffmpeg via
gst-libav, and x264 is an *encoder* wanted only for WebRTC, which is off. That
removed `x264` from the set — the one package with no release tarball at all,
only a git snapshot.

What WPE still owes: **it has never rendered a page.** 136 minutes and `rc=0`
is a compile, not a browser. And **the shell does not exist** — MiniBrowser is
a bare view with keyboard shortcuts and no URL bar, so the chrome is ours to
write.
the ladder and the budget claim does not apply to it. It is a stopwatch.

---

## Networking, and the firmware problem

### Ethernet

`iproute2` + `dhcpcd`. Most wired NICs need no firmware. This works and raises
nothing.

### WiFi — three parts, and the third is the problem

**1. The driver** is in the kernel already.

**2. The supplicant** is `wpa_supplicant`, and it is the right choice
specifically because it does **not** need dbus. Its control interface is a Unix
socket, and `wpa_cli` talks to it directly. `iwd` is more modern and wants dbus
for anything convenient; NetworkManager and connman want dbus and polkit. On a
system built to avoid dbus, `wpa_supplicant` is the only one that fits.

**3. The firmware is a binary blob, and it does not trace to the seed.**

Nearly every WiFi chipset requires a vendor firmware image loaded at runtime —
`linux-firmware`, redistributable but not source. It cannot be built, only
copied.

This is the sharpest conflict in the project between "works on a laptop" and
"every file traces to the seed". It should be handled the way the flavor fork
is handled: **declared, not hidden.**

```
veron why /lib/firmware/iwlwifi-so-a0-gf-a0-83.ucode

  NOT BUILDABLE -- vendor binary firmware
  source     linux-firmware, rev a3f91c…
  sha256     7d2e…
  license    redistributable, no source available
  traces to  nothing. This is a declared opaque input.
```

`veron status` should count it in its own category — neither "verified" nor
"via nix" but **"opaque"** — so the number is visible rather than absent. A
system with three firmware blobs and 4,182 verified files is an honest
description; one that quietly omits them is not.

Ethernet-only installs have zero opaque inputs, which is worth being able to
state.

### How a user actually connects

No GUI. `labwc` has no tray, and every graphical WiFi applet routes through
NetworkManager and therefore dbus.

```
wpa_passphrase MYSSID 'my password' >> /etc/wpa_supplicant/wpa_supplicant.conf
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
dhcpcd wlan0
```

Worth wrapping in one script — scan, prompt, append, restart — which is thirty
lines of shell and better than importing dbus for a text field. If a graphical
one is wanted later, that is the point at which taking dbus becomes a
deliberate decision rather than a transitive dependency.

---

## Decisions this set encodes

- **No systemd.** `dinit` or `s6`; `seatd` instead of logind.
- **No dbus, no polkit.** Costs automount and graphical network config. A file
  manager can browse without udisks2; mounting is manual, or dbus is taken
  deliberately later.
- **No X11 and no XWayland**, until something needs it.
- **No PAM**, if there is no display manager. If SDDM lands, PAM likely
  follows.
- **Two libcs on the system** if Nix is installed alongside — see
  `DERIVATIONS.md`. Nix packages use nixpkgs' own glibc; nothing links across.

## The order the rest is built in, and why

**B5 — graphics and Wayland (15).** Next, and not for size. It settles the two
things nothing else can: **whether mesa builds without Rust** — `rustc`,
`zerocopy` and `syn` are all in mesa 26's declarations, and configure returning
`rc=0` is not the same as compiling — and **whether meson-plus-cmake-4 is a
general problem**. glib needed a patch to stop its dependency lookup falling
through to meson's CMake backend; mesa, wlroots and libinput are all meson. If
two more need patches, that is a pattern wanting a systemic answer rather than
one patch per package. B5 is also the first time `fetch-git.sh` runs in anger,
for `libxkbcommon`.

**B5.5 — it boots to a login.** Not packages, and the biggest unknown in the
project: dinit service definitions, the `/etc` skeleton, getty autologin, the
kernel installed into the image, the EFI stub. Doing it here rather than after
the browser means a system that boots and logs in at **~57 packages instead of
~100**, with everything after it additive — and it turns the guest tests from a
harness into a real session.

**B6 — system, network, TLS (18).** After which `curl https://example.com` from
the booted image is a genuinely strong end-to-end signal: DNS, TCP, TLS and the
`make-ca` trust store in one command.

**B7 — desktop (16).** labwc, foot, fuzzel, yambar, and the libudev-zero
underneath them.

**B8 — the browser (14).** Last, and the longest: WPE alone is 136 minutes.
The **browser shell does not exist** and is ours to write — MiniBrowser has
keyboard shortcuts and no URL bar — which is worth starting during B7 rather
than discovering at B8.

**What changes when B5 lands:** LLVM is 27 minutes by itself, so a spike run
stops being something to do casually. That is a workflow decision, not a recipe
one, and it has not been made.

## Open questions

Four of the original five are answered, and the answers are recorded where they
were decided rather than only here. Question 5 is now answered too — by reading
mesa's tarball rather than by building it — but it is left below rather than
moved up, because what it uncovered replaced it with a harder problem in the
same package. Two new questions (6 and 7) came out of reading wlroots and cairo.

**Settled.**

0. **Ladybird or WPE?** WPE. Measured at 136 minutes, `rc=0`, on a hosted
   runner — which also settled the question behind it: with LLVM's 27 minutes
   that is 163 against a 360-minute cap, so **self-hosted runners are not
   needed**. Ladybird moved to requiring Rust 1.96+, Qt6 and dbus, which is
   the opposite of why it was attractive.
1. **Does Ladybird still require Qt6?** Moot — but yes, and that is why it was
   dropped. Group 7 collapsed to autologin + labwc, the smaller system this
   file already recommended.
2. **Can mesa be built without llvm?** No. LLVM is required for llvmpipe, which
   is required for WPE on any machine without a supported GPU. Scoped to core
   plus the AArch64 target: 27 minutes, 659 MB. `mesa` also needs `libelf`,
   which no book mentioned.

**Still open.**

3. **Does the musl flavor go to tier 2?** mesa and most desktop software assume
   glibc; Alpine carries real patch sets. If the musl branch is meant to reach
   a desktop, that patch burden is where it lives.
4. **Where do firmware blobs live in the ledger**, and does `veron status` grow
   an `opaque` category? `linux-firmware` is ~1 GB of binaries that provably
   cannot be built from source — the only such thing in the system. The
   decision is that it ships **optionally, pulled by the user**, so the audit
   claim stays intact; the mechanism is not built.
5. **Can mesa be built without Rust?** **Answered by reading mesa 26.1.6:
   yes on aarch64 — and only by an architecture accident.** The trigger is one
   line, `meson.build:835`:

   ```meson
   if with_gallium_rusticl or with_nouveau_vk or with_tools.contains('etnaviv') or with_virtgpu_kumquat
     add_languages('rust', required: true)
   ```

   `gallium-rusticl` and `virtgpu_kumquat` default false, `tools` to `[]`.
   `with_nouveau_vk` comes from `vulkan-drivers`, which defaults to `auto` and
   expands **per architecture**: x86 gets `nouveau` and therefore Rust,
   aarch64 does not. So `vulkan-drivers` must be **pinned explicitly** rather
   than inherited — upstream adding nouveau to the aarch64 list would switch
   the no-Rust policy off silently.

   The `*-rs.wrap` files that made `rustc`, `zerocopy` and `syn` appear in the
   declared set are subproject wraps: the union of every optional feature, not
   what our flags need.

   **What replaces this as mesa's hard problem is Python.** mesa requires
   `mako >= 0.8.0` (hard error), `packaging` (its `distutils` fallback was
   removed in Python 3.12 and stage 5 builds 3.14), and `PyYAML` — where a
   missing module surfaces as the misleading `Python <version> not found`.
   With MarkupSafe that is four packages, none pinned, and **no pip**. How a
   Python library gets installed at all is an open design question; the
   `meson` recipe's copy-into-site-packages is the only precedent in the tree.
6. **Does `auto` mean what the recipes assume?** No, and wlroots is the proof.
   `-Dbackends=auto` does **not** expand to the available backends unless
   `auto_features` is explicitly `enabled`; it stays literally `['auto']`, which
   makes `'drm' in backends` false, which makes `hwdata`, `libdisplay-info`,
   `libseat`, `libudev` and `libinput` all `required: false` — and then
   `subdir('drm')` is entered anyway and bails with `subdir_done()`. The result
   configures, compiles and installs green with **no DRM backend, no input and
   no session**, and says nothing. Pin `-Dbackends=drm,libinput
   -Dsession=enabled`. Full trace in
   [`spikes/stage5/PACKAGES.md`](./spikes/stage5/PACKAGES.md).

7. **Do the recipes' wrap fallbacks need closing?** cairo names subproject
   fallbacks for all seven of its dependencies, so a failed pkg-config lookup
   attempts a download rather than reporting not-found. Only
   `bwrap --unshare-all` stops that — but `guest/selfrebuild.sh` runs the same
   recipes inside the booted image, where a network may exist, and a vendored
   pixman would enter a system claiming every byte traces to a recorded source
   with no ledger record describing it. libdisplay-info sets
   `wrap_mode=nodownload` in its own `project()` defaults, so it is not an
   exotic hardening. Genuinely cross-cutting, therefore a policy decision.

8. **What makes it boot?** `dinit` is pinned. Service definitions, the `/etc`
   skeleton, getty autologin, kernel installation into the image and the EFI
   stub are not packages and do not exist anywhere. Every boot so far has been
   `qemu -kernel` running a harness that mounts, checks and exits.

## Two things this file predicted and the work has since changed

**The source mirror became load-bearing, not just an obligation.** It was
scoped as a stage 6 item — "reproducible from pinned sources" is false the day
an upstream tarball moves. It is now the reason a shipped Veron does **not**
need to carry every build-only package: a user with a network rebuilds any
package from its recipe, same pins, same commands, same hashes. See
[`sources/MIRROR.md`](./sources/MIRROR.md). **134 routes across 107 artifacts,
every one reachable from at least two places** — and it stopped being
theoretical the day three consecutive runs died on a single slow host.

**Licensing moved from a ledger field to its own detector.** `ledger/README.md`
asks for an SPDX id per source, and this file assumed that was a lookup. It is
not: composite documents match per-section, ids get deprecated, and `AND`
versus `OR` in a compound expression changes what a distributor must do.
`spikes/stage5/tools/license.py` detects against the SPDX guidelines and
reports **two confidence tiers** rather than one answer, which is the honest
shape for a field that will be wrong sometimes.
