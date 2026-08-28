#!/bin/sh
# stages/6-release/box-fw.sh -- runs INSIDE the box (rooted at the released
# system, uid 0): the pinned firmware tree, prepared for absorption.
#
#     box-fw.sh FWDL FWTREE      (paths as seen inside the box)
#
# What the workflow's FW step did on the runner with the runner's make, tar,
# xz and zstd, done here with the system's own. Every compressed file is
# zstd -19 -T1 by the same binary the image ships, in sorted order.
set -eu
DL="$1"; TREE="$2"
rm -rf "$TREE" "$DL/stage"; mkdir -p "$TREE" "$DL/stage"
lf=$(ls "$DL"/linux-firmware-*.tar.xz | head -1)
[ -s "$lf" ] || { echo "box-fw: no linux-firmware tarball in $DL"; exit 1; }
xz -dc "$lf" | tar -xf - -C "$DL"
src=$(ls -d "$DL"/linux-firmware-*/ | head -1)
make -C "$src" install DESTDIR="$DL/stage" FIRMWAREDIR=/ >/dev/null
cp -a "$src"/WHENCE* "$DL/stage/"
cp -a "$src"/LICEN* "$DL/stage/"
cp -a "$src"/GPL* "$DL/stage/" 2>/dev/null || true
[ "$(find "$DL/stage" -maxdepth 2 \( -name 'LICEN*' -o -name 'GPL*' \) | wc -l)" -gt 10 ] \
  || { echo "box-fw: suspiciously few license files in the tree"; exit 1; }
n=0
find "$DL/stage" -type f ! -name 'WHENCE*' ! -name 'LICEN*' ! -name 'GPL*' ! -name '*.txt' \
     ! -path '*/LICENSES/*' ! -path '*/intel-ucode/*' | LC_ALL=C sort | while read -r f; do
  zstd -q -19 -T1 --rm "$f"
done
cp -a "$DL/stage/." "$TREE/"
if ls "$DL"/intel-ucode-*.tar.gz >/dev/null 2>&1; then
  tar -xzf "$(ls "$DL"/intel-ucode-*.tar.gz | head -1)" -C "$DL"
  cp -a "$DL"/intel-ucode-20*/intel-ucode "$TREE/"
  cp "$DL"/intel-ucode-20*/license "$TREE/LICENSE.intel-ucode"
fi
if ls "$DL"/wireless-regdb-*.tar.xz >/dev/null 2>&1; then
  xz -dc "$(ls "$DL"/wireless-regdb-*.tar.xz | head -1)" | tar -xf - -C "$DL"
  cp "$DL"/wireless-regdb-*/regulatory.db "$DL"/wireless-regdb-*/regulatory.db.p7s "$TREE/"
fi
[ -e "$TREE/WHENCE" ] || [ -e "$TREE/WHENCE.zst" ] || { echo "box-fw: prepared tree lost WHENCE"; exit 1; }
rm -rf "$DL/stage" "$DL"/linux-firmware-*/ "$DL"/intel-ucode-20*/ "$DL"/wireless-regdb-*/
echo "  firmware tree: $(find "$TREE" -type f | wc -l) file(s), $(du -sh "$TREE" | cut -f1), compressed by $(zstd --version 2>&1 | head -1)"
