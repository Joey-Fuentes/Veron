#!/usr/bin/env bash
# Veron spike runner.
#
# Assemble a per-architecture assembly source, link it static, run it under
# QEMU user-mode, and report stdout + exit code. The SAME script runs locally
# (Termux, a dev box) and in CI, so your inner loop is identical everywhere.
#
#   usage:  tools/spike.sh <x86_64|aarch64|riscv64> <source.s> [--dump]
#
#   --dump   also print objdump -d disassembly (eyeball the emitted bytes)
#
# Requires (all from apt on Ubuntu; see ci/Dockerfile):
#   qemu-user
#   binutils-x86-64-linux-gnu  binutils-aarch64-linux-gnu  binutils-riscv64-linux-gnu
#
# Every arch is assembled with its cross-binutils and run under the matching
# qemu-user binary, so this is host-agnostic: it behaves the same whether the
# host is x86_64, an arm64 phone, or anything else.

set -euo pipefail

arch="${1:?usage: spike.sh <x86_64|aarch64|riscv64> <source.s> [--dump]}"
src="${2:?need a source file}"
dump="${3:-}"

case "$arch" in
  x86_64)  prefix="x86_64-linux-gnu-";  qemu="qemu-x86_64"  ;;
  aarch64) prefix="aarch64-linux-gnu-"; qemu="qemu-aarch64" ;;
  riscv64) prefix="riscv64-linux-gnu-"; qemu="qemu-riscv64" ;;
  *) echo "unknown arch: $arch (want x86_64 | aarch64 | riscv64)" >&2; exit 2 ;;
esac

[ -f "$src" ] || { echo "no such source: $src" >&2; exit 2; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
obj="$work/a.o"; elf="$work/a.elf"

# assemble + link static (no libc — seed/stage binaries stand alone)
"${prefix}as" -o "$obj" "$src"
"${prefix}ld" -static -o "$elf" "$obj"

echo "== ${arch} : $(basename "$src") =="
echo "-- elf size: $(stat -c%s "$elf") bytes"

# run under qemu-user; capture stdout and exit code without tripping set -e
set +e
out="$("$qemu" "$elf")"; rc=$?
set -e

echo "-- stdout:"
printf '%s\n' "$out"
echo "-- exit code: ${rc}"

if [ "$dump" = "--dump" ]; then
  echo "-- disassembly:"
  "${prefix}objdump" -d "$elf"
fi

# propagate the binary's exit code so CI goes red on a nonzero spike
exit "$rc"
