#!/bin/sh
# stages/3-micro-c/cross-amd64.sh -- THE CROSS: from tcc-arm64 to tcc-amd64,
# the artifact stage 4 actually consumes. Extracted from
# stage0-stage4-complete-amd64.yml (the TRUE zero-budget form). One script,
# both homes; the primary home is the aarch64 CI runner, where tcc-arm64
# executes natively.
#
#     sh stages/3-micro-c/cross-amd64.sh            in + chain
#     sh stages/3-micro-c/cross-amd64.sh in         musl fetch only (network)
#     sh stages/3-micro-c/cross-amd64.sh chain      hermetic
#     sh stages/3-micro-c/cross-amd64.sh records    re-emit without rebuild
#
# THE LADDER (names by target, per the naming decision):
#   RUNG     tcc-arm64 builds an aarch64 musl + libtcc1.a   -> sys/aarch64
#   CROSS 1  tcc-arm64 compiles tcc.c -DTCC_TARGET_X86_64 against that
#            sysroot -> tcc-arm64-to-amd64: an AARCH64 binary that EMITS
#            x86_64 (the file check asserts exactly that)
#   CROSS 2  tcc-arm64-to-amd64 builds an x86_64 musl + libtcc1.a
#   CROSS 3  it compiles tcc.c once more against those
#            -> tcc-amd64: x86_64, static, no host gcc in its history
#
# DECLARED DIVERGENCE FROM THE SPIKE: the spike's aarch64 libc rung runs
# spikes/stage4/bridge/rungs.sh (5,367 lines -- the whole bridge ladder).
# The cross needs only libc + crt + libtcc1, so this script builds the
# aarch64 sysroot with the SAME minimal recipe CROSS 2 uses, retargeted.
# Consequence, stated plainly: the official tcc-amd64 may differ in bytes
# from the spike's tcc-x86_64. The spike's sha was never a committed oracle;
# the official numbers are what THIS chain mints, gated by determinism
# across runs (the compare gate) and by behavior (the x86_64 verify job runs
# the compiler natively).
#
# INPUT RESOLUTION: tcc-arm64 comes from out/3/aarch64/, and its sha256 must
# equal the one in the committed stages/3-micro-c/substages.toml -- the
# cross consumes the recorded contract, not whatever file happens to exist.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do
  ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/sources/tcc.toml" ] || { echo "FAIL: no repo root above $HERE"; exit 1; }
cd "$ROOT"

MUSL_VER="${MUSL_VER:-1.2.5}"
PHASE="${1:-all}"
IN="$ROOT/in/3"
B="$ROOT/build/3/x86_64"
OUT="$ROOT/out/3/x86_64"
AOUT="$ROOT/out/3/aarch64"

# The chain executes tcc-arm64 (an aarch64 binary). Same three worlds as
# build.sh; VERON_RUNNER overrides.
if [ -n "${VERON_RUNNER:-}" ]; then RUN="$VERON_RUNNER"
elif [ "$(uname -o 2>/dev/null)" = Android ]; then
  command -v qemu-aarch64 >/dev/null 2>&1 && RUN=qemu-aarch64 || {
    echo "FAIL: Android needs qemu-aarch64 (pkg install qemu-user-aarch64)"; exit 1; }
elif [ "$(uname -m)" = aarch64 ]; then RUN=""
elif [ -x spikes/toolbox/qemu-aarch64-static ]; then RUN="$ROOT/spikes/toolbox/qemu-aarch64-static"
else echo "FAIL: need aarch64 or the toolbox qemu"; exit 1; fi
run() { ${RUN:+"$RUN"} "$@"; }
art() { printf '    %-22s %10s bytes  %s\n' "$1" "$(wc -c < "$2")" \
        "$(sha256sum "$2" | cut -c1-16)"; }

# =========================================================================
# IN -- the musl source, mirrored fetch, digest recorded then enforced
# =========================================================================
do_in() {
  mkdir -p "$IN"
  if [ -s "$IN/musl-$MUSL_VER.tar.gz" ] && [ -f "$HERE/MUSL-PINS.sha256" ] \
     && ( cd "$IN" && sha256sum -c "$HERE/MUSL-PINS.sha256" --quiet ); then
    echo "  musl-$MUSL_VER.tar.gz already present and pinned"
    return 0
  fi
  for m in https://musl.libc.org/releases \
           https://distfiles.macports.org/musl \
           https://ftp.barfooze.de/pub/sabotage/tarballs; do
    curl -fsSL --retry 3 -o "$IN/musl-$MUSL_VER.tar.gz" \
      "$m/musl-$MUSL_VER.tar.gz" && [ -s "$IN/musl-$MUSL_VER.tar.gz" ] && break
    rm -f "$IN/musl-$MUSL_VER.tar.gz"
  done
  [ -s "$IN/musl-$MUSL_VER.tar.gz" ] \
    || { echo "FAIL: no musl-$MUSL_VER.tar.gz from any mirror"; exit 1; }
  if [ -f "$HERE/MUSL-PINS.sha256" ]; then
    ( cd "$IN" && sha256sum -c "$HERE/MUSL-PINS.sha256" )
  else
    ( cd "$IN" && sha256sum "musl-$MUSL_VER.tar.gz" ) > "$HERE/MUSL-PINS.sha256"
    echo "  RECORDED musl digest -> stages/3-micro-c/MUSL-PINS.sha256 (commit it):"
    sed 's/^/    /' "$HERE/MUSL-PINS.sha256"
  fi
}

# One musl build, parameterized by target -- the CROSS 2 recipe, used for
# both rungs so the two sysroots are built the same declared way.
#   musl_build <target> <CC-invocation-with-runner> <sysroot-dir>
musl_build() {
  _t="$1"; _cc="$2"; _sys="$3"
  rm -rf "$B/m-$_t" "$B/bld-$_t" "$_sys"
  mkdir -p "$B/m-$_t"
  tar -xzf "$IN/musl-$MUSL_VER.tar.gz" -C "$B/m-$_t" --strip-components=1
  ( cd "$B/m-$_t"
    rm -f src/complex/*.c
    rm -f "src/math/$_t"/*  2>/dev/null || true
    [ "$_t" = x86_64 ] && sed -i 's/@PLT//g' src/signal/x86_64/sigsetjmp.s
    true )
  # tcc has -ar; musl's makefile wants AR and RANLIB as programs
  printf '#!/bin/sh\nexec %s -ar "$@"\n' "$_cc" > "$B/$_t-ar"
  printf '#!/bin/sh\nexit 0\n' > "$B/$_t-ranlib"
  chmod +x "$B/$_t-ar" "$B/$_t-ranlib"
  mkdir -p "$B/bld-$_t"
  ( cd "$B/bld-$_t" && "$B/m-$_t/configure" --target="$_t" \
      --disable-shared --prefix="$_sys" CC="$_cc" > cfg.log 2>&1 ) \
    || { echo "  musl configure ($_t) failed:"; tail -8 "$B/bld-$_t/cfg.log" | sed 's/^/    /'; exit 1; }
  ( cd "$B/bld-$_t" && timeout 1800 make -j"$(nproc)" \
      AR="$B/$_t-ar" RANLIB="$B/$_t-ranlib" > b.log 2>&1 \
    && make install AR="$B/$_t-ar" RANLIB="$B/$_t-ranlib" >> b.log 2>&1 ) \
    || { echo "  musl build ($_t) failed:"
         grep -aE "^[^ ]*\.(c|s|S):[0-9]+" "$B/bld-$_t/b.log" | head -8 | sed 's/^/    /'
         tail -8 "$B/bld-$_t/b.log" | sed 's/^/    /'; exit 1; }
  for f in lib/libc.a lib/crt1.o lib/crti.o lib/crtn.o; do
    [ -s "$_sys/$f" ] || { echo "  FAIL: sysroot ($_t) missing $f"; exit 1; }
  done
  echo "    sys/$_t: libc.a $(wc -c < "$_sys/lib/libc.a") bytes + crt trio"
}

# libtcc1 for a target -- THE FILE LIST IS PER-TARGET, exactly as the
# spike has it: arm64's runtime is lib-arm64.c + 4 (box step 10b, "5 of 5
# objects"); x86_64's is libtcc1.c + 6 (the CROSS 2 list). The first
# release used the x86_64 list for both and died on libtcc1.c's
# "#error unsupported CPU type" -- the CPU dispatch in that file simply
# does not include arm64 at this tcc version.
#   libtcc1_build <target> <CC-invocation> <out-archive>
libtcc1_build() {
  _t="$1"; _cc="$2"; _a="$3"
  case "$_t" in
    aarch64) _files="lib-arm64.c stdatomic.c builtin.c atomic.S alloca.S"
             _flags="-B$IN/tcc-src -I$IN/tcc-src -I$IN/tcc-src/include"
             _min=5 ;;
    x86_64)  _files="libtcc1.c alloca.S alloca-bt.S stdatomic.c atomic.S builtin.c va_list.c"
             _flags="-I. -Iinclude"
             _min=4 ;;
    *) echo "  FAIL: no libtcc1 recipe for $_t"; exit 1 ;;
  esac
  ( cd "$IN/tcc-src"
    rm -f "$B"/lt_"$_t"_*.o
    _n=0
    for f in $_files; do
      [ -f "lib/$f" ] || continue
      $_cc $_flags -c "lib/$f" -o "$B/lt_${_t}_$(echo "$f" | tr './' '__').o" \
        > "$B/lt-$_t.log" 2>&1 \
        || { echo "  lib/$f ($_t) did not compile:"
             tail -6 "$B/lt-$_t.log" | sed 's/^/    /'; exit 1; }
      _n=$((_n + 1))
    done
    [ "$_n" -ge "$_min" ] || { echo "  only $_n libtcc1 objects ($_t), want $_min"; exit 1; }
    $_cc -ar rcs "$_a" "$B"/lt_"$_t"_*.o >> "$B/lt-$_t.log" 2>&1 \
      || { echo "  ar failed ($_t):"; tail -4 "$B/lt-$_t.log" | sed 's/^/    /'; exit 1; }
    echo "    libtcc1 ($_t): $_n objects, $(wc -c < "$_a") bytes" )
}

# =========================================================================
# CHAIN
# =========================================================================
do_chain() {
  [ -s "$IN/musl-$MUSL_VER.tar.gz" ] || { echo "FAIL: run the in phase"; exit 1; }
  [ -d "$IN/tcc-src" ] || { echo "FAIL: run build.sh in first (tcc-src)"; exit 1; }
  TA="$AOUT/tcc-arm64"
  [ -x "$TA" ] || { echo "FAIL: no $TA -- run build.sh chain first"; exit 1; }
  # THE CONTRACT CHECK: consume the recorded artifact, not a stray file
  want=$(python3 -c "
import tomllib
d = tomllib.load(open('stages/3-micro-c/substages.toml','rb'))
for s in d['substage']:
    if s['id'] == '3/4/tcc-arm64': print(s['output'][0]['sha256'])" 2>/dev/null || true)
  got=$(sha256sum "$TA" | cut -d' ' -f1)
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    echo "FAIL: out/3/aarch64/tcc-arm64 ($got)"
    echo "      does not match the committed record ($want)"; exit 1
  fi
  [ -n "$want" ] && echo "  tcc-arm64 matches the committed record ($got)" \
                 || echo "  (no committed record yet; consuming $got)"
  rm -rf "$B" && mkdir -p "$B" "$OUT"
  TCC() { run "$TA" "$@"; }

  echo "== RUNG: tcc-arm64 builds its own aarch64 sysroot =="
  libtcc1_build aarch64 "run $TA" "$B/aarch64-libtcc1.a"
  musl_build aarch64 "$RUN $TA" "$B/sys-aarch64"

  echo "== CROSS 1: tcc-arm64 builds the compiler that emits x86_64 =="
  A="$B/sys-aarch64"
  ( cd "$IN/tcc-src" && run "$TA" -o "$B/tcc-arm64-to-amd64" \
      -DONE_SOURCE=1 -DTCC_TARGET_X86_64 -DCONFIG_TCC_STATIC=1 \
      -I. -static -nostdinc -nostdlib -I"$A/include" \
      "$A/lib/crt1.o" "$A/lib/crti.o" tcc.c "$A/lib/libc.a" \
      "$B/aarch64-libtcc1.a" "$A/lib/crtn.o" > "$B/x1.log" 2>&1 ) \
    || { echo "  FAIL: CROSS 1 (rc=$?):"
         grep -aiE "error|undefined|not found" "$B/x1.log" | head -12 | sed 's/^/    /'; exit 1; }
  case "$(file -b "$B/tcc-arm64-to-amd64")" in
    *aarch64*|*"ARM aarch64"*) : ;;
    *) echo "  FAIL: tcc-arm64-to-amd64 must be an aarch64 binary that emits x86_64"
       file -b "$B/tcc-arm64-to-amd64"; exit 1 ;;
  esac
  art tcc-arm64-to-amd64 "$B/tcc-arm64-to-amd64"
  XT() { run "$B/tcc-arm64-to-amd64" "$@"; }

  echo "== CROSS 2: that compiler builds the x86_64 sysroot =="
  libtcc1_build x86_64 "run $B/tcc-arm64-to-amd64" "$B/x86_64-libtcc1.a"
  musl_build x86_64 "$RUN $B/tcc-arm64-to-amd64" "$B/sys-x86_64"

  echo "== CROSS 3: tcc-amd64 -- x86_64, static, no host gcc in its history =="
  S="$B/sys-x86_64"
  ( cd "$IN/tcc-src" && run "$B/tcc-arm64-to-amd64" -o "$B/tcc-amd64" \
      -DONE_SOURCE=1 -DTCC_TARGET_X86_64 -DCONFIG_TCC_STATIC=1 \
      -I. -static -nostdinc -nostdlib -I"$S/include" \
      "$S/lib/crt1.o" "$S/lib/crti.o" tcc.c "$S/lib/libc.a" \
      "$B/x86_64-libtcc1.a" "$S/lib/crtn.o" > "$B/g2.log" 2>&1 ) \
    || { echo "  FAIL: CROSS 3 (rc=$?):"
         grep -aiE "error|undefined|not found" "$B/g2.log" | head -12 | sed 's/^/    /'; exit 1; }
  case "$(file -b "$B/tcc-amd64")" in
    *x86-64*|*x86_64*) : ;;
    *) echo "  FAIL: wrong target"; file -b "$B/tcc-amd64"; exit 1 ;;
  esac
  case "$(file -b "$B/tcc-amd64")" in
    *"dynamically linked"*) echo "  FAIL: not static"; exit 1 ;;
  esac
  chmod 0755 "$B/tcc-amd64"

  # publish the contracts: the compiler, its runtime, and the sysroot it
  # was linked against (stage 4 consumes all three)
  cp "$B/tcc-amd64" "$B/tcc-arm64-to-amd64" "$B/x86_64-libtcc1.a" "$OUT/"
  tar -czf "$OUT/sys-x86_64.tar.gz" -C "$B" sys-x86_64
  echo
  echo "== STAGE 3 (amd64 leg) OUTPUT =="
  printf '  %-20s %10s bytes  sha256 %s  mode %s\n' tcc-amd64 \
    "$(wc -c < "$OUT/tcc-amd64")" "$(sha256sum "$OUT/tcc-amd64" | cut -d' ' -f1)" \
    "$(stat -c %04a "$OUT/tcc-amd64")"
  emit_records
}

# =========================================================================
# RECORDS -- 3/5..3/8, same discipline: generated by the run
# =========================================================================
fact() { printf 'sha256 = "%s"\nbytes  = %s\n' \
         "$(sha256sum "$1" | cut -d" " -f1)" "$(wc -c < "$1")"; }
inp() { printf '\n[[substage.input]]\nrole   = "%s"\nname   = "%s"\n' "$1" "$2"
  fact "$3"; }
outp() { printf '\n[[substage.output]]\npath   = "%s"\n' "$1"
  fact "$2"; printf 'mode   = "%s"\n' "$(stat -c %04a "$2")"; }
emit_records() {
  RT="$OUT/substages.toml"
  TA_SHA=$(sha256sum "$AOUT/tcc-arm64" | cut -d' ' -f1)
  X_SHA=$(sha256sum "$B/tcc-arm64-to-amd64" | cut -d' ' -f1)
  {
  printf '# stage 3 amd64-leg records -- GENERATED by cross-amd64.sh.\n'

  printf '\n[[substage]]\nid = "3/5/sysroot-aarch64"\nstage = 3\narch = "aarch64"\nflavor = "trunk"\nroot = "repo"\n'
  inp source "musl-$MUSL_VER.tar.gz" "$IN/musl-$MUSL_VER.tar.gz"
  printf '\n[[substage.input]]\nrole   = "builder"\nref    = "3/4/tcc-arm64"\nsha256 = "%s"\n' "$TA_SHA"
  outp "build/3/x86_64/sys-aarch64/lib/libc.a" "$B/sys-aarch64/lib/libc.a"
  outp "build/3/x86_64/aarch64-libtcc1.a" "$B/aarch64-libtcc1.a"

  printf '\n[[substage]]\nid = "3/6/tcc-arm64-to-amd64"\nstage = 3\narch = "x86_64"\nflavor = "trunk"\nroot = "repo"\n'
  inp source "tcc.c (pinned tree + tcc-veron.patch)" "$IN/tcc-src/tcc.c"
  printf '\n[[substage.input]]\nrole   = "builder"\nref    = "3/4/tcc-arm64"\nsha256 = "%s"\n' "$TA_SHA"
  printf '\n[[substage.input]]\nrole   = "tool"\nref    = "3/5/sysroot-aarch64"\nsha256 = "%s"\n' "$(sha256sum "$B/sys-aarch64/lib/libc.a" | cut -d' ' -f1)"
  outp "out/3/x86_64/tcc-arm64-to-amd64" "$OUT/tcc-arm64-to-amd64"

  printf '\n[[substage]]\nid = "3/7/sysroot-x86_64"\nstage = 3\narch = "x86_64"\nflavor = "trunk"\nroot = "repo"\n'
  inp source "musl-$MUSL_VER.tar.gz" "$IN/musl-$MUSL_VER.tar.gz"
  printf '\n[[substage.input]]\nrole   = "builder"\nref    = "3/6/tcc-arm64-to-amd64"\nsha256 = "%s"\n' "$X_SHA"
  outp "out/3/x86_64/sys-x86_64.tar.gz" "$OUT/sys-x86_64.tar.gz"
  outp "out/3/x86_64/x86_64-libtcc1.a" "$OUT/x86_64-libtcc1.a"

  printf '\n[[substage]]\nid = "3/8/tcc-amd64"\nstage = 3\narch = "x86_64"\nflavor = "trunk"\nroot = "repo"\n'
  inp source "tcc.c (pinned tree + tcc-veron.patch)" "$IN/tcc-src/tcc.c"
  printf '\n[[substage.input]]\nrole   = "builder"\nref    = "3/6/tcc-arm64-to-amd64"\nsha256 = "%s"\n' "$X_SHA"
  printf '\n[[substage.input]]\nrole   = "tool"\nref    = "3/7/sysroot-x86_64"\nsha256 = "%s"\n' "$(sha256sum "$OUT/sys-x86_64.tar.gz" | cut -d' ' -f1)"
  outp "out/3/x86_64/tcc-amd64" "$OUT/tcc-amd64"
  } > "$RT"
  echo "  records emitted: $RT ($(grep -c '^\[\[substage\]\]' "$RT") substages)"
  if [ -f "$HERE/substages-amd64.toml" ]; then
    if cmp -s "$RT" "$HERE/substages-amd64.toml"; then
      echo "  records MATCH the committed stages/3-micro-c/substages-amd64.toml"
    else
      echo "  FAIL: emission drifted from the committed amd64 record:"
      diff "$HERE/substages-amd64.toml" "$RT" | head -20
      exit 1
    fi
  fi
}

case "$PHASE" in
  in)      do_in ;;
  chain)   do_chain ;;
  records) emit_records ;;
  all)     do_in; do_chain ;;
  *) echo "usage: cross-amd64.sh [in|chain|records]"; exit 2 ;;
esac
