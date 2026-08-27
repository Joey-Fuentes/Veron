#!/bin/sh
# tools/diag/kernel-diff.sh -- compare a published generic kernel with the
# one this checkout built (box4g/), on any host with python3 and curl:
#
#     sh tools/diag/kernel-diff.sh            # against 4/kernel-x86_64
#
# Prints both digests, extracts both ELFs (tools/diag/extract-vmlinux.py --
# the kernel's own scripts/extract-vmlinux needs GNU grep -b and a mktemp
# template busybox lacks), then the first differing byte and the strings
# that appear in only one of them. Written 2026-08-27 for the open item
# "laptop vmlinuz ddfd1d91... vs CI 8c816b21..., same config, same
# toolchain": the strings diff names an embedded input (path, date, host,
# locale-sorted table); an empty one with differing bytes points at code
# layout (link order, -j) instead.
#     sh tools/diag/kernel-diff.sh A B       # any two kernel images
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
W="$ROOT/box4g/diag"; mkdir -p "$W"
if [ $# -eq 2 ]; then
  A="$(readlink -f "$1")"; L="$(readlink -f "$2")"; cd "$W"; cp "$A" ci-vmlinuz
else
  cd "$W"
  [ -s ci-vmlinuz ] || curl -fsSL -o ci-vmlinuz https://github.com/Joey-Fuentes/Veron/releases/download/4/kernel-x86_64/vmlinuz-generic
  L="$ROOT/box4g/build/arch/x86/boot/bzImage"
fi
echo "== compression"; grep -E '^CONFIG_KERNEL_(GZIP|XZ|ZSTD|LZ4|LZMA|BZIP2)=y' "$ROOT/box4g/build/.config" 2>/dev/null || true
echo "== digests"; sha256sum ci-vmlinuz "$L"
python3 "$HERE/extract-vmlinux.py" ci-vmlinuz > ci.elf
python3 "$HERE/extract-vmlinux.py" "$L" > laptop.elf
ls -l ci.elf laptop.elf
echo "== first differing byte"; cmp ci.elf laptop.elf | head -1 || true
strings ci.elf | sort > s1; strings laptop.elf | sort > s2
echo "== strings only in CI (<) / only on laptop (>), first 40"; diff s1 s2 | head -40 || true
echo "== count of differing string lines"; diff s1 s2 | grep -c '^[-+][^-+]' || true
