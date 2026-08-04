# Stage 5 — the package set

The target: a system that browses the web, on Wayland, that can rebuild itself
from source with no host. Roughly **130–150 upstreams**, and 200+ is the honest
budget once dependency tails are resolved rather than estimated.

Counts below are from reading dependency graphs, not from building them. Treat
them as planning numbers.

---

## What exists now, and what each job answers

This file was written as a plan. Several of its open questions have since been
turned into measurements, and the jobs are the current source of truth where
they disagree with the estimates below.

| job | the question it answers |
|---|---|
| `sysroot-inventory` | where the 5.6 GB is, without re-running the ladder |
| `stage5-entry` | **the entry contract** — does the trimmed sysroot still compile C, C++ and `-flto`, and still boot? Cutting is easy; a 500 MB sysroot that cannot compile is worse than a 5.6 GB one that can |
| `stage5-probe` | what a package actually is — its real dependencies and flags — instead of guessing |
| `stage5-spike` | two packages (`pkgconf`, `hello`) built on the proven entry contract, merged, booted |
| `stage5-closure` | the package set mapped **backwards**: name what the system must do, and let the closure say what it costs |
| `wpe-timing` | how long WPE WebKit takes to compile — a stopwatch, deliberately not hermetic |
| `llvm-timing` | the same question for LLVM, which arrives through mesa whether or not anyone chose it |
| `stage5-license` | what licence each package actually carries, detected against the SPDX guidelines rather than guessed from a filename |
| `mirror-verify` | that every pinned tarball is still reachable from more than one place, and still hashes to its pin |

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
tier 1   self-hosting CLI system          ~60 upstreams   the real milestone
tier 2   Wayland + graphics               ~35             a demo
tier 3   Qt6, SDDM, Ladybird              ~35             a hard package
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
util-linux  e2fsprogs  dosfstools  shadow  tzdata  ca-certificates
init: dinit          (or s6 + skalibs + execline)
```

`dinit` is the smaller decision; `s6` is three packages and a different model.
Either avoids systemd, which would pull dbus, kmod, libcap and a large policy
surface.

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
```

`seatd` is what makes logind — and therefore systemd — avoidable. `labwc`,
`cage` and `sway` all support it.

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

### 7 — Qt and session

```
double-conversion  qtbase  qtdeclarative  qtsvg
sddm
lxqt-build-tools  libfm-qt  pcmanfm-qt
```

**Conditional on Ladybird needing Qt.** If Ladybird has moved to its own UI,
this group collapses: no SDDM, no pcmanfm-qt, and the login becomes `agetty
--autologin` with `exec labwc` from the profile, with `nnn` in `foot` as the
file manager. That is a much smaller system and the recommendation if Qt is not
otherwise required.

### 8 — Ladybird

```
icu  simdutf  woff2  libavif  sqlite  skia  ladybird
```

**Ladybird uses vcpkg**, which vendors its dependencies. A hermetic build means
unbundling that and supplying each one from the ledger. This is why the tier-3
estimate is the softest number in this document.

Chosen over Firefox for one reason: **it is C++, not Rust.** Firefox would put
the mrustc chain — rustc bootstrapped through a long series of its own
versions — on the critical path. Ladybird is an ordinary hard package instead
of a second bootstrap problem, and it shares this project's thesis: an
independent engine written from scratch because the incumbents are too large to
be understood.

### 8b — WPE WebKit, the other candidate

`wpe-timing` measures WPE WebKit rather than Ladybird, and the reason is worth
recording: **the browser decision rests on a number nobody has.** Estimates for
how long a modern engine takes to compile range from a few hours to a full day
on a Pi, and that gap decides something much larger than a package — whether
stage 5 needs **self-hosted runners**, which is a bigger commitment than any
recipe in this file.

WPE is also C++ and also avoids Rust, so it sits in the same bracket as
Ladybird on the bootstrap question. Where they differ:

- **WPE is production WebKit**, so it renders the real web today. Ladybird is
  an independent engine and does not yet.
- **WPE is larger and has a heavier dependency tail** — GStreamer, ICU, and a
  long list this file has not priced.
- **Ladybird is the better thesis fit**: from scratch, because the incumbents
  are too large to understand. That is this project's own argument one layer up.

Neither is chosen. The measurement comes first, which is why `wpe-timing` is
explicitly **not hermetic** — dependencies come from apt because the question is
how long the *engine* takes, not whether its dependency tree can be
bootstrapped. Mixing the two would measure neither. Nothing it produces enters
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

## Open questions to settle before building

0. **Ladybird or WPE?** Blocked on `wpe-timing`. The answer decides whether
   stage 5 needs self-hosted runners, which outranks every other question here.
1. **Does Ladybird still require Qt6?** Decides whether group 7 exists at all,
   and therefore whether the login is SDDM or autologin. Largest single fork in
   this plan.
2. **Can mesa be built without llvm** for the target hardware? One of the five
   giants.
3. **Does the musl flavor go to tier 2?** mesa and most desktop software assume
   glibc; Alpine carries real patch sets to make them work on musl. If the musl
   branch is meant to reach a desktop, that patch burden is where it lives.
4. **Where do firmware blobs live in the ledger**, and does `veron status`
   grow an `opaque` category? Recommended above; not yet decided.

## Two things this file predicted and the work has since changed

**The source mirror became load-bearing, not just an obligation.** It was
scoped as a stage 6 item — "reproducible from pinned sources" is false the day
an upstream tarball moves. It is now the reason a shipped Veron does **not**
need to carry every build-only package: a user with a network rebuilds any
package from its recipe, same pins, same commands, same hashes. See
[`sources/MIRROR.md`](./sources/MIRROR.md). 105 routes, every artifact reachable
from at least two.

**Licensing moved from a ledger field to its own detector.** `ledger/README.md`
asks for an SPDX id per source, and this file assumed that was a lookup. It is
not: composite documents match per-section, ids get deprecated, and `AND`
versus `OR` in a compound expression changes what a distributor must do.
`spikes/stage5/tools/license.py` detects against the SPDX guidelines and
reports **two confidence tiers** rather than one answer, which is the honest
shape for a field that will be wrong sometimes.
