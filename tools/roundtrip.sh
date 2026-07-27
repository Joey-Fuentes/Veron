#!/bin/sh
# roundtrip.sh -- verify one binary against its own source, end to end.
#
#   usage: tools/roundtrip.sh <source.s> <binary> <pinned-toolchain-prefix>
#
# WHY THIS EXISTS AS A SCRIPT. The same verification was built inline for
# stage0-as over about twenty revisions, and every lesson in it -- the six
# address invariants, the object-name rule, the readelf-not-objdump rule -- is
# specific to nothing about stage0-as. `elf` needs identical treatment and
# copying the block would guarantee the two drift, with the copy staying green
# while the original grows a check it does not have.
#
# WHY `elf` NEEDS IT AT ALL. stage3-hermetic-arm64 runs exactly four host-tool
# commands, and two of them are for elf:
#
#     as -o s0.o  stage0-as.aarch64.s ; ld -static -o stage0-as s0.o
#     as -o elf.o elf.aarch64.s       ; ld -static -o elf     elf.o
#
# Committing a verified stage0-as and not a verified elf would leave `as` and
# `ld` on the build path regardless, so the budget would not move. Both, or
# neither.
#
# The checks, in the order they earn their keep:
#   A   disassemble -> reassemble -> compare .text     mechanical fidelity
#   A2  reconstruct the whole ELF and compare          the artifact, not a section
#   B   source vs disassembly, normalised              instruction-level agreement
#   E   canonical source vs canonical disassembly      a plain diff, no normaliser
#
# Exit status is the number of checks that failed, so a caller can gate on it.

set -eu
SRC=${1:?source .s}
BIN=${2:?linked binary}
P=${3:?pinned toolchain prefix}
W=$(basename "$BIN")
fail=0

echo "  ================ $W ================"
"$P/bin/objdump" -d "$BIN" > "$W.dis"
"$P/bin/objdump" -t "$BIN" > "$W.syms"
"$P/bin/objdump" -h "$BIN" > "$W.secs"
"$P/bin/objcopy" -O binary --only-section=.text "$BIN" "$W.text.bin"
"$P/bin/objcopy" -O binary --only-section=.rodata "$BIN" "$W.rodata.bin" \
  2>/dev/null || : > "$W.rodata.bin"

# ---- A2: the whole binary -------------------------------------------------
# The object is assembled AND linked under the name the original build used:
# the FILE symbol records the object the LINKER was given, so producing s0.o
# and then linking it as rebuild.o puts the wrong name in the symbol table.
obj=$(sed -n 's/.*FILE *LOCAL *//p' "$W.syms" 2>/dev/null | head -1)
[ -n "$obj" ] || obj="$W.o"
python3 tools/s0_rebuild.py "$W.dis" "$W.syms" "$W.secs" "$W.rodata.bin" \
  "$W.rebuild.s"
rm -rf "rb-$W" && mkdir -p "rb-$W" && cp "$W.rebuild.s" "rb-$W/in.s"
set --
while read -r a; do set -- "$@" "$a"; done < "$W.rebuild.s.secs"
if ( cd "rb-$W" && "$P/bin/as" -o "$obj" in.s ) 2>"$W.as.err" \
   && ( cd "rb-$W" && "$P/bin/ld" "$@" -o "../$W.rebuilt" "$obj" ) \
        2>"$W.ld.err"; then
  if cmp -s "$W.rebuilt" "$BIN"; then
    printf '  A2  whole binary      %8s  %s  MATCHES\n' \
      "$(wc -c < "$BIN")" "$(sha256sum "$BIN" | cut -c1-16)"
  else
    printf '  A2  whole binary      %8s vs %-8s DIFFERS\n' \
      "$(wc -c < "$BIN")" "$(wc -c < "$W.rebuilt")"
    for sec in .text .rodata; do
      "$P/bin/objcopy" -O binary --only-section=$sec "$W.rebuilt" \
        "$W.r$sec.bin" 2>/dev/null || : > "$W.r$sec.bin"
      cmp -s "$W$sec.bin" "$W.r$sec.bin" \
        && printf '        %-9s identical\n' "$sec" \
        || printf '        %-9s DIFFERS\n' "$sec"
    done
    echo "      symbols: $(grep -c '^ *[0-9]*:' "$W.o.s" 2>/dev/null || echo ?)"
    fail=$((fail + 1))
  fi
else
  echo "  A2  rebuild failed:"
  grep -i -m4 'error\|undefined\|out of range' "$W.as.err" "$W.ld.err" \
    2>/dev/null | sed 's/^/        /' || true
  fail=$((fail + 1))
fi

# ---- E: plain diff --------------------------------------------------------
"$P/bin/objdump" -d --no-show-raw-insn --no-addresses "$BIN" > "$W.canon.dis" \
  2>/dev/null || "$P/bin/objdump" -d --no-show-raw-insn "$BIN" > "$W.canon.dis"
python3 tools/s0_canon.py source "$SRC"          > "$W.canon.src"
python3 tools/s0_canon.py disasm "$W.canon.dis"  > "$W.canon.txt"
n=$(diff "$W.canon.src" "$W.canon.txt" | grep -c '^[<>]' || true)
if [ "$n" = 0 ]; then
  printf '  E   plain diff        %8s canonical lines  IDENTICAL\n' \
    "$(wc -l < "$W.canon.src")"
else
  printf '  E   plain diff        %8s differing\n' "$n"
  python3 tools/s0_canon.py classify "$W.canon.src" "$W.canon.txt" \
    | sed 's/^/        /'
  fail=$((fail + 1))
fi

echo "  $W: $fail check(s) failed"
exit "$fail"
