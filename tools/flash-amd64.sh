( set -eu

  DL="${DL:-$HOME/Downloads}"
  ROOT=/dev/nvme0n1p5          # Veron's root -- OVERWRITTEN
  PERSIST=/dev/nvme0n1p7       # Veron's /persist -- EMPTIED

  # --- refuse to touch a partition that is not the one meant -------------
  lbl=$(sudo blkid -s LABEL -o value "$PERSIST" 2>/dev/null || true)
  [ "$lbl" = "veron-persist" ] || {
    echo "refusing: $PERSIST is labelled '${lbl:-<none>}', not veron-persist"
    exit 1; }

  mkdir -p "$DL"; cd "$DL"

  # --- clean up any PRIOR RUN'S wreckage, and never leak our own ---------
  # A failed run exits mid-script with /mnt/veron still mounted; the rerun
  # then dd's over a mounted filesystem and e2fsck rightly refuses
  # ("is mounted. Cannot continue", 2026-08-16). Reruns are the contract,
  # so: unmount stale mounts on entry, and an EXIT trap guarantees the
  # same on ANY exit, success or failure.
  sudo umount /mnt/veron 2>/dev/null || true
  sudo umount /mnt/veron-persist 2>/dev/null || true
  trap 'sudo umount /mnt/veron 2>/dev/null; sudo umount /mnt/veron-persist 2>/dev/null' EXIT
  if mount | grep -q "^$ROOT "; then
    echo "FAIL: $ROOT is still mounted somewhere else -- unmount it first"
    exit 1
  fi

  # --- 1. fetch: the image, and BOTH kernels ------------------------------
  # PLAIN curl AGAINST PUBLIC RELEASE URLS, NO gh, NO AUTH: the repo is
  # public and this script must run on a machine that has never heard of
  # `gh auth login` (it demanded one on 2026-08-16 and stopped the flash).
  # Slash-in-tag download URLs work literally -- the stage-4 workflow
  # fetches src/* releases exactly this way. ONE ASSET PER CALL, EACH
  # VERIFIED BY NAME: a release missing an asset says WHICH release is
  # short WHAT, before anything else runs.
  REL=https://github.com/Joey-Fuentes/Veron/releases/download
  for a in rootfs.img.tar.zst Image initramfs.cpio.gz; do
    curl -fSL --retry 2 -o "$a" "$REL/5/latest-x86_64/$a" \
      || { echo "FAIL: 5/latest-x86_64 has no asset '$a'"; exit 1; }
    [ -s "$DL/$a" ] || { echo "FAIL: '$a' downloaded empty"; exit 1; }
  done
  for a in vmlinuz-generic modules-7.1.5-generic.tar.zst KERNEL-GENERIC-SHA256; do
    curl -fSL --retry 2 -o "$a" "$REL/4/kernel-x86_64/$a" \
      || { echo "FAIL: 4/kernel-x86_64 has no asset '$a'"; exit 1; }
    [ -s "$DL/$a" ] || { echo "FAIL: '$a' downloaded empty"; exit 1; }
  done
  # EXTRACTION ONLY AFTER EVERY INPUT IS PROVEN PRESENT -- the old order
  # extracted first and checked after, which is backwards.
  tar --zstd -xf rootfs.img.tar.zst
  [ -s "$DL/rootfs.img" ] || { echo "FAIL: rootfs.img.tar.zst held no rootfs.img"; exit 1; }
  # the generic kernel is PINNED -- verify before it touches a disk
  grep -E 'vmlinuz-generic|modules' KERNEL-GENERIC-SHA256 | sha256sum -c -

  # --- 2. write the root, then GROW THE FILESYSTEM TO THE PARTITION ------
  # The image carries an ext4 sized at image-creation size; the partition
  # is bigger, and the extra space is INVISIBLE until the filesystem is
  # told about it. The full firmware tree was the first payload big enough
  # to hit that ceiling -- "No space left on device" with gigabytes free
  # on p5, 2026-08-16. e2fsck first because resize2fs refuses without it.
  sudo dd if="$DL/rootfs.img" of="$ROOT" bs=4M status=progress conv=fsync
  sudo e2fsck -f -y "$ROOT"
  sudo resize2fs "$ROOT"

  # --- 3. modules + THE WHOLE FIRMWARE TREE into the root ----------------
  # FIRMWARE IS DATA RIDING BESIDE THE IMAGE, exactly as the kernel does:
  # the image stays byte-identical and firmware installs at flash time from
  # the PINNED mirror (sources/firmware.toml; mirrored to src/* releases).
  # The WHOLE tree, not this laptop's two families -- "any laptop" means
  # every wifi chip, GPU, sound DSP and bluetooth radio in linux-firmware,
  # zstd-compressed on disk, read verbatim by FW_LOADER_COMPRESS_ZSTD. The
  # hotplug coldplug replay then loads whatever drivers THIS machine's
  # devices fingerprint, and the firmware for them is simply there.
  # --keep-directory-symlink IS LOAD-BEARING: the image's /lib is a SYMLINK
  # into usr/lib, and without the flag GNU tar replaces it with a real
  # directory, the ELF interpreter path vanishes, and every dynamic binary
  # fails execve ("not found" on a file that exists, rc=127). One missing
  # flag took down every compiled binary in the image, 2026-08-16.
  sudo mkdir -p /mnt/veron
  sudo mount "$ROOT" /mnt/veron
  sudo tar --zstd --keep-directory-symlink \
       -xf "$DL/modules-7.1.5-generic.tar.zst" -C /mnt/veron

  FW=linux-firmware-20260810
  RD=wireless-regdb-2026.05.30
  curl -fSL --retry 2 -o "$FW.tar.xz" "$REL/src/$FW.tar.xz/$FW.tar.xz" \
    || curl -fsSLO \
    "https://www.kernel.org/pub/linux/kernel/firmware/$FW.tar.xz"
  curl -fSL --retry 2 -o "$RD.tar.xz" "$REL/src/$RD.tar.xz/$RD.tar.xz" \
    || curl -fsSLO \
    "https://www.kernel.org/pub/software/network/wireless-regdb/$RD.tar.xz"
  # the pins, verbatim from sources/firmware.toml -- verify BEFORE the disk
  printf '%s\n' \
    "ac17c34fe73756926a961fbafadf8d8f07a3bd2dd2f4ea31a0fb5d50c714a49a  $FW.tar.xz" \
    "8a27bfc081bafed8c24dd70fab0d96f098e5a0bfcd08d3da672595f225ab8993  $RD.tar.xz" \
    | sha256sum -c -
  rm -rf /tmp/fw && mkdir -p /tmp/fw
  tar -xf "$FW.tar.xz" -C /tmp/fw --strip-components=1
  # the tree's own installer: dedup + zstd, WHENCE-faithful layout.
  # Its host-side tools, installed HERE so this script has no hidden
  # steps -- apt is a no-op when they already exist:
  sudo apt-get install -y --no-install-recommends \
       rdfind zstd make cpio >/dev/null
  ( cd /tmp/fw && sudo make install-zst DESTDIR=/mnt/veron )
  tar -xf "$RD.tar.xz" -C /tmp/fw --strip-components=1 \
      "$RD/regulatory.db" "$RD/regulatory.db.p7s"
  sudo cp /tmp/fw/regulatory.db /tmp/fw/regulatory.db.p7s \
       /mnt/veron/lib/firmware/
  echo "  modules:  $(sudo find /mnt/veron/lib/modules -name '*.ko' | wc -l)"
  echo "  firmware: $(sudo find /mnt/veron/lib/firmware -type f | wc -l) files"

  # --- 3b. the FALLBACK kernel pair, rebuilt every flash -----------------
  # dd wiped Image and initramfs-fw off p5; an old GRUB entry pointing at
  # nothing is how one field run ended ("error: file '/initramfs-fw.cpio.gz'
  # not found"). A fallback entry is only a fallback while its files exist.
  # The minimal kernel's drivers are BUILT IN and probe before p5 mounts,
  # so ITS firmware still rides decompressed in ITS initramfs:
  sudo rm -rf /tmp/ir && mkdir -p /tmp/ir && cd /tmp/ir
  zcat "$DL/initramfs.cpio.gz" | sudo cpio -idm
  # blobs from the tree JUST INSTALLED on p5 -- the flash host needs none
  sudo mkdir -p lib/firmware/amdgpu lib/firmware/rtw89
  for f in /mnt/veron/lib/firmware/amdgpu/renoir_*.bin.zst; do
    zstd -d -f -c "$f" | sudo tee "lib/firmware/amdgpu/$(basename "${f%.zst}")" >/dev/null
  done
  zstd -d -f -c /mnt/veron/lib/firmware/rtw89/rtw8852a_fw.bin.zst \
    | sudo tee lib/firmware/rtw89/rtw8852a_fw.bin >/dev/null
  sudo sh -c 'find . | cpio -o -H newc' | gzip > "$DL/initramfs-fw.cpio.gz"
  echo "  amdgpu blobs: $(sudo ls lib/firmware/amdgpu | wc -l)  (expect ~12)"
  cd "$DL"

  # --- 4. BOTH kernel pairs where GRUB can read them ----------------------
  # generic: vmlinuz-generic + the STOCK initramfs (overlayfs is built in
  # as of fragment v6, so the two-file initramfs needs nothing added)
  sudo cp "$DL/vmlinuz-generic" "$DL/initramfs.cpio.gz" \
          "$DL/Image" "$DL/initramfs-fw.cpio.gz" /mnt/veron/
  ls -l /mnt/veron/vmlinuz-generic /mnt/veron/initramfs.cpio.gz \
        /mnt/veron/Image /mnt/veron/initramfs-fw.cpio.gz
  sudo umount /mnt/veron

  # --- 5. empty the persistence partition --------------------------------
  # rm, NOT mkfs. The label is what guest/init searches for, and a fresh
  # filesystem would come back without one -- so /persist would silently
  # stop being found and every boot would look stateless for a reason
  # nothing reports. Deleting the contents keeps the label and the UUID.
  sudo mkdir -p /mnt/veron-persist
  sudo mount "$PERSIST" /mnt/veron-persist
  sudo find /mnt/veron-persist -mindepth 1 -maxdepth 1 \
       ! -name 'lost+found' -exec rm -rf {} +
  ls -A /mnt/veron-persist
  sudo umount /mnt/veron-persist

  echo "VERON-READY  reboot and pick Veron"
)
