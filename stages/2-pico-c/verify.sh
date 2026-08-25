#!/bin/sh
# stages/2-pico-c/verify.sh -- rebuild stage 2 through the committed Stage 1
# pair and require the recorded output hashes. One script, both homes:
# native aarch64, or any host via qemu-aarch64-static. No python in the box.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"
SA=stages/1-self-assembly/self-assembler-arm64
EW=stages/1-self-assembly/elf-wrapper-arm64
# RUNNER SELECTION. Three worlds:
#   - plain aarch64 linux: direct exec
#   - Android/Termux: the app cannot execve from home, so Termux routes
#     through linker64, which loads only PIE -- our static ET_EXEC trust
#     root is refused with "unexpected e_type: 2". proot's own loader
#     handles static ELFs; require it there. (pkg install proot)
#   - anything else: the toolbox qemu
# VERON_RUNNER overrides all three.
# THE RUNNER, AND THE SEAL. Inside stages/box.sh the box sets VERON_BOX=1 and
# VERON_RUNNER to the in-box qemu (empty on an aarch64 host); that is the
# official path, on CI, on Veron and on any Linux alike, and the only tools
# that resolve are the box's. Run bare, this script still works -- for a
# quick look, on Termux through proot -- and SAYS SO, because bare means the
# host's tools are reachable and nothing here is measured against a budget.
if [ -n "${VERON_BOX:-}" ]; then
  RUN="${VERON_RUNNER:-}"
elif [ -n "${VERON_RUNNER:-}" ]; then RUN="$VERON_RUNNER"
elif [ "$(uname -o 2>/dev/null)" = Android ]; then
  command -v proot >/dev/null 2>&1 || {
    echo "FAIL: Android blocks direct exec of static binaries (linker64"
    echo "      loads only PIE). Install the loader:  pkg install proot"
    echo "      or set VERON_RUNNER to a loader of your choice."; exit 1; }
  RUN=proot
elif [ "$(uname -m)" = aarch64 ]; then RUN=""
elif command -v qemu-aarch64-static >/dev/null 2>&1; then RUN="qemu-aarch64-static"
elif command -v qemu-aarch64 >/dev/null 2>&1; then RUN="qemu-aarch64"
else echo "FAIL: need aarch64, or qemu-aarch64-static on PATH (the tools bundle ships one)"; exit 1; fi
[ -n "${VERON_BOX:-}" ] || echo "UNSEALED: running on the host, not in stages/box.sh -- nothing below is held to a budget"
run() { ${RUN:+"$RUN"} "$@"; }
# ELF e_machine without file(1) -- busybox has no file applet. 0xB7 aarch64, 0x3E x86_64.
elf_machine() { od -An -tx1 -j18 -N1 "$1" 2>/dev/null | tr -d ' \n'; }
mkdir -p out/2/aarch64
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# the recorded sha256 and size of a substage's first OUTPUT, read with awk
# (the box holds no python): after the id line, skip the inputs -- they carry
# sha256/bytes too -- to the first [[substage.output]] and take its pair
want() { awk -v id="$1" '
  $0 ~ ("^id *= *\"" id "\"") { f = 1 }
  f && /^\[\[substage\.output\]\]/ { o = 1 }
  f && o && /^sha256 *=/ { s = $3; gsub(/"/, "", s) }
  f && o && /^bytes *=/  { print s, $3; exit }' stages/2-pico-c/substages.toml; }

echo "== 2/1 pico-c-assembler =="
run "$SA" < stages/2-pico-c/pico-c-assembler-arm64.s > "$W/pca.bin"
run "$EW" out/2/aarch64/pico-c-assembler < "$W/pca.bin"
set -- $(want 2/1/pico-c-assembler)
got=$(sha256sum out/2/aarch64/pico-c-assembler | cut -d' ' -f1)
[ "$got" = "$1" ] && [ "$(wc -c < out/2/aarch64/pico-c-assembler)" = "$2" ] \
  && echo "  MATCHES recorded $1" | cut -c1-40 || { echo "  STALE: got $got"; exit 1; }

echo "== 2/2 pico-c =="
run out/2/aarch64/pico-c-assembler < stages/2-pico-c/pico-c-arm64.s > "$W/pc.s0txt"
run "$SA" < "$W/pc.s0txt" > "$W/pc.bin"
run "$EW" out/2/aarch64/pico-c < "$W/pc.bin"
set -- $(want 2/2/pico-c)
got=$(sha256sum out/2/aarch64/pico-c | cut -d' ' -f1)
[ "$got" = "$1" ] && [ "$(wc -c < out/2/aarch64/pico-c)" = "$2" ] \
  && echo "  MATCHES recorded $1" | cut -c1-40 || { echo "  STALE: got $got"; exit 1; }

echo "== canon canary (the compiler-shaped fixpoint) =="
run out/2/aarch64/pico-c < stages/2-pico-c/selfhost/canon.c > "$W/canon.s1"
run out/2/aarch64/pico-c-assembler < "$W/canon.s1" > "$W/canon.s0txt"
run "$SA" < "$W/canon.s0txt" > "$W/canon.bin"
run "$EW" "$W/canon" < "$W/canon.bin"
printf 'int  main( ) {return 42 ; }\n' > "$W/m.c"
run "$W/canon" < "$W/m.c" > "$W/c1" && run "$W/canon" < "$W/c1" > "$W/c2"
cmp -s "$W/c1" "$W/c2" || { echo "  FAIL: canon not a fixpoint"; exit 1; }
echo "  PASS: canon(canon(x)) == canon(x)  ($(wc -c < "$W/canon") B, $(sha256sum "$W/canon" | cut -c1-16))"

echo "== renamed error prefixes =="
printf 'b nowhere\n' | run out/2/aarch64/pico-c-assembler >/dev/null 2>"$W/e1" || true
head -c 36 "$W/e1" | grep -q "^pico-c-assembler: unresolved label: " || { echo FAIL; exit 1; }
printf 'int main(){break;}\n' | run out/2/aarch64/pico-c >/dev/null 2>"$W/e2" || true
head -c 8 "$W/e2" | grep -q "^pico-c: " || { echo FAIL; exit 1; }
echo "  PASS: both prefixes exact"
echo "STAGE 2 VERIFY: green"
