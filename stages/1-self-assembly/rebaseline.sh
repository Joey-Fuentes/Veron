#!/bin/sh
# stages/1-self-assembly/rebaseline.sh
#
#   ./stages/1-self-assembly/rebaseline.sh derive   produce candidates + BASELINE.txt
#   ./stages/1-self-assembly/rebaseline.sh verify   compare against committed binaries
#
# THE COMMITTED ARTIFACTS ARE gen1 AND elfgen1 -- what the ladder builds from
# its own translated source -- never a host-toolchain build.
#
# BOOTSTRAP: the committed spike pair (spikes/stage0-as/stage0-as +
# spikes/elf/elf, read-only), which is itself verified on every push by its
# own workflow. NO host assembler or linker is needed to derive -- more in
# the project's spirit than the old as+ld path, and it runs anywhere:
# natively on aarch64, or on any host via qemu-aarch64-static (the tools
# bundle ships ours; stages/box.sh puts it in the box).
#
# The as+ld bounded-diff check (all divergence from a fresh binutils build
# must be the .bss-referencing adr words) runs ADDITIONALLY when `as` exists
# on an aarch64 host -- in CI, always; locally, when you have binutils.
#
# Gates, in order:
#   1. lint both sources        4. gen1 -> gen2 -> gen3 byte-identical
#   2. mechanical translation   5. elfgen1 self-wraps: == elfgen2 == elfgen3
#      (no ### leftovers)       6. oracle regression: gen1+elfgen1 build the
#   3. bootstrap gen1/elfgen1      spike stage-1 AND stage-2 sources to bytes
#      from the committed pair     identical to the committed pair's
#   [7. as+ld bounded diff, when binutils is present on aarch64]
#   8. behavior probes: renamed reject-prefix prints exactly; exit(42) runs

set -eu
MODE="${1:-verify}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SA_SRC="$HERE/self-assembler-arm64.s"
EW_SRC="$HERE/elf-wrapper-arm64.s"
XL="$ROOT/tools/s0_selfhost.py"
BOOT_AS="$ROOT/spikes/stage0-as/stage0-as"   # read-only oracle bootstrap
BOOT_EW="$ROOT/spikes/elf/elf"

# `airlock` -- host side, python: lint the .s sources, translate them, write
# the committed .s0 files, stop. Run it when the .s change; CI runs it before
# the box and refuses a dirty tree, so the committed translation can never
# lag the source.
if [ "${1:-}" = airlock ]; then
  python3 "$XL" lint "$SA_SRC" && python3 "$XL" lint "$EW_SRC"
  python3 "$XL" xlate "$SA_SRC" "$HERE/self-assembler-arm64.s0" >/dev/null
  python3 "$XL" xlate "$EW_SRC" "$HERE/elf-wrapper-arm64.s0" >/dev/null
  for f in self-assembler-arm64.s0 elf-wrapper-arm64.s0; do
    grep -q '^###' "$HERE/$f" && { echo "FAIL: $f has untranslatable lines"; exit 1; }
    echo "  $f: $(wc -c < "$HERE/$f") bytes"
  done
  exit 0
fi
ORACLE_S1="$ROOT/spikes/stage1-as/stage1-as.s0"
ORACLE_S2="$ROOT/spikes/stage2-pico-c/stage2-pico-c.s1"

# Run-an-aarch64-binary shim: native, binfmt, or the committed toolbox qemu.
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


[ -x "$BOOT_AS" ] && [ -x "$BOOT_EW" ] || {
  echo "FAIL: committed bootstrap pair missing/not executable:"; \
  ls -l "$BOOT_AS" "$BOOT_EW" 2>&1 | sed 's/^/  /'; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$W"

# THE TRANSLATION IS COMMITTED, AND THE BOX READS THE COMMITTED FORM. The
# .s sources are the readable form; the .s0 the bootstrap assembler eats is
# their mechanical translation by tools/s0_selfhost.py -- python, which the
# box does not hold and must not, since the translation shapes bytes. So
# the .s0 files are committed beside the .s, the `airlock` phase (host)
# lints and regenerates them and refuses a byte of drift, and `verify` (in
# the box) reads the committed .s0 only. Same move as tccdefs_.h in stage 3.
echo "== 1+2. lint + mechanical translation: committed .s0, checked =="
[ -s "$HERE/self-assembler-arm64.s0" ] && [ -s "$HERE/elf-wrapper-arm64.s0" ] \
  || { echo "FAIL: committed .s0 translations missing -- run: rebaseline.sh airlock"; exit 1; }
if command -v python3 >/dev/null 2>&1 && [ -z "${VERON_BOX:-}" ]; then
  python3 "$XL" lint "$SA_SRC"
  python3 "$XL" lint "$EW_SRC"
  python3 "$XL" xlate "$SA_SRC" sa.gen.s0 >/dev/null
  python3 "$XL" xlate "$EW_SRC" ew.gen.s0 >/dev/null
  cmp -s sa.gen.s0 "$HERE/self-assembler-arm64.s0" && cmp -s ew.gen.s0 "$HERE/elf-wrapper-arm64.s0" \
    || { echo "FAIL: the committed .s0 files do not match a fresh translation of the .s sources -- review, then commit the regenerated ones"; exit 1; }
  echo "  translations regenerated and identical to the committed .s0"
else
  echo "  (in the box: committed .s0 taken as is; the airlock phase re-proves them)"
fi
cp "$HERE/self-assembler-arm64.s0" sa.s0; cp "$HERE/elf-wrapper-arm64.s0" ew.s0
for f in sa.s0 ew.s0; do
  if grep -q '^###' "$f"; then
    echo "FAIL: $f has untranslatable lines:"; grep '^###' "$f" | sed 's/^/    /'
    exit 1
  fi
done

echo "== 3+4. self-assembler: bootstrap gen1, prove gen1 == gen2 == gen3 =="
run "$BOOT_AS" < sa.s0 > gen1.bin
run "$BOOT_EW" gen1 < gen1.bin
run ./gen1 < sa.s0 > gen2.bin
run "$BOOT_EW" gen2 < gen2.bin
run ./gen2 < sa.s0 > gen3.bin
cmp -s gen2.bin gen1.bin || { echo "FAIL: gen2 != gen1"; exit 1; }
cmp -s gen3.bin gen2.bin || { echo "FAIL: gen3 != gen2"; exit 1; }
printf '  PASS: gen1 == gen2 == gen3  (%s bytes wrapped, %s)\n' \
  "$(wc -c < gen1)" "$(sha256sum gen1 | cut -c1-16)"

echo "== 5. elf-wrapper: bootstrap elfgen1, prove it self-wraps to a fixpoint =="
run "$BOOT_AS" < ew.s0 > elfgen1.bin
run "$BOOT_EW" elfgen1 < elfgen1.bin
run ./elfgen1 elfgen2 < elfgen1.bin
run ./elfgen2 elfgen3 < elfgen1.bin
cmp -s elfgen2 elfgen1 || { echo "FAIL: elfgen2 != elfgen1"; exit 1; }
cmp -s elfgen3 elfgen2 || { echo "FAIL: elfgen3 != elfgen2"; exit 1; }
run ./gen1 < ew.s0 > elfgen1-by-gen1.bin
cmp -s elfgen1-by-gen1.bin elfgen1.bin || {
  echo "FAIL: builder edge -- gen1(ew.s0) != elfgen1 bytes"; exit 1; }
printf '  PASS: elfgen1 == elfgen2 == elfgen3  (%s bytes, %s)\n' \
  "$(wc -c < elfgen1)" "$(sha256sum elfgen1 | cut -c1-16)"

echo "== 6. oracle regression (spikes read-only): stage-1 AND stage-2 bytes =="
if [ -f "$ORACLE_S1" ]; then
  run "$BOOT_AS" < "$ORACLE_S1" > r1.bin && run "$BOOT_EW" r1 < r1.bin
  run ./gen1     < "$ORACLE_S1" > n1.bin && run ./elfgen1 n1 < n1.bin
  cmp -s r1 n1 || { echo "FAIL: stage-1 differs between pairs"; exit 1; }
  echo "  PASS: stage-1 identical from both pairs ($(wc -c < n1) bytes)"
  if [ -f "$ORACLE_S2" ]; then
    run ./r1 < "$ORACLE_S2" > r2.s 2>/dev/null
    run "$BOOT_AS" < r2.s > r2.bin && run "$BOOT_EW" r2 < r2.bin
    run ./n1 < "$ORACLE_S2" > n2.s 2>/dev/null
    run ./gen1 < n2.s > n2.bin && run ./elfgen1 n2 < n2.bin
    cmp -s r2 n2 || { echo "FAIL: pico-c differs between pipelines"; exit 1; }
    echo "  PASS: pico-c identical from both full pipelines ($(wc -c < n2) bytes)"
  fi
else
  echo "  SKIP: oracle not present"
fi

echo "== 7. as+ld bounded diff (extra check; runs when binutils is present) =="
if [ "$(uname -m)" = aarch64 ] && command -v as >/dev/null 2>&1 \
   && command -v ld >/dev/null 2>&1; then
  as -o sa.o "$SA_SRC" && ld -static -o sa-ref sa.o
  objcopy -O binary --only-section=.text sa-ref reference.bin
  objdump -d sa-ref > ref.dis
  tb=$(objdump -h sa-ref | awk '$2==".text"{print $4; exit}')
  nd=$(cmp -l gen1.bin reference.bin 2>/dev/null \
       | awk '{print int(($1-1)/4)}' | sort -u | wc -l)
  nb=$(cmp -l gen1.bin reference.bin 2>/dev/null \
       | awk '{print int(($1-1)/4)}' | sort -un \
       | while read -r w; do
           a=$(printf '%x' $((0x$tb + w * 4)))
           grep -m1 "^ *$a:" ref.dis
         done | grep -cE "inbuf|symtab|outword" || true)
  printf '  words differing from as+ld: %s (all must be .bss refs)\n' "$nd"
  { [ "$nd" = "$nb" ] && [ "$nd" -le 7 ]; } \
    || { echo "FAIL: divergence is not only the .bss references"; exit 1; }
  echo "  PASS: bounded to the .bss-referencing adr words"
else
  echo "  SKIP: needs binutils on aarch64 (CI runs this on every push)"
fi

echo "== 8. behavior probes =="
printf 'not an instruction\n' | run ./gen1 >/dev/null 2>err.txt || true
[ "$(head -c 26 err.txt)" = "self-assembler: rejected: " ] \
  || { echo "FAIL: reject prefix wrong:"; head -1 err.txt; exit 1; }
echo "  PASS: 'self-assembler: rejected: ' prints exactly (26 bytes)"
printf 'mov x0 42\nmov x8 93\nsvc\n' | run ./gen1 > e42.bin
run ./elfgen1 e42 < e42.bin
run ./e42 && rc=0 || rc=$?
[ "$rc" = 42 ] || { echo "FAIL: exit(42) program returned $rc"; exit 1; }
echo "  PASS: program built by the new pair runs (exit 42)"

echo "== 9. $MODE =="
case "$MODE" in
  derive)
    cp gen1    "$HERE/self-assembler-arm64"
    cp elfgen1 "$HERE/elf-wrapper-arm64"
    chmod 755 "$HERE/self-assembler-arm64" "$HERE/elf-wrapper-arm64"
    {
      echo "# Stage 1 Self-Assembly -- BASELINE (re-derive with rebaseline.sh)"
      if [ -n "${RUN:-}" ]; then _emu="yes (${RUN##*/})"; else _emu="no (native aarch64)"; fi
      echo "# bootstrap: committed spike pair; emulated: $_emu"
      for b in self-assembler-arm64 elf-wrapper-arm64; do
        printf '%s  %s  %s bytes\n' \
          "$(sha256sum "$HERE/$b" | cut -d' ' -f1)" "$b" "$(wc -c < "$HERE/$b")"
      done
    } > "$HERE/BASELINE.txt"
    echo "  WROTE committed candidates + BASELINE.txt:"
    sed 's/^/    /' "$HERE/BASELINE.txt"
    ;;
  verify)
    st=0
    for pair in "self-assembler-arm64 gen1" "elf-wrapper-arm64 elfgen1"; do
      set -- $pair
      if [ ! -f "$HERE/$1" ]; then
        echo "  $1: NOT COMMITTED YET (run 'derive' first)"; st=1; continue
      fi
      if cmp -s "$HERE/$1" "$2"; then
        printf '  %-22s committed %s  MATCHES this run\n' "$1" \
          "$(sha256sum "$HERE/$1" | cut -c1-16)"
      else
        printf '  %-22s committed %s  built %s  STALE\n' "$1" \
          "$(sha256sum "$HERE/$1" | cut -c1-16)" "$(sha256sum "$2" | cut -c1-16)"
        st=1
      fi
    done
    exit "$st"
    ;;
  *) echo "usage: rebaseline.sh [derive|verify]"; exit 2 ;;
esac
echo
echo "  (Optional deeper proof: ./stages/1-self-assembly/roundtrip.sh --"
echo "   the pinned two-decoder round-trip. Not needed to produce or use"
echo "   stage 1's outputs; CI runs it on every stage-1 change.)" 
