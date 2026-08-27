#!/bin/sh
# tools/fetch-tools.sh -- the stage-5 tools bundle (tools-x86_64.tar.zst),
# verified against its TOOLS-SHA256, unpacked as ./veron-tools/.
#
#     sh tools/fetch-tools.sh            # exit 0 with veron-tools/ ready, or 1
#
# What CI uses so that its packers and gates run THIS PROJECT'S binaries --
# zstd for every published archive, qemu/OVMF for gates -- rather than
# apt's. On a Veron image the same binaries are in /usr/bin already; this
# is for hosts that are not Veron. The bundle is a release of its own
# (5/latest-x86_64), so a run on a commit whose stage 5 has not published
# yet gets the previous bundle, which is fine: the tools are recorded by
# hash wherever they are used.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"; cd "$ROOT"
REPO="${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}"
REL="https://github.com/$REPO/releases/download/5/latest-x86_64"
mkdir -p dl-tools
for f in tools-x86_64.tar.zst TOOLS-SHA256 TOOLS-WHENCE; do
  curl -fsSL --connect-timeout 20 --retry 3 -o "dl-tools/$f" "$REL/$f" || { echo "  tools bundle: $f not available from $REL"; exit 1; }
done
( cd dl-tools && sha256sum -c TOOLS-SHA256 >/dev/null ) || { echo "  tools bundle: TOOLS-SHA256 does not match"; exit 1; }
rm -rf veron-tools; mkdir -p veron-tools
if command -v zstd >/dev/null 2>&1; then zstd -dc dl-tools/tools-x86_64.tar.zst | tar -xf - -C veron-tools --strip-components=1
else tar --zstd -xf dl-tools/tools-x86_64.tar.zst -C veron-tools --strip-components=1; fi
echo "  veron-tools/: $(ls veron-tools | tr '\n' ' ')"
grep -E '^(zstd|busybox|qemu-aarch64-static|qemu-system-x86_64) ' dl-tools/TOOLS-WHENCE | sed 's/^/    /' || true
