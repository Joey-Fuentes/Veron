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
# EVERY non-code section, not just .rodata. elf keeps its 120-byte ELF header
# template in .data because the program patches p_filesz into it at runtime, so
# a rebuild that only knew about .rodata had no label for `header` and the link
# failed on an undefined reference.
rm -rf "sec-$W" && mkdir -p "sec-$W"
for sec in .rodata .data; do
  "$P/bin/objcopy" -O binary --only-section=$sec "$BIN" "sec-$W/$sec.bin" \
    2>/dev/null || : > "sec-$W/$sec.bin"
done
cp "sec-$W/.rodata.bin" "$W.rodata.bin" 2>/dev/null || : > "$W.rodata.bin"

# ---- A2: the whole binary -------------------------------------------------
# The object is assembled AND linked under the name the original build used:
# the FILE symbol records the object the LINKER was given, so producing s0.o
# and then linking it as rebuild.o puts the wrong name in the symbol table.
obj=$(sed -n 's/.*FILE *LOCAL *//p' "$W.syms" 2>/dev/null | head -1)
[ -n "$obj" ] || obj="$W.o"
python3 tools/s0_rebuild.py "$W.dis" "$W.syms" "$W.secs" "sec-$W" \
  "$W.rebuild.s"
rm -rf "rb-$W" && mkdir -p "rb-$W" && cp "$W.rebuild.s" "rb-$W/in.s"
set --
while read -r a; do set -- "$@" "$a"; done < "$W.rebuild.s.secs"
if ( cd "rb-$W" && "$P/bin/as" -o "$obj" in.s ) 2>"$W.as.err" \
   && ( cd "rb-$W" && "$P/bin/ld" "$@" -o "../$W.rebuilt" "$obj" ) \
        2>"$W.ld.err"; then
  if cmp -s "$W.rebuilt" "$BIN"; then
    # BOTH SHAS, SIDE BY SIDE. Printing one sha and the word MATCHES asks the
    # reader to take the comparison on trust; printing the original and the
    # reassembled lets them see it. Same shape as the artifact table the
    # stage0-as round trip prints.
    printf '\n  === %s ARTIFACTS ===\n' "$W"
    printf '  %-26s %10s  %-16s  %s\n' 'ARTIFACT' 'BYTES' 'SHA256[0:16]' 'vs ORIGINAL'
    printf '  %-26s %10s  %-16s  %s\n' 'source .s' \
      "$(wc -c < "$SRC")" "$(sha256sum "$SRC" | cut -c1-16)" '-'
    printf '  %-26s %10s  %-16s  %s\n' "binary $W (ORIGINAL)" \
      "$(wc -c < "$BIN")" "$(sha256sum "$BIN" | cut -c1-16)" 'the original'
    printf '  %-26s %10s  %-16s  %s\n' "binary $W (REASSEMBLED)" \
      "$(wc -c < "$W.rebuilt")" "$(sha256sum "$W.rebuilt" | cut -c1-16)" \
      'MATCHES the original'
    printf '  %-26s %10s  %-16s  %s\n' 'disassembly' \
      "$(wc -c < "$W.dis")" "$(sha256sum "$W.dis" | cut -c1-16)" 'n/a -- text'
    printf '  %-26s %10s  %-16s  %s\n' 'reconstructed .s' \
      "$(wc -c < "$W.rebuild.s")" "$(sha256sum "$W.rebuild.s" | cut -c1-16)" '-'
    echo
  else
    printf '  A2  whole binary      %8s vs %-8s DIFFERS\n' \
      "$(wc -c < "$BIN")" "$(wc -c < "$W.rebuilt")"
    # EVERY SECTION THE BINARY HAS, not a hardcoded two. elf keeps its ELF
    # header template in .data, which this loop never looked at -- so the
    # per-section report could say ".text identical, .rodata identical" while
    # the whole-file comparison failed, and name nothing.
    for sec in $("$P/bin/objdump" -h "$BIN" | awk '$2 ~ /^\./ {print $2}'); do
      "$P/bin/objcopy" -O binary --only-section=$sec "$W.rebuilt" \
        "$W.r$sec.bin" 2>/dev/null || : > "$W.r$sec.bin"
      # SIZES TOO. "DIFFERS" alone cannot distinguish a content difference
      # from an empty-versus-absent one, and .bss has no file bytes at all --
      # so the report said .bss DIFFERS without saying whether either side
      # even had any.
      _os=$(wc -c < "$W$sec.bin" 2>/dev/null || echo 0)
      _rs=$(wc -c < "$W.r$sec.bin" 2>/dev/null || echo 0)
      if cmp -s "$W$sec.bin" "$W.r$sec.bin"; then
        printf '        %-9s identical (%s bytes)\n' "$sec" "$_os"
      else
        printf '        %-9s DIFFERS  %s vs %s bytes' "$sec" "$_os" "$_rs"
        if [ "$_os" = "$_rs" ] && [ "$_os" != 0 ]; then
          # cmp's message says "char" on some builds and "byte" on others, so
          # parsing it printed the whole sentence instead of a number. cmp -l
          # gives the offset as its first field, unambiguously.
          printf '  first differing byte %s' \
            "$(cmp -l "$W$sec.bin" "$W.r$sec.bin" 2>/dev/null | head -1 | awk '{print $1}')"
        fi
        printf '\n'
      fi
    done
    # Symbol counts from both sides. The previous line read a file that was
    # never created and printed "symbols: ?" every time -- a diagnostic that
    # cannot fail is not a diagnostic.
    for _s in "$BIN" "$W.rebuilt"; do
      "$P/bin/readelf" -W -s "$_s" > "$W.$(basename "$_s").syms" 2>/dev/null || true
    done
    printf '      symbols: original %s  rebuilt %s\n' \
      "$(grep -c '^ *[0-9]*:' "$W.$(basename "$BIN").syms" 2>/dev/null || echo 0)" \
      "$(grep -c '^ *[0-9]*:' "$W.$(basename "$W.rebuilt").syms" 2>/dev/null || echo 0)"
    diff "$W.$(basename "$BIN").syms" "$W.$(basename "$W.rebuilt").syms" \
      | grep '^[<>]' | head -6 | sed 's/^/        /' || true
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

# PRINT THE WHOLE DISASSEMBLY WHEN IT IS SMALL ENOUGH TO READ. The point of
# this project is that a person can audit the seed by reading it; a check that
# proves the bytes match the source and then hides both is only half the job.
# 200 instructions is about three screens -- past that it is noise, and the
# artifact is uploaded either way.
_n=$(grep -c "^ *[0-9a-f]*:" "$W.dis" 2>/dev/null || echo 0)
if [ "$_n" -le 200 ]; then
  echo
  echo "  ---- $W: the full disassembly, $_n instructions ----"
  sed -n '/Disassembly/,$p' "$W.dis" | sed 's/^/  /'
  echo "  ---- end $W ----"
else
  echo "  ($_n instructions -- too long to print; see the uploaded artifact)"
fi

echo "  $W: $fail check(s) failed"
exit "$fail"
