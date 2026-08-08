# What is left, and what each thing costs

Stage 5 builds 121 packages, boots, and renders a web page. This file is the
other half: everything named as missing along the way, with the cost and the
blocker for each.

**It exists because the alternative is rediscovery.** Most entries below were
found by a build failing, and the failure named the gap far more precisely than
planning would have. Where that is true, the failure is quoted.

---

## The decision that shapes the rest

**Veron is a distribution, not an appliance.** Users may take prebuilt binaries
or compile the identical recipe themselves.

That is not a preference; it decides whether half of this file is in scope. An
appliance can ship English-only with no installer, no accounts and no updates.
A distribution cannot.

**The package format mostly exists already** — it is simply not in a container.
A format needs a payload, a manifest, a dependency list and provenance:

| | where it already lives |
|---|---|
| payload | `dest/<pkg>`; the checkpoint tarball is a package cache in all but name |
| manifest | `[installs]` — prefixes, file count, and **a digest over the sorted listing** |
| dependencies | `[deps]` by kind, and *complete* rather than derived from ELF scanning after the fact |
| provenance | the recipe: URL, sha256, signature, every configure flag, and prose saying why |

No other distribution's format asserts the manifest digest. That is what makes
"compile it yourself and check you get the same bytes" a property of the format
rather than a separate project. `VERON-IMAGE-REPRO-OK` already proves the image
side of it.

**The mirror is the repo mechanism, working today:** GitHub releases as
storage, `MIRRORS.tsv` as the routing table, sha256 verified on fetch,
github-before-upstream ordering.

**And it means the recipe is the product**, not an implementation detail — the
same conclusion the documentation section below reaches from the other end.

---

## Blocked on nothing but work

### Persistence — and everything downstream waits on it

`guest/init` mounts `lowerdir=disk(ro)` over `upperdir=tmpfs`. Every write —
`/etc`, `/home`, the browser's cache, an installed package — lives in RAM and
is gone at poweroff. That is exactly why `VERON-IMAGE-REPRO-OK` can assert the
image is byte-identical run to run, and it is the right default for CI.

It is also a live USB, not a system anyone owns.

Moving `upperdir` to a partition is one line and a pile of decisions:

- **Finding it.** busybox `mount` in this build has no `LABEL=` support —
  `early-filesystems` already carries a workaround. And what happens when the
  partition is absent: boot ephemeral, or refuse?
- **Creating it.** Nothing partitions or formats anything today. See
  `e2fsprogs` below.
- **What persists.** Whole overlay upper means an installed package survives —
  and so does a broken `/etc`, with no way back. Splitting `/home` and `/etc`
  keeps the base pristine and makes "reset" mean something.
- **Encryption.** A user password that unlocks nothing is theatre. LUKS means
  `cryptsetup`, unpinned, plus device-mapper kernel config.

**The ephemeral path must survive all of it.** The guest tests boot and run
with nobody typing anything.

### Login — meaningless before persistence

The console service runs `getty -n` — `-n` means **no prompt** — and
`/etc/passwd` says `root:x:` pointing at an `/etc/shadow` **that does not
exist**. There is no authentication of any kind.

**No package is needed for the basic form:** busybox already has `login`,
`passwd`, `su`, `adduser`, `addgroup`, `chpasswd`, `cryptpw` and `mkpasswd`.
What is needed is `/etc/shadow` with a real hash, dropping `-n`, a non-root
user in the `video`/`tty`/`input` groups — which would finally exercise the
`video` group `seatd` asks for — and a decision on root (locked `!` plus a
normal user is the sane default).

**But `libxcrypt` is not pinned**, and `AUTHENTICATION.md` is blunt about what
that means: *"'No password' is not a temporary state being deferred — it is the
state until that package exists."*

And if `/etc/shadow` resets every boot, the password is decoration. **Order:
persistence, then accounts, then login.**

### Things already built that quietly depend on missing pieces

| gap | what it breaks |
|---|---|
| **no clock** | `tzdb` is installed and *nothing sets the time* — no ntp, no chrony, no hwclock service. **A wrong clock fails TLS certificate validation**, so the browser's HTTPS story has an unmet dependency. On a VM the guest inherits the host clock and this hides; on real hardware with a dead RTC it does not. |
| **no entropy config** | the kernel sets no `VIRTIO_RNG` and no `RANDOM_TRUST_CPU`. Early-boot crypto can block or be weak — TLS again, and anything generating keys. |
| **no e2fsprogs** | the rootfs is ext4 and there is **no `mke2fs` and no `e2fsck`** — only `fsck.fat`, from dosfstools. The system cannot check or repair its own filesystem, and cannot create the persistence partition above. |
| **no logs** | dinit swallows service stderr and no service sets `logfile=`. **This already cost three runs**: seatd exited 1 saying nothing, then labwc segfaulted saying nothing, and both were diagnosed only by running them by hand on the console. |
| **no swap** | the browser is the largest memory consumer here and there is no swap story. |

### Upgrade semantics — the hardest part, and nonexistent

What happens when a user has edited `/etc/xdg/labwc/rc.xml` and a new
`veron-system` ships a different one? Every distribution carries scars from
this — `.rpmnew`, dpkg's conffile prompt, Arch's `.pacnew`, all heuristics.

**Veron has an advantage worth using:** `[installs]` records the digest of
every file *as shipped*, so "has the user modified this?" is answerable exactly
rather than guessed. Three-way merge becomes possible instead of a prompt.

### A story for packages we do not ship

121 packages is an image, not a distribution. Either the recipe format is good
enough that outsiders write recipes — which is what the importer and the
option-default differ below are *for* — or the set stays whatever we
personally build.

---

## Internationalisation — four independent gaps

An appliance can ship English-only. A distribution cannot, so this moved from
"not needed" to "not done" the moment that decision was made.

**1. Message translation — blocked on `gettext`, which exists nowhere.** Not a
stage-5 package, not in the stage-4 sysroot. **Sixteen recipes disable NLS**:
bash, elfutils, fontconfig, glib, the four gstreamer packages, hello, labwc,
libgpg-error, libidn2, m4, p11-kit, xkeyboard-config, xz.

That was not a preference — it was forced. glib's own `[undeclarable]` entry:

> *"`xgettext` … LOAD-BEARING: xgettext being absent is the only reason
> `subdir('po')` is skipped, and therefore **the only reason a set with no
> gettext recipe gets through glib at all**."*

Adding gettext is the unlock; then sixteen recipes flip, which is sixteen key
moves and therefore a batch, not a drive-by.

**2. Locales — one exists, and more are nearly free.** `veron-system`
generates `C.utf8` and nothing else. Anything requesting a locale gets C, which
is what made foot print *"'C' is not a UTF-8 locale"* before even that one
existed. `localedef` and `/usr/share/i18n` are already in the sysroot and
`veron-system` already has a locale step — generating more is a loop, not a
package. The real question is **which**: a full glibc locale set is ~100 MB, so
this wants a policy, not "all of them".

**3. Fonts — DejaVu only, 22 files, and the most visible gap.** Latin, Greek,
Cyrillic. **CJK, Arabic, Hebrew, Devanagari, Thai and emoji all render as
tofu.** A user in Japan opens the browser and sees boxes — not degraded,
unusable. Noto is the answer; Noto Sans CJK alone is ~20 MB with no dependency
tail, and fontconfig would pick it up with no code change. **This is the
browser's gap too**, since wpewebkit renders whatever fontconfig hands it.

**4. Input methods — nothing at all, and it is a subsystem.** No fcitx, no
ibus, no anthy, no libpinyin. **Japanese, Chinese and Korean cannot be typed**,
anywhere. On Wayland this needs `text-input-v3` / `zwp_input_method_v2`, which
labwc supports and nothing here uses. fcitx5 pulls a real tail — and
historically wants dbus, which should be checked before committing.

**Order, by what a non-English user hits first:** fonts → locales → input
methods → message translation.

---

## Desktop applications

`nnn` in `foot` is the current file manager, and the menu's "Files" entry opens
it. Beyond that the desktop is a compositor, a terminal, a launcher, a
wallpaper and a bar.

**Free — zero or near-zero new dependencies, all satisfied by what is built:**

| | why it matters |
|---|---|
| **`wl-clipboard`** | **there is no copy/paste at all** — you cannot copy a URL from foot into the browser. Its only dependency is `wayland-client`. The single most glaring gap. |
| `grim` + `slurp` | screenshots; wayland + pixman + libpng + cairo, all present |
| `wlr-randr` | display config; wayland + wayland-protocols only |
| `swayidle` | idle timeouts via `ext-idle-notify`, which labwc supports |
| `alsa-utils` | `alsamixer`/`amixer` — **alsa-lib is built and there is no volume control** |
| `nano` | there is no editor but busybox `vi` |

**Small, high-value tails:**

- **`imv`** — image viewer; reuses pango/cairo/mesa/ICU. Enable only the
  libpng/libjpeg/libwebp backends and it adds nothing.
- **`mpv`** — media player; reuses ffmpeg, adds `libass` and `libplacebo`.
- **`swaylock`** — screen locker. **PAM is not required**: upstream compiles
  `shadow.c` instead of `pam.c` when libpam is absent, reading `/etc/shadow`
  via `crypt()` — so it needs `libxcrypt`, already planned for login.

**Two honest dead ends:**

- **There is no GTK-free, Qt-free, Wayland-native graphical file manager.**
  PCManFM, Thunar, Nautilus, Nemo, Caja are GTK; Dolphin and PCManFM-Qt are Qt.
  The strategic option is **FLTK 1.4 built Wayland-only** — it renders through
  Cairo and Pango, which are present, and bundles libdecor — as a base for a
  file manager, a graphical editor and an archiver. Otherwise `nnn` in a
  terminal is the answer.
- **Notifications are impossible without dbus.** The FreeDesktop spec *is* a
  D-Bus protocol: a server must own `org.freedesktop.Notifications` on the
  session bus. mako, fnott and dunst all need a running `dbus-daemon`; `basu`
  removes the *systemd* build dependency, not the runtime bus. `fnott` is the
  lowest-tail option (it reuses fcft and tllist) if dbus is ever accepted.

**PDF has a free answer:** rebuild wpewebkit with `-DENABLE_PDFJS=ON`. zathura
is GTK; mupdf's viewer needs X11 and freeglut.

---

## Containers — decided: `crun`, not Docker

**Docker is five Go projects** and forces a Go bootstrap that cannot start
natively on aarch64: Go 1.4 is the last C-written Go and predates arm64.
Buildroot says so outright — *"go-bootstrap-stage1 does not work on 64-bit
arm"* — and Gentoo and Alpine both inject a prebuilt binary.

**A Docker image is not a special format**, which is what makes the cheap path
work:

```
manifest.json   which layers, which config
config.json     env, cmd, workdir, user
layers          gzip/zstd tarballs, applied in order
```

Pulling is HTTPS GETs against the registry API; unpacking is tar extraction in
sequence. **Nothing in that needs Go** — skopeo and umoci are Go by accident of
who wrote them.

**Everything the fetcher needs is already built:** curl with TLS (from the
stage-4 sysroot's openssl, which curl's recipe records as an undeclarable
edge), python 3 with `ssl`, libarchive, and zlib/xz/zstd. **So the fetcher is a
script, not a package** — roughly 200 lines to get an anonymous token, fetch
the manifest, select the arm64 entry, pull each blob, extract in order, and
translate the image config into crun's `config.json`.

**New packages: one.** `crun` — C, and its `configure.ac` hard-requires
libseccomp (have), libcap (have) and yajl, which can be embedded with
`--enable-embedded-yajl`. `libsystemd` is optional and unused;
`--cgroup-manager=cgroupfs` is the default.

**The real cost is kernel config, which means a stage-4 run:**

```
namespaces  NET_NS PID_NS IPC_NS UTS_NS        (NAMESPACES, USER_NS done)
cgroup v2   CGROUPS CGROUP_PIDS CGROUP_DEVICE CGROUP_FREEZER CGROUP_SCHED
            CPUSETS MEMCG BLK_CGROUP CGROUP_CPUACCT BPF_CGROUP_DEVICE
keys        KEYS
networking  BRIDGE VETH NETFILTER NF_NAT NF_CONNTRACK IP_NF_FILTER
            IP_NF_TARGET_MASQUERADE BRIDGE_NETFILTER
            NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_MATCH_CONNTRACK
storage     OVERLAY_FS -- already on
```

All plain `=y`; none needs `CONFIG_MODULES`, which suits the monolithic kernel.
**Bundle them with the deferred wifi symbols** (`CFG80211`, `MAC80211`,
`RFKILL`) — stage 4 is two hours and should be entered once. Plus a dinit step:
`mount -t cgroup2 none /sys/fs/cgroup`, which needs no systemd.

**What a user gets:** `crun run` on any ordinary image. `ubuntu:24.04` arm64 is
a rootfs tarball with Ubuntu's glibc, coreutils and apt; kernel 7.1.5 is far
newer than anything those binaries need.

**What it will not do:** no networking out of the box (crun does not do
networking — the container shares the host netns or has none until veth/bridge/
NAT exists, so no `apt update`); no daemon, no API, no `docker build`; no layer
caching unless overlayfs stacking is implemented; systemd as PID 1 inside will
not work; GUI apps need the Wayland socket bind-mounted in.

---

## Language toolchains — Rust and Go, in stage 4, in parallel

**Why stage 4.** Both are self-hosted compilers with a bootstrap chain, which
is exactly what stage 4 already is. A stage-5 package is one tarball, one
configure, one make; a language toolchain is five tarballs and a chain where
each rung exists only to build the next.

**Go's chain** is C → Go 1.4 → 1.19 → 1.21 → 1.23 → current, and **the aarch64
problem** is that Go 1.4 predates arm64. gccgo is the only pure-source first
rung and lags badly — go.dev pins GCC 12/13's gccgo at the Go 1.18 stdlib
without generics. **Whether GCC 15's gccgo is better is unverified and worth
checking first**, since it decides the whole approach. Go's bootstrap
requirement also rises yearly: 1.26 needs 1.24.6+.

**Rust is likely worse and was not researched.** rustc also needs a previous
rustc; `mrustc` (C++) is the usual pure-source entry and its aarch64 support is
weaker than x86_64. **Research it properly rather than assuming it mirrors Go.**

**What they unlock:** Go gives the whole container-image ecosystem including
the registry pull/unpack tools a no-Go story has no mature answer for; Rust
gives youki, netavark, and a large share of modern Wayland and CLI tooling.

**Doing them in parallel is sound** — neither depends on the other, both root
at gcc. It is also the first case where stage 4's sequential rung model costs
real time.

---

## Two browser network tests, in order, and only the first is a gate

**1. Two Veron instances, offline — this one gates.** One VM runs
`python3 -m http.server`; the other leases an address by DHCP, points
MiniBrowser at `http://10.42.0.1:8000/`, and the proof is a **screenshot of the
rendered page**.

It composes two things that already pass independently — the two-VM segment
that produces `VERON-DHCP-OK` and `VERON-NET-PING-OK`, and the desktop
screenshot. Nothing new is invented: the client keeps its desktop up instead of
powering off, and the URL stops being `file://`. `python3` is already in the
set.

**What it proves that the `file://` shot cannot:** libsoup3's HTTP client, a
DNS-free direct-IP fetch, and `WPENetworkProcess` reaching the wire **from
inside the bubblewrap sandbox**.

HTTPS is a second step on the same rig: gnutls ships `certtool`, so the server
can generate a self-signed cert and the client exercises libsoup3 →
glib-networking → gnutls → p11-kit → the 121-root bundle. Either add the cert
to the bundle, or assert the handshake happens and verification correctly
*fails* — a real result worth having.

**2. Real internet, best effort, and it must never fail the run.** Once (1) is
green: fetch google.com, then youtube.com if that renders, and upload whatever
was captured. `-netdev user` gives NAT'd outbound with no privileges.

**It is not a gate, deliberately.** It is the only thing in the suite that
depends on DNS, someone else's uptime, rate limits, and what a remote site
serves a user agent it has never seen. A red X from any of those teaches
nothing about Veron. Report, upload, exit 0.

**Order matters.** (1) first, because when (2) fails there must be no question
whether the fault is ours.

### On YouTube specifically

The codec stack is sufficient: MSE is ON by default in the WPE port, WebAudio
and video are ON, and `matroskademux` + `vp9dec` + `opusdec` covers YouTube's
primary path. `h264parse` from gst-plugins-bad matters because H.264 is the
cheapest path under software decode.

**Two things no flag fixes.** Performance — QEMU TCG emulating a cortex-a57
with llvmpipe and software VP9 decode is realistically 144p–240p with frame
drops. And DRM — EME is off (gated behind `ENABLE_EXPERIMENTAL_FEATURES`) and
there is no Widevine CDM, so DRM-gated content is unplayable and
`youtube.com/tv` is defunct for uncertified browsers regardless.

---

## Tooling that would make all of this routine

**The bottleneck was never finding flags.** What cost runs this cycle:
`--disable-seq` (ours, correct in isolation, wrong for a consumer that compiles
a MIDI source unconditionally); `--disable-libatomic` (ours, invisible for 119
packages, fatal for the 120th); `gst-inspect --exists` asserting plugin names
where the tool takes element names; wpewebkit's `USE_ATK`, `USE_AVIF`,
`USE_JPEGXL`, `USE_WOFF2`, `USE_LIBBACKTRACE`, `USE_SYSPROF_CAPTURE` and
`USE_GSTREAMER_GL` all defaulting ON and fatal without libraries we lack.

**Every one of those is in a file a machine can read.** They were found by
hand, one CI run at a time.

**The gate that proves the point:** `sysroot-trim.sh:104` already *named*
`libatomic.so.1` among the runtime libraries it checks — and `continue`d when
the file was absent. It asked whether what exists is *safe*, never whether what
*should* exist *does*. That is the generalisable lesson.

In rough order of value:

1. **Option-default diffing.** Read the package's own option definitions —
   `meson_options.txt`, `configure --help`, `WEBKIT_OPTION_DEFINE`,
   `AC_ARG_ENABLE` — and diff them against `[declared].configure_flags`. Report
   every option that **defaults ON and is not overridden**, and every one whose
   absence is fatal. This alone would have caught four of the above before a
   single run.
2. **Absence gates.** Sweep every place the system names something it needs and
   check the failure mode is "missing" as well as "wrong".
3. **A draft-recipe importer** from BLFS pages, APKBUILDs, ebuilds and bitbake
   recipes: fill in URL, flags and deps mechanically, leave `[installs]` absent
   and the deferral marked UNVERIFIED. **Note the trap:** other systems'
   recipes are excellent *hints* and unreliable *sources of truth*. BLFS's
   webkitgtk page caught three fatal WPE options our own audit missed — and in
   the same stretch, distro-derived research claimed `ENABLE_SPELLCHECK`
   defaults ON (that is the GTK port) and that bison was required (true of a
   git checkout, false of a release tarball). Both were **true statements about
   a different build**.
4. **The cross-check as a gate rather than a habit.** Reading the whole
   dependency list of a reference page should not depend on anyone remembering
   to.

### `stage5-isolate` is most of the hermetic per-package tool already

`gh workflow run stage5-isolate.yml -f packages="wpewebkit"` builds a package
in a root composed of the stage-4 sysroot plus the DESTDIRs of what it
**declares** and nothing else, stacked with `bwrap --overlay-src`. In the
normal build `deps.build` only *orders* things; under isolate an undeclared
dependency becomes a build failure that names itself.

Four things between that and a development tool: it builds from the pinned
tarball rather than a working tree; it is CI-only, so the loop is push,
dispatch, wait; there is no `--keep` or shell-in on failure; and it proves deps
are *sufficient*, not *minimal* — dropping each declared dep in turn and
reporting which removals still build would answer the other half.

### Documentation should be generated, not written

**The measurement that settles the approach:** the ten top-level `.md` files
total ~3,500 lines. The `[declared].deferral` fields across 121 recipes total
**31,000+ words** — roughly nine times as much prose, written at the moment
each decision was made, next to the thing it describes.

So this is a **collection** problem, not a writing one — which is what
doxygen's model solves, and why "write more markdown" is the wrong instinct.
Hand-written overviews go stale the moment a recipe changes; a deferral cannot,
because changing the recipe is what puts you in the file.

Everything a generator needs is already structured: source URL, digest,
signature, declared flags, deps by kind, `[undeclarable]` with reasons, install
prefixes and digests, guest tests, and patch headers written as prose with the
diff appended. Plus `PLAN.txt` as a dependency graph and `MIRRORS.tsv` as a
provenance table. The recipes already cross-reference each other constantly —
*"same shape as libcap's bash dependency"*, *"the lib64 cascade"* — and those
become links.

**But the published site is not all 31,000 words.** Most of a deferral is a
build diary — valuable in the repo, next to the file, for whoever edits it
next; noise on a website. Inside the same field is the durable part: alsa-lib
needs `seq` because a consumer compiles `gstalsamidisrc.c` unconditionally;
wpewebkit turns off ATK, AVIF and JPEGXL because they default ON and are fatal
without libraries this system excludes; ruby is `build_only` because nothing at
runtime executes it.

Generate the site from the **structured fields** first and treat the deferral
as an expandable "why"; give deferrals named sections later, once the shape is
proven. **And aim the gate at the right thing:** not "does this recipe have a
deferral" — they all do — but **"does every non-default flag have a stated
reason"**.

---

## Stage 4 is two hours, and 80–90% of it is building gcc

The bootstrap chain is load-bearing and cannot be collapsed. **The
reproducibility rebuild is not:** it builds gcc a second time solely to compare
`cc1`/`cc1plus` bytes, and could be conditional on the gcc pin and flag list
changing rather than unconditional. The larger win is caching `/tools` and the
pre-B4 sysroot the way stage 5 checkpoints packages.

**Explicitly deferred, to be done properly later.** Two consequences in the
meantime: batch every kernel-config change into one trip, and expect the
stage-5 run *after* any stage-4 change to rebuild all 121 packages, because the
sysroot digest is part of every package key.

---

## Also outstanding

- **qemu** — the only remaining package from the original set. Needs a `dtc`
  pin: `ARM_VIRT` selects `DEVICE_TREE`, which requires `FDT`, and
  `hw/core/Kconfig:9` says *"fail the build if libfdt not found"*. The
  `--disable-download` flag and the python-tooling patch are already written.
- **A version and security audit of every pin.** Deferred until the browser
  works. The worked example is `p11-kit` at 0.25.5: **CVE-2026-18938 is 32-bit
  only and does not apply**, but CVE-2026-13757 and CVE-2026-2100 in the
  skipped releases do. That distinction is the point of the sweep.
- **The CA bundle is frozen** at NSS 3.126 with no updater and no revocation
  path. A CA distrusted upstream stays trusted until the pin moves.
- **`libidn2` and `qemu` carry `signing_key` values** read out of the signature
  that shipped beside the artifact. That proves the binding and nothing about
  who holds the key; `policy/keyring.toml` has no entry for either.
- **96 ninja invocations carry no `-j`**, so `policy jobs = 1` has never
  applied to any meson package. Only wpewebkit is large enough for it to
  matter, and it now states `-j4`. Making the claim true means moving ~40
  package keys.
- **23 checkpoint recipes lack an explicit `--libdir`**, and 18 recipes have
  flags in a step that are not in `[declared]`.
