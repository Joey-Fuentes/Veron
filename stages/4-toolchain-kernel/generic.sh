#!/bin/bash
# stages/4-toolchain-kernel/generic.sh -- the generic kernel (4/kernel-x86_64),
# built by the stage-4 sysroot, as ONE SCRIPT WITH PHASES, the same text on a
# GitHub runner, a Veron laptop, or any Linux with bubblewrap:
#
#     sh stages/4-toolchain-kernel/generic.sh in       the sysroot (out/4/lfs first, else 4/latest-x86_64, attested) + the pinned kernel source
#     sh stages/4-toolchain-kernel/generic.sh config   defconfig + veron-generic.fragment, the REQUIRED-CONFIGS gate
#     sh stages/4-toolchain-kernel/generic.sh build    the kernel and its modules, in the sysroot box, KBUILD_* pinned
#     sh stages/4-toolchain-kernel/generic.sh boot     squashfs + overlay gate under qemu (needs mksquashfs; skipped, said so, without it)
#     sh stages/4-toolchain-kernel/generic.sh efi      the kernel as the EFI boot program, under OVMF (ours when the host has it)
#     sh stages/4-toolchain-kernel/generic.sh loader   veron-boot.efi, built hermetically in the box
#     sh stages/4-toolchain-kernel/generic.sh pack     rel/: vmlinuz-generic, config, loader, modules tarball, KERNEL-GENERIC-SHA256
#     sh stages/4-toolchain-kernel/generic.sh all
#
# EXTRACTED 2026-08-26 FROM 4-generic-kernel-amd64.yml, step bodies verbatim.
# Everything that makes a byte runs in a bwrap box rooted at the stage-4
# sysroot with PATH=/usr/bin:/usr/sbin -- the sysroot's own gcc, make,
# flex, bison, bc, perl. The host contributes bwrap (the wall), qemu and
# OVMF for the gates (the image's own where present), and, for the modules
# tarball, GNU tar where present (transport, not artifact: the kernel and
# module bytes are what KERNEL-GENERIC-SHA256 records per file).
# `sh build.sh` is how every stage is invoked in this repo, and the image's sh
# is busybox: re-exec under bash, which these step bodies were written for.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/sources/tcc.toml" ] || { echo "FAIL: no repo root above $HERE"; exit 1; }
cd "$ROOT"
set -a; . "$HERE/pins.env"; set +a
G="$ROOT/box4g"          # the generic kernel's own scratch: lfs/ build/ rel/ ...
OUTG="$ROOT/out/4-generic"
REPO="${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}"
mkdir -p "$G" "$OUTG"

phase_in() {
  mkdir -p "$G"
  # THE SYSROOT: a local stage-4 run's trimmed sysroot when there is one --
  # out/4/lfs (pack on a host without GNU tar) or out/4/rel/sysroot.tar.zst
  # -- else the published 4/latest-x86_64, digest-checked and, where gh is
  # present, attestation-verified. Same bytes either way; the log says which.
  rm -rf "$G/lfs"; mkdir -p "$G/lfs"
  if [ -d "$ROOT/out/4/lfs" ]; then
    cp -a "$ROOT/out/4/lfs/." "$G/lfs/"; echo "  sysroot: out/4/lfs (local stage-4 run)"
  elif [ -s "$ROOT/out/4/rel/sysroot.tar.zst" ]; then
    zstd -dc "$ROOT/out/4/rel/sysroot.tar.zst" | tar -xf - -C "$G/lfs"; echo "  sysroot: out/4/rel/sysroot.tar.zst (local stage-4 run)"
  else
    mkdir -p in/4
    command -v gh >/dev/null 2>&1 || { echo "FAIL: no local stage-4 sysroot and no gh to fetch 4/latest-x86_64"; exit 1; }
    gh release download 4/latest-x86_64 -D in/4 --clobber
    got=$(sha256sum in/4/sysroot.tar.zst | cut -d' ' -f1)
    want=$(cut -d' ' -f1 in/4/SYSROOT-SHA256)
    [ "$got" = "$want" ] || { echo "FAIL: sysroot digest mismatch"; exit 1; }
    gh attestation verify in/4/sysroot.tar.zst -R "$REPO" >/dev/null && echo "  attestation: verified" \
      || { echo "FAIL: sysroot.tar.zst's attestation did not verify"; exit 1; }
    echo "VERON-ENTRY-OK  $got"
    zstd -dc in/4/sysroot.tar.zst | tar -xf - -C "$G/lfs"
  fi
  # THE KERNEL SOURCE: our src/ mirror first, kernel.org second, the pin either way
  mkdir -p dl
  if ! [ -s "dl/linux-$KERNEL.tar.xz" ] || ! sh tools/verify-source.sh "dl/linux-$KERNEL.tar.xz" >/dev/null 2>&1; then
    REL="https://github.com/$REPO/releases/download"
    curl -fsSL --connect-timeout 15 --max-time 900 --retry 2 -o "dl/linux-$KERNEL.tar.xz" \
         "$REL/src/linux-$KERNEL.tar.xz/linux-$KERNEL.tar.xz" \
      || curl -fsSL --connect-timeout 20 --max-time 900 --retry 2 -o "dl/linux-$KERNEL.tar.xz" \
         "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL%%.*}.x/linux-$KERNEL.tar.xz"
  fi
  sh tools/verify-source.sh "dl/linux-$KERNEL.tar.xz"
  rm -rf "$G/build"; mkdir -p "$G/build"
  tar -xf "dl/linux-$KERNEL.tar.xz" -C "$G/build" --strip-components=1
  echo "== PROBE: every tool the kernel build needs, named before it is missed =="

  # a refusal says why: a missing tool fails HERE with its name, not
  # forty minutes into the build with a cryptic recipe error
  # THE BOX SHAPE IS PHASE B's ("THE SYSROOT IS THE FILESYSTEM"),
  # copied from 4-toolchain-kernel-amd64.yml, which paid for it:
  # absolute bind, /usr/bin/sh entry, PATH=/usr/bin:/usr/sbin,
  # --unshare-all --die-with-parent. The first revision here used a
  # RELATIVE bind and env(1) -- bwrap printed usage to a suppressed
  # stderr and every tool probed MISSING (run 86667281511).
  ls -ld $G/lfs/usr/bin/sh || { echo "FAIL: sysroot has no /usr/bin/sh"; exit 1; }
  # THE CANARY: one box invocation with stderr WIDE OPEN. If bwrap
  # itself cannot run, this says so in its own words, and the loop
  # below never gets to print a false MISSING about the sysroot.
  bwrap --unshare-all --die-with-parent \
    --bind "$G/lfs" / --proc /proc --dev /dev \
    --tmpfs /tmp --tmpfs /run \
    --setenv PATH /usr/bin:/usr/sbin --setenv HOME /tmp --setenv TMPDIR /tmp --setenv TZ UTC --setenv LC_ALL C \
    /usr/bin/sh -c 'echo "  canary: the box opens; sh is $(command -v sh)"' \
    || { echo "FAIL: bwrap cannot open the box -- its own message is above"; exit 1; }
  fail=0
  for t in gcc make flex bison bc perl gzip gawk; do
    if bwrap --unshare-all --die-with-parent \
         --bind "$G/lfs" / --proc /proc --dev /dev \
         --tmpfs /tmp --tmpfs /run \
         --setenv PATH /usr/bin:/usr/sbin --setenv HOME /tmp --setenv TMPDIR /tmp --setenv TZ UTC --setenv LC_ALL C \
         /usr/bin/sh -c "command -v $t" >/dev/null 2>&1; then
      echo "  ok      $t"
    else
      echo "  MISSING $t"; fail=1
    fi
  done
  [ "$fail" = 0 ] || { echo "FAIL: the sysroot lacks tools named above"; exit 1; }

}

phase_config() {

  box() { bwrap --unshare-all --die-with-parent \
          --bind "$G/lfs" / --bind "$G/build" /build \
          --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
          --setenv PATH /usr/bin:/usr/sbin --setenv HOME /tmp --setenv TMPDIR /tmp --setenv TZ UTC --setenv LC_ALL C \
          --chdir /build \
          /usr/bin/sh -c "$*"; }
  cp stages/4-toolchain-kernel/generic/veron-generic.fragment $G/build/
  box "make ARCH=x86_64 defconfig"
  box "sh scripts/kconfig/merge_config.sh -m .config veron-generic.fragment"
  box "make ARCH=x86_64 olddefconfig"
  # THE GATE: every fragment line must survive dependency resolution
  # verbatim. olddefconfig silently dropping a line is the classic
  # failure; here it is a listed, fatal one.
  miss=0
  while IFS= read -r line; do
    grep -Fxq "$line" $G/build/.config || { echo "  DROPPED $line"; miss=1; }
  done < stages/4-toolchain-kernel/generic/REQUIRED-CONFIGS
  [ "$miss" = 0 ] || { echo "FAIL: the config gate lists every dropped line above"; exit 1; }
  echo "VERON-CONFIG-GATE-OK  $(grep -c '^CONFIG_' $G/build/.config) options, all required lines held"

}

phase_build() {

  box() { bwrap --unshare-all --die-with-parent \
          --bind "$G/lfs" / --bind "$G/build" /build \
          --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
          --setenv PATH /usr/bin:/usr/sbin --setenv HOME /tmp --setenv TMPDIR /tmp --setenv TZ UTC --setenv LC_ALL C \
          --setenv KBUILD_BUILD_TIMESTAMP "$KBUILD_TS" \
          --setenv KBUILD_BUILD_USER veron \
          --setenv KBUILD_BUILD_HOST veron \
          --chdir /build \
          /usr/bin/sh -c "$*"; }
  # THE TIMESTAMP IS THE TARBALL'S, NOT THE CLOCK'S -- and the tarball's
  # mtime is whatever the download gave it, which is not a constant across
  # hosts. Pinned to the epoch instead: reproducible everywhere, and the
  # kernel's own banner already names the toolchain.
  # THE TIMESTAMP MUST PARSE TO 0 IN THE BOX'S OWN date, AND THE BOX SAYS
  # WHICH FORM DID. gen_initramfs turns KBUILD_BUILD_TIMESTAMP into the
  # built-in initramfs's cpio mtimes with `date -d`; the box's date is the
  # sysroot's busybox. Two lessons, both paid for in 2026-08-27 kernels:
  #   "1970-01-01"                  parses, as LOCAL midnight -- the host's
  #                                 timezone in the image (laptop ddfd1d91
  #                                 vs CI 8c816b21, 5 hours apart)
  #   "1970-01-01 00:00:00 UTC"     does not parse in busybox date; the
  #                                 fallback is the wall clock, so three CI
  #                                 runs gave three kernels (e270c142,
  #                                 f6af6578, ed282f7d)
  # Stage 4's B6 already probes for a form that parses to 0 and refuses to
  # continue otherwise; this is that probe, with TZ=UTC set in the box so
  # a zone-less form means UTC everywhere. Same sysroot -> same busybox ->
  # same chosen form on every host, so the banner is the same string too.
  KBUILD_TS=""
  for _f in "1970-01-01 00:00:00 UTC" "1970-01-01 00:00:00" "@0"; do
    if [ "$(KBUILD_TS="$_f" box "date -d '$_f' +%s 2>/dev/null")" = 0 ]; then KBUILD_TS="$_f"; break; fi
  done
  [ -n "$KBUILD_TS" ] || { echo "FAIL: no timestamp form parses to 0 in the box's date -- the built-in initramfs would carry the clock"; exit 1; }
  echo "  KBUILD_BUILD_TIMESTAMP='$KBUILD_TS' parses to 0 in the box (TZ=UTC): built-in initramfs mtimes are 0"
  export KBUILD_TS
  # AGENTS.md invariant 9: NEVER TRUNCATE LOGS IN CI. The build
  # streams live -- the output is the heartbeat -- AND tees to
  # /build/kbuild.log, which is bind-mounted so the file survives
  # the box and uploads whole. An earlier revision wrote to the
  # box's tmpfs and tail -40'd failures: destroyed evidence, twice.
  # THE STATUS RIDES IN A FILE, NOT IN PIPESTATUS. The box's shell is
  # busybox ash, which has no PIPESTATUS; the earlier \${PIPESTATUS:-\$?}
  # silently became tee's \$? -- always 0 -- and a failing make passed
  # this step (measured 2026-08-25: modules_install failed on depmod
  # and the step went green). make's own status is written beside
  # the log and the box exits with it.
  box "{ make ARCH=x86_64 -j\$(nproc); echo \$? > /build/kbuild.rc; } 2>&1 | tee /build/kbuild.log; exit \$(cat /build/kbuild.rc)" \
    || { echo "FAIL: kbuild failed -- the FULL log streamed above and is in the kbuild-log artifact"; exit 1; }
  # DEPMOD=: SKIPS DEPMOD IN THE BOX. The sysroot has no kmod (it was
  # never in the LFS list; the minimal kernel is all built-in and
  # never needed it), so depmod resolves to busybox's applet, which
  # ignores INSTALL_MOD_PATH and chdirs to bare /lib/modules --
  # "No such file or directory", run of 2026-08-16. modules.dep is
  # DERIVED METADATA computed from the .ko set, so the host's real
  # kmod generates it below, same doctrine as mksquashfs preparing
  # test data. (kmod joins the sysroot alongside zstd when stage 4
  # next grows -- then this moves back in the box.)
  # DEPMOD=true, NOT DEPMOD=: -- this kernel's scripts/depmod.sh
  # exec's \$DEPMOD, and exec needs a program; ':' is a shell builtin
  # and failed with 127 (kernel 7.1.5, run of 2026-08-25). busybox
  # has a real true applet, so exec finds it and does nothing, which
  # is the whole intent. Same status-in-a-file exit as kbuild above.
  box "{ make ARCH=x86_64 INSTALL_MOD_PATH=/build/staging DEPMOD=true modules_install; echo \$? > /build/modinstall.rc; } 2>&1 | tee /build/modinstall.log; exit \$(cat /build/modinstall.rc)" \
    || { echo "FAIL: modules_install failed -- the log streamed above"; exit 1; }
  krel=$(ls $G/build/staging/lib/modules)
  # depmod IN THE BOX, WITH THE SYSROOT'S BUSYBOX, ON EVERY HOST. The first
  # version preferred a host kmod when it found one: a runner then shipped
  # kmod's ten modules.* index files and a laptop shipped busybox's
  # modules.dep.bb, with all 182 .ko byte-identical (tools/diag/modules-diff,
  # 2026-08-27) -- a host tool deciding published content. The image runs
  # busybox modprobe-small and reads modules.dep.bb; that is the index to
  # ship, written by the same busybox on both sides. modprobe-small's
  # depmod reads only /lib/modules, so the staging tree is bound there.
  bwrap --unshare-all --die-with-parent \
    --bind "$G/lfs" / --bind "$G/build" /build --bind "$G/build/staging/lib/modules" /lib/modules \
    --proc /proc --dev /dev --tmpfs /tmp \
    --setenv PATH /usr/bin:/usr/sbin --setenv TZ UTC --setenv LC_ALL C \
    /usr/bin/busybox depmod -F /build/System.map "$krel"
  echo "  depmod: the sysroot's busybox (modprobe-small), in the box"
  [ -s "$G/build/staging/lib/modules/$krel/modules.dep.bb" ] \
    || { echo "FAIL: depmod wrote no modules.dep.bb"; exit 1; }
  echo "depmod: $(ls $G/build/staging/lib/modules/$krel/modules.dep* 2>/dev/null | head -1) for $krel"
  ls -la $G/build/arch/x86/boot/bzImage
  echo "modules: $(find $G/build/staging/lib/modules -name '*.ko' | wc -l)"

}

phase_boot() {
  command -v mksquashfs >/dev/null 2>&1 || { echo "  no mksquashfs on this host -- the squashfs+overlay gate is skipped here (runs on CI); the EFI gate below still runs"; return 0; }
  cd "$G"

  # host prepares test DATA; the GUEST KERNEL proves capability --
  # squashfs=y reads the medium, loop=y, overlay.ko loads, tmpfs
  # stacks: the live-boot spine, demonstrated before publishing
  mkdir -p sqroot initrd/bin initrd/lib/modules
  echo "the payload" > sqroot/proof.txt
  mksquashfs sqroot payload.squashfs -comp zstd -quiet
  cp $G/lfs/usr/bin/busybox initrd/bin/busybox 2>/dev/null || cp $G/lfs/bin/busybox initrd/bin/busybox
  # overlay is =y as of fragment v6 (machine #1's fall-through,
  # 2026-08-16), so there is normally no overlay.ko -- the guest
  # then skips the insmod and the mount exercises the BUILT-IN fs,
  # which is exactly the bare-metal shape. The module path stays
  # handled so a future =m flip does not break this gate.
  ov=$(find $G/build/staging -name 'overlay.ko*' | head -1 || true)
  [ -n "$ov" ] && cp "$ov" initrd/overlay.ko || : > initrd/no-overlay-module
  cat > initrd/init << 'INIT'
#!/bin/busybox sh
/bin/busybox mkdir -p /proc /sys /dev /ro /rw /work /merged
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sys /sys
/bin/busybox mount -t devtmpfs dev /dev
[ -f /overlay.ko ] && /bin/busybox insmod /overlay.ko
/bin/busybox mount -t squashfs -o ro /dev/vda /ro || { echo VERON-GENERIC-FAIL squashfs; /bin/busybox poweroff -f; }
/bin/busybox mount -t tmpfs tmpfs /rw
/bin/busybox mkdir -p /rw/up /rw/work
/bin/busybox mount -t overlay overlay -o lowerdir=/ro,upperdir=/rw/up,workdir=/rw/work /merged \
  || { echo VERON-GENERIC-FAIL overlay; /bin/busybox poweroff -f; }
echo written > /merged/new.txt
/bin/busybox cat /merged/proof.txt
echo "VERON-GENERIC-TESTS pass=2 fail=0"
/bin/busybox poweroff -f
INIT
  chmod +x initrd/init
  ( cd initrd && find . | cpio -o -H newc --quiet | gzip ) > initrd.img
  TMPDIR="$QTMP" timeout -k 30 180 "$(qemu_bin)" -m 1024 -nographic -no-reboot \
    -kernel $G/build/arch/x86/boot/bzImage -initrd initrd.img \
    -drive file=payload.squashfs,format=raw,if=virtio \
    -append "console=ttyS0 rdinit=/init" | tee boot.log || true
  grep -q "VERON-GENERIC-TESTS pass=2 fail=0" boot.log \
    || { echo "FAIL: the boot gate did not pass"; exit 1; }
  echo "VERON-GENERIC-BOOT-OK"

  cd "$ROOT"
}

# the emulator and firmware: this project's own where the host has them
qemu_bin() { command -v qemu-system-x86_64; }
# qemu's vvfat driver (the EFI gate's fat:rw: drive) writes a temp file
# under $TMPDIR, default /var/tmp -- which the image does not have. The
# gates' qemu gets one that exists, PER INVOCATION: exporting it here leaked
# a host path into the boxes (bwrap passes the environment through) and
# kbuild's mktemp failed on CI (run 2026-08-26). Boxes set their own below.
mkdir -p "$G/tmp"; QTMP="$G/tmp"
ovmf_fd() { for f in /usr/share/qemu/OVMF.fd /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd "$ROOT/veron-tools/share/qemu/OVMF.fd"; do [ -f "$f" ] && { echo "$f"; return; }; done; echo ""; }

phase_efi() {
  cd "$G"
  OVMF=$(ovmf_fd); [ -n "$OVMF" ] || { echo "  no OVMF firmware on this host -- EFI gate skipped, said so"; cd "$ROOT"; return 0; }
  echo "  qemu: $(qemu_bin)  firmware: $OVMF"
  # TWO WAYS TO HAND THE KERNEL TO THE FIRMWARE. Ubuntu's OVMF.fd carries the
  # UEFI Shell, which runs startup.nsh from the FAT drive -- that is how
  # LoadOptions (the command line) get tested. The project's own OVMF is a
  # SECURE_BOOT_ENABLE build, and edk2's OvmfPkgX64.dsc omits the shell in
  # that case (run 2026-08-26 on the laptop: "No bootable option or device
  # was found"). There the kernel goes in as EFI/BOOT/BOOTX64.EFI, the
  # removable-media path every UEFI boots unasked: the EFI stub and the
  # root-mount witness are still proven; LoadOptions cannot be, and the
  # gate says so instead of failing on the wrong thing.
  efi_run() {   # $1 = shell | fallback
    rm -rf efiboot; mkdir -p efiboot/EFI/BOOT
    cp build/arch/x86/boot/bzImage efiboot/kernel.efi
    if [ "$1" = shell ]; then
      printf 'kernel.efi console=ttyS0,115200 root=PARTUUID=00000000-dead-dead-dead-000000000000 rw init=/usr/bin/dinit panic=-1\r\n' > efiboot/startup.nsh
    else
      cp build/arch/x86/boot/bzImage efiboot/EFI/BOOT/BOOTX64.EFI
    fi
    : > efiboot/serial.log
    TMPDIR="$QTMP" timeout -k 30 300 "$(qemu_bin)" -machine q35 -m 1024 -nographic -no-reboot -nic none \
      -bios "$OVMF" -drive format=raw,file=fat:rw:efiboot \
      -serial file:efiboot/serial.log > efiboot/qemu.err 2>&1 &
    qpid=$!
    for _i in $(seq 1 300); do
      if grep -q "Waiting for root device\|Cannot open root device\|VFS: Unable to mount root\|No bootable option" efiboot/serial.log 2>/dev/null; then
        sleep 2; echo "  witness seen after ${_i}s; stopping qemu"; kill "$qpid" 2>/dev/null || true; break
      fi
      kill -0 "$qpid" 2>/dev/null || break
      sleep 1
    done
    wait "$qpid" || true
  }
  efi_run shell
  MODE=shell
  if grep -q "No bootable option" efiboot/serial.log 2>/dev/null; then
    echo "  this OVMF has no UEFI Shell (a SECURE_BOOT build): retrying by the removable-media path, EFI/BOOT/BOOTX64.EFI"
    efi_run fallback; MODE=fallback
  fi
  echo "--- qemu's own output (efiboot/qemu.err) ---"
  sed 's/^/    /' efiboot/qemu.err 2>/dev/null | head -20 || true
  echo "--- serial (tail) ---"
  tail -60 efiboot/serial.log || true
  fail=0
  grep -Eq "efi: EFI v|EFI stub" efiboot/serial.log \
    && echo "  ok    EFI handover confirmed (runtime banner or stub chatter)" \
    || { echo "  FAIL  no EFI evidence: kernel did not boot via EFI"; fail=1; }
  if [ "$MODE" = shell ]; then
    grep -q "Command line:.*root=PARTUUID=00000000-dead" efiboot/serial.log \
      && echo "  ok    LoadOptions became the kernel command line" \
      || { echo "  FAIL  LoadOptions did not reach the cmdline"; fail=1; }
  else
    echo "  skip  LoadOptions -> cmdline: not testable without the firmware shell on this host (CI's OVMF has it)"
  fi
  grep -Eq "Waiting for root device|Cannot open root device|unknown-block|VFS: Unable to mount root" efiboot/serial.log \
    && echo "  ok    the kernel reached root mounting (waiting or reported it, as designed)" \
    || { echo "  FAIL  the kernel never reached root mounting"; fail=1; }
  [ "$fail" -eq 0 ] || { cd "$ROOT"; exit 1; }
  echo "VERON-EFISTUB-OK  no bootloader, no initramfs: the kernel IS the boot program ($MODE path)"
  cd "$ROOT"
}

phase_loader() {

  # veron-boot.efi is boot code, so it is built here under the pinned
  # stage-4 toolchain and published beside the kernel -- never with a
  # host compiler. The pinned binutils targets ELF only, so we cannot
  # objcopy to PE; instead we lay the loader out as one contiguous,
  # position-independent image with its entry at offset 0 (veron-boot.lds),
  # flatten it with objcopy -O binary, and wrap it in a PE32+ EFI header
  # with mkpe -- our own from-source tool, the same trick the kernel uses
  # for its own stub. No host tools, no PE-capable binutils.
  box() { bwrap --unshare-all --die-with-parent \
          --bind "$G/lfs" / --bind "$G/build" /build \
          --ro-bind "$ROOT/spikes/stage6/boot" /boot-src \
          --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
          --setenv PATH /usr/bin:/usr/sbin --setenv HOME /tmp --setenv TMPDIR /tmp --setenv TZ UTC --setenv LC_ALL C \
          --chdir /build \
          /usr/bin/sh -c "$*"; }
  box "cc -ffreestanding -fno-stack-protector -fshort-wchar -mno-red-zone \
         -fpic -fno-stack-check -ffunction-sections -fdata-sections \
         -I/boot-src -c /boot-src/veron-boot.c -o /build/veron-boot.o"
  box "ld -nostdlib -T /boot-src/veron-boot.lds -Bsymbolic \
         /build/veron-boot.o -o /build/veron-boot.elf"
  box "objcopy -O binary /build/veron-boot.elf /build/veron-boot.bin"
  # bss size = __bss_end - __bss_start, read from the ELF symbols in the box.
  box "cc -O2 -Wall -Wextra -std=c11 -o /build/mkpe /boot-src/mkpe.c"
  box 'set -eu; bs=$(readelf -s /build/veron-boot.elf | awk "/__bss_start/{print \$2}"); \
       be=$(readelf -s /build/veron-boot.elf | awk "/__bss_end/{print \$2}"); \
       bss=$(( 0x$be - 0x$bs )); \
       /build/mkpe /build/veron-boot.bin "$bss" /build/veron-boot.efi'
  [ -s $G/build/veron-boot.efi ] || { echo "  FAIL: veron-boot.efi not produced"; exit 1; }
  # prove it is a PE32+ EFI application (subsystem 10) before we ship it.
  python3 - "$G/build/veron-boot.efi" <<'PY'
import sys
d=open(sys.argv[1],"rb").read()
pe=int.from_bytes(d[0x3c:0x40],"little")
assert d[:2]==b"MZ" and d[pe:pe+4]==b"PE\x00\x00", "not a PE"
ss=int.from_bytes(d[pe+24+68:pe+24+70],"little")
assert ss==10, f"subsystem {ss} != 10 (EFI application)"
print(f"  ok    veron-boot.efi is PE32+ EFI application ({len(d)} bytes)")
PY

}

phase_pack() {
  cd "$G"; rm -rf rel; mkdir -p rel
  cp build/arch/x86/boot/bzImage rel/vmlinuz-generic
  cp build/.config rel/config-generic
  cp build/veron-boot.efi rel/veron-boot.efi
  # THE MODULES TARBALL IS TRANSPORT: GNU tar's sorted, root-owned form where
  # the host has it (the workflow's exact line); busybox tar piped through
  # zstd elsewhere, stated. The per-module bytes are what the manifest and
  # the initramfs consume.
  # --mtime=@0: without it the tarball carried pack time on all 320 members
  # (three CI runs, three digests, every member's CONTENT identical --
  # tools/diag/modules-diff.py, 2026-08-27). The sysroot tarball always had it.
  if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=gnu \
        --zstd -cf "rel/modules-$KERNEL-generic.tar.zst" -C build/staging .
  else
    find build/staging -exec touch -h -t 197001010000.00 {} +
    ( cd build/staging && tar -cf - . ) | zstd -19 -q > "rel/modules-$KERNEL-generic.tar.zst"
    echo "  modules tarball made with busybox tar (no GNU tar here) -- its digest differs from a runner's; the modules inside do not"
  fi
  ( cd rel && sha256sum vmlinuz-generic config-generic veron-boot.efi "modules-$KERNEL-generic.tar.zst" ) > rel/KERNEL-GENERIC-SHA256
  cat rel/KERNEL-GENERIC-SHA256
  rm -rf "$OUTG/rel"; cp -a rel "$OUTG/rel"
  echo "  out/4-generic/rel: $(ls "$OUTG/rel" | tr '\n' ' ')"
  cd "$ROOT"
}

case "${1:-all}" in
  in)     phase_in ;;
  config) phase_config ;;
  build)  phase_build ;;
  boot)   phase_boot ;;
  efi)    phase_efi ;;
  loader) phase_loader ;;
  pack)   phase_pack ;;
  all)    phase_in; phase_config; phase_build; phase_boot; phase_efi; phase_loader; phase_pack ;;
  *) echo "usage: generic.sh [in|config|build|boot|efi|loader|pack|all]"; exit 2 ;;
esac
