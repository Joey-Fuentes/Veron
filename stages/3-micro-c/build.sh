#!/bin/sh
# stages/3-micro-c/build.sh -- the REAL stage-3 build: micro-c born of the
# bootstrap, then micro-c compiles tcc, our M1 and hex2 link it. Extracted
# from .github/workflows/stage0-stage4-complete-amd64.yml -- the TRUE
# zero-budget form (stage4-arch-spike-* starts from host gcc and is never a
# source for the official tree). One script, both homes.
#
#     sh stages/3-micro-c/build.sh            in/ phase + chain
#     sh stages/3-micro-c/build.sh in         in/ phase only (the only part
#                                             that may touch the network)
#     sh stages/3-micro-c/build.sh chain      chain only (hermetic)
#
# INPUT RESOLUTION (design 3.4): stage 2's artifacts come from
# out/2/aarch64/, produced by stages/2-pico-c/verify.sh against its records.
# Stage 1's binaries are committed. Nothing here reads spikes/ except the
# three vendored fallbacks below, each printed loudly as PIN-FALLBACK.
#
# PIN-TRUE vs PIN-FALLBACK. Two inputs are pinned to commits the repo does
# not vendor at that exact pin:
#     mescc-tools  MESCC_SHA  5adfbf3   (reference vendors 4262d48)
#     M2libc       M2LIBC_SHA 68a23cfd  (reference vendors ca023d8)
# With network, the in/ phase fetches the true pins via clone_pinned. Without
# it, the reference copies are used and every artifact hash printed by this
# run is a LOGIC PROOF, not the official number -- the banner says which.
# Official numbers are whatever the pin-true run mints into substages.toml.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do
  ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/sources/tcc.toml" ] || { echo "FAIL: no repo root above $HERE"; exit 1; }
cd "$ROOT"

MESCC_SHA=5adfbf3d21b0d3fe93f76c7d99d35d418e630d7a  # workflow env: 5adfbf3
M2LIBC_SHA=68a23cfd05d5a355ba7a30c770d684cbe86fcc4e
PHASE="${1:-all}"
IN="$ROOT/in/3"
B="$ROOT/build/3/aarch64"
OUT="$ROOT/out/3/aarch64"
PINTRUE=yes

if [ "$(uname -m)" = aarch64 ]; then RUN=""
elif [ -x spikes/toolbox/qemu-aarch64-static ]; then RUN="$ROOT/spikes/toolbox/qemu-aarch64-static"
else echo "FAIL: need aarch64 or the toolbox qemu"; exit 1; fi
run() { ${RUN:+"$RUN"} "$@"; }
art() { printf '    %-28s %10s bytes  %s\n' "$1" "$(wc -c < "$2")" \
        "$(sha256sum "$2" | cut -c1-16)"; }

# =========================================================================
# IN -- everything that may touch a network, and every vendored fallback
# =========================================================================
do_in() {
  mkdir -p "$IN"

  echo "== in/3: tcc-src = toolbox tarball + the series (CI's own base) =="
  rm -rf "$IN/tcc-src"
  mkdir -p "$IN/tcc-src"
  tar -xzf spikes/toolbox/tcc-5ec0e6f8-arm64-configured.tar.gz \
      -C "$IN/tcc-src" --strip-components=1
  [ -f "$IN/tcc-src/config.h" ] || { echo "FAIL: not the configured tarball"; exit 1; }
  for p in spikes/stage3/patches/tcc-arm64-asm/[0-9]*.patch \
           spikes/stage3/patches/tcc-microc/[0-9]*.patch; do
    git -C "$IN/tcc-src" apply --ignore-whitespace "$ROOT/$p" 2>/dev/null \
      || patch -p1 -d "$IN/tcc-src" -i "$ROOT/$p" >/dev/null \
      || { echo "FAIL: $(basename "$p") does not apply"; exit 1; }
  done
  grep -q '#include <float.h>' "$IN/tcc-src/tccgen.c" || { echo "FAIL: 0006 absent"; exit 1; }
  grep -q 'VT_VALMASK | VT_LVAL | VT_SYM)) == VT_CONST' "$IN/tcc-src/tccgen.c" \
    || { echo "FAIL: 0007 absent"; exit 1; }
  find "$IN/tcc-src" -name '*.rej' | grep -q . && { echo "FAIL: .rej present"; exit 1; }
  find "$IN/tcc-src" -name '*.orig' -delete
  echo "  tcc-src ready: $(ls "$IN"/tcc-src/*.c | wc -l) .c files"

  echo "== in/3: m2libc-veron = reference + the m2libc series =="
  rm -rf "$IN/m2libc-veron"
  cp -r spikes/reference/m2libc "$IN/m2libc-veron"
  git -C "$IN/m2libc-veron" init -q 2>/dev/null || true
  for p in spikes/stage3/patches/m2libc/[0-9]*.patch; do
    git -C "$IN/m2libc-veron" apply --ignore-whitespace "$ROOT/$p" \
      || { echo "FAIL: $(basename "$p")"; exit 1; }
  done
  grep -q '^DEFINE ret ' "$IN/m2libc-veron/aarch64/aarch64_defs.M1" \
    || { echo "FAIL: no DEFINE ret -- wrong tables"; exit 1; }
  grep -q 'define va_copy(ap1, ap2) ap1 = ap2' "$IN/m2libc-veron/stdarg.h" \
    || { echo "FAIL: va_copy patch absent"; exit 1; }
  echo "  m2libc (ours): $(grep -c '^DEFINE' "$IN/m2libc-veron/aarch64/aarch64_defs.M1") DEFINEs"

  echo "== in/3: M2libc at the pin (bootstrap.c + bootstrappable.c) =="
  rm -rf "$IN/m2libc-pin"
  if ( . tools/clone-pinned.sh \
       && clone_pinned "$IN/m2libc-pin" "$M2LIBC_SHA" \
            "https://github.com/oriansj/M2libc.git" ) 2>/dev/null; then
    echo "  M2libc @ $M2LIBC_SHA (pin-true)"
  else
    PINTRUE=no
    cp -r spikes/reference/m2libc "$IN/m2libc-pin"
    echo "  PIN-FALLBACK: reference m2libc (ca023d8) stands in for $M2LIBC_SHA"
  fi
  python3 tools/drop_asm.py "$IN/m2libc-pin/aarch64/linux/bootstrap.c" \
    > "$IN/patched_bootstrap.c"
  art 'patched_bootstrap.c' "$IN/patched_bootstrap.c"

  echo "== in/3: micro-c tree = the ADOPTED source (that is what adoption is for) =="
  rm -rf "$IN/microc" && mkdir -p "$IN/microc/M2libc"
  cp -r "$HERE/micro-c/." "$IN/microc/"
  # the flist names M2libc/bootstrappable.c; supply it at the pin's path
  cp "$IN/m2libc-pin/bootstrappable.c" "$IN/microc/M2libc/bootstrappable.c"
  S="$IN/microc/test/test1000/hello-aarch64.sh"
  sed -e ':a' -e '/\\$/{N; s/\\\n/ /; ta}' "$S" > "$IN/joined.sh"
  grep -m1 'bin/M2-Planet' "$IN/joined.sh" \
    | grep -oE -- '-f[[:space:]]+[^[:space:]]+' \
    | sed 's/^-f[[:space:]]*//' > "$IN/microc-srcs.txt"
  [ -s "$IN/microc-srcs.txt" ] || { echo "FAIL: empty -f list"; exit 1; }
  echo "  -f list: $(wc -l < "$IN/microc-srcs.txt") files (from the tree's own script)"

  echo "== in/3: mescc-tools at the pin, rewritten for pico-c =="
  rm -rf "$IN/mescc"
  if ( . tools/clone-pinned.sh \
       && clone_pinned "$IN/mescc" "$MESCC_SHA" \
            "https://github.com/oriansj/mescc-tools.git" ) 2>/dev/null; then
    echo "  mescc-tools @ $MESCC_SHA (pin-true)"
  else
    PINTRUE=no
    cp -r spikes/reference/mescc-tools "$IN/mescc"
    echo "  PIN-FALLBACK: reference mescc-tools (4262d48) stands in for 5adfbf3"
  fi
  # CI clones --recursive; clone_pinned does not do submodules. The include
  # closure folds M2libc/bootstrappable.h into the unit, so supply mescc's
  # M2libc from the M2libc pin explicitly (and say so -- it is a declared
  # substitution for the submodule, identical in the pin-true case).
  rm -rf "$IN/mescc/M2libc"
  cp -r "$IN/m2libc-pin" "$IN/mescc/M2libc"
  # source lists from upstream's own makefile -- three hand-written lists in
  # a row were wrong; the one they all missed was stringify.c
  MK="$IN/mescc/makefile"
  srcs() { grep -E "^bin/$1:" "$MK" | sed 's/|.*//' \
             | grep -o '[A-Za-z0-9_./-]*\.c' | awk '!seen[$0]++' \
             | grep -v 'bootstrappable\.c'; }
  order() { m=""; r=""
    for f in $1; do
      if grep -q '^int main(' "$IN/mescc/$f" 2>/dev/null; then m="$f"; else r="$r $f"; fi
    done; echo "$r $m"; }
  for t in M1 hex2; do
    out=$(order "$(srcs "$t")")
    [ -n "$(echo $out)" ] || { echo "FAIL: no $t sources derived"; exit 1; }
    h=$(python3 tools/include_closure.py "$IN/mescc" $out) \
      || { echo "FAIL: include closure for $t"; exit 1; }
    printf '%s\n' $h $out > "$IN/$t-srcs.txt"
    echo "  $t: $(wc -l < "$IN/$t-srcs.txt") files"
  done
  # M1's max_string default is 4096; tcc's keyword table is 19,571 chars
  grep -q 'max_string = 4096,' "$IN/mescc/M1-macro.c" \
    || { echo "FAIL: max_string anchor moved"; exit 1; }
  sed -i 's/max_string = 4096,/max_string = 262144,/' "$IN/mescc/M1-macro.c"
  rm -rf "$IN/mescc-oct" "$IN/mescc-s2"
  for t in M1 hex2; do
    python3 tools/octal_to_decimal.py "$IN/mescc" "$IN/mescc-oct" \
      $(cat "$IN/$t-srcs.txt") || { echo "FAIL: octal rewrite $t"; exit 1; }
  done
  for t in M1 hex2; do
    python3 tools/defines_to_enums.py "$IN/mescc-oct" "$IN/mescc-s2" \
      $(cat "$IN/$t-srcs.txt") || { echo "FAIL: defines rewrite $t"; exit 1; }
  done
  for t in M1 hex2; do
    while read -r f; do
      [ -f "$IN/mescc-s2/$f" ] || { echo "FAIL: mescc-s2/$f missing"; exit 1; }
    done < "$IN/$t-srcs.txt"
  done
  echo "  mescc-s2 ready (octal + defines rewritten)"
  echo "$PINTRUE" > "$IN/PIN-TRUE"
}

# =========================================================================
# CHAIN -- hermetic: nothing below touches a network or a host compiler
# =========================================================================
do_chain() {
  [ -f "$IN/PIN-TRUE" ] || { echo "FAIL: run the in/ phase first"; exit 1; }
  PINTRUE=$(cat "$IN/PIN-TRUE")
  SA="$ROOT/stages/1-self-assembly/self-assembler-arm64"
  EW="$ROOT/stages/1-self-assembly/elf-wrapper-arm64"
  PCA="$ROOT/out/2/aarch64/pico-c-assembler"
  PC="$ROOT/out/2/aarch64/pico-c"
  [ -x "$PCA" ] && [ -x "$PC" ] || {
    echo "FAIL: stage 2 artifacts absent -- run stages/2-pico-c/verify.sh"; exit 1; }
  rm -rf "$B" && mkdir -p "$B" "$OUT" && cd "$B"

  # ---- micro-c, born of the bootstrap (workflow phase 10) ----
  echo "== micro-c: pico-c compiles the whole unit, the ladder assembles it =="
  { cat "$IN/patched_bootstrap.c"
    cat "$ROOT/stages/2-pico-c/m2libc-shim.c"
    while read -r f; do
      case "$f" in
        M2libc/aarch64/linux/bootstrap.c) ;;
        M2libc/bootstrap.c) ;;
        *) cat "$IN/microc/$f" ;;
      esac
    done < "$IN/microc-srcs.txt"
  } > microc.c
  art 'microc.c (patched unit)' microc.c
  run "$PC"  < microc.c   > microc.s1
  run "$PCA" < microc.s1  > microc.s0
  run "$SA"  < microc.s0  > microc.bin
  run "$EW"  micro-c      < microc.bin
  [ -x micro-c ] && [ "$(wc -c < micro-c)" -gt 65536 ] \
    || { echo "FAIL: micro-c did not build"; exit 1; }
  art 'micro-c (ours)' micro-c

  # ---- M1 and hex2, built the same way (workflow build2) ----
  echo "== M1 and hex2: pico-c builds the linker pair =="
  for o in M1 hex2; do
    { cat "$IN/patched_bootstrap.c"
      cat "$ROOT/stages/2-pico-c/m2libc-shim.c"
      cat "$IN/m2libc-pin/bootstrappable.c"
      while read -r f; do cat "$IN/mescc-s2/$f"; done < "$IN/$o-srcs.txt"
    } > "$o.c"
    run "$PC"  < "$o.c"  > "$o.s1"
    run "$PCA" < "$o.s1" > "$o.s0"
    run "$SA"  < "$o.s0" > "$o.bin"
    run "$EW"  "$o"      < "$o.bin"
    [ -x "$o" ] && [ "$(wc -c < "$o")" -gt 4096 ] \
      || { echo "FAIL: $o did not build"; exit 1; }
    art "$o (ours)" "$o"
  done

  # ---- micro-c compiles tcc; our M1 and hex2 link it ----
  echo "== tcc: micro-c compiles it, three-section split, M1 + hex2 link =="
  MCFLAGS='--architecture aarch64 --max-string 65536'
  L="$ROOT/stages/3-micro-c/micro-c-libc"
  M="$IN/m2libc-veron"
  ( cd "$IN/tcc-src" && run "$B/micro-c" $MCFLAGS --expand-includes \
      -D ONE_SOURCE=1 -D TCC_TARGET_LINUX=1 \
      -D CONFIG_TCC_STATIC=1 -I . -I "$L" -I "$M" \
      -f tcc.c -o "$B/libtcc.M1" )
  echo "    libtcc.M1: $(wc -l < libtcc.M1) lines, $(grep -c '^:FUNCTION_' libtcc.M1) functions"
  run ./micro-c $MCFLAGS -I "$M" \
    -f "$M/stdio.h" -f "$M/stdio.c" -f "$M/bootstrappable.c" -o m2libc.M1
  run ./micro-c $MCFLAGS -I "$L" -f "$L/impl/runtime.c"      -o runtime.M1
  run ./micro-c $MCFLAGS -f "$L/impl/setjmp-aarch64.c"       -o setjmp.M1
  # THREE SECTIONS, NOT TWO -- a global holding a string is arbitrary-length
  # data between units, and every function after it lands misaligned: SIGBUS.
  : > tcc.code; : > tcc.glob; : > tcc.strs
  for f in libtcc.M1 m2libc.M1 runtime.M1 setjmp.M1; do
    sed '/^# Program global variables$/,$d' "$f" >> tcc.code
    sed -n '/^# Program global variables$/,/^# Program strings$/p' "$f" \
      | sed '/^# Program strings$/d' >> tcc.glob
    sed -n '/^# Program strings$/,$p' "$f" >> tcc.strs
  done
  cat tcc.code tcc.glob tcc.strs > tcc-all.M1
  A="$IN/m2libc-veron/aarch64"
  run ./M1 -f "$A/aarch64_defs.M1" -f "$A/libc-full.M1" \
           -f tcc-all.M1 --little-endian --architecture aarch64 \
           -o tcc-all.hex2
  run ./hex2 --architecture aarch64 --little-endian \
             --base-address 0x400000 -f "$A/ELF-aarch64.hex2" \
             -f tcc-all.hex2 -o mc-tcc
  chmod +x mc-tcc
  [ -x mc-tcc ] || { echo "FAIL: no mc-tcc"; exit 1; }

  # ---- gates: it runs, and it is a compiler ----
  v=$(run ./mc-tcc -v 2>&1 | head -1)
  echo "    mc-tcc -v: $v"
  case "$v" in *tcc*) : ;; *) echo "FAIL: mc-tcc does not announce itself"; exit 1 ;; esac

  cp mc-tcc "$OUT/mc-tcc"
  echo
  echo "== STAGE 3 (aarch64 leg) OUTPUT =="
  printf '  %-10s %10s bytes  sha256 %s  mode %s\n' mc-tcc \
    "$(wc -c < "$OUT/mc-tcc")" "$(sha256sum "$OUT/mc-tcc" | cut -d' ' -f1)" \
    "$(stat -c %04a "$OUT/mc-tcc")"
  if [ "$PINTRUE" = yes ]; then
    echo "  PIN-TRUE run: these are official numbers."
  else
    echo "  PIN-FALLBACK run: LOGIC PROOF ONLY -- official numbers come from"
    echo "  a run whose in/ phase fetched mescc@5adfbf3 and M2libc@68a23cfd."
  fi
}

case "$PHASE" in
  in)    do_in ;;
  chain) do_chain ;;
  all)   do_in; do_chain ;;
  *) echo "usage: build.sh [in|chain]"; exit 2 ;;
esac
