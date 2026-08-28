#!/bin/bash
# stages/6-release/build.sh -- stage 6, the consumer release, on any host.
#
#     sh stages/6-release/build.sh in       # rootfs (stage 5), kernel + loader + modules (stage 4), firmware pins
#     sh stages/6-release/build.sh unpack   # rootfs.img -> box6/rootfs, with this project's debugfs
#     sh stages/6-release/build.sh fw       # the firmware tree, made in the box
#     sh stages/6-release/build.sh image    # the A/B GPT image, made in the box, twice, compared
#     sh stages/6-release/build.sh boot     # boots it the way a consumer boots it (ahci, usb), under our OVMF
#     sh stages/6-release/build.sh pack     # out/6: named image, .zst by our zstd, SHA256SUMS, PACKED-BY, BUDGET
#
# THE RULE THIS STAGE FOLLOWS, the same as 4 and 5: every tool that shapes a
# published byte is this project's own, run inside a box; the host supplies
# a kernel, bubblewrap, and the network. Here the box is rooted at THE
# SYSTEM BEING RELEASED -- the unpacked rootfs has python 3.14, e2fsprogs,
# make, zstd, busybox -- and bubblewrap maps the invoking user to uid 0, so
# every file mke2fs records is root's. Before this the workflow's steps ran
# the runner's python, debugfs, make, zstd and kmod, and the image's files
# were owned by whichever uid ran the job (runner on CI, veron on a
# laptop): one release, two owners.
#
# What stays on the host: fetching (curl, python3 for tools/mirror.py --
# the airlock, as in stage 5), the unpack (debugfs: the bundle's, or the
# image's own on Veron), the boot gate (qemu: the bundle's, or the image's
# own, with the OVMF the system ships), and hashing. All of it recorded in
# box6/BUDGET by sha256.
#
# Inputs, local first: out/5/rootfs.img and out/4-generic/rel/* from this
# checkout's own stages 5 and 4; else the releases, digest- and (with gh)
# attestation-verified.

[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; cd "$ROOT"
S6="$ROOT/box6"; OUT6="$ROOT/out/6"; REPO="${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}"
ARCH=x86_64
mkdir -p "$S6"
PHASE="${1:-}"; [ -n "$PHASE" ] || { sed -n '4,10p' "$0"; exit 2; }

budget() { # name path -- record a host-side tool by hash
  [ -x "$2" ] || return 0
  printf '%-18s %s  %s\n' "$1" "$(sha256sum "$2" | cut -d' ' -f1)" "$2" >> "$S6/BUDGET"
}
# ---- resolution of the tools that may come from the bundle -----------------
tool() { # name -> path: VERON_TOOLS, veron-tools/ (the stage-5 bundle), the image's own; else empty
  for c in "${VERON_TOOLS:-/nonexistent}/$1" "$ROOT/veron-tools/$1" "/usr/sbin/$1" "/usr/bin/$1"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
# ---- the box: the released system, uid 0, this stage's directory as one mount
box() { # args... -- run inside the released system (read-only as /); this
        # stage's directory, writable, at /tmp/v6 as ONE mount (so hardlinked
        # staging copies stay on one filesystem); stage scripts and the
        # stage-5/6 tools read-only beside it
  bwrap --unshare-all --die-with-parent --uid 0 --gid 0 \
    --ro-bind "$S6/rootfs" / --proc /proc --dev /dev --tmpfs /tmp \
    --dir /tmp/v6 --bind "$S6" /tmp/v6 \
    --dir /tmp/stage --ro-bind "$HERE" /tmp/stage \
    --dir /tmp/tools6 --ro-bind "$ROOT/spikes/stage6/tools" /tmp/tools6 \
    --dir /tmp/tools5 --ro-bind "$ROOT/spikes/stage5/tools" /tmp/tools5 \
    --setenv PATH /usr/bin:/usr/sbin --setenv HOME /tmp --setenv TMPDIR /tmp/v6/tmp \
    --setenv TZ UTC --setenv LC_ALL C --setenv SOURCE_DATE_EPOCH 0 \
    "$@"
}

fetch_release() { # tag file dest -- curl from the release; gh attestation when gh is here
  local tag="$1" f="$2" d="$3"
  mkdir -p "$d"
  curl -fsSL --retry 3 -o "$d/$f" "https://github.com/$REPO/releases/download/$tag/$f" \
    || { echo "  no $f in release $tag"; return 1; }
  if command -v gh >/dev/null 2>&1; then
    gh attestation verify "$d/$f" -R "$REPO" >/dev/null 2>&1 && echo "  attestation: $f verified" \
      || echo "  attestation: $f NOT verified (gh present, verification failed) -- stated"
  fi
}

case "$PHASE" in
# =============================================================================
in)
  echo "=== 6 in: the inputs ==="
  rm -rf "$S6/in"; mkdir -p "$S6/in/rootfs" "$S6/in/kernel" "$S6/fw-dl"; : > "$S6/BUDGET"
  budget curl "$(command -v curl || true)"; budget python3-airlock "$(command -v python3 || true)"
  # -- the rootfs: this checkout's stage 5, else the release
  if [ -s "$ROOT/out/5/rootfs.img" ]; then
    cp "$ROOT/out/5/rootfs.img" "$S6/in/rootfs/rootfs.img"; cp "$ROOT/out/5/IMAGE-SHA256" "$S6/in/rootfs/" 2>/dev/null || true
    echo "  rootfs: out/5/rootfs.img (this checkout's stage 5)"
  else
    fetch_release "5/latest-$ARCH" rootfs.img.tar.zst "$S6/in/rootfs"
    fetch_release "5/latest-$ARCH" IMAGE-SHA256 "$S6/in/rootfs" || true
    Z=$(tool zstd) || { echo "  no zstd to unpack the release (bundle or image)"; exit 1; }
    ( cd "$S6/in/rootfs" && "$Z" -dc rootfs.img.tar.zst | tar -xf - ) && rm -f "$S6/in/rootfs/rootfs.img.tar.zst"
    echo "  rootfs: release 5/latest-$ARCH"
  fi
  [ -s "$S6/in/rootfs/rootfs.img" ] || { echo "FAIL: no rootfs.img"; exit 1; }
  [ -s "$S6/in/rootfs/IMAGE-SHA256" ] && ( cd "$S6/in/rootfs" && sha256sum -c IMAGE-SHA256 ) || echo "  (no IMAGE-SHA256 beside the rootfs -- digest not cross-checked)"
  sha256sum "$S6/in/rootfs/rootfs.img" | sed 's/^/  /'
  # -- the kernel, loader, modules: this checkout's generic kernel, else the release
  if [ -s "$ROOT/out/4-generic/rel/vmlinuz-generic" ]; then
    cp "$ROOT/out/4-generic/rel"/vmlinuz-generic "$ROOT/out/4-generic/rel"/veron-boot.efi "$ROOT/out/4-generic/rel"/modules-*.tar.zst "$ROOT/out/4-generic/rel"/KERNEL-GENERIC-SHA256 "$S6/in/kernel/"
    echo "  kernel: out/4-generic/rel (this checkout's generic kernel)"
  else
    for f in vmlinuz-generic veron-boot.efi KERNEL-GENERIC-SHA256; do fetch_release "4/kernel-$ARCH" "$f" "$S6/in/kernel"; done
    mods=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/4/kernel-$ARCH" | grep -o '"name": *"modules-[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$mods" ] && fetch_release "4/kernel-$ARCH" "$mods" "$S6/in/kernel"
    echo "  kernel: release 4/kernel-$ARCH"
  fi
  ( cd "$S6/in/kernel" && grep -E 'vmlinuz-generic|veron-boot.efi|modules-' KERNEL-GENERIC-SHA256 | sha256sum -c - ) | sed 's/^/  /'
  # -- firmware: the pinned tree's sources, through the mirror (airlock)
  python3 - > "$S6/fw-list.tsv" <<'PY'
import tomllib
for src in tomllib.load(open("sources/firmware.toml", "rb"))["source"]:
    if not src.get("sha256"):
        print("SKIP\t%s\tunpinned -- stated, not silent" % src["name"]); continue
    if src.get("url"):
        fname, url = src["url"].rsplit("/", 1)[-1], src["url"]
    elif src.get("git") and src.get("commit"):
        fname, url = "%s-%s.tar.gz" % (src["name"], src["version"]), src["git"]
    else:
        raise SystemExit("source %r has neither url nor git+commit" % src["name"])
    print("FETCH\t%s\t%s\t%s\t%s" % (src["name"], src["sha256"], fname, url))
PY
  while IFS="$(printf '\t')" read -r verb name a b c; do
    case "$verb" in
      SKIP)  echo "  $name: $a" ;;
      FETCH) echo "  fetch $name ($b)"
             timeout 900 python3 tools/mirror.py fetch "$a" "$b" --url "$c" --dest "$S6/fw-dl" \
               || { echo "FAIL: fetch of $name -- if the mirror lacks firmware, run tools/mirror-sources.sh once (authed)"; exit 1; }
             case "$name" in linux-firmware|wireless-regdb|intel-ucode) : ;; *) echo "FAIL: $name is pinned but has no handler -- add one deliberately"; exit 1 ;; esac ;;
    esac
  done < "$S6/fw-list.tsv"
  echo "VERON-6-IN-OK"
  ;;
# =============================================================================
unpack)
  echo "=== 6 unpack: the released system, as a tree ==="
  # tools/ext4-extract.py, python's standard library, verified against
  # debugfs rdump on this project's own image layout. NOT debugfs: a static
  # glibc debugfs dlopen()s the host's libc for NSS and aborts when that libc
  # is not the one it was built with (the bundle's, on a runner, 2026-08-27:
  # "rtld_static_init: guard_sym != NULL"). Reading a filesystem is a pure
  # function of its bytes; this reads it the same way on every host.
  budget python3-airlock "$(command -v python3 || true)"
  rm -rf "$S6/rootfs"; mkdir -p "$S6/rootfs"
  python3 tools/ext4-extract.py "$S6/in/rootfs/rootfs.img" "$S6/rootfs" | sed 's/^/  /'
  [ -e "$S6/rootfs/etc/veron-release" ] || { echo "FAIL: extraction produced no tree"; exit 1; }
  for t in usr/bin/python3 usr/sbin/mke2fs usr/sbin/debugfs usr/bin/make usr/bin/zstd usr/bin/busybox usr/share/qemu/OVMF.fd; do
    [ -e "$S6/rootfs/$t" ] || { echo "FAIL: the released system lacks $t, which this stage runs in the box"; exit 1; }
  done
  echo "VERON-6-UNPACK-OK"
  ;;
# =============================================================================
fw)
  echo "=== 6 fw: the firmware tree, in the box ==="
  mkdir -p "$S6/tmp"
  box /usr/bin/sh /tmp/stage/box-fw.sh /tmp/v6/fw-dl /tmp/v6/fwtree
  python3 tools/manifest.py "firmware-tree (fwtree)" "$S6/fwtree" 2>/dev/null || true
  echo "VERON-6-FW-OK"
  ;;
# =============================================================================
image)
  echo "=== 6 image: the A/B GPT image, in the box, by the system itself ==="
  rm -rf "$S6/img"; mkdir -p "$S6/img" "$S6/tmp"
  box /usr/bin/sh /tmp/stage/box-image.sh /tmp/v6 /tmp/tools6 /tmp/tools5 /tmp/v6/img
  [ -s "$S6/img/veron-$ARCH.raw" ] || { echo "FAIL: no image"; exit 1; }
  python3 tools/manifest.py "image-raw ($ARCH)" "$S6/img/veron-$ARCH.raw" 2>/dev/null || true
  echo "VERON-6-IMAGE-OK  $(sha256sum "$S6/img/veron-$ARCH.raw" | cut -d' ' -f1)"
  ;;
# =============================================================================
boot)
  echo "=== 6 boot: the consumer path, ahci and usb, under the system's own OVMF ==="
  IMG="$S6/img/veron-$ARCH.raw"; [ -s "$IMG" ] || { echo "FAIL: no image -- run image first"; exit 1; }
  Q=$(tool qemu-system-x86_64) || true
  if [ -z "$Q" ]; then
    # the image's own qemu, run inside the released system (its libraries)
    mkdir -p "$S6/bin"
    { echo '#!/bin/sh'; echo "exec bwrap --die-with-parent --bind $S6/rootfs / --dev-bind /dev /dev --proc /proc --bind $S6 $S6 --setenv TMPDIR $S6/tmp /usr/bin/qemu-system-x86_64 \"\$@\""; } > "$S6/bin/qemu-system-x86_64"
    chmod +x "$S6/bin/qemu-system-x86_64"; Q="$S6/bin/qemu-system-x86_64"; budget qemu "$S6/rootfs/usr/bin/qemu-system-x86_64"
  else budget qemu "$Q"; fi
  OVMF="$S6/rootfs/usr/share/qemu/OVMF.fd"; budget OVMF "$OVMF"
  ACCEL=""; [ -w /dev/kvm ] && ACCEL="-enable-kvm"
  before=$(sha256sum "$IMG" | cut -d' ' -f1); echo "  guard: image before boot = $before"
  mkdir -p "$S6/boot"
  for attach in ahci usb; do
    if [ "$attach" = usb ]; then DRIVE="-device qemu-xhci -device usb-storage,drive=d0 -drive if=none,id=d0,format=raw,file=$IMG,snapshot=on"
    else DRIVE="-drive format=raw,file=$IMG,snapshot=on"; fi
    log="$S6/boot/serial-$attach.log"; : > "$log"
    echo "=== boot attempt: $attach ==="
    TMPDIR="$S6/tmp" timeout -k 30 300 "$Q" -machine q35 $ACCEL -cpu qemu64 -m 2048 -nographic -no-reboot -nic none \
      -bios "$OVMF" $DRIVE -serial "file:$log" > "$S6/boot/qemu-$attach.err" 2>&1 &
    qpid=$!
    for _i in $(seq 1 300); do
      grep -q "\[  OK  \] boot\|as init process" "$log" 2>/dev/null && { sleep 3; break; }
      kill -0 "$qpid" 2>/dev/null || break; sleep 1
    done
    kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
    echo "--- serial (tail) ---"; tail -40 "$log" || true
    fail=0
    grep -Eq "efi: EFI v|EFI stub" "$log" && echo "  ok    EFI handover" || { echo "  FAIL  no EFI evidence"; fail=1; }
    grep -q "veron-boot: starting the kernel" "$log" && echo "  ok    veron-boot ran and launched the kernel" || { echo "  FAIL  veron-boot did not run"; fail=1; }
    grep -iq "command line:.*root=PARTUUID=aaaa0002" "$log" && echo "  ok    the baked cmdline named slot A" || { echo "  FAIL  baked cmdline absent"; fail=1; }
    grep -Eq "EXT4-fs \(.*\): mounted|VFS: Mounted root" "$log" && echo "  ok    slot A mounted" || { echo "  FAIL  root never mounted"; fail=1; }
    grep -q "as init process" "$log" && echo "  ok    the kernel handed the machine to dinit" || { echo "  FAIL  init never ran"; fail=1; }
    [ "$fail" -eq 0 ] || { echo "--- qemu's own output ---"; sed 's/^/    /' "$S6/boot/qemu-$attach.err" | head -20; exit 1; }
  done
  after=$(sha256sum "$IMG" | cut -d' ' -f1)
  [ "$before" = "$after" ] || { echo "FAIL: the boot gate MUTATED the image ($before -> $after)"; exit 1; }
  echo "  ok    image unchanged by the boot gate"
  echo "VERON-BOOT-GATE-OK  the consumer path boots to init, on both attachments"
  ;;
# =============================================================================
pack)
  echo "=== 6 pack: out/6 ==="
  IMG="$S6/img/veron-$ARCH.raw"; [ -s "$IMG" ] || { echo "FAIL: no image"; exit 1; }
  rm -rf "$OUT6"; mkdir -p "$OUT6"
  SHA7=$(sha256sum "$IMG" | cut -c1-7)
  if [ -s "$S6/boot/serial-usb.log" ] && grep -q "as init process" "$S6/boot/serial-usb.log"; then name="veron-$ARCH-$SHA7.img"
  else name="veron-$ARCH-$SHA7.NOBOOT.img"; echo "  no passed boot gate in box6/boot -- named NOBOOT, unpublishable"; fi
  cp "$IMG" "$OUT6/$name"
  Z=$(tool zstd) || { echo "FAIL: no zstd (bundle or image)"; exit 1; }
  ZPROV="system"; case "$Z" in "$ROOT/veron-tools/"*) ZPROV="veron-tools bundle";; "${VERON_TOOLS:-/nonexistent}"*) ZPROV="VERON_TOOLS";; esac
  "$Z" -19 -T0 -q --no-progress -f -o "$OUT6/$name.zst" "$OUT6/$name"
  ( cd "$OUT6" && sha256sum "$name" "$name.zst" ) > "$OUT6/SHA256SUMS"
  printf 'packed-by  image %s  zstd-binary %s (%s, level 19, -T0)  archive %s  %s\n' \
    "$(sha256sum "$IMG" | cut -d' ' -f1)" "$(sha256sum "$Z" | cut -d' ' -f1)" "$ZPROV" \
    "$(sha256sum "$OUT6/$name.zst" | cut -d' ' -f1)" "$name.zst" > "$OUT6/PACKED-BY"
  cp "$S6/BUDGET" "$OUT6/BUDGET"; cp -a "$S6/boot" "$OUT6/boot" 2>/dev/null || true
  cat "$OUT6/SHA256SUMS" "$OUT6/PACKED-BY"
  echo "VERON-6-PACK-OK  $(ls "$OUT6")"
  ;;
*) echo "unknown phase: $PHASE"; exit 2 ;;
esac
