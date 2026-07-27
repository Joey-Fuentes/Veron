#!/bin/sh
# rung1.sh -- tcc -> gcc 4.7.4 -> gcc 4.7.4 -> gcc 4.7.4 -> gcc 10.2.0.
#
# PORTED FROM .github/workflows/tcc-builds-gcc-arm64.yml, which is the
# authoritative version. Every configure line here is that job's, verbatim.
#
# ---------------------------------------------------------------------------
# WHY THE PASSES ARE NOT NUMBERED
#
# They used to be "STAGE 1/2/3", taken from the job this is ported from. That
# was a mistake: this repository already has FOUR live meanings for a small
# integer next to the word stage --
#
#   ARCHITECTURE.md §2    stage 3 = mini-c
#   AGENTS.md §4          stage 3 = full-c
#   tcc-builds-gcc-arm64  its own third step
#   stage4-complete       rung 3 = kernel + boot
#
# -- and the numbering disagreement between the first two is an unresolved
# stop-and-ask. Adding a fifth scheme made log lines unreadable without knowing
# which file the reader had open. The passes are named by the transition they
# perform instead. Nothing to collide with.
#
# ---------------------------------------------------------------------------
# WHY THERE ARE THREE 4.7.4 BUILDS AND NOT TWO
#
# The previous revision built two and compared their cc1 -- and that comparison
# could never have meant anything, because build A is compiled by TCC and build
# B is compiled by GCC. Two different compilers have no reason to emit the same
# object code, so the check had no pass condition, and it was annotated
# "expected at this rung" so that its one possible outcome read as success.
# That is the same defect as a gate printing "expect exit 55" beside the real
# value and exiting 0 regardless.
#
# The comparison that MEANS something is B against C: both are gcc 4.7.4 built
# from identical source, by compilers that are themselves gcc 4.7.4 built from
# identical source. A correct compiler emits the same code regardless of what
# compiled it, so B and C should be byte-identical, and a difference is a real
# finding -- a miscompilation by tcc that survives a generation, or
# non-determinism. That is ARCHITECTURE.md's audit regime B (diverse
# double-compilation), and it is the check --disable-bootstrap turns off.
#
# It costs one extra 4.7.4 build. Run 81908437787 measured those at 2-5 minutes
# against gcc 10's 5 and a 330-minute budget, so cost was never the reason.
#
# EVERYTHING THE CONFIGURE LINE CONTAINS MUST BE IDENTICAL, NOT JUST --prefix.
# Run 81910448983 got this half right and the comparison failed on my setup
# rather than on the compilers. gcc records its full configure command line in
# the binary (it is what `gcc -v` prints back), so B carried
#     CC=/work/g47a/bin/gcc          <- build A's prefix
# and C carried
#     CC=/work/g47/bin/gcc           <- build B's prefix
# one character shorter. cmp put the first difference at offset 41, which is
# ELF64's e_shoff -- the section table had moved because everything after the
# string shifted. The decoded bytes were literally "a/bin" against "/bin".
#
# So all three of these are now routed through fixed paths that do not change
# between B and C:
#     /work/cc-prev    symlink, repointed to whichever compiler is building
#     /work/prereq     one prefix, wiped and rebuilt per pass
#     /work/bld        one build directory, wiped per pass
# B installs to the real prefix, C installs the same prefix under a DESTDIR,
# and the trees are compared. If gcc canonicalises the symlink when recording
# the line, this will still differ -- and the comparison now prints both
# configure strings on failure, so that takes one look rather than one run.
set -u

# THE VERSION SET CROSSES THE BOUNDARY AS A FILE, NOT AS INHERITED ENV.
# box.sh uses --clearenv on purpose: the box's environment is part of what this
# job DECLARES, not whatever the runner happened to export. Run 81907665505
# died here -- "GMP_VER: parameter not set" -- because this script was written
# as though the workflow's env: block reached inside. It does not, and should
# not.
. /work/versions.env
cd /work
NP=$(nproc)
say() { printf '%s\n' "$*"; }
die() { say "  $*"; exit 1; }

# DIAGNOSTICS ARE THE PRODUCT WHEN A BUILD FAILS. Run 81908437787's gcc 10 step
# printed "--- where the errors are ---" followed by twenty lines of make
# entering and leaving directories, because this port kept ONE of the four
# greps the original job uses and then ran an unlabelled tail straight after it.
# The failing line was somewhere in a log that was never uploaded.
diagnose() {   # $1 = logfile, $2 = label
  say "  --- $2: compiler diagnostics ---"
  grep -nE "error:|internal compiler error|undefined reference" "$1" \
    | grep -v 'make\[' | head -20 | sed 's/^/    /'
  say "  --- $2: which files ---"
  grep -oE '^[^ :]+\.(c|cc|h|H|cpp):[0-9]+:[0-9]*:? *error:' "$1" \
    | cut -d: -f1 | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'
  say "  --- $2: which make targets ---"
  grep -nE "\*\*\* \[" "$1" | head -8 | sed 's/^/    /'
  say "  --- $2: last 25 lines ---"
  tail -25 "$1" | sed 's/^/    /'
  say "  --- $2: full log $1 ($(wc -l < "$1") lines) is uploaded as an artifact ---"
}

TCC=/work/tccsrc/tcc
[ -x "$TCC" ] || die "no tcc at $TCC"
say "  builder: $("$TCC" -v 2>&1 | head -1)"
say "  (there is no host gcc in this box -- box.sh --show-mask printed the proof)"

mkdir -p src

# EVERY PASS REBUILDS ITS OWN gmp/mpfr/mpc. What the reference chain does, and
# the honest shape: a pass's cc1 should contain object code from the compiler
# that pass is testing. FRESH TREES, not `make distclean` -- if distclean
# misses, make relinks .o files the previous compiler produced into an archive
# this pass attributes to the new one.
# ONE PREFIX PATH, REBUILT PER PASS. It used to be pA/pB/pC, which put
# --with-gmp=/work/pB into B's recorded configure line and /work/pC into C's.
# Same length, different bytes -- another difference that was mine.
build_prereqs() {   # $1 = CC
  rm -rf /work/prereq; mkdir -p /work/prereq
  for p in gmp-$GMP_VER mpfr-$MPFR_VER mpc-$MPC_VER; do
    rm -rf "/work/src-$p"; mkdir -p "/work/src-$p"; cd "/work/src-$p"
    case "$p" in
      mpc-*) tar xf /work/src/$p.tar.gz ;;
      *)     tar xf /work/src/$p.tar.xz ;;
    esac
    cd "$p"
    EXTRA=""
    case "$p" in
      gmp-*)  EXTRA="--disable-assembly" ;;
      mpfr-*) EXTRA="--with-gmp=/work/prereq" ;;
      mpc-*)  EXTRA="--with-gmp=/work/prereq --with-mpfr=/work/prereq" ;;
    esac
    # shellcheck disable=SC2086
    ./configure CC="$1" --disable-shared $EXTRA --prefix=/work/prereq \
      > conf.log 2>&1 || { say "    $p configure FAILED"; tail -20 conf.log | sed 's/^/      /'; return 1; }
    make -j"$NP" > build.log 2>&1 || { say "    $p build FAILED"; diagnose "$PWD/build.log" "$p"; return 1; }
    make install > /dev/null 2>&1 || return 1
    say "    $p ok"
    cd /work
  done
}

# ONE configure LINE, THREE CALL SITES, so B and C cannot drift apart. If they
# drifted, the comparison below would be measuring the drift.
# ONE BUILD DIRECTORY. bB and bC were the same length, so they did not show up
# in run 81910448983 -- but DW_AT_comp_dir records it and a two-character name
# is luck, not design.
configure_47() {   # $1 = CC  $2 = prefix
  rm -rf /work/bld && mkdir /work/bld && cd /work/bld
  # No CXX. All of gcc 4.7 is C, INCLUDING cc1plus, which is the whole reason
  # 4.7 is the entry point: a C compiler yields a C++98 compiler.
  # --disable-bootstrap: with it on, the tree would bootstrap itself internally
  # and the contribution of the compiler being tested would be discarded --
  # which is also why the B-vs-C comparison has to be done by hand.
  /work/gcc-$GCC47/configure \
    CC="$1" \
    --build=aarch64-unknown-linux-gnu \
    --host=aarch64-unknown-linux-gnu \
    --target=aarch64-unknown-linux-gnu \
    --prefix="$2" --enable-languages=c,c++ \
    --disable-multilib --disable-bootstrap --disable-werror \
    --disable-libsanitizer --disable-libgomp --disable-libquadmath \
    --disable-libssp --disable-libatomic --disable-shared \
    --with-gmp=/work/prereq --with-mpfr=/work/prereq --with-mpc=/work/prereq \
    > conf.log 2>&1
}

# ============================================================ tcc -> gcc 4.7.4
say ""
say "  === [tcc -> gcc 4.7.4]   build A ==="
say "  --- prerequisites, built by tcc ---"
build_prereqs "$TCC -B/work/tccsrc" || die "build A prerequisites failed"
configure_47 "$TCC -B/work/tccsrc" /work/g47a \
  || { say "  configure FAILED"; tail -30 /work/bld/conf.log | sed 's/^/    /'; exit 1; }
# MAKEINFO=true: 2026's makeinfo rejects 2012's texinfo and would report failure
# over documentation. -Otarget: with -j, parallel output interleaves and the
# first error lands next to another target's warnings.
make -j"$NP" -Otarget MAKEINFO=true > build.log 2>&1 \
  || { say "  build FAILED"; diagnose /work/bld/build.log "build A"; exit 1; }
make install > install.log 2>&1
[ -x /work/g47a/bin/gcc ] || die "build A installed no gcc"
say "  A: $(/work/g47a/bin/gcc --version | head -1)"
cd /work

# PREFLIGHT. The gmp/mpfr/mpc version check the next configure runs is an
# AC_TRY_LINK, and it fails identically for two different reasons: this gcc
# cannot link at all, or it cannot link THOSE archives. Tell them apart before
# configure hides it behind one "no".
printf 'int main(void){return 42;}\n' > /tmp/p1.c
/work/g47a/bin/gcc /tmp/p1.c -o /tmp/p1 2> /tmp/p1.err || true
if [ -x /tmp/p1 ]; then /tmp/p1; say "  preflight: A links and runs (exit $?, expect 42)"
else say "  preflight: BUILD A CANNOT LINK"; head -12 /tmp/p1.err | sed 's/^/    /'; exit 1; fi

# ====================================================== gcc 4.7.4 -> gcc 4.7.4
say ""
say "  === [gcc 4.7.4 A -> gcc 4.7.4 B]   build B ==="
say "  --- prerequisites, rebuilt by A ---"
# THE SYMLINK IS THE POINT. B and C must both record CC=/work/cc-prev/bin/gcc.
ln -sfn /work/g47a /work/cc-prev
build_prereqs /work/cc-prev/bin/gcc || die "build B prerequisites failed"
configure_47 /work/cc-prev/bin/gcc /work/g47 \
  || { say "  configure FAILED"; tail -30 /work/bld/conf.log | sed 's/^/    /'; exit 1; }
make -j"$NP" -Otarget MAKEINFO=true > build.log 2>&1 \
  || { say "  build FAILED"; diagnose /work/bld/build.log "build B"; exit 1; }
make install > install.log 2>&1
[ -x /work/g47/bin/gcc ] || die "build B installed no gcc"
say "  B: $(/work/g47/bin/gcc --version | head -1)"
cd /work

# ====================================================== gcc 4.7.4 -> gcc 4.7.4
say ""
say "  === [gcc 4.7.4 B -> gcc 4.7.4 C]   build C, for comparison ==="
say "  --- prerequisites, rebuilt by B ---"
# REPOINT, DO NOT RENAME. Same string, different target -- that is the whole
# trick, and it is why the recorded configure lines can now be identical.
ln -sfn /work/g47 /work/cc-prev
build_prereqs /work/cc-prev/bin/gcc || die "build C prerequisites failed"
# SAME --prefix AND SAME CC STRING AS B, different DESTDIR. See the header.
configure_47 /work/cc-prev/bin/gcc /work/g47 \
  || { say "  configure FAILED"; tail -30 /work/bld/conf.log | sed 's/^/    /'; exit 1; }
make -j"$NP" -Otarget MAKEINFO=true > build.log 2>&1 \
  || { say "  build FAILED"; diagnose /work/bld/build.log "build C"; exit 1; }
make install DESTDIR=/work/dC > install.log 2>&1
[ -x /work/dC/work/g47/bin/gcc ] || die "build C installed no gcc"
cd /work

# ========================================================== bootstrap compare
say ""
say "  === BOOTSTRAP COMPARISON: is C byte-identical to B? ==="
say "  Both are gcc 4.7.4 from identical source at an identical --prefix,"
say "  compiled by compilers that are themselves gcc 4.7.4 from identical"
say "  source. A correct compiler emits the same code either way."
bfail=0
sfail=0

# WHAT IS COMPARED, AND IN WHICH ORDER. Two questions, and run 81910448983
# conflated them:
#   1. does the CODE match?      compare with debug info stripped
#   2. does everything match?    compare raw
# (1) is the compiler question. (2) additionally covers recorded build metadata
# -- configure line, comp_dir, producer strings -- which is my setup's problem
# rather than the compiler's. Reporting them separately means a metadata-only
# difference reads as a metadata difference instead of as a miscompilation.
confline() {   # $1 = binary -> the configure line gcc recorded in it
  "$1" -v 2>&1 | sed -n 's/^Configured with: //p' | head -1 && return 0
  strings "$1" 2>/dev/null | grep -m1 -- '--enable-languages' || echo '<unreadable>'
}

cmp_one() {   # $1 = label  $2 = path in B  $3 = path in C
  if [ ! -f "$2" ] || [ ! -f "$3" ]; then say "    $1: missing on one side"; bfail=1; return; fi

  # (1) code, debug info removed
  rm -f /tmp/sb /tmp/sc
  cp "$2" /tmp/sb; cp "$3" /tmp/sc
  objcopy --strip-debug /tmp/sb 2>/dev/null || strip -g /tmp/sb 2>/dev/null || true
  objcopy --strip-debug /tmp/sc 2>/dev/null || strip -g /tmp/sc 2>/dev/null || true
  sb=$(sha256sum /tmp/sb | cut -d' ' -f1); sc=$(sha256sum /tmp/sc | cut -d' ' -f1)

  # (2) everything
  hb=$(sha256sum "$2" | cut -d' ' -f1); hc=$(sha256sum "$3" | cut -d' ' -f1)

  if [ "$sb" = "$sc" ] && [ "$hb" = "$hc" ]; then say "    $1: identical"; return; fi
  if [ "$sb" = "$sc" ]; then
    say "    $1: code identical, metadata differs"
    say "      stripped  $sb  (both)"
    say "      raw       B $hb"
    say "      raw       C $hc"
    sfail=1
    return
  fi
  say "    $1: CODE DIFFERS"
  say "      stripped  B $sb"
  say "      stripped  C $sc"
  say "      sizes     B=$(stat -c%s "$2")  C=$(stat -c%s "$3")"
  say "      first differing bytes of the stripped images (offset, B, C, octal):"
  cmp -l /tmp/sb /tmp/sc 2>/dev/null | head -5 | sed 's/^/        /'
  bfail=1
}
for rel in bin/gcc bin/g++ bin/cpp; do
  cmp_one "$rel" "/work/g47/$rel" "/work/dC/work/g47/$rel"
done
for n in cc1 cc1plus; do
  b=$(find /work/g47 -name "$n" -type f 2>/dev/null | head -1)
  c=$(find /work/dC/work/g47 -name "$n" -type f 2>/dev/null | head -1)
  if [ -z "$b" ] || [ -z "$c" ]; then say "    $n: not found on one side"; bfail=1; continue; fi
  cmp_one "$n" "$b" "$c"
done

# THE CONFIGURE LINES, PRINTED WHENEVER ANYTHING DIFFERS. In run 81910448983
# the entire difference was one character of this string, and finding that out
# cost a 12-minute run and a hexdump. It costs two lines to print.
if [ "$bfail" -ne 0 ] || [ "$sfail" -ne 0 ]; then
  say ""
  say "  --- recorded configure lines ---"
  say "    B: $(confline /work/g47/bin/gcc)"
  say "    C: $(confline /work/dC/work/g47/bin/gcc)"
  say "    (these must be byte-identical. If they are not, the difference"
  say "     belongs to this script setup and not to the compilers.)"
fi

if [ "$bfail" -ne 0 ]; then
  say ""
  say "  THE BOOTSTRAP COMPARISON FAILED ON CODE."
  say ""
  say "  Stripped images differ, so this is not recorded build metadata. Either"
  say "  tcc miscompiled gcc 4.7.4 in a way that survives a generation, or"
  say "  something in the build is non-deterministic. Both are worth knowing"
  say "  and neither of those is an expected result. Look first."
  exit 1
fi
if [ "$sfail" -ne 0 ]; then
  say ""
  say "  CODE MATCHES; RECORDED METADATA DOES NOT."
  say ""
  say "  The compilers agree, which is the question this check exists to ask."
  say "  What differs is what the build recorded about itself. Compare the two"
  say "  configure lines above -- run 81910448983 differed by a single"
  say "  character of a path and it took a hexdump to see it."
  say ""
  say "  This is a real difference and it is not being waved through: the"
  say "  chain record will carry it, and the intended state is byte-identical."
  exit 1
fi
say "    all identical -- gcc 4.7.4 has reached a fixed point under itself"

# ====================================================== g++ 4.7 -> gcc 10.2.0
say ""
say "  === [g++ 4.7.4 -> gcc 10.2.0] ==="
say "  (the rung the whole choice of 4.7 exists for)"
tar xf /work/src/gcc-$GCC10.tar.xz
say "  --- prerequisites, rebuilt by B ---"
build_prereqs /work/g47/bin/gcc || die "gcc 10 prerequisites failed"

rm -rf b10 && mkdir b10 && cd b10
/work/gcc-$GCC10/configure \
  CC=/work/g47/bin/gcc CXX=/work/g47/bin/g++ \
  --build=aarch64-unknown-linux-gnu \
  --host=aarch64-unknown-linux-gnu \
  --target=aarch64-unknown-linux-gnu \
  --prefix=/work/out10 --enable-languages=c,c++ \
  --disable-multilib --disable-bootstrap --disable-werror \
  --disable-libsanitizer --disable-libvtv --disable-libgomp \
  --disable-libquadmath \
  --with-gmp=/work/prereq --with-mpfr=/work/prereq --with-mpc=/work/prereq \
  > conf.log 2>&1
if [ ! -f Makefile ]; then
  say "  no Makefile -- configure tail:"; tail -25 conf.log | sed 's/^/    /'
  [ -f config.log ] && { say "  --- config.log complaints ---"
    grep -nE "error:|cannot find|undefined reference|No such file" config.log | tail -25 | sed 's/^/    /'; }
  exit 1
fi
timeout 10800 make -j"$NP" -Otarget MAKEINFO=true > build.log 2>&1
rc=$?
case "$rc" in
  0)   say "  make rc=0 -- completed" ;;
  124) say "  make rc=124 -- TIMED OUT after 10800s"; exit 1 ;;
  *)   say "  make rc=$rc -- failed"
       # THE TWO FAILURES WORTH TELLING APART. gcc 10's sources refusing a
       # C++98/03 compiler shows up as errors in gcc/*.c and libcpp -- and gcc
       # 10's own prerequisites name 4.8.3 as the floor, so that is the
       # documented risk of the 4.7 rung, not a surprise. A 2020 tree meeting a
       # 2026 glibc shows up in the headers instead. Different fixes, same
       # top-level message.
       diagnose /work/b10/build.log "gcc 10"
       exit 1 ;;
esac
make install > install.log 2>&1
[ -x /work/out10/bin/gcc ] || die "gcc 10 installed no gcc"
say "  gcc 10: $(/work/out10/bin/gcc --version | head -1)"

say ""
say "  rung 1 complete: tcc -> 4.7.4 -> 4.7.4 (= 4.7.4) -> 10.2.0"
exit 0
