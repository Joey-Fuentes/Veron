#!/bin/sh
# rung1.sh -- tcc -> gcc 4.7.4 -> gcc 4.7.4 -> gcc 10.2.0, inside the box.
#
# PORTED FROM .github/workflows/tcc-builds-gcc-arm64.yml, which is the
# authoritative version. Every configure line here is that job's, verbatim.
# The diagnostics are thinner: that job prints a full inventory on failure and
# tells apart "gcc 10's sources refuse a C++98 compiler" from "2020 source met
# a 2026 glibc". If this rung fails, go read that job, do not re-derive it here.
set -u
# THE VERSION SET CROSSES THE BOUNDARY AS A FILE, NOT AS INHERITED ENV.
# box.sh uses --clearenv on purpose: the box's environment is part of what this
# job DECLARES, not whatever the runner happened to export. Run 81907665505
# died here -- "GMP_VER: parameter not set" -- because this script was written
# as though the workflow's env: block reached inside. It does not, and it should
# not. /work/versions.env is written by the job before entry, so the set is
# explicit, is one definition for all rungs, and lands in the log as an answer
# to "which versions was this".
. /work/versions.env
cd /work
NP=$(nproc)
say() { printf '%s\n' "$*"; }
die() { say "  $*"; exit 1; }

TCC=/work/tccsrc/tcc
[ -x "$TCC" ] || die "no tcc at $TCC"
say "  builder: $("$TCC" -v 2>&1 | head -1)"
say "  (there is no host gcc in this box -- box.sh --show-mask printed the proof)"

mkdir -p src prefix prefix3

# ---------------------------------------------------------------- prerequisites
# EVERY RUNG REBUILDS ITS OWN gmp/mpfr/mpc. What the reference chain does, and
# the honest shape: stage N's cc1 should contain object code from the compiler
# stage N is testing. FRESH TREES, not `make distclean` -- if distclean misses,
# make relinks .o files the previous compiler produced into an archive this
# step attributes to the new one.
build_prereqs() {   # $1 = CC, $2 = prefix
  for p in gmp-$GMP_VER mpfr-$MPFR_VER mpc-$MPC_VER; do
    rm -rf "/work/$2-$p"; mkdir -p "/work/$2-$p"; cd "/work/$2-$p"
    case "$p" in
      gmp-*)  tar xf /work/src/$p.tar.xz  ;;
      mpfr-*) tar xf /work/src/$p.tar.xz  ;;
      mpc-*)  tar xf /work/src/$p.tar.gz  ;;
    esac
    cd "$p"
    EXTRA=""
    case "$p" in
      gmp-*)  EXTRA="--disable-assembly" ;;
      mpfr-*) EXTRA="--with-gmp=/work/$2" ;;
      mpc-*)  EXTRA="--with-gmp=/work/$2 --with-mpfr=/work/$2" ;;
    esac
    # shellcheck disable=SC2086
    ./configure CC="$1" --disable-shared $EXTRA --prefix="/work/$2" \
      > conf.log 2>&1 || { say "    $p configure FAILED"; tail -15 conf.log | sed 's/^/      /'; return 1; }
    make -j"$NP" > build.log 2>&1 || { say "    $p build FAILED"; tail -15 build.log | sed 's/^/      /'; return 1; }
    make install > /dev/null 2>&1 || return 1
    say "    $p ok"
    cd /work
  done
}

# ---------------------------------------------------------------- stage 1
say ""
say "  === STAGE 1: tcc -> gcc 4.7.4 (c, c++) ==="
say "  --- prerequisites, built by tcc ---"
build_prereqs "$TCC -B/work/tccsrc" prefix || die "stage 1 prerequisites failed"

rm -rf b1 && mkdir b1 && cd b1
# No CXX. All of gcc 4.7 is C, INCLUDING cc1plus, which is the whole reason 4.7
# is the entry point: a C compiler yields a C++98 compiler.
# --disable-bootstrap: with it on, stage2 would be built by the stage1 xgcc and
# tcc's contribution would be discarded.
/work/gcc-$GCC47/configure \
  CC="$TCC -B/work/tccsrc" \
  --build=aarch64-unknown-linux-gnu \
  --host=aarch64-unknown-linux-gnu \
  --target=aarch64-unknown-linux-gnu \
  --prefix=/work/out1 --enable-languages=c,c++ \
  --disable-multilib --disable-bootstrap --disable-werror \
  --disable-libsanitizer --disable-libgomp --disable-libquadmath \
  --disable-libssp --disable-libatomic --disable-shared \
  --with-gmp=/work/prefix --with-mpfr=/work/prefix --with-mpc=/work/prefix \
  > conf1.log 2>&1 || { say "  configure FAILED"; tail -30 conf1.log | sed 's/^/    /'; exit 1; }

# MAKEINFO=true: 2026's makeinfo rejects 2012's texinfo and would report failure
# over documentation. -Otarget: with -j, parallel output interleaves and the
# first error lands next to another target's warnings.
make -j"$NP" -Otarget MAKEINFO=true > build1.log 2>&1 || {
  say "  build FAILED"
  grep -nE "error:|internal compiler error" build1.log | grep -v 'make\[' | head -15 | sed 's/^/    /'
  tail -20 build1.log | sed 's/^/    /'; exit 1; }
make install > /dev/null 2>&1
[ -x /work/out1/bin/gcc ] || die "stage 1 installed no gcc"
say "  stage 1: $(/work/out1/bin/gcc --version | head -1)"
cd /work

# ---------------------------------------------------------------- stage 2
say ""
say "  === STAGE 2: that gcc rebuilds gcc 4.7.4 ==="
G1=/work/out1/bin/gcc
# PREFLIGHT. The gmp/mpfr/mpc version check is an AC_TRY_LINK and it fails
# identically for two different reasons: this gcc cannot link at all, or it
# cannot link THESE archives. Tell them apart before configure hides it.
printf 'int main(void){return 42;}\n' > /tmp/p1.c
"$G1" /tmp/p1.c -o /tmp/p1 2> /tmp/p1.err || true
if [ -x /tmp/p1 ]; then /tmp/p1; say "  preflight: stage-1 gcc links and runs (exit $?, expect 42)"
else say "  preflight: STAGE-1 GCC CANNOT LINK"; head -10 /tmp/p1.err | sed 's/^/    /'; exit 1; fi

say "  --- prerequisites, rebuilt by the tcc-built gcc ---"
build_prereqs "$G1" prefix2 || die "stage 2 prerequisites failed"

rm -rf b2 && mkdir b2 && cd b2
/work/gcc-$GCC47/configure \
  CC="$G1" \
  --build=aarch64-unknown-linux-gnu \
  --host=aarch64-unknown-linux-gnu \
  --target=aarch64-unknown-linux-gnu \
  --prefix=/work/out2 --enable-languages=c,c++ \
  --disable-multilib --disable-bootstrap --disable-werror \
  --disable-libsanitizer --disable-libgomp --disable-libquadmath \
  --disable-libssp --disable-libatomic --disable-shared \
  --with-gmp=/work/prefix2 --with-mpfr=/work/prefix2 --with-mpc=/work/prefix2 \
  > conf2.log 2>&1 || { say "  configure FAILED"; tail -30 conf2.log | sed 's/^/    /'; exit 1; }
make -j"$NP" -Otarget MAKEINFO=true > build2.log 2>&1 || {
  say "  build FAILED"; tail -20 build2.log | sed 's/^/    /'; exit 1; }
make install > /dev/null 2>&1
[ -x /work/out2/bin/gcc ] || die "stage 2 installed no gcc"
cd /work

# THE FIXPOINT, ACTUALLY CHECKED. The previous revision called stage 2 a
# "fixpoint" and never compared anything -- a second build with no diff is just
# a second build. cc1 is the interesting object: if stage 1 and stage 2 produce
# the same cc1, the compiler has reached a fixed point under itself.
say ""
say "  === FIXPOINT: is stage 2's cc1 stage 1's cc1? ==="
C1=$(find /work/out1 -name cc1 -type f 2>/dev/null | head -1)
C2=$(find /work/out2 -name cc1 -type f 2>/dev/null | head -1)
if [ -n "$C1" ] && [ -n "$C2" ]; then
  H1=$(sha256sum "$C1" | cut -d' ' -f1); H2=$(sha256sum "$C2" | cut -d' ' -f1)
  say "    stage1 cc1: $H1"
  say "    stage2 cc1: $H2"
  if [ "$H1" = "$H2" ]; then
    say "    IDENTICAL -- fixpoint reached"
  else
    # NOT A FAILURE, A FINDING. tcc-built and gcc-built cc1 differing is
    # expected; what matters is that the difference is RECORDED rather than
    # implied by the word "fixpoint". Closing it is the 3-stage bootstrap,
    # which is deferred here and declared as such in the chain record.
    say "    DIFFER -- expected at this rung; 3-stage bootstrap is deferred"
  fi
else
  say "    cc1 not found in one or both trees -- cannot compare"
fi

# ---------------------------------------------------------------- stage 3
say ""
say "  === STAGE 3: g++ 4.7 -> gcc 10.2.0 ==="
say "  (the rung the whole choice of 4.7 exists for)"
tar xf /work/src/gcc-$GCC10.tar.xz
export PATH=/work/out2/bin:$PATH
build_prereqs /work/out2/bin/gcc prefix3 || die "stage 3 prerequisites failed"

rm -rf b3 && mkdir b3 && cd b3
/work/gcc-$GCC10/configure \
  CC=/work/out2/bin/gcc CXX=/work/out2/bin/g++ \
  --build=aarch64-unknown-linux-gnu \
  --host=aarch64-unknown-linux-gnu \
  --target=aarch64-unknown-linux-gnu \
  --prefix=/work/out10 --enable-languages=c,c++ \
  --disable-multilib --disable-bootstrap --disable-werror \
  --disable-libsanitizer --disable-libvtv --disable-libgomp \
  --disable-libquadmath \
  --with-gmp=/work/prefix3 --with-mpfr=/work/prefix3 --with-mpc=/work/prefix3 \
  > conf3.log 2>&1
if [ ! -f Makefile ]; then
  say "  no Makefile -- configure tail:"; tail -20 conf3.log | sed 's/^/    /'
  [ -f config.log ] && { say "  --- config.log complaints ---"
    grep -nE "error:|cannot find|undefined reference|No such file" config.log | tail -25 | sed 's/^/    /'; }
  exit 1
fi
timeout 10800 make -j"$NP" -Otarget MAKEINFO=true > build3.log 2>&1
rc=$?
case "$rc" in
  0)   say "  make rc=0 -- completed" ;;
  124) say "  make rc=124 -- TIMED OUT after 10800s"; exit 1 ;;
  *)   say "  make rc=$rc -- failed"
       # THE TWO FAILURES WORTH TELLING APART. gcc 10's sources refusing a
       # C++98 compiler shows up as errors in gcc/*.c; a 2020 tree meeting a
       # 2026 glibc shows up in the headers. Different fixes, same message.
       say "  --- where the errors are ---"
       grep -oE '^[^ :]+\.(c|cc|h|H):[0-9]+:[0-9]*:? *error:' build3.log \
         | cut -d: -f1 | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'
       tail -20 build3.log | sed 's/^/    /'; exit 1 ;;
esac
make install > /dev/null 2>&1
[ -x /work/out10/bin/gcc ] || die "stage 3 installed no gcc"
say "  stage 3: $(/work/out10/bin/gcc --version | head -1)"
say ""
say "  rung 1 complete: tcc -> 4.7.4 -> 4.7.4 -> 10.2.0"
exit 0
