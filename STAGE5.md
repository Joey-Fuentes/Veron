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
| pinned — digest, signature, licence, declared dependencies all read from the tarball | **121** |
| recipes written | **121** |
| built, installed, staged and booted | **121** |
| install sets pinned by digest | **121** |
| artifacts mirrored | **276 routes** |
| artifacts with fewer than two fetch routes | **0** |

**All 121 build, the image reproduces byte-for-byte, it boots, and the browser
renders a page:**

```
VERON-BUILD-OK        every package built
VERON-MANIFEST-OK     21912 paths, 3958.4 MiB
VERON-LEDGER-OK       121 record(s)         VERON-STATUS-OK  unknown = 0
VERON-INSTALLS-OK     0 stray prefixes, 0 changed install sets, 0 unchecked
VERON-IMAGE-REPRO-OK  two builds, identical bytes
VERON-STAGE5-BOOT-OK  the packages ran under the kernel
VERON-STAGE5-LOGIN-OK dinit brought up every service
VERON-STAGE5-TESTS    pass=154 fail=0 none=2
VERON-DHCP-OK         the client leased an address from the server VM
VERON-NET-PING-OK     and the two machines exchanged packets
VERON-SHOT-OK         1280x800, 1255 distinct colours
VERON-SELFREBUILD-OK  VERON-SELFHOST-OK
```

**The browser renders.** The screenshot job boots the image, starts labwc, and
points MiniBrowser at a local page; the captured framebuffer is **71.7%
`#1e6f50`** — the page's background colour, which appears nowhere else in the
desktop — in a 1024x746 window, with the CSS gradient bar and 5,661 pixels of
large white text. That is wpewebkit 2.52.5 on a system built from source,
painting through `wl_shm` with no GPU.

**And it browses the real web.** Booted by hand under qemu on a laptop, the
image reaches `example.com` over HTTPS, follows links with the mouse, and
**renders YouTube's player** — thumbnail, title, controls and scrubber. What
does not work is output rather than the browser: there is no GStreamer video
sink and no audio device (see
[`ROADMAP-STAGE5.md`](./ROADMAP-STAGE5.md)), and TCG emulation of a cortex-a57
makes it slow enough that only the shape of the thing is worth judging.

**31 of 48 built from their declared dependencies alone** when
`stage5-isolate` was last run — it composes each package's root from the
stage-4 sysroot plus only what its recipe declares, so an undeclared
dependency becomes a build failure that names itself. The first sweep's
failures were a fault in the composition rule rather than in the recipes,
described in `spikes/stage5/ROADMAP.md`.

**That measurement is stale: it predates 74 of the packages now in the set.**
It is quoted as the last number actually taken rather than updated by
guesswork, and re-running the job is the only way to replace it.

Counts below that are not in that table are still from reading dependency
graphs rather than building them. Treat those as planning numbers.

**111 was also wrong in a direction worth recording.** Seven packages have
been added to the set since it was measured, and none was found by any tool:

| added | how it was missed |
|---|---|
| `llvm` | mesa finds it with `method: 'config-tool'` — LLVM ships no `.pc` file |
| `mako`, `markupsafe`, `packaging`, `pyyaml` | mesa asks with `run_command(python3, '-c', 'import mako')` |
| `hwdata`, `libdisplay-info` | pinned and mirrored, absent from every group list below |

All seven were found by reading tarballs. That is the concrete form of the
blindness the next paragraphs describe, and the reason `probe.py reconcile`
now exists as a **gate** rather than a report.

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

**What is left is written down.** Everything named as missing along the way —
persistence, login, updates, i18n, containers, the language toolchains, the
desktop applications that do not exist yet — is in
[`ROADMAP-STAGE5.md`](./ROADMAP-STAGE5.md), with the cost and the blocker for
each.

---

## Running it on your own machine

The spike publishes a GitHub release with everything needed to boot the system
under qemu: `rootfs.img.tar.zst`, the kernel `Image`, `initramfs.cpio.gz`, and
`IMAGE-SHA256`.

**Two releases, one per architecture.** `stage5/latest` is aarch64;
`stage5/latest-amd64` is x86_64, published by `stage5-spike-amd64`. The asset
names are identical in both, which is why they are separate tags rather than
suffixed filenames on a shared one — see `spikes/stage5/AMD64.md`. Everything
below is the aarch64 arm; the x86_64 commands are in *Running the x86_64 image*
after it.

```sh
gh release download stage5/latest \
  --pattern 'rootfs.img.tar.zst' --pattern 'IMAGE-SHA256' \
  --pattern 'Image' --pattern 'initramfs.cpio.gz'
tar --zstd -xf rootfs.img.tar.zst
sha256sum -c IMAGE-SHA256
```

**Extract before verifying: `IMAGE-SHA256` digests the uncompressed
`rootfs.img`**, not the tarball — the publish step runs
`sha256sum rootfs.img | tee IMAGE-SHA256` before compressing. Checking it
against `rootfs.img.tar.zst` would fail, and the failure would look like a
corrupt download rather than a checked file being absent.

You need `qemu-system-aarch64`. On an x86_64 host that is **full emulation**
under TCG, not virtualisation, so everything below is slow — this proves the
system works, it is not a pleasant desktop.

```sh
qemu-system-aarch64 \
  -M virt -cpu cortex-a57 -smp 4 -m 4096 \
  -display gtk -serial mon:stdio \
  -drive file=rootfs.img,format=raw,if=virtio \
  -device virtio-gpu-pci -device virtio-keyboard-pci -device virtio-mouse-pci \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -kernel Image -initrd initramfs.cpio.gz \
  -append "console=ttyAMA0 rdinit=/init panic=1 loglevel=4 veron.boot=system"
```

`-display gtk` gives a window where CI uses `-nographic`, and **`-serial
mon:stdio` puts the guest console in the terminal you launched from** rather
than inside the QEMU window. That matters more than it sounds: without it the
console and the desktop share one window and you have to flip between them
through the `View` menu, which makes reading a log while watching the screen
almost impossible. With it, `Ctrl-A` then `C` switches to the QEMU monitor
(`info mice` and friends) and `Ctrl-A` then `X` quits.

**Use `virtio-mouse-pci`, not `virtio-tablet-pci`** — which is the opposite of
the usual advice for QEMU guests, for a reason specific to this system.

A tablet is an *absolute* device: it reports coordinates, needs no pointer
grab, and the guest cursor tracks the host cursor exactly. That is what you
want, and QEMU offers it correctly — `info mice` reports
`* Mouse #2: QEMU Virtio Tablet (absolute)`.

**But libinput will not use it here.** The tablet advertises `EV_REL` for its
scroll wheel *and* `EV_ABS` for its axes, and libudev-zero's classifier treated
those as mutually exclusive — see `packages/libudev-zero/patches/0001`, which
fixes the enumeration. With that patch libinput now *sees* the tablet and then
rejects its events:

```
[ERROR] [libinput] libinput bug: Event for missing capability CAP_POINTER
                    on device "QEMU Virtio Tablet"
```

because the classifier tags it `ID_INPUT_MOUSE` — a *relative* pointer — while
the device sends absolute coordinates. Fixing that second half is outstanding.

A plain `virtio-mouse-pci` has `REL_X`, `REL_Y` and `BTN_LEFT`, takes the
relative branch cleanly, and works. The cost is that QEMU must **grab** the
host cursor to synthesise deltas; `Ctrl-Alt-G` releases the grab if it gets in
the way.

**The cursor is drawn in software, and that is a deliberate setting.**
`labwc-session` exports `WLR_NO_HARDWARE_CURSORS=1`. wlroots otherwise puts the
cursor on a KMS hardware plane, which on virtualised DRM needs a hotspot the
older ioctls do not carry — so the compositor tracks the pointer perfectly and
draws nothing. This is *not* implied by `WLR_RENDERER=pixman`: the renderer
decides how the scene is composited, the cursor plane is a separate decision,
and both have to be made. Measured here: the theme loaded, the pointer moved,
and the screen stayed bare until this was set.

**Then, at the console, three things are started by hand.** None of them is an
oversight; each is a decision recorded elsewhere in this file.

```sh
dhcpcd eth0                                   # see below
dinitctl start labwc                          # not in boot.d, deliberately
/usr/bin/foot &                               # a terminal inside the session
/usr/libexec/wpe-webkit-2.0/MiniBrowser https://example.com
```

**`dinitctl`, not `dinit`.** Typing the daemon instead of the control client
gets you a second dinit that fails on the socket PID 1 already holds:

```
Could not determine cgroup root path
Control socket is already active (another instance already running?)
```

The first line is benign on its own — dinit looks for a cgroup2 hierarchy and
this system mounts none. To confirm a healthy boot: `cat /proc/1/comm` prints
`dinit`, and `dinitctl list` shows `boot`, `console`, `early-filesystems`,
`seatd` and `xdg-runtime`. `labwc` is absent from that list until started,
which is the intent.

**Give labwc 30–90 seconds.** CI allows a 45-second settle on native aarch64;
under TCG emulation on an x86_64 host it is slower still, and `ninja`-style
progress output does not exist — the window simply stays as the kernel
framebuffer console (a blinking underscore) until the first frame paints. That
blank screen is not a failure.

If labwc exits instead, `dinitctl status labwc` gives the reason — but note
that **dinit swallows service stderr**, so the way to see an actual error is to
run the wrapper directly:

```sh
sh /etc/dinit.d/scripts/labwc-session
```

**Networking works and is not automatic.** `-netdev user` is SLIRP: NAT through
the host, no bridge, no root, no `/dev/net/tun`. Its built-in DHCP server will
answer `dhcpcd`, and DNS is at `10.0.2.3`. But **`boot.d` contains only
`console`, `early-filesystems`, `seatd` and `xdg-runtime` — there is no dhcpcd
service.** DHCP has only ever been exercised by the two-VM test, which drives
it by hand. A system that brings its own interface up at boot is work not yet
done, not a thing that broke.

**labwc is started by hand for the reason given under "the session".** A
compositor that fails during a package test would look like a broken system
rather than a broken compositor, so it is kept out of `boot.d` and started
explicitly.

**There is no login.** The console service runs `getty -n`, which means no
prompt, and `/etc/passwd` names an `/etc/shadow` that does not exist. That is
defensible only because there is nothing listening on the network; see
`AUTHENTICATION.md`, which records this as a condition rather than a state, and
names the trigger — the day networking lands — that has now fired.

### Running the x86_64 image

Same release layout, different tag, and on an amd64 laptop this is **native**
rather than the full emulation the aarch64 image needs — so it is quick enough
to actually use.

```sh
mkdir -p ~/veron-amd64 && cd ~/veron-amd64
gh release download stage5/latest-amd64 -R Joey-Fuentes/Veron \
  --pattern 'rootfs.img.tar.zst' --pattern 'IMAGE-SHA256' \
  --pattern 'Image' --pattern 'initramfs.cpio.gz'
tar --zstd -xf rootfs.img.tar.zst
sha256sum -c IMAGE-SHA256
```

`Image` is a **bzImage** and is called `Image` anyway: the stage-4 amd64 spike
copies `arch/x86/boot/bzImage` to that name so a consumer's download path has
the same shape on every architecture. Extract before verifying, for the reason
above — `IMAGE-SHA256` digests the uncompressed `rootfs.img`.

The exact invocation CI uses, which runs the guest test suite and exits:

```sh
qemu-system-x86_64 \
  -cpu qemu64 -smp 4 -m 4096 \
  -nographic -no-reboot -nic none \
  -drive file=rootfs.img,format=raw,if=virtio \
  -device virtio-gpu-pci -device virtio-keyboard-pci \
  -kernel Image -initrd initramfs.cpio.gz \
  -append "console=ttyS0 earlycon rdinit=/init panic=1 loglevel=7 veron.boot=system"
```

`-nographic` puts the console in the terminal you launched from. **`Ctrl-A`
then `X` quits** — `Ctrl-C` goes to the guest. `-no-reboot` makes it halt
rather than loop.

**Drop `veron.boot=system` to get a system to poke at** instead of a test run;
that flag is what tells init to run the package tests and exit. For the desktop
rather than the console, swap `-nographic` for `-display gtk -serial mon:stdio`
and add `-device virtio-mouse-pci` — the mouse advice under the aarch64 section
applies unchanged, and so does starting labwc by hand.

**Faster, with KVM**, since the guest is the same architecture as the host:

```sh
  -enable-kvm -cpu host      # in place of -cpu qemu64
```

That needs `/dev/kvm` readable — usually membership of the `kvm` group.

#### The two `-cpu` values disagree, and that is a finding rather than a nuisance

At the time of writing the published x86_64 image still contains a `libffi`
built with `--with-gcc-arch=native`, meaning **it was compiled for the CPU of
the machine that built it** — a recent Xeon runner. So:

| | |
|---|---|
| `-cpu qemu64` | `traps: python3 trap invalid opcode ... in libffi.so.8.2.0` |
| `-cpu host` | likely passes, if your laptop is new enough |

Two minutes of local reproduction for a defect that took a full CI run to find,
and a demonstration of why the fix was to pin libffi to the baseline rather
than to raise the emulated CPU until the image ran. Raising it would have made
the test green and left an image that only boots on hardware as new as whatever
built it. `spikes/stage5/AMD64.md` records the whole thing; once a run lands
with the pinned `libffi`, both `-cpu` values should pass and this table becomes
history.

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
- **Passwordless from the start, and no default password ever.** A published
  default credential is worse than none — it is remotely guessable and scanned
  for. Autologin root on the console is what ships, and it is defensible only
  because there is no network; that is a trigger, not a state. Anything
  non-deterministic — machine id, credential registrations, any hash — is
  generated at first boot into a writable layer, never baked into the image,
  which is how the byte-identical guarantee survives contact with per-instance
  state.
- **No PAM** — decided, not assumed. This used to read *"if there is no display
  manager; if SDDM lands, PAM likely follows"*, which was a guess. It is now a
  decision with a reason: linux-pam's own tail is modest, but **busybox's
  `login` and `su` bypass PAM entirely**, so adopting it also means adopting
  shadow or util-linux for a PAM-aware login. PAM-free costs roughly half the
  packages and none of the large ones. See `AUTHENTICATION.md`.
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

**The system does not know its own name, and the toolchain wears it instead.**
`gcc -dumpmachine` reports `aarch64-unknown-linux-gnu` — measured, 678
occurrences in a stage-5 diagnostic bundle and no other triplet — while the
cross toolchain that built it is `aarch64-veron-linux-gnu`. The scaffolding is
named for the project and the project is named `unknown`.

The decided end state is `aarch64-toolchain-linux-{gnu,musl}` for the
scaffolding and **`aarch64-veron-linux-gnu` for the system**, recorded in
`spikes/stage4/README.md`. It moves every triplet-bearing path in
`manifest.tsv` and `files.tsv`, so it breaks the run-to-run comparison once,
deliberately — which is a reason to do it **before** stage 5's install digests
are pinned harder, and in the same chain rerun as the kernel change.

**The kernel had no DRM, and a probe found it before six recipes were written
against it.** stage5-spike boots QEMU with `-device virtio-gpu-pci` and the
guest reports what it can see:

```
VERON-DRM-ABSENT    no /dev/dri/card0
drm modules:        (empty)
VERON-EVDEV-OK      1 event node(s)
```

arm64 defconfig leaves DRM out of a build that ships only
`arch/arm64/boot/Image` — no `modules_install`, no `/lib/modules`, no kmod, so
**a symbol at `=m` is indistinguishable from `=n` here**. wlroots with
`-Dbackends=drm` would have built green and found no device to open: the same
shape as `-Dbackends=auto`, one layer down and arriving from the kernel rather
than the recipe.

`DRM`, `DRM_VIRTIO_GPU`, `INPUT_EVDEV` and `VIRTIO_INPUT` are now set in
stage4-complete and **verified as `=y`, hard** — `olddefconfig` can silently
demote a symbol to `=m`, and only a `grep "=y"` tells that from success.
**This requires a stage 0–4 rerun before wlroots is worth writing.**

### The boot artefact: an ESP tree, and wrappers around it

**The base is a directory, not an image.** Everything a user might want is a
different way of wrapping the same files:

```
EFI/BOOT/BOOTAA64.EFI       <- Image, renamed. The kernel's EFI stub IS the
                               bootloader, so there is no GRUB to configure.
EFI/BOOT/initramfs.cpio.gz  <- only if the overlay design keeps one
```

| output | how it is made | for |
|---|---|---|
| `.img` | GPT + FAT partition holding the tree, plus an ext4 root | `dd` to USB, any UEFI aarch64 machine, qemu, UTM |
| hybrid ISO | `xorriso -e` with the tree as the El Torito EFI image, squashfs root | Ventoy, and a live-try image — the same work |
| dual boot | copy the tree into an existing ESP under `EFI/veron/`, then `efibootmgr` | a machine that already has an OS |
| AVF / crosvm / `-kernel` | the two files used directly, no wrapper | Android's Virtualization Framework, CI |

**Why the tree and not the image.** An ISO cannot be derived from a GPT image
without unpacking it, and the dual-boot case wants the files rather than a
disk. With the tree as the artefact every wrapper is additive and none depends
on another; with the image as the artefact the ISO becomes an unpack-and-repack,
which is the shape that goes stale.

**The root filesystem is the split that cannot be avoided:** `.img` wants
ext4-in-a-partition, ISO wants squashfs-in-a-file. Same content, different
container — and `veron rootfs` already produces the canonical tar, so both are
packagings of *that*. So the base is two artefacts, the **ESP tree** and
**`rootfs.tar`**, and each output is a recipe for combining them.

**Determinism lives in the wrappers, and that is the argument for the split.**
A directory of files is trivially reproducible. GPT disk and partition GUIDs,
FAT volume IDs and per-file timestamps, ISO creation dates — every one is a
place a random value appears and breaks `VERON-IMAGE-REPRO-OK` in a way that
looks like a real regression. All are settable (`mkfs.vfat -i`, `sgdisk -U`,
`SOURCE_DATE_EPOCH`), and keeping the tree as the base makes each wrapper's
determinism a separate small problem instead of one large one.

**Build order:** the tree first, booted with `-bios edk2-aarch64-code.fd` and
`-drive file=fat:rw:esp/` — no partition table, no filesystem image, which
tests the EFI stub and the kernel command line in isolation. Then `.img`, which
is the only wrapper B5.5 needs. The ISO is worth doing when there is a desktop
to try rather than a console.

**Two things this leaves open**, both decided by the storage model rather than
by the packaging:

- **Whether an initramfs survives at all.** With `EXT4_FS=y` and virtio-blk the
  kernel can mount root directly. But assembling a read-only base plus a
  writable overlay needs something to run before `/` is final, and an initramfs
  is where that normally lives. Overlay ⇒ keep one; read-write root ⇒ drop it.
- **Where the kernel command line comes from.** No bootloader means no
  `cmdline` file. Either `CONFIG_CMDLINE` is baked in — which fixes
  `root=PARTUUID=…` as a constant, and *helps* reproducibility — or the ESP
  carries a UEFI shell script.

### The EFI stub boots, and it arrives with no command line

Measured locally, with the toolbox emulator and the firmware it packs: an ESP
holding the kernel as `\EFI\BOOT\BOOTAA64.EFI`, booted with
`-bios edk2-aarch64-code.fd` and **no `-kernel`**:

```
BdsDxe: starting Boot0001
Booting Linux
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

**The stub works.** UEFI found the fallback path, loaded the kernel as an EFI
application and started Linux with no bootloader anywhere. That is the design
working.

**What it has no way to get is arguments.** The firmware starts the fallback
path with empty `LoadOptions`; a freshly written disk has no NVRAM boot entry
to carry any; and a `cmdline` file beside the kernel does nothing, because
that is a systemd-boot convention rather than something the stub reads. So the
only sources are a boot entry created by `efibootmgr` on an already-running
system, or something in the ESP that sets `LoadOptions` before starting the
kernel.

**`CONFIG_CMDLINE` was added here and then removed, because the test that
settled it also showed it was the wrong fix.** Booting this kernel from a
UEFI Shell with arguments on the line:

```
Kernel command line: linux console=ttyAMA0 root=/dev/vdb rw init=/sbin/dinit
mounted filesystem
VERON-PID1-OK
```

That is a full boot to userland through firmware, with no `-kernel`, no
initramfs and no bootloader -- so **`LoadOptions` reaches the stub correctly
and the kernel needs no help.** What was missing is something to set it.

And baking `root=` into the kernel would be actively wrong: it names one
partition, while the same kernel has to serve the `.img`, an ISO whose root is
a squashfs, and Android's AVF which passes its own line. One kernel, three
roots -- the variable part belongs to the wrapper.

`spikes/stage5/boot/` is that piece. It compiles cleanly with the chain's own
gcc and converts to PE with its own binutils; the firmware does not yet accept
the image, and `spikes/stage5/boot/README.md` says exactly where that stands.

### The disk image builds, boots itself, and reproduces

`spikes/stage5/tools/veron-image` writes the GPT and the FAT32 ESP directly
rather than calling `sgdisk`, `mkfs.vfat` and `mcopy`. Tested end to end:
real edk2 firmware read the partition table, mounted the filesystem, found
`\EFI\BOOT\BOOTAA64.EFI` at the fallback path and the stub booted Linux --
with no `-kernel`, no bootloader and nothing on the QEMU line but the disk.

**Written rather than delegated, because every one of those tools puts
something random or time-dependent in the image**: `sgdisk` draws GUIDs from
`/dev/urandom`, `mkfs.vfat` takes the volume id from the clock, and `mcopy`
stamps each directory entry with the wall time. Each has an override, and
mkosi's own experience report is that after pinning the obvious ones,
directory mtimes still leaked through `mcopy` and had to be chased
separately. Writing the bytes means there is no field this tool does not
choose -- and `veron rootfs` already writes its tar this way rather than
trusting a host tar.

It also removes three build dependencies. A from-source distribution that
cannot produce its own disk image without three packages from someone else's
archive has missed its own point.

Two builds, two seconds apart, are the same bytes. The `PARTUUID` is a
constant of the tool, so `root=PARTUUID=56455230-4e00-4000-8000-000000000002`
can go into `CONFIG_CMDLINE` before the partition exists -- which is what the
EFI-stub boot needs, since it has no other way to receive one.

### What does not work, so nobody promises it

**Apple Silicon on bare metal: no.** Macs expose no UEFI; they boot through
iBoot, so Linux there means the Asahi chain (`m1n1` → U-Boot → EFI) and our
image would be booting someone else's bootloader stack. **As a VM it is one of
the better places to run Veron** — UTM or qemu with Hypervisor.framework gives
near-native aarch64. Intel Macs are x86-64 and out of scope entirely.

**Ventoy wants an ISO.** It chainloads an ISO's own EFI bootloader out of an
El Torito structure; raw `.img` support exists and is the weaker path. That is
the reason the ISO is a real second output rather than a rename.

**Two toolbox compromises come due here.** qemu is linked dynamically because
Ubuntu no longer ships `libmount.a` and glib's static chain cannot be completed
from apt; and the UEFI firmware is the prebuilt blob qemu vendors, covered by
the qemu pin but built by nobody here. Both are fixed by the same move: qemu as
a stage-5 package — its six build dependencies, glib, pixman, zlib, meson,
ninja and python, are **already recipes** — plus EDK2 from source so `-bios`
loads something this project compiled. See `spikes/toolbox/README.md`.

**B5.5 — it boots to a login.** Not packages, and the biggest unknown in the
project: dinit service definitions, the `/etc` skeleton, getty autologin, the
kernel installed into the image, the EFI stub. The first three now exist as a
package — `veron-system`, the first recipe whose upstream is this repository —
so `/etc` goes through a DESTDIR, the manifest and the ledger like everything
else, and `veron why /etc/fstab` answers. What is still missing is the handoff:
`guest/init` mounts read-only, runs the tests and powers off, so dinit is never
PID 1 and the console service never starts. Doing it here rather than after
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

**And passkeys are part of B8, not an addition to it.** WebKitGTK and WPE
implement **no WebAuthn on Linux at all** — `ENABLE_WEB_AUTHN` is `PRIVATE OFF`
and the only transport backend in the tree is macOS/IOKit; the bug has been
open since 2019. But WebKit's CTAP1/CTAP2, CBOR and HID framing are already
platform-independent C++, so a Linux backend supplies **device I/O only**:
enumerate `/dev/hidraw*`, filter on FIDO usage page `0xF1D0`, read and write
reports. Roughly 1,000–2,000 lines, **no new dependencies**, and it is more of
the browser code this section already commits to writing. The one difference
worth naming: it is a patch against WebKit's tree and rebases every release,
where the shell is ours and does not. See `AUTHENTICATION.md`.

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
[`sources/MIRROR.md`](./sources/MIRROR.md). **255 routes across 115 artifacts,
every one reachable from at least two places** — and it stopped being
theoretical the day three consecutive runs died on a single slow host.

**Licensing moved from a ledger field to its own detector.** `ledger/README.md`
asks for an SPDX id per source, and this file assumed that was a lookup. It is
not: composite documents match per-section, ids get deprecated, and `AND`
versus `OR` in a compound expression changes what a distributor must do.
`spikes/stage5/tools/license.py` detects against the SPDX guidelines and
reports **two confidence tiers** rather than one answer, which is the honest
shape for a field that will be wrong sometimes.
