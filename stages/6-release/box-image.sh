#!/bin/sh
# stages/6-release/box-image.sh -- runs INSIDE the box (rooted at the
# released system, mapped to uid 0): the A/B GPT disk image, twice, compared.
#
#     box-image.sh S6 TOOLS6 TOOLS5 OUTDIR
#
#   S6      the stage's work directory as bound in the box (one mount, so
#           veron-mkimage's hardlinked staging copy stays on one filesystem)
#   TOOLS6  spikes/stage6/tools (veron-mkimage, veron-mkfat, veron-mkgpt)
#   TOOLS5  spikes/stage5/tools (normalize-ext4.py)
#   OUTDIR  where veron-x86_64.raw lands
#
# Everything here is the system's own: python3 for mkfat/mkgpt/normalise,
# mke2fs out of the unpacked rootfs (veron-mkimage already prefers it),
# busybox modinfo for the firmware prune, tar for the modules. Because the
# box maps the invoking user to uid 0, every file the unpack produced is
# root-owned as mke2fs sees it -- the image's files are root's, on a runner
# and on a laptop alike, which they were not when the host user owned them.
set -eu
S6="$1"; T6="$2"; T5="$3"; OUT="$4"
export TMPDIR="$S6/tmp"; mkdir -p "$TMPDIR" "$OUT"
ROOTFS="$S6/rootfs"; K="$S6/in/kernel"
[ -e "$ROOTFS/etc/veron-release" ] || { echo "box-image: no unpacked rootfs at $ROOTFS"; exit 1; }
[ -s "$K/vmlinuz-generic" ] || { echo "box-image: no vmlinuz-generic"; exit 1; }
[ -s "$K/veron-boot.efi" ] || { echo "box-image: no veron-boot.efi"; exit 1; }
MODTAR=$(ls "$K"/modules-*.tar.zst 2>/dev/null | head -1 || true)
[ -n "$MODTAR" ] || { echo "box-image: no modules tarball"; exit 1; }

python3 /tmp/stage/dedupe-tree.py "$ROOTFS"

# the modules, unpacked once for the firmware prune (veron-mkimage unpacks
# them again into the staging copy; that is its contract)
rm -rf "$S6/mods-scan" "$S6/fw"; mkdir -p "$S6/mods-scan"
zstd -dc "$MODTAR" | tar -xf - -C "$S6/mods-scan"
ABSORB="--modules-tar $MODTAR"
if [ -d "$S6/fwtree" ]; then
  python3 /tmp/stage/prune-firmware.py "$S6/mods-scan" "$S6/fwtree" "$S6/fw"
  ABSORB="$ABSORB --firmware-dir $S6/fw"
else
  echo "  no firmware tree -- image without firmware, stated"
fi
rm -rf "$S6/mods-scan"

build() {
  VERON_NORMALIZE="$T5/normalize-ext4.py" \
    sh "$T6/veron-mkimage" --rootfs "$ROOTFS" --kernel "$K/vmlinuz-generic" --loader "$K/veron-boot.efi" \
       $ABSORB --out "$1"
}
build "$OUT/veron-x86_64.raw"
build "$OUT/veron-x86_64.raw2" >/dev/null 2>&1
cmp "$OUT/veron-x86_64.raw" "$OUT/veron-x86_64.raw2" \
  && echo "  image REPRODUCED (built twice in this box, same bytes)" \
  || { echo "  image NOT reproducible within one box"; exit 1; }
rm -f "$OUT/veron-x86_64.raw2"
sha256sum "$OUT/veron-x86_64.raw"
echo "  made by: $(python3 --version 2>&1), $("$ROOTFS/usr/sbin/mke2fs" -V 2>&1 | head -1), $(zstd --version 2>&1 | head -1)"
