#!/bin/sh
# stages/1-self-assembly/roundtrip.sh
#
#   ./stages/1-self-assembly/roundtrip.sh [pinned-toolchain-dir]
#                                          default: build/toolchains/pinned
#
# THE DEEP VERIFICATION: prove the committed Stage 1 binaries match their
# sources by round-trip disassembly under TWO independent, PINNED decoders
# -- GNU binutils 2.47 (built from source by the host compiler; tier 2,
# verification-side only) and LLVM 22.1.8 (the upstream PREBUILT release;
# only llvm-objdump and llvm-mc are copied out, nothing is built).
#
# OPTIONAL LOCALLY, MANDATORY IN CI. Nothing stage 1 produces needs this
# script: rebaseline.sh derives and gates the committed binaries with no
# toolchain at all, and every later stage consumes those. This script is
# the extra, deeper proof -- run it locally when you want it (one network
# fetch + ~15 min cold, cached after), while CI runs it on EVERY change
# under stages/1-self-assembly/ without exception.
#
# THE CHECKS, BY THEIR REAL NAMES. The engine (tools/roundtrip.sh, shared
# with the live spike gate and therefore not edited -- 7.0) still prints
# its historical spike-era letters; they map as:
#
#   A   reassemble    disassemble -> reassemble -> compare .text bytes:
#                     the disassembly DENOTES THE SAME MACHINE CODE
#   A2  reconstruct   the WHOLE ELF rebuilds from its own disassembly and
#                     section dumps, byte for byte -- the artifact itself
#   B   readback      normalised source vs normalised disassembly: a human
#                     reading the disassembly reads what the source says
#   C   crosscheck    the two independent decoders agree with EACH OTHER
#   E   plain-diff    canonical source == canonical disassembly under a
#                     plain `diff`, no normaliser at all
#
# The letters rename inside the engine at spike cutover, not before.
#
# What runs, in order:
#   0. PIN the toolchain: binutils 2.47 built from source (cross-configured
#      for aarch64 when the host is not aarch64), llvm-objdump + llvm-mc
#      copied from the llvmorg-22.1.8 release. Cached in the pinned dir; the
#      ONLY step that touches the network, and only on a cold cache. A
#      PINS.sha256 file is written on first fetch and enforced ever after.
#   1. LEG 1: assemble both sources with BOTH assemblers (pinned GNU as,
#      pinned llvm-mc), and link the GNU objects into the as+ld references.
#   2. ENGINE per binary: tools/roundtrip.sh <src> <ref> <P> -- the repo's
#      own generic engine: A disassemble->reassemble->compare .text,
#      A2 reconstruct the WHOLE ELF and compare, B normalised source vs
#      disassembly, E canonical plain diff. (GNU decoder; gating.)
#   3. LLVM LEGS + CROSSCHECK (the inline additions the engine lacks):
#      B against llvm-objdump, E against canonicalised llvm output, verbatim
#      under both decoders, and check C -- the two decoders' canonical
#      streams must agree with each other.
#   4. TIE TO THE COMMITTED BINARIES: the committed artifact is gen1 (the
#      self-host build), not the as+ld reference, so its code bytes are the
#      committed file minus the 120-byte wrapper header, and they must
#      differ from the reference .text ONLY at the .bss-referencing adr
#      words (inbuf/symtab/outword) -- the gate-17 bound, applied to the
#      bytes actually committed. elf-wrapper's committed bytes get the same
#      treatment against its reference.
#
# Requires: python3, curl, xz, make, a C compiler (cold cache only), and
# nothing aarch64 about the host -- the pins are cross-configured, no qemu,
# nothing executes.

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SA_SRC="$HERE/self-assembler-arm64.s"
EW_SRC="$HERE/elf-wrapper-arm64.s"
SA_BIN="$HERE/self-assembler-arm64"
EW_BIN="$HERE/elf-wrapper-arm64"

BINUTILS_VER="${BINUTILS_VER:-2.47}"
LLVM_VER="${LLVM_VER:-22.1.8}"
ROUNDTRIP_BUDGET="${ROUNDTRIP_BUDGET:-0}"   # the ratchet: 0 = nothing may miss
P="${1:-$ROOT/build/toolchains/pinned}"
P="$(mkdir -p "$P" && cd "$P" && pwd)"

case "$(uname -m)" in
  aarch64) CROSS="";  LLVM_ASSET="Linux-ARM64" ;;
  x86_64)  CROSS="aarch64-linux-gnu"; LLVM_ASSET="Linux-X64" ;;
  *) echo "FAIL: unhandled host $(uname -m)"; exit 1 ;;
esac

# ---- 0. pin the toolchain (extracted from the spike gate; portabilized) ----
if [ -x "$P/bin/objdump" ] && [ -x "$P/bin/llvm-objdump" ]; then
  echo "  pinned toolchain: restored from $P"
else
  for t in curl xz make cc python3; do command -v "$t" >/dev/null 2>&1 || {
    echo "FAIL: cold cache needs '$t' (binutils build + llvm fetch)"; exit 1; }; done
  mkdir -p "$P/bin" "$P/src"
  echo "  --- GNU binutils $BINUTILS_VER, from source: no distro ships a"
  echo "      release this new, and the point is to control the version."
  curl -fsSL --retry 3 --max-time 600 \
    "https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz" \
    -o "$P/src/binutils.tar.xz"
  curl -fsSL --retry 3 --max-time 900 \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VER/LLVM-$LLVM_VER-$LLVM_ASSET.tar.xz" \
    -o "$P/src/llvm.tar.xz"
  # TRUST ON FIRST FETCH, ENFORCED EVER AFTER. The spike gate fetched with no
  # digest at all; here the first fetch records PINS.sha256 and every later
  # cold cache must reproduce it. Pre-seed the file from a trusted source to
  # remove even the first-fetch trust.
  if [ -f "$HERE/PINS.sha256" ]; then
    (cd "$P/src" && sha256sum -c "$HERE/PINS.sha256")
  else
    (cd "$P/src" && sha256sum binutils.tar.xz llvm.tar.xz) > "$HERE/PINS.sha256"
    echo "  RECORDED first-fetch digests -> PINS.sha256 (commit it):"
    sed 's/^/    /' "$HERE/PINS.sha256"
  fi
  tar -C "$P/src" -xf "$P/src/binutils.tar.xz"
  mkdir -p "$P/src/b" && ( cd "$P/src/b" && \
    "../binutils-$BINUTILS_VER/configure" --prefix="$P" \
      ${CROSS:+--target=$CROSS} \
      --disable-nls --disable-gdb --disable-gdbserver \
      --disable-sim --disable-werror > configure.log 2>&1 && \
    make -j"$(nproc)" > build.log 2>&1 && make install > install.log 2>&1 ) || {
      echo "  binutils build FAILED -- last 20 lines:"; \
      tail -20 "$P/src/b/build.log" 2>/dev/null | sed 's/^/    /'; exit 1; }
  # Cross builds prefix every tool; give the extracted checks the plain names.
  if [ -n "$CROSS" ]; then
    for t in as ld objdump objcopy readelf nm; do
      [ -e "$P/bin/$t" ] || ln -s "$CROSS-$t" "$P/bin/$t"
    done
  fi
  tar -C "$P/src" -xf "$P/src/llvm.tar.xz"
  for t in llvm-objdump llvm-mc; do
    cp "$(find "$P/src" -name "$t" -type f | head -1)" "$P/bin/"
  done
  rm -rf "$P/src/binutils-$BINUTILS_VER" "$P/src/b" "$P"/src/LLVM-*
fi
echo "  --- versions now pinned ---"
"$P/bin/as" --version | head -1 | sed 's/^/    /'
"$P/bin/objdump" --version | head -1 | sed 's/^/    /'
"$P/bin/llvm-objdump" --version | grep -i version | head -1 | sed 's/^/    /'
"$P/bin/llvm-mc" --version | grep -i version | head -1 | sed 's/^/    /'

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$W"
fail=0

for pair in "sa $SA_SRC $SA_BIN" "ew $EW_SRC $EW_BIN"; do
  set -- $pair
  N="$1"; SRC="$2"; COMMITTED="$3"
  echo
  echo "================ $(basename "$SRC") ================"

  # ---- 1. LEG 1: both assemblers, then the as+ld reference ----
  "$P/bin/as" -o "$N-ref.o" "$SRC"   # the FILE symbol lands in the linked
                                     # symtab; the engine rebuilds as $W.o,
                                     # so the names must agree or A2's
                                     # whole-binary compare differs on it
  "$P/bin/llvm-mc" -triple=aarch64-linux-gnu -filetype=obj \
    -o "$N-llvm.o" "$SRC" 2> "$N-llvm-mc.err" || true
  [ -s "$N-llvm.o" ] || { echo "  llvm-mc could not assemble the source:"; \
    head -3 "$N-llvm-mc.err" | sed 's/^/    /'; fail=$((fail+1)); }
  "$P/bin/ld" -static -o "$N-ref" "$N-ref.o"
  printf '  %-14s %8s  %s  (pinned as+ld reference)\n' "$N-ref" \
    "$(wc -c < "$N-ref")" "$(sha256sum "$N-ref" | cut -c1-16)"

  # ---- 2. the engine: checks A, A2, B, E under the pinned GNU decoder ----
  ( cd "$ROOT" && tools/roundtrip.sh "$SRC" "$W/$N-ref" "$P" ) || fail=$((fail+$?))

  # ---- 3. LLVM legs + crosscheck (extracted from the spike gate) ----
  "$P/bin/objdump" -d "$N-ref" > "$N.dis"
  "$P/bin/llvm-objdump" -d "$N-ref" > "$N.llvm.dis"
  rc_gnu=0; rc_llvm=0
  set +e
  echo "  ...B against GNU objdump $BINUTILS_VER:"
  ( cd "$ROOT" && python3 tools/s0_roundtrip.py "$SRC" "$W/$N.dis" \
      --budget "$ROUNDTRIP_BUDGET" ); rc_gnu=$?
  echo "  ...B against llvm-objdump $LLVM_VER:"
  ( cd "$ROOT" && python3 tools/s0_roundtrip.py "$SRC" "$W/$N.llvm.dis" \
      --budget "$ROUNDTRIP_BUDGET" ); rc_llvm=$?
  echo "  --- E under llvm-objdump, canonicalised ---"
  "$P/bin/llvm-objdump" -d --no-show-raw-insn --no-leading-addr \
    "$N-ref" > "$N.canon.llvm.dis" 2>/dev/null || \
    "$P/bin/llvm-objdump" -d --no-show-raw-insn "$N-ref" > "$N.canon.llvm.dis"
  ( cd "$ROOT" && python3 tools/s0_canon.py source "$SRC" ) > "$N.canon.src"
  ( cd "$ROOT" && python3 tools/s0_canon.py disasm "$W/$N.canon.llvm.dis" ) \
      > "$N.canon.llvm.txt"
  ndd=$(diff "$N.canon.src" "$N.canon.llvm.txt" | grep -c '^[<>]' || true)
  if [ "$ndd" = 0 ]; then
    echo "    IDENTICAL ($(wc -l < "$N.canon.src") canonical lines)"
  else
    echo "    $ndd differing canonical lines vs llvm-objdump:"
    ( cd "$ROOT" && python3 tools/s0_canon.py classify \
        "$W/$N.canon.src" "$W/$N.canon.llvm.txt" ) | sed 's/^/      /'
    fail=$((fail+1))
  fi
  echo "  --- verbatim, both decoders ---"
  ( cd "$ROOT" && python3 tools/s0_roundtrip.py verbatim "$SRC" "$W/$N.dis" )
  ( cd "$ROOT" && python3 tools/s0_roundtrip.py verbatim "$SRC" "$W/$N.llvm.dis" )
  echo "  --- C. do the two disassemblers agree with each other? ---"
  ( cd "$ROOT" && python3 tools/s0_roundtrip.py crosscheck \
      "$W/$N.dis" "$W/$N.llvm.dis" ) || fail=$((fail+1))
  set -e
  if [ "$rc_gnu" != 0 ] || [ "$rc_llvm" != 0 ]; then
    echo "  round-trip budget exceeded (gnu rc=$rc_gnu, llvm rc=$rc_llvm)"
    fail=$((fail+1))
  fi

  # ---- 4. tie to the COMMITTED binary ----
  # The committed artifact is gen1: its code bytes are the file minus the
  # 120-byte wrapper header, and they may differ from the reference .text
  # ONLY at the .bss-referencing adr words (the gate-17 bound).
  if [ -f "$COMMITTED" ]; then
    "$P/bin/objcopy" -O binary --only-section=.text "$N-ref" "$N-ref.text"
    tail -c +121 "$COMMITTED" > "$N-committed.code"
    head -c "$(wc -c < "$N-ref.text")" "$N-committed.code" > "$N-committed.text"
    tb=$("$P/bin/objdump" -h "$N-ref" | awk '$2==".text"{print $4; exit}')
    nd=$(cmp -l "$N-committed.text" "$N-ref.text" 2>/dev/null \
         | awk '{print int(($1-1)/4)}' | sort -u | wc -l)
    # THE BOUND IS DERIVED, NOT HARDCODED: every symbol the binary defines
    # outside .text (data/bss), read from the binary itself -- so the check
    # is right for any Stage 1 artifact without a per-binary list.
    dsyms=$("$P/bin/objdump" -t "$N-ref" | awk '$4!=".text" && $NF ~ /^[a-z_]/ {print $NF}'             | sort -u | paste -sd'|' -)
    nb=$(cmp -l "$N-committed.text" "$N-ref.text" 2>/dev/null \
         | awk '{print int(($1-1)/4)}' | sort -un \
         | while read -r w; do
             a=$(printf '%x' $((0x$tb + w * 4)))
             grep -m1 "^ *$a:" "$N.dis"
           done | grep -cE "adr.*<(${dsyms:-NONE})>" || true)
    printf '  committed vs reference .text: %s differing words (bound: .bss/.data adr only)\n' "$nd"
    if [ "$nd" != "$nb" ] || [ "$nd" -gt 7 ]; then
      echo "  FAIL: committed bytes diverge beyond the data-addressing bound:"
      cmp -l "$N-committed.text" "$N-ref.text" 2>/dev/null \
        | awk '{print int(($1-1)/4)}' | sort -un | head -8 \
        | while read -r w; do
            a=$(printf '%x' $((0x$tb + w * 4)))
            grep -m1 "^ *$a:" "$N.dis" | sed 's/^/    /'
          done
      fail=$((fail+1))
    else
      echo "  PASS: the committed code bytes are the reference's, modulo the"
      echo "        declared data-layout adr words."
    fi
  else
    echo "  SKIP committed tie: $COMMITTED not committed yet"
  fi
done

echo
if [ "$fail" = 0 ]; then
  echo "ROUND-TRIP: both sources match their binaries under BOTH pinned"
  echo "decoders (binutils $BINUTILS_VER, LLVM $LLVM_VER); committed bytes tied."
else
  echo "ROUND-TRIP: $fail check(s) FAILED"
fi
exit "$fail"
