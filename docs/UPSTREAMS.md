# UPSTREAMS.md -- the per-source survey (RULED 2026-08-18: understand each repo's release conventions BEFORE automating a watcher)

Every pinned source, its hosting family, how that family defines
"latest", the pin's POLICY, and a VERIFICATION column that is only ever
filled by actually checking -- dated, with what was found. A row whose
verification is empty has NOT been walked; the watcher may not consume
a source until its row is verified, because "latest" is a per-repo
convention, not a global one. Two traps already caught by the first
three checks: lookalike projects (zlib-ng beside zlib; runtimejs's
stale musl copy beside musl.libc.org) and channels that differ from
hosting (musl's GitHub presence is a mirror; releases.html is the
truth).

## Policy classes
- **track-stable** (default): move to upstream's latest stable via the
  update->prove->cleanup lifecycle (section 14 of STAGE6-RELEASE.md).
- **chain-frozen**: stage-4 bootstrap pins (gcc 4.7.4 / 4.8.5 / 10.2.0,
  tcc 0.9.28rc, the LFS book editions). These are HISTORY, not staleness:
  moving one is a bootstrap-chain redesign, deliberately out of scope
  for the watcher. The report lists them under their own heading so
  they can never look like neglect.

## Stage-4 and system pins (the heavyweight lane: any move here reruns stage 4 -> 5 -> 6)
| source | pinned | policy | how latest is defined | verification |
|---|---|---|---|---|
| gcc (bootstrap) | 4.7.4, 4.8.5, 10.2.0 | chain-frozen | n/a | n/a by policy |
| tcc | 0.9.28rc (git) | chain-frozen | n/a | n/a by policy |
| linux kernel | 7.1.5 | track-stable | kernel.org releases.json -- VERIFIED 2026-08-18: publishes it for parsers by design, and guarantees a "stable"-marked entry always exists so parsers never break. The strongest convention in the set. | pin is on the CURRENT stable branch (7.1 left rc in ~June 2026). OPEN POLICY QUESTION, not a staleness: stable branch (7.1.x, fast) vs longterm (6.18/6.12/6.6, maintained into 2027-28) -- which channel a consumer OS tracks is a ruling to make, recorded here until made. |
| musl | 1.2.5 | track-stable | musl.libc.org/releases.html (GitHub copies are stale mirrors) | **VERIFIED 2026-08-18: OUTDATED -- 1.2.6 released 2026-03-20** |
| busybox | 1.36.1 | track-stable | busybox.net/downloads listing | |
| gmp / mpfr / mpc | 6.3.0 / 4.2.2 / 1.3.1 | track-stable | GNU ftp listings | |
| linux-firmware | 20260810 | track-stable | kernel.org firmware git tags (date-versioned) | pinned 8 days before survey |
| wireless-regdb | 2026.05.30 | track-stable | kernel.org regdb releases | |
| intel-ucode | 20260812 (commit) | track-stable | Intel GitHub releases; PIN THE COMMIT, tarballs are forge-synthesized | pinned at survey time |

## Hosting families and how each defines "latest"

### github-releases (31 source(s))
GitHub Releases: `gh api repos/<o>/<r>/releases/latest` -- but confirm per repo that releases (not just tags) are the project's channel, and that prereleases are excluded

| package | pinned | verification |
|---|---|---|
| bubblewrap | 0.11.0 |  |
| dejavu-fonts | 2.37 |  |
| dhcpcd | 10.2.4 |  |
| dosfstools | 4.2 |  |
| expat | 2.7.4 |  |
| flex | 2.6.4 |  |
| fltk | 1.4.5 |  |
| fribidi | 1.0.16 |  |
| graphite2 | 1.3.14 |  |
| harfbuzz | 12.3.2 |  |
| icu | 78.2 |  |
| lcms2 | 2.19.1 |  |
| libarchive | 3.8.5 |  |
| libffi | 3.5.2 |  |
| libjpeg-turbo | 3.1.3 |  |
| libnl | 3.12.0 |  |
| libpsl | 0.21.5 |  |
| libseccomp | 2.6.1 |  |
| libusb | 1.0.30 |  |
| libyaml | 0.2.5 |  |
| llvm | 22.1.8 |  |
| meson | 1.10.1 |  |
| nghttp2 | 1.68.0 |  |
| p11-kit | 0.25.5 |  |
| pcre2 | 10.47 |  |
| pkgconf | 3.0.5 |  |
| swaybg | 1.2.2 |  |
| utf8proc | 2.11.3 |  |
| xz | 5.8.3 |  |
| zlib | 1.3.2 | VERIFIED 2026-08-18: pinned 1.3.2 IS current (released 2026-02-17; zlib.net + GitHub agree). Trap noted: zlib-ng is a different project. |
| zstd | 1.5.7 |  |

### github-archive-tag (16 source(s))
GitHub tags only (no release objects): list tags, per-repo filter needed for stable-vs-dev tag shapes

| package | pinned | verification |
|---|---|---|
| brotli | 1.1.0 |  |
| ccid | 1.8.2 |  |
| dinit | 0.22.1 |  |
| hwdata | 0.410 |  |
| json-c | 0.18 |  |
| labwc | 0.9.1 |  |
| libepoxy | 1.5.10 |  |
| libhyphen | 2.8.9 |  |
| libudev-zero | 1.0.3 |  |
| libvpx | 1.16.0 |  |
| libxkbcommon | 1.13.2 |  |
| ninja | 1.13.2 |  |
| nnn | 5.2 |  |
| pcsc-lite | 2.5.1 |  |
| seatd | 0.9.3 |  |
| wl-clipboard | 2.3.0 |  |

### gnu.org / mirrors.kernel.org(gnu) (13 source(s))
GNU ftp directory listing; highest version-sorted tarball. Signatures per GNU keyring

| package | pinned | verification |
|---|---|---|
| autoconf | 2.73 |  |
| automake | 1.18.1 |  |
| bash | 5.3 |  |
| gmp | 6.3.0 |  |
| gperf | 3.3 |  |
| hello | 2.12.3 |  |
| libidn2 | 2.3.8 |  |
| libtasn1 | 4.21.0 |  |
| libtool | 2.6.2 |  |
| m4 | 1.4.21 |  |
| ncurses | 6.6 |  |
| nettle | 3.10.2 |  |
| readline | 8.3 |  |

### gitlab.freedesktop (11 source(s))
freedesktop GitLab: tags API per project; wayland/wlroots/etc. use plain semver tags

| package | pinned | verification |
|---|---|---|
| fontconfig | 2.17.1 |  |
| libdisplay-info | 0.4.0 |  |
| libdrm | 2.4.134 |  |
| libevdev | 1.13.4 |  |
| libinput | 1.31.3 |  |
| libsfdo | 0.1.4 |  |
| shared-mime-info | 2.5.1 |  |
| wayland | 1.26.0 |  |
| wayland-protocols | 1.49 |  |
| wlroots | 0.19.1 |  |
| xkeyboard-config | 2.48 |  |

### ? (10 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| veron-about | 1 |  |
| veron-auth | 1.0 |  |
| veron-browser | 1.0 |  |
| veron-cursors | 1 |  |
| veron-edit | 1.4.5 |  |
| veron-filechooser | 1 |  |
| veron-fltk-style | 1 |  |
| veron-pinentry | 1.0 |  |
| veron-system | 0.1.0 |  |
| wpe-platform-veron | 1.0 |  |

### www.gnupg.org (7 source(s))
GnuPG publishes swdb.lst -- a SIGNED machine-readable version database covering gnupg, libgcrypt, libgpg-error, libassuan, libksba, npth, pinentry. USE IT: one signed file answers seven pins

| package | pinned | verification |
|---|---|---|
| gnupg | 2.5.21 |  |
| gnutls | 3.8.10 |  |
| libassuan | 3.0.2 |  |
| libgcrypt | 1.11.3 |  |
| libgpg-error | 1.56 |  |
| libksba | 1.8.0 |  |
| npth | 1.8 |  |

### download.gnome.org (6 source(s))
GNOME: cache.json per project; EVEN minor = stable convention on older projects

| package | pinned | verification |
|---|---|---|
| glib | 2.86.4 |  |
| glib-networking | 2.80.1 |  |
| graphene | 1.10.8 |  |
| libsoup | 3.6.5 |  |
| libxml2 | 2.15.1 |  |
| pango | 1.57.0 |  |

### gstreamer.freedesktop.org (6 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| gst-libav | 1.28.1 |  |
| gst-plugins-bad | 1.28.1 |  |
| gst-plugins-base | 1.28.1 |  |
| gst-plugins-good | 1.28.1 |  |
| gstreamer | 1.28.1 |  |
| orc | 0.4.41 |  |

### codeberg.org (5 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| fcft | 3.3.1 |  |
| foot | 1.27.0 |  |
| fuzzel | 1.14.1 |  |
| tllist | 1.1.0 |  |
| yambar | 1.11.0 |  |

### files.pythonhosted.org (4 source(s))
PyPI JSON API: pypi.org/pypi/<name>/json -> info.version

| package | pinned | verification |
|---|---|---|
| mako | 1.4.0 |  |
| markupsafe | 3.0.3 |  |
| packaging | 26.3 |  |
| pyyaml | 6.0.3 |  |

### downloads.sourceforge.net (3 source(s))
SourceForge: RSS per project or files listing; fragile, verify per repo

| package | pinned | verification |
|---|---|---|
| freetype | 2.14.1 |  |
| freetype-bootstrap | 2.14.1 |  |
| libpng | 1.6.55 |  |

### kernel.org (3 source(s))
kernel.org publishes releases.json -- the one upstream with a machine-readable channel (stable/longterm per branch)

| package | pinned | verification |
|---|---|---|
| git | 2.53.0 |  |
| iproute2 | 6.18.0 |  |
| libcap | 2.76 |  |

### downloads.xiph.org (3 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| libogg | 1.3.6 |  |
| libvorbis | 1.3.7 |  |
| opus | 1.6.1 |  |

### www.alsa-project.org (2 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| alsa-lib | 1.2.16.1 |  |
| alsa-utils | 1.2.16 |  |

### sourceware.org (2 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| bzip2 | 1.0.8 |  |
| elfutils | 0.192 |  |

### www.cairographics.org (2 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| cairo | 1.18.4 |  |
| pixman | 0.46.4 |  |

### archive.mozilla.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| ca-certificates | 3.126 |  |

### chrony-project.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| chrony | 4.8 |  |

### cmake.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| cmake | 4.2.3 |  |

### curl.se (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| curl | 8.18.0 |  |

### downloads.videolan.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| dav1d | 1.5.4 |  |

### ffmpeg.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| ffmpeg | 8.1.2 |  |

### astron.com (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| file | 5.48 |  |

### storage.googleapis.com (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| libwebp | 1.6.0 |  |

### archive.mesa3d.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| mesa | 26.1.6 |  |

### bitmath.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| mtdev | 1.1.7 |  |

### git.zx2c4.com (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| pass | 1.7.4 |  |

### www.cpan.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| perl | 5.44.0 |  |

### www.python.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| python | 3.14.6 |  |

### cache.ruby-lang.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| ruby | 4.0.6 |  |

### git.sr.ht (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| scdoc | 1.11.3 |  |

### www.sqlite.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| sqlite | 3.53.4 |  |

### www.iana.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| tzdb | 2026c |  |

### dotat.at (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| unifdef | 2.12 |  |

### w1.fi (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| wpa_supplicant | 2.11 |  |

### wpewebkit.org (1 source(s))
convention NOT YET characterised -- first verification of any member must record how this host announces releases

| package | pinned | verification |
|---|---|---|
| wpewebkit | 2.52.5 |  |

## The verification process (per repo, before the watcher exists)
1. Open the pinned url's project page THE WAY A MAINTAINER WOULD --
   find where the project itself says releases are announced.
2. Record in this file: the authoritative channel, the current latest,
   whether our pin matches, and any trap (lookalikes, dev-vs-stable tag
   shapes, mirrors posing as homes). Date every entry.
3. Only then may the watcher consume the source, using the recorded
   channel -- never a guessed one.
Investigation log (nothing acted on -- this phase records only):
- 2026-08-18: zlib CURRENT (1.3.2 is latest, released 2026-02-17).
- 2026-08-18: musl OUTDATED (1.2.6 since 2026-03-20; stage-4 lane).
  Recorded, not queued.
- 2026-08-18: kernel convention VERIFIED (releases.json, parser-stable
  by upstream design); pin on current stable branch; branch-choice
  policy question opened above.
- Traps caught so far: zlib-ng (lookalike project), runtimejs/musl-libc
  (stale mirror posing as home). Every future row check must ask
  "is this the project's own channel or a copy".
- GnuPG's swdb.lst: a SIGNED version database covering seven pins at
  once -- to be verified as that family's channel in a future pass.
~140 of 153 rows remain unwalked. The watcher does not exist and will
not be built until this file says the methods are solid.
