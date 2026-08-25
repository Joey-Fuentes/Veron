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
art() { printf '    %-22s %10s bytes  %s\n' "$1" "$(wc -c < "$2")" \
        "$(sha256sum "$2" | cut -c1-16)"; }

# =========================================================================
# IN -- the musl source, mirrored fetch, digest recorded then enforced
# =========================================================================
do_in() {
  mkdir -p "$IN"
  if [ -s "$IN/musl-$MUSL_VER.tar.gz" ] && [ -f "$HERE/MUSL-PINS.sha256" ] \
     && ( cd "$IN" && sha256sum -c "$HERE/MUSL-PINS.sha256" >/dev/null ); then
    echo "  musl-$MUSL_VER.tar.gz already present and pinned"
    return 0
  fi
  # OUR RELEASE FIRST: source tarballs live as GitHub releases on this repo
  # (the design's in/-from-our-releases rule), so the build never depends on
  # upstream hosting being awake -- musl.libc.org timing out cost a run 134
  # seconds PER ATTEMPT before this ordering. Upstream mirrors remain as
  # fallback; MUSL-PINS.sha256 makes every mirror equivalent by content.
  for m in "https://github.com/${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}/releases/download/sources" \
           https://distfiles.macports.org/musl \
           https://ftp.barfooze.de/pub/sabotage/tarballs \
           https://musl.libc.org/releases; do
    curl -fsSL --connect-timeout 15 --retry 2 -o "$IN/musl-$MUSL_VER.tar.gz" \
      "$m/musl-$MUSL_VER.tar.gz" && [ -s "$IN/musl-$MUSL_VER.tar.gz" ] && {
        echo "  fetched from $m"; break; }
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
  # musl's Makefile, EXECUTED BY HAND: the same object set in the same order
  # with the flags that mean anything to tcc, from INSIDE the source tree
  # with relative paths. No configure, no make. Three things this buys,
  # each measured (2026-08-25, x86_64 leg, against the runner's archive):
  #   - no make in stage 3, where nothing has built one yet; the budget
  #     stays busybox + the compiler this script was handed
  #   - no host path in any object: configure was invoked by absolute path,
  #     so srcdir was absolute, so every tcc -c wrote the host's directory
  #     into the STT_FILE symbol -- 1277 members, three hosts, three
  #     different libc.a digests, same code. Relative paths make one digest.
  #   - 1277 of 1277 members byte-identical to the make-driven build once
  #     that symbol is removed, and the tcc-amd64 linked from it identical
  #     to the record (090429cf...). The archive changed; the compiler did not.
  # Makefile line numbers below are musl-1.2.5's.
  _t="$1"; _cc="$2"; _sys="$3"; _w="$B/m-$_t"
  rm -rf "$_w" "$_sys"; mkdir -p "$_w"
  tar -xzf "$IN/musl-$MUSL_VER.tar.gz" -C "$_w" --strip-components=1
  ( cd "$_w"
    # ---- the source-tree edits the make-driven build made, kept, each stated ----
    rm -f src/complex/*.c                     # tcc has no _Complex
    rm -rf "src/math/$_t"                     # the arch math .s wants a GNU-syntax assembler
    [ "$_t" = x86_64 ] && sed -i 's/@PLT//g' src/signal/x86_64/sigsetjmp.s
    printf 'int _ldprobe[sizeof(long double) == 8 ? 1 : -1];\n' > "$B/ldsize-$_t.c"
    if $_cc -c -o "$B/ldsize-$_t.o" "$B/ldsize-$_t.c" 2>/dev/null \
       && [ -f "arch/$_t/bits/float.h" ]; then
      cat > "arch/$_t/bits/float.h" <<'FLOATH'
#define FLT_EVAL_METHOD 0

#define LDBL_TRUE_MIN 4.94065645841246544177e-324L
#define LDBL_MIN 2.22507385850720138309e-308L
#define LDBL_MAX 1.79769313486231570815e+308L
#define LDBL_EPSILON 2.22044604925031308085e-16L

#define LDBL_MANT_DIG 53
#define LDBL_MIN_EXP (-1021)
#define LDBL_MAX_EXP 1024

#define LDBL_DIG 15
#define LDBL_MIN_10_EXP (-307)
#define LDBL_MAX_10_EXP 308

#define DECIMAL_DIG 17
FLOATH
      echo "    bits/float.h ($_t): rewritten -- this compiler's long double is 8 bytes"
    else
      echo "    bits/float.h ($_t): left alone"
    fi
    rm -f "$B/ldsize-$_t.c" "$B/ldsize-$_t.o"
    # ---- generated headers, exactly the Makefile's three rules (98-106) ----
    mkdir -p obj/include/bits obj/src/internal
    sed -f tools/mkalltypes.sed "arch/$_t/bits/alltypes.h.in" include/alltypes.h.in > obj/include/bits/alltypes.h
    cp "arch/$_t/bits/syscall.h.in" obj/include/bits/syscall.h
    sed -n -e 's/__NR_/SYS_/p' < "arch/$_t/bits/syscall.h.in" >> obj/include/bits/syscall.h
    printf '#define VERSION "%s"\n' "$(sh tools/version.sh)" > obj/src/internal/version.h
    # ---- the object set: BASE_SRCS/ARCH_SRCS -> ALL_OBJS, arch overrides
    #      replace generic, sorted (Makefile 21-33) ----
    _dirs="$(for d in src/* src/malloc/mallocng crt ldso; do [ -d "$d" ] && echo "$d"; done)"
    for d in $_dirs; do
      for f in "$d"/*.c; do [ -f "$f" ] && echo "${f%.c}.o"; done
      for f in "$d/$_t"/*.c "$d/$_t"/*.s "$d/$_t"/*.S; do [ -f "$f" ] && echo "${f%.*}.o"; done
    done | LC_ALL=C sort -u > objs.all
    sed -n "s|/$_t/|/|p" objs.all | LC_ALL=C sort -u > objs.replaced
    LC_ALL=C comm -23 objs.all objs.replaced > objs.keep          # ALL_OBJS
    grep '^src/' objs.keep > objs.libc                             # LIBC_OBJS = AOBJS
    # ---- flags. Of configure's CFLAGS_AUTO, tcc implements two words
    #      (libtcc.c options_f and the -O parser): -O sets __OPTIMIZE__ for the
    #      preprocessor, -fno-asynchronous-unwind-tables drops .eh_frame. Both
    #      are passed so the objects are the ones the make-driven build made;
    #      the rest of that list is a no-op for tcc and is not written down as
    #      if it did something. -DCRT on crt objects (130), -fPIC on Scrt1
    #      and rcrt1 (116). ----
    _cf="-std=c99 -ffreestanding -nostdinc -O2 -fno-asynchronous-unwind-tables -D_XOPEN_SOURCE=700 -Iarch/$_t -Iarch/generic -Iobj/src/internal -Isrc/include -Isrc/internal -Iobj/include -Iinclude"
    _n=0
    while read -r o; do
      b="${o%.o}"; s=""
      for e in c s S; do [ -f "$b.$e" ] && { s="$b.$e"; break; }; done
      [ -n "$s" ] || { echo "  FAIL: no source for $o"; exit 1; }
      mkdir -p "obj/${o%/*}"
      x=""
      case "$o" in crt/*) x="-DCRT" ;; esac
      case "$o" in crt/Scrt1.o|crt/rcrt1.o|crt/*/Scrt1.o|crt/*/rcrt1.o) x="$x -fPIC" ;; esac
      $_cc $_cf $x -c -o "obj/$o" "$s" > "$B/musl-$_t.log" 2>&1 \
        || { echo "  FAIL: $s did not compile ($_t):"; tail -6 "$B/musl-$_t.log" | sed 's/^/    /'; exit 1; }
      _n=$((_n+1))
    done < objs.keep
    # ---- lib/libc.a: rm -f; ar rc in AOBJS order (Makefile 165-168).
    #      tcc's ar writes constant date/uid/gid/mode; ranlib is a no-op ----
    mkdir -p lib; rm -f lib/libc.a
    $_cc -ar rc lib/libc.a $(sed 's|^|obj/|' objs.libc) || { echo "  FAIL: ar ($_t)"; exit 1; }
    # ---- what the cross consumes: libc.a, the crt trio, the headers.
    #      lib/%.o is obj/crt/$(ARCH)/%.o when the arch has one (174), else
    #      obj/crt/%.o (177): crt1 is generic C, crti/crtn are arch .s ----
    mkdir -p "$_sys/lib" "$_sys/include/bits"
    cp lib/libc.a "$_sys/lib/"
    for c in crt1 crti crtn; do
      if [ -f "obj/crt/$_t/$c.o" ]; then cp "obj/crt/$_t/$c.o" "$_sys/lib/$c.o"; else cp "obj/crt/$c.o" "$_sys/lib/$c.o"; fi
    done
    # headers as install-headers lays them: include/, then generic bits, then
    # the arch's bits over them, then the two generated ones (Makefile 59-62)
    cp -r include/. "$_sys/include/"
    [ -d arch/generic/bits ] && cp -r arch/generic/bits/. "$_sys/include/bits/"
    cp -r "arch/$_t/bits/." "$_sys/include/bits/"
    cp obj/include/bits/alltypes.h obj/include/bits/syscall.h "$_sys/include/bits/"
    echo "    sys/$_t: libc.a $(wc -c < lib/libc.a) bytes, $_n objects, $(wc -l < objs.libc) members + crt trio" )
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
  # the recorded digest of 3/4/tcc-arm64, read with sed (no python in the
  # box): the sha256 line that follows the output path line
  want=$(sed -n -e '/^path *= *"out\/3\/aarch64\/tcc-arm64"/{' -e 'n' -e 's/^sha256 *= *"\([0-9a-f]*\)".*/\1/p' -e '}' stages/3-micro-c/substages.toml | head -1)
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
  case "$(elf_machine "$B/tcc-arm64-to-amd64")" in
    b7) : ;;
    *) echo "  FAIL: tcc-arm64-to-amd64 must be an aarch64 binary that emits x86_64 (e_machine $(elf_machine "$B/tcc-arm64-to-amd64"))"; exit 1 ;;
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
  case "$(elf_machine "$B/tcc-amd64")" in
    3e) : ;;
    *) echo "  FAIL: wrong target (e_machine $(elf_machine "$B/tcc-amd64"), want 3e)"; exit 1 ;;
  esac
  # static: no PT_INTERP. The program header table starts at e_phoff (0x20,
  # 8 bytes); each x86_64 phdr is 56 bytes, p_type is its first 4; PT_INTERP
  # is 3. busybox od reads it; no readelf in the box.
  _phoff=$(od -An -tu8 -j32 -N8 "$B/tcc-amd64" | tr -d ' '); _phnum=$(od -An -tu2 -j56 -N2 "$B/tcc-amd64" | tr -d ' ')
  _i=0; while [ "$_i" -lt "$_phnum" ]; do
    [ "$(od -An -tu4 -j$((_phoff + _i*56)) -N4 "$B/tcc-amd64" | tr -d ' ')" = 3 ] && { echo "  FAIL: not static (PT_INTERP present)"; exit 1; }
    _i=$((_i+1)); done
  chmod 0755 "$B/tcc-amd64"

  # THE 3->4 CONTRACT (per the boundary decision): stage 3 hands the
  # COMPILER, nothing else -- stage 4's rung 0 rebuilds musl and libtcc1
  # with it. The sysroots built above are scaffolding: hashed as
  # intermediates in the records for falsifiability, published only into
  # the workflow artifact as TEST FIXTURES for the native-verify job,
  # never as stage outputs. tcc-arm64-to-amd64 publishes beside the
  # contract because it is the recorded builder -- audit, not handoff.
  cp "$B/tcc-amd64" "$B/tcc-arm64-to-amd64" "$OUT/"
  # DETERMINISTIC CONTAINER (the compare gate's first catch: tar embeds
  # mtimes and gzip a timestamp, so identical contents made a different
  # tarball every run -- 12 drifting bytes while every direct .a hash held).
  # PORTABLY: --sort/--owner/--mtime are GNU tar's and busybox tar (the
  # image's) has none of them. The same determinism by other means -- every
  # mtime set to the epoch, the member list sorted and fed with -T, gzip -n
  # -- so two runs on one host give one tarball. Ownership is whatever the
  # host's is (root in CI's box, veron on the image); this file is a test
  # fixture verify-native unpacks, recorded nowhere, so cross-host byte
  # identity is not a promise it makes.
  ( cd "$B" && find sys-x86_64 -exec touch -h -t 197001010000.00 {} + \
    && find sys-x86_64 | LC_ALL=C sort > sys-x86_64.list \
    && tar -cf - -T sys-x86_64.list | gzip -n > sys-x86_64.tar.gz \
    && rm -f sys-x86_64.list )
  cp "$B/sys-x86_64.tar.gz" "$B/x86_64-libtcc1.a" "$OUT/"   # fixtures for verify-native
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

  # TWO substages, not four: the sysroots are steps' scratch -- "substage
  # boundaries exist exactly where hashing pays", and nothing downstream
  # consumes a sysroot. Their key artifacts appear as INTERMEDIATE inputs
  # (hashed, falsifiable) of the two compilers they served.
  printf '\n[[substage]]\nid = "3/5/tcc-arm64-to-amd64"\nstage = 3\narch = "x86_64"\nflavor = "trunk"\nroot = "repo"\n'
  inp source "tcc.c (pinned tree + tcc-veron.patch)" "$IN/tcc-src/tcc.c"
  inp source "musl-$MUSL_VER.tar.gz" "$IN/musl-$MUSL_VER.tar.gz"
  inp intermediate "sys-aarch64/lib/libc.a (rung scaffold)" "$B/sys-aarch64/lib/libc.a"
  inp intermediate "aarch64-libtcc1.a (rung scaffold)" "$B/aarch64-libtcc1.a"
  printf '\n[[substage.input]]\nrole   = "builder"\nref    = "3/4/tcc-arm64"\nsha256 = "%s"\n' "$TA_SHA"
  outp "out/3/x86_64/tcc-arm64-to-amd64" "$OUT/tcc-arm64-to-amd64"

  printf '\n[[substage]]\nid = "3/6/tcc-amd64"\nstage = 3\narch = "x86_64"\nflavor = "trunk"\nroot = "repo"\n'
  inp source "tcc.c (pinned tree + tcc-veron.patch)" "$IN/tcc-src/tcc.c"
  inp source "musl-$MUSL_VER.tar.gz" "$IN/musl-$MUSL_VER.tar.gz"
  # record CONTENT, not container: the .a is the scaffold's identity, the
  # tarball is packaging for the verify-native fixture
  inp intermediate "sys-x86_64/lib/libc.a (cross scaffold)" "$B/sys-x86_64/lib/libc.a"
  inp intermediate "x86_64-libtcc1.a (cross scaffold)" "$B/x86_64-libtcc1.a"
  printf '\n[[substage.input]]\nrole   = "builder"\nref    = "3/5/tcc-arm64-to-amd64"\nsha256 = "%s"\n' "$X_SHA"
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
