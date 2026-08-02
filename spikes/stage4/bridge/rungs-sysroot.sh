#!/bin/sh
# PHASE B -- THE FINAL SYSTEM, BUILT BY THE FINAL TOOLCHAIN, WITH THE SYSROOT
# AS `/`.
#
# ONE COPY, TWO ARMS, same as rungs.sh: this file is run unchanged by
# stage3-to-stage4-reference and stage3-to-stage4-bridge. It takes no compiler
# argument at all, because by this point there is only one compiler that can
# run here and it came out of phase A.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A SEPARATE SANDBOX AND NOT A FUNCTION IN rungs.sh
#
# Phase A ran with the BOX as /, where /usr is MUSL -- rung 2 installs it there
# because tcc's crt search path is compiled in at configure time and cannot be
# redirected from the command line (rungs.sh, "THE SYSROOT IS /usr"). That was
# correct, and it spends the one prefix the final system wants.
#
# So the final toolchain was built --prefix=/usr into $S=/work/lfs, and a glibc
# toolchain built --prefix=/usr only functions when its prefix really IS the
# root: its PT_INTERP (/lib/ld-linux-aarch64.so.1), its library search path and
# its header search path are all absolute.
#
# An earlier revision tried to bridge that with a helper called `in_sysroot`
# that set PATH and nothing else. PATH does not move an interpreter. The kernel
# resolves PT_INTERP against the root the process is running in, so every
# glibc-linked binary phase A installed failed to exec, and busybox sh reported
# that as "gcc: not found" -- the message for a missing PROGRAM. Three rungs
# were built on top of that mistake.
#
# The mechanism to do it properly was already in this repository:
# hermetic-gcc15.yml's box15.sh, "No /usr bind. No /etc bind. The sysroot IS
# the filesystem." The workflow now invokes this file that way.
#
# /tools/bin IS DELIBERATELY NOT ON PATH.
#
# That is where phase A's cross toolchain lives -- binutils pass 1 and gcc 15
# pass 1, both musl-static, both perfectly capable of running in here. LFS
# drops the same directory on entering its chroot: "Notice that /tools/bin is
# not in the PATH. This means that the cross toolchain will no longer be used."
#
# For us it is stronger than hygiene. The claim this job exists to make is that
# what ships was built by the FINAL toolchain, and a PATH that cannot reach the
# earlier one turns that from a convention into a property the sandbox enforces.
# If something below reaches for $LFS_TGT-gcc it fails loudly instead of
# quietly producing an artifact from the wrong compiler.
#
# ---------------------------------------------------------------------------
# THE ORDER, AND WHAT BUILDS WHAT
#
#   B0  the sysroot is usable          -- gcc/g++/ld/as/make/sh all RUN
#   B1  prerequisites, by gcc pass 2   -- gawk m4 bison flex python bc openssl
#   B2  glibc,    native, by pass 2    -- the final libc
#   B3  binutils, native, by pass 2    -- the final as/ld/ar
#   B4  gcc,      native, by pass 2    -- THE FINAL COMPILER
#   B5  busybox,  by B4                -- what the initramfs runs
#   B6  linux,    by B4                -- the Image
#   B7  initramfs
#   B8  hand out, and hash everything that leaves
#
# B2-B4 are LFS chapter 8's rebuild and the reason is the book's: the chapter 6
# copies were built in "the cross-compilation mode", where features requiring a
# host-executable test program are disabled. They work; they are not the same
# artifact a native build produces. Everything from B5 down is built by B4.
#
# --disable-bootstrap THROUGHOUT, which is this repository's standing choice --
# "with it on, stage2 would be built by the stage1 xgcc and tcc's contribution
# would be discarded" (stage4-complete.yml). The determinism claim here is made
# by RERUN instead: B8 hashes the final compiler and the image, and two runs of
# the same commit printing the same hashes is the evidence. That is a different
# and cheaper property than a fixpoint, and it is the one being claimed.
#
# EVERY RUNG REPORTS; NOTHING HERE EXITS NON-ZERO, same rule as phase A.

set -u

say()   { printf '%s\n' "$*"; }
head1() { say ""; say "  === $* ==="; }
onedir() { ls -d $1 2>/dev/null | head -1 | sed 's|^\./||'; }

# WHERE IT FAILED, NOT WHAT FINISHED LAST -- the same helper phase A grew, and
# for the same reason: under `make -j` a tail lands on whichever module
# finished last, which is by definition one that SUCCEEDED. A gcc build that
# died in build-fixincludes printed twenty-five lines of gmp's libtool
# succeeding, and the real ld message was never logged.
whyfail() {        # $1 = logfile
    [ -s "$1" ] || { say "      (no $1)"; return; }
    _n=$(grep -nE "error:|undefined reference|cannot find|No such file|Error [0-9]" "$1" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$_n" ]; then
        _from=1; [ "$_n" -gt 30 ] && _from=$(( _n - 30 ))
        say "      --- $1, around the first error (line $_n) ---"
        sed -n "${_from},$(( _n + 8 ))p" "$1" | sed 's/^/      /'
    else
        say "      --- $1, last 25 lines (nothing matched an error pattern) ---"
        tail -25 "$1" | sed 's/^/      /'
    fi
}

ARM=${ARM:-unnamed}
NP=$(nproc 2>/dev/null || echo 2)
W=/build                       # scratch, bound by the workflow; NOT the sysroot
SRC=$W/src
mkdir -p "$SRC" 2>/dev/null || true

B0=skip; B1=skip; B2=skip; B3=skip; B4=skip; B5=skip; B6=skip; B7=skip; B8=skip

say ""
say "  === PHASE B: the sysroot IS the filesystem ==="
say "  arm:   $ARM"
say "  PATH:  $PATH"
say "  jobs:  $NP     (an undeclared input -- printed so a hash mismatch"
say "                  between runs can be attributed rather than guessed at)"

# THE SAME untar AS PHASE A, AND FOR THE SAME REASONS. Kept in step with
# rungs.sh's copy deliberately; if one changes the other should.
untar() {
    _t=$(ls "$1"*.tar.gz "$1"*.tar.xz "$1"*.tar.bz2 2>/dev/null | head -1)
    if [ -z "$_t" ]; then
        say "    no tarball matching $1* -- /in holds:"
        ls -1 /in 2>/dev/null | sed 's/^/      /'
        return 1
    fi
    case "$_t" in
        *.tar.gz)  _flag=-zxf ;;
        *.tar.xz)  _flag=-Jxf ;;
        *.tar.bz2) _flag=-jxf ;;
        *) say "    unknown archive type: $_t"; return 1 ;;
    esac
    say "    tar $_flag $_t   (cwd: $(pwd))"
    tar "$_flag" "$_t" 2>/tmp/untar.err || {
        say "    tar refused it:"; sed 's/^/      /' /tmp/untar.err | head -3; return 1; }
    return 0
}

# UNPACK INTO A PRIVATE DIRECTORY, ALWAYS. Phase A recorded what happens
# otherwise: `onedir` globs the whole source root, so by the tenth package
# `onedir "make-4.4"` returned busybox-1.36.1 and the log said "extracting
# make" while naming busybox.
# THE PATH COMES BACK IN A GLOBAL, NOT ON STDOUT. `_d=$(fetch ...)` would
# capture everything untar and say print as part of the path, and the first
# symptom would be a configure script "not found" at a directory name with a
# tar command embedded in it.
FDIR=
fetch() {            # $1 = /in prefix, e.g. /in/m4-   $2 = tag
    FDIR=
    rm -rf "$SRC/$2" && mkdir -p "$SRC/$2" || return 1
    ( cd "$SRC/$2" && untar "$1" ) || return 1
    _fd=$(cd "$SRC/$2" && onedir '* ./*')
    [ -n "$_fd" ] || { say "    nothing unpacked for $2"; return 1; }
    FDIR="$SRC/$2/$_fd"
    return 0
}

# ---------------------------------------------------------------------------
head1 "RUNG B0 -- is the sysroot actually usable?"
# RUN THEM, DO NOT STAT THEM. This is the check phase A's rung 16 gained for
# the same reason, and it is this repository's oldest recurring bug: "rung 4 =
# ok meant the files existed, not that they ran. It reported ok, and rung 5
# after it, while `as` could not be executed at all."
#
# -x is true of a dynamic binary whose interpreter is missing, which is
# precisely the failure this phase exists to fix. So each one is executed.
_ok=yes
for _n in sh make gcc g++ ld as ar; do
  if ! command -v "$_n" > /dev/null 2>&1; then
    printf '    %-5s NOT ON PATH\n' "$_n"; _ok=no; continue
  fi
  if "$_n" --version > /dev/null 2>&1 || [ "$_n" = sh ]; then
    printf '    %-5s %s\n' "$_n" "$("$_n" --version 2>&1 | head -1)"
  else
    printf '    %-5s present, DOES NOT EXECUTE\n' "$_n"; _ok=no
  fi
done
# AND THAT THE CROSS TOOLCHAIN IS UNREACHABLE, which is the property the PATH
# is enforcing. Reported rather than assumed, because a PATH is easy to widen
# by accident and the consequence -- an artifact built by pass 1 -- is silent.
if command -v "${LFS_TGT:-aarch64-veron-linux-gnu}-gcc" > /dev/null 2>&1; then
  say "    THE CROSS COMPILER IS ON PATH. /tools/bin must not be reachable"
  say "    here, or 'built by the final toolchain' stops being enforced."
  _ok=no
else
  say "    cross toolchain unreachable: yes (this is the point)"
fi
# A REAL COMPILE AND A REAL RUN, because --version only proves the driver execs.
cat > /tmp/b0.c <<'EOF'
#include <stdio.h>
int main(void){ printf("B0\n"); return 42; }
EOF
gcc /tmp/b0.c -o /tmp/b0 2>/tmp/b0.err && /tmp/b0 > /dev/null 2>&1
_rc=$?
if [ "$_rc" = 42 ]; then
  say "    compile + link + run: ok (rc=42 as expected)"
else
  say "    compile/link/run FAILED:"; sed 's/^/      /' /tmp/b0.err 2>/dev/null | head -8
  _ok=no
fi
if [ "$_ok" = yes ]; then B0=ok; else B0=FAIL; say "    phase B cannot proceed."; fi

# ---------------------------------------------------------------------------
head1 "RUNG B1 -- prerequisites, built by gcc pass 2, into the sysroot"
# WHAT IS HERE AND WHY EACH ONE. This list is measured rather than copied from
# a table of contents -- tool-probe ran each package's own configure in a box
# with a controlled PATH and glibc answered:
#
#     configure: error:
#       *** These critical programs are missing or too old: make gawk bison python
#
# so gawk, bison and python are hard requirements of B2, not chapter 8 niceties.
# flex comes before bison because bison's configure checks for it even though
# its scanner ships pre-generated. m4 comes before both. bc is required by
# kernel/time/Makefile, which pipes CONFIG_HZ through it to generate
# timeconst.h. openssl is required because arm64 defconfig sets
# CONFIG_MODULE_SIG, so the kernel builds scripts/sign-file.c, which includes
# <openssl/bio.h> -- without it the build stops partway on a missing header
# that reads as a kernel problem and is not one.
#
# perl IS IN THIS LIST AND WAS NOT BEFORE. Phase A built perl into $PFX,
# musl-linked, for glibc's benefit on that side. $PFX is not on this PATH and
# that perl would not run here anyway. glibc's build wants one.
#
# BUSYBOX awk IS NOT ENOUGH and the failure is specific:
#     awk: bad regex '\/[^': Invalid regular expression
#     awk: scripts/sysd-rules.awk:31: Call to undefined function
# which is why gawk is built rather than aliased.
if [ "$B0" = ok ]; then
  b1=ok
  for pk in m4 gawk flex bison perl python bc openssl; do
    [ "$b1" = ok ] || break
    case "$pk" in
      python)  _bin=python3 ;;
      openssl) _bin=openssl ;;
      *)       _bin=$pk ;;
    esac
    # openssl ANSWERS `version`, NOT `--version`, so probing with --version
    # reports a perfectly good openssl as absent and rebuilds it every run.
    case "$pk" in openssl) _vflag=version ;; *) _vflag=--version ;; esac
    if command -v "$_bin" > /dev/null 2>&1 && "$_bin" "$_vflag" > /dev/null 2>&1; then
      say "    $pk: already in the sysroot and runs"
      continue
    fi
    # THE PREFIX IS VERSION-PINNED WHERE /in HOLDS MORE THAN ONE MATCH, and
    # Python's tarball is capital-P. "/in/python-" matches nothing at all;
    # "/in/binutils-" matches BOTH 2.30 and 2.47 and `head -1` takes 2.30 --
    # the version pinned to tcc's ceiling, three rungs below this one.
    case "$pk" in
      python)  _pfx="/in/Python-$PYTHON_VER" ;;
      gawk)    _pfx="/in/gawk-$GAWK_VER" ;;
      m4)      _pfx="/in/m4-$M4_VER" ;;
      bc)      _pfx="/in/bc-$BC_VER" ;;
      bison)   _pfx="/in/bison-$BISON_VER" ;;
      flex)    _pfx="/in/flex-$FLEX_VER" ;;
      perl)    _pfx="/in/perl-$PERL_VER" ;;
      openssl) _pfx="/in/openssl-$OPENSSL_VER" ;;
      *)       _pfx="/in/$pk-" ;;
    esac
    fetch "$_pfx" "$pk" || { b1=FAIL; say "    $pk did not unpack"; break; }
    _d=$FDIR
    # perl and openssl do not use autoconf; each gets its own line.
    case "$pk" in
      perl)
        ( cd "$_d" && ./Configure -des -Dprefix=/usr -Dvendorprefix=/usr \
              > c.log 2>&1 && make -j"$NP" > b.log 2>&1 && make install > i.log 2>&1 ) ;;
      openssl)
        # install_sw, NOT install: the full target builds documentation, which
        # wants perl modules we do not have. INSTALL_LIBS is edited out because
        # a shared build produces no libcrypto.a for it to install -- stage 4's
        # sed, for stage 4's reason.
        ( cd "$_d" && ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib \
              shared no-tests > c.log 2>&1 \
          && make -j"$NP" > b.log 2>&1 \
          && sed -i "/INSTALL_LIBS/s/libcrypto.a libssl.a//" Makefile \
          && make install_sw > i.log 2>&1 ) ;;
      bc)
        # NOT AUTOCONF. bc 7.x is Gavin Howard's rewrite and ships
        # configure.sh; ./configure does not exist, so the shell answers 127.
        # The bridge README records exactly that -- "bc returns 127, meaning
        # its configure script did not execute at all ... not yet diagnosed."
        ( cd "$_d" && { [ -f ./configure.sh ] && sh ./configure.sh --prefix=/usr \
                        || ./configure --prefix=/usr; } > c.log 2>&1 \
          && make -j"$NP" > b.log 2>&1 && make install > i.log 2>&1 ) ;;
      python)
        # --without-ensurepip: pip is not needed by anything here, and its
        # install phase runs the freshly built interpreter over bundled
        # wheels. Nothing in the chain imports it; glibc only wants python3
        # to exist and answer --version.
        ( cd "$_d" && ./configure --prefix=/usr --without-ensurepip > c.log 2>&1 \
          && make -j"$NP" > b.log 2>&1 && make install > i.log 2>&1 ) ;;
      *)
        ( cd "$_d" && ./configure --prefix=/usr > c.log 2>&1 \
          && make -j"$NP" MAKEINFO=true > b.log 2>&1 \
          && make install MAKEINFO=true > i.log 2>&1 ) ;;
    esac
    _rc=$?
    if [ "$_rc" = 0 ] && command -v "$_bin" > /dev/null 2>&1; then
      say "    $pk: installed -- $("$_bin" "$_vflag" 2>&1 | head -1)"
    else
      b1=FAIL; say "    $pk NOT INSTALLED"
      tail -12 "$_d/c.log" 2>/dev/null | sed 's/^/      /'
      tail -12 "$_d/b.log" 2>/dev/null | sed 's/^/      /'
    fi
  done
  # ASSERT THE HEADER, which is the whole reason openssl is on the list.
  if [ "$b1" = ok ]; then
    if [ -f /usr/include/openssl/bio.h ]; then
      say "    openssl/bio.h present -- scripts/sign-file.c can build"
    else
      say "    openssl/bio.h DID NOT INSTALL -- the kernel will stop on it"
      b1=FAIL
    fi
  fi
  # AND THAT gawk IS A REAL ONE, exercising the two constructs that failed.
  # A weak probe, and said to be: both pass on mawk. The strong check is that
  # it was built above rather than aliased.
  if [ "$b1" = ok ]; then
    echo | gawk 'function f(x){return x+1}{print f(1)}' 2>/dev/null | grep -qx 2 \
      || { say "    gawk has no user-defined functions -- glibc will fail"; b1=FAIL; }
  fi
  B1=$b1
fi

# ---------------------------------------------------------------------------
head1 "RUNG B2 -- glibc, rebuilt NATIVELY by gcc pass 2"
# NO --host, NO --build, NO DESTDIR. That is the whole difference from phase
# A's rung 13 and it is the point: this is a native build installing over
# itself, so autoconf's "cross-compilation mode" is off and every feature test
# that needs to RUN a program can run one.
#
# --enable-kernel is carried across unchanged; it is glibc's minimum supported
# kernel and is unrelated to either KHDR or KERNEL.
#
# INSTALLING A LIBC OVER THE RUNNING ONE IS THE RISK IN THIS RUNG. Every
# process here is dynamically linked against the very libc.so.6 being replaced.
# glibc's own install is written for this -- it installs to a temporary name
# and renames, which is atomic -- but a FAILED install halfway through leaves a
# sysroot that cannot run anything, including the tools needed to diagnose it.
# That is why B8 hashes and why the workflow keeps phase A's sysroot cache: a
# broken B2 is recoverable by rerunning phase B, not by repairing in place.
if [ "$B1" = ok ]; then
  if fetch "/in/glibc-$GLIBC" glibc; then
    _d=$FDIR
    # glibc-fhs-1.patch, THE SAME ONE RUNG 13 APPLIES. LFS applies it to the
    # chapter 8 build as well as chapter 5's, and this is a fresh unpack, so
    # it arrives unpatched. It moves the FHS-noncompliant directories glibc
    # would otherwise create.
    if [ -f /in/glibc-fhs-1.patch ]; then
      if ( cd "$_d" && patch -Np1 -i /in/glibc-fhs-1.patch ) > /tmp/gp.log 2>&1; then
        say "    applied glibc-fhs-1.patch"
      else
        say "    glibc-fhs-1.patch DID NOT APPLY:"
        tail -6 /tmp/gp.log | sed 's/^/      /'; B2=FAIL
      fi
    else
      say "    glibc-fhs-1.patch not in /in"; B2=FAIL
    fi
    rm -rf "$W/b-glibc" && mkdir -p "$W/b-glibc" && cd "$W/b-glibc"
    echo "rootsbindir=/usr/sbin" > configparms
    if [ "$B2" = FAIL ]; then
      say "    not configuring -- the patch above did not apply"
    elif "$_d/configure" --prefix=/usr --disable-nscd \
         --enable-kernel="${ENABLE_KERNEL:-5.4}" \
         libc_cv_slibdir=/usr/lib > c.log 2>&1 \
       && timeout 7200 make -j"$NP" > b.log 2>&1 \
       && make install > i.log 2>&1; then
      B2=ok
      say "    glibc rebuilt natively: $(/usr/bin/ldd --version 2>&1 | head -1)"
      # THE TOOLCHAIN MUST STILL WORK AFTER THE LIBC UNDER IT WAS REPLACED.
      # If this fails, nothing below can run and the reason is here rather
      # than three rungs up.
      gcc /tmp/b0.c -o /tmp/b2 2>/dev/null && /tmp/b2 > /dev/null 2>&1
      if [ $? = 42 ]; then
        say "    the compiler still runs against the libc it just replaced"
      else
        say "    THE COMPILER NO LONGER RUNS after the glibc install."
        B2=FAIL
      fi
    else
      B2=FAIL; say "    --- glibc errors ---"
      grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      whyfail c.log
      whyfail b.log
    fi
    cd /
  else B2=FAIL; say "    glibc did not unpack"; fi
fi

# ---------------------------------------------------------------------------
head1 "RUNG B3 -- binutils, rebuilt NATIVELY by gcc pass 2"
# LFS 8.x, and the two lines the book adds that phase A's cross build did not
# need are both about libtool baking in paths from the wrong side. They are
# harmless here and are omitted deliberately rather than forgotten: there is no
# other side any more, because this sandbox contains nothing but the sysroot.
if [ "$B2" = ok ]; then
  if fetch "/in/binutils-$BINUTILS_LFS" binutils; then
    _d=$FDIR
    rm -rf "$W/b-binutils" && mkdir -p "$W/b-binutils" && cd "$W/b-binutils"
    if "$_d/configure" --prefix=/usr --enable-gold=no --enable-ld=default \
         --enable-plugins --enable-shared --disable-werror \
         --enable-64-bit-bfd --enable-new-dtags --enable-gprofng=no \
         --disable-nls > c.log 2>&1 \
       && timeout 5400 make -j"$NP" MAKEINFO=true > b.log 2>&1 \
       && make install MAKEINFO=true > i.log 2>&1; then
      B3=ok; say "    binutils: $(ld --version 2>&1 | head -1)"
    else
      B3=FAIL; say "    --- binutils errors ---"
      grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      whyfail b.log
    fi
    cd /
  else B3=FAIL; say "    binutils did not unpack"; fi
fi

# ---------------------------------------------------------------------------
head1 "RUNG B4 -- gcc, rebuilt NATIVELY.  THIS IS THE FINAL COMPILER."
# build == host == target, no sysroot, no cross prefix. Everything below this
# rung is built by what it installs, and nothing above it contributes a byte to
# the image.
#
# gmp/mpfr/mpc GO IN-TREE, which is what the book does and what stage 4 calls
# "simpler and more reliable than a separate prefix".
#
# --disable-bootstrap: the repository's standing choice, so that this build is
# a MEASUREMENT of gcc pass 2 rather than a fixpoint of itself. The determinism
# claim is made by rerun in B8.
if [ "$B3" = ok ]; then
  if fetch "/in/gcc-$GCC15" gcc; then
    _d=$FDIR
    # THE t-aarch64-linux SED, AND THIS TREE IS A FRESH ONE.
    #
    # Rung 11 applies this to the tree PHASE A unpacked. B4 unpacks its own
    # copy from /in, so it arrives unpatched and the edit has to happen again
    # -- a fresh tarball carries none of phase A's source edits.
    #
    # LFS seds gcc/config/i386/t-linux64 for x86_64; the aarch64 file doing
    # the same job is t-aarch64-linux, and nothing in the book covers aarch64
    # so this is ours. Without it libstdc++ installs into /usr/lib64, a
    # directory this sysroot has no symlink to. g++ still LINKS -- the program
    # dies at exec with "error while loading shared libraries: libstdc++.so.6",
    # which reads as a broken C++ runtime rather than a misplaced file.
    #
    # ASSERT THE ANCHOR. A sed that matches nothing ships an unchanged file
    # and looks exactly like a sed that worked, so this fails here rather
    # than at exec time in the guest.
    _t="$_d/gcc/config/aarch64/t-aarch64-linux"
    if [ ! -f "$_t" ]; then
      say "    $_t is missing -- gcc has moved this file"; B4=FAIL
    elif ! grep -q 'mabi\.lp64=' "$_t"; then
      say "    $_t has no mabi.lp64= line. It now reads:"
      sed 's/^/      /' "$_t"; B4=FAIL
    else
      sed -e '/mabi\.lp64=/s|lib64|lib|' -i.orig "$_t"
      say "    64-bit libdir: $(grep 'mabi\.lp64=' "$_t")"
    fi
    for _lib in gmp mpfr mpc; do
      if fetch "/in/$_lib-" "il-$_lib"; then
        mv "$FDIR" "$_d/$_lib" 2>/dev/null \
          || say "    $_lib could not be moved in-tree"
      else
        say "    $_lib did not unpack -- gcc will look for a system copy"
      fi
    done
    rm -rf "$W/b-gcc" && mkdir -p "$W/b-gcc" && cd "$W/b-gcc"
    # LD=ld IS THE BOOK'S, and it stops gcc's configure picking a linker other
    # than the binutils B3 just installed.
    if [ "$B4" = FAIL ]; then
      say "    not configuring -- the source edit above did not take"
    elif "$_d/configure" --prefix=/usr LD=ld --disable-multilib --disable-bootstrap \
         --disable-fixincludes --enable-default-pie \
         --enable-default-ssp --disable-nls --enable-languages=c,c++ \
         > c.log 2>&1 \
       && timeout 14400 make -j"$NP" > b.log 2>&1 \
       && make install > i.log 2>&1; then
      ln -sf gcc /usr/bin/cc 2>/dev/null || true
      B4=ok
      say "    FINAL COMPILER: $(gcc --version 2>&1 | head -1)"
      say "    from:           $(command -v gcc)"
      gcc /tmp/b0.c -o /tmp/b4 2>/dev/null && /tmp/b4 > /dev/null 2>&1
      if [ $? = 42 ]; then
        say "    it compiles, links and runs"
      else
        say "    THE FINAL COMPILER DOES NOT PRODUCE A WORKING BINARY"; B4=FAIL
      fi
    else
      B4=FAIL; say "    --- gcc errors ---"
      grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      whyfail b.log
    fi
    cd /
  else B4=FAIL; say "    gcc did not unpack"; fi
fi

# ---------------------------------------------------------------------------
head1 "RUNG B5 -- busybox, BY THE FINAL COMPILER.  This is the one that ships."
# THE COPY PHASE A INSTALLED IS OVERWRITTEN HERE, deliberately. That one was
# cross-built by gcc 15 pass 1 and existed only to provide /usr/bin/sh so this
# phase could run a configure script at all. It is a chapter 6 tool; this is
# its chapter 8 replacement, and it is what the initramfs runs.
#
# CONFIG_STATIC, ASSERTED AFTER oldconfig. The initramfs has no loader and no
# libc, so a dynamic busybox cannot run as init at all. oldconfig re-derives
# symbols and has undone this exact edit before, in this repository, three runs
# running -- and a sed that matches nothing ships an unchanged file and looks
# exactly like a sed that worked.
#
# CONFIG_TC OFF: busybox 1.36.1 predates the removal of CBQ traffic control
# from the kernel, so tc.c cannot compile against linux 7.x headers at all.
# CONFIG_TLS/SSL_CLIENT OFF: reaches for LONG_BIT without the feature macro.
if [ "$B4" = ok ]; then
  if fetch "/in/busybox-$BUSYBOX_VER" busybox; then
    _d=$FDIR
    cd "$_d"
    make defconfig > /dev/null 2>&1
    yes '' | make oldconfig > /dev/null 2>&1
    for _sym in SSL_CLIENT FEATURE_WGET_OPENSSL TLS TC; do
      sed -i "s/^CONFIG_$_sym=y/# CONFIG_$_sym is not set/" .config
    done
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    grep -q '^CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config
    yes '' | make oldconfig > /dev/null 2>&1
    _bad=0
    grep -q '^CONFIG_STATIC=y' .config || { say "    CONFIG_STATIC did not survive oldconfig"; _bad=1; }
    grep -qE '^CONFIG_(TLS|SSL_CLIENT|TC)=y' .config && { say "    TLS/TC came back after oldconfig"; _bad=1; }
    if [ "$_bad" != 0 ]; then
      grep -E '^(# )?CONFIG_(STATIC|TLS|SSL_CLIENT|TC)' .config | sed 's/^/      /'
      B5=FAIL
    elif timeout 3600 make CFLAGS_EXTRA="-D_GNU_SOURCE" -j"$NP" > b.log 2>&1 \
         && [ -x busybox ]; then
      # A STATIC ELF HAS NO PT_INTERP; readelf says so exactly. Not a grep for
      # a substring, which is what reported "static: NO" for a static binary.
      if readelf -l busybox 2>/dev/null | grep -q "interpreter"; then
        say "    NOT STATIC -- this busybox cannot be init"
        readelf -l busybox 2>/dev/null | grep -A1 interpreter | head -2 | sed 's/^/      /'
        B5=FAIL
      else
        install -m 0755 busybox /usr/bin/busybox
        # THE SHA OF WHAT THE FINAL COMPILER JUST BUILT, RECORDED FOR B7.
        #
        # Phase A also installs a busybox here -- cross-compiled by gcc 15
        # PASS 1, purely so this sandbox had a /usr/bin/sh to run a configure
        # script with. It is a chapter 6 tool and it must not ship.
        #
        # Control flow already prevents that: B7 is gated on B6, B6 on B5, so
        # a failed rebuild produces no initramfs at all rather than one
        # holding the pass-1 copy. But that is an ARGUMENT, and this file
        # holds everything else to a measurement. B7 compares against this.
        sha256sum busybox | cut -d" " -f1 > "$W/busybox.sha"
        ( cd /usr/bin && ./busybox --install -s . 2>/dev/null ) || \
          ( cd /usr/bin && for _a in $(./busybox --list 2>/dev/null); do
              [ "$_a" = busybox ] || ln -sf busybox "$_a"; done )
        B5=ok
        say "    busybox: $(wc -c < busybox) bytes, static, $(./busybox --list | wc -l) applets"
        say "    built by: $(gcc --version 2>&1 | head -1)"
      fi
    else
      B5=FAIL; say "    --- errors ---"
      grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      whyfail b.log
    fi
    cd /
  else B5=FAIL; say "    busybox did not unpack"; fi
fi

# ---------------------------------------------------------------------------
head1 "RUNG B6 -- the kernel, BY THE FINAL COMPILER"
# NATIVELY, WITH NO CROSS_COMPILE AT ALL, which is what LFS chapter 10 does and
# what stage4-complete's box15.sh does. An earlier revision cross-compiled this
# with $LFS_TGT-gcc -- pass 1, built --without-headers before a libc existed --
# which produces a working kernel and the wrong claim.
#
# A FRESH TREE, not the one phase A ran `headers_install` in: that one was
# mrproper'd and had another compiler in it.
#
# THE CONFIG EDITS, AND WHY EACH:
#   WERROR off        a 2026 gcc warns about 2026 kernel code and -Werror turns
#                     every warning into a build failure
#   DEVTMPFS+_MOUNT   bwrap is unprivileged so the initramfs cannot mknod
#                     /dev/console; the kernel mounts devtmpfs before running
#                     init, so /dev/console exists by the time init opens it
#   9P + 9P_VIRTIO    lets qemu hand this sysroot to the guest read-only so the
#                     booted kernel can run the compiler that built it.
#                     Verified softly -- a kernel that boots is a good result
#                     whether or not 9p is there.
if [ "$B5" = ok ]; then
  if fetch "/in/linux-$KERNEL" linux; then
    _d=$FDIR
    cd "$_d"
    make ARCH=arm64 defconfig > /dev/null 2>&1
    set_cfg() {   # $1 = symbol without CONFIG_, $2 = y|n
      sed -i "/^CONFIG_$1=/d; /^# CONFIG_$1 is not set/d" .config
      if [ "$2" = y ]; then echo "CONFIG_$1=y" >> .config
      else echo "# CONFIG_$1 is not set" >> .config; fi
    }
    set_cfg WERROR n
    set_cfg DEVTMPFS y
    set_cfg DEVTMPFS_MOUNT y
    set_cfg NET_9P y
    set_cfg NET_9P_VIRTIO y
    set_cfg 9P_FS y
    make ARCH=arm64 olddefconfig > /dev/null 2>&1
    _bad=0
    grep -q "^CONFIG_WERROR=y" .config && { say "    WERROR came back after olddefconfig"; _bad=1; }
    grep -q "^CONFIG_DEVTMPFS_MOUNT=y" .config || { say "    DEVTMPFS_MOUNT did not take"; _bad=1; }
    # EACH 9p SYMBOL BY NAME. stage4-complete does this, and the reason is that
    # "9p unavailable" in the guest is the same message whether the kernel
    # lacks the protocol, the transport or the filesystem -- three different
    # fixes behind one string. NOT fatal: the in-guest compiler test is a
    # bonus and a kernel that boots is a good result without it.
    for _sym in NET_9P NET_9P_VIRTIO 9P_FS; do
      if grep -q "^CONFIG_$_sym=y" .config; then
        printf '    9p: CONFIG_%-14s on\n' "$_sym"
      else
        printf '    9p: CONFIG_%-14s NOT SET -- in-guest gcc test will be skipped\n' "$_sym"
      fi
    done
    if [ "$_bad" != 0 ]; then
      grep -E "^(# )?CONFIG_(WERROR|DEVTMPFS)" .config | sed 's/^/      /'; B6=FAIL
    else
      say "    building with: $(gcc --version 2>&1 | head -1)"
      if timeout 7200 make ARCH=arm64 -j"$NP" Image > b.log 2>&1 \
         && [ -f arch/arm64/boot/Image ]; then
        cp arch/arm64/boot/Image "$W/Image"; B6=ok
        say "    Image: $(wc -c < "$W/Image") bytes"
      else
        B6=FAIL; say "    --- errors ---"
        grep -nE "error:|Error [0-9]|No rule to make" b.log 2>/dev/null | head -15 | sed 's/^/      /'
      whyfail b.log
      fi
    fi
    cd /
  else B6=FAIL; say "    linux did not unpack"; fi
fi

# ---------------------------------------------------------------------------
head1 "RUNG B7 -- initramfs"
# The busybox from B5 plus an init script. cpio newc, gzipped, which is what
# the kernel unpacks.
if [ "$B6" = ok ]; then
  rm -rf "$W/ir" && mkdir -p "$W/ir/bin" "$W/ir/dev" "$W/ir/proc" "$W/ir/sys" \
                             "$W/ir/mnt/sysroot" "$W/ir/tmp" "$W/ir/tests"
  cp /usr/bin/busybox "$W/ir/bin/busybox"
  # IS THIS THE ONE B5 BUILT, OR THE PASS-1 COPY PHASE A LEFT?
  #
  # Asked of the bytes rather than inferred from which rungs ran. If these
  # differ, something overwrote /usr/bin/busybox between B5 and here and the
  # initramfs would ship a binary from the wrong compiler -- the single thing
  # this phase exists to prevent.
  _want=$(cat "$W/busybox.sha" 2>/dev/null || echo missing)
  _got=$(sha256sum "$W/ir/bin/busybox" | cut -d' ' -f1)
  if [ "$_want" = "$_got" ]; then
    say "    busybox in the initramfs is B5's: $(echo "$_got" | cut -c1-16)"
  else
    say "    THE BUSYBOX BEING PACKED IS NOT THE ONE B5 BUILT."
    say "      B5 built:  $_want"
    say "      packing:   $_got"
    say "    That is the pass-1 cross copy or something else entirely, and it"
    say "    must not ship. Stopping."
    B7=FAIL
  fi
fi
if [ "$B6" = ok ] && [ "$B7" != FAIL ]; then

  # BINARIES FOR THE GUEST TO RUN, COMPILED BY THE FINAL COMPILER.
  #
  # "Reaching userspace is not the same as being a good build" is
  # stage4-complete's phrasing, and its boot step fails the job when these
  # fail. A kernel that reaches a shell proves the kernel; it proves nothing
  # about the compiler that built the userland beside it. These do, and
  # without them a miscompiling gcc produces a green run.
  #
  # STATIC, NECESSARILY: the initramfs has no loader and no libc, so anything
  # dynamic cannot run there at all. That also makes this an exercise of the
  # final gcc's static link path, libstdc++.a and libm.a included.
  #
  # Each exits 0 on success, so init counts instead of parsing.
  _tsrc=$W/tsrc; rm -rf "$_tsrc"; mkdir -p "$_tsrc"
  cat > "$_tsrc/t_printf.c" <<'EOF'
#include <stdio.h>
int main(void){ char b[64]; snprintf(b,sizeof b,"%d-%s-%.2f",7,"x",1.5);
  return !(b[0]=='7' && b[2]=='x'); }
EOF
  cat > "$_tsrc/t_malloc.c" <<'EOF'
#include <stdlib.h>
#include <string.h>
int main(void){ char *p=malloc(1<<20); if(!p) return 1; memset(p,0xA5,1<<20);
  int bad=(unsigned char)p[(1<<20)-1]!=0xA5; free(p); return bad; }
EOF
  cat > "$_tsrc/t_string.c" <<'EOF'
#include <string.h>
int main(void){ char b[32]="veron"; strcat(b,"-ok");
  return !(strcmp(b,"veron-ok")==0 && strlen(b)==8 && strstr(b,"-ok")!=0); }
EOF
  cat > "$_tsrc/t_math.c" <<'EOF'
#include <math.h>
int main(void){ double r=sqrt(2.0);
  return !(r>1.41421 && r<1.41422 && fabs(pow(2.0,10.0)-1024.0)<1e-9); }
EOF
  cat > "$_tsrc/t_file.c" <<'EOF'
#include <stdio.h>
#include <string.h>
int main(void){ char b[16]={0}; FILE*f=fopen("/tmp/t","w"); if(!f) return 1;
  fputs("veron",f); fclose(f); f=fopen("/tmp/t","r"); if(!f) return 2;
  if(!fgets(b,sizeof b,f)) return 3; fclose(f); return strcmp(b,"veron")!=0; }
EOF
  cat > "$_tsrc/t_fork.c" <<'EOF'
#include <sys/wait.h>
#include <unistd.h>
int main(void){ pid_t p=fork(); if(p<0) return 1; if(p==0) _exit(7);
  int st=0; if(waitpid(p,&st,0)<0) return 2;
  return !(WIFEXITED(st) && WEXITSTATUS(st)==7); }
EOF
  cat > "$_tsrc/t_time.c" <<'EOF'
#include <time.h>
int main(void){ struct timespec ts;
  if(clock_gettime(CLOCK_MONOTONIC,&ts)) return 1; return !(time(0)>0); }
EOF
  cat > "$_tsrc/t_cxx.cc" <<'EOF'
#include <string>
#include <vector>
#include <stdexcept>
int main(){ std::vector<std::string> v{"a","b"}; v.push_back("c");
  int caught=0;
  try { throw std::runtime_error("x"); } catch (const std::exception&) { caught=1; }
  return !(v.size()==3 && v[2]=="c" && caught); }
EOF
  _tn=0
  for _t in "$_tsrc"/t_*.c; do
    _tb=$(basename "$_t" .c)
    if gcc -static -O2 "$_t" -o "$W/ir/tests/$_tb" -lm 2>/dev/null; then
      _tn=$((_tn+1))
    else
      say "    could not build $_tb -- the guest will run one test fewer"
    fi
  done
  # C++ SEPARATELY, because a failure here is a different fact: it says
  # libstdc++.a or the static exception tables are wrong, not that C is.
  if g++ -static -O2 "$_tsrc/t_cxx.cc" -o "$W/ir/tests/t_cxx" 2>/dev/null; then
    _tn=$((_tn+1))
  else
    say "    could not build t_cxx -- static libstdc++ or EH tables are missing"
  fi
  say "    guest test binaries: $_tn, static, by gcc $(gcc -dumpversion)"
  ( cd "$W/ir" && ./bin/busybox --list > /tmp/applets.txt 2>/dev/null
    while read -r a; do ln -sf busybox "bin/$a" 2>/dev/null; done < /tmp/applets.txt )
  if ( cd "$W/ir" && mknod dev/console c 5 1 2>/dev/null ); then
    say "    /dev/console created in the image"
  else
    say "    no mknod here -- /dev/console comes from CONFIG_DEVTMPFS_MOUNT"
  fi
cat > "$W/ir/init" <<'INIT'
#!/bin/sh
mount -t proc  none /proc 2>/dev/null
mount -t sysfs none /sys  2>/dev/null
mount -t tmpfs none /tmp  2>/dev/null
echo
echo "================================================"
echo "  VERON-BRIDGE: the guest, reporting on itself"
echo "================================================"
echo "VERON-BOOT-OK $(uname -srm)"
# /proc/version CARRIES BOTH TOOLCHAIN VERSIONS -- the gcc and the GNU ld that
# built this kernel. That is the single most useful line in the whole boot,
# because it is the kernel itself saying which compiler produced it.
echo "VERON-COMPILER $(cat /proc/version)"

echo "=== VERON-TESTS: binaries this chain compiled, run under this kernel ==="
tp=0; tf=0
for t in /tests/*; do
  [ -x "$t" ] || continue
  if "$t"; then
    echo "   $(basename "$t") PASS"; tp=$((tp+1))
  else
    echo "   $(basename "$t") FAIL rc=$?"; tf=$((tf+1))
  fi
done
echo "VERON-TESTS pass=$tp fail=$tf"

echo "=== VERON-GCC-IN-GUEST: the compiler, inside the kernel it built ==="
# OPTIONAL AND NON-FATAL. qemu offers the sysroot over 9p; if the share is
# absent, or 9p is not in this kernel, this is skipped and the boot still
# counts. The share is READ-ONLY, so the compile cannot write into it --
# a tmpfs is bound over the chroot's /tmp for the output.
if mount -t 9p -o trans=virtio,version=9p2000.L,ro,msize=262144 \
         veronsysroot /mnt/sysroot 2>/dev/null; then
  echo "   9p sysroot mounted read-only"
  if [ -x /mnt/sysroot/usr/bin/gcc ]; then
    mkdir -p /tmp/out
    mount --bind /tmp/out /mnt/sysroot/tmp 2>/dev/null
    printf 'int main(void){return 42;}\n' > /tmp/out/g.c
    if chroot /mnt/sysroot /usr/bin/gcc /tmp/g.c -o /tmp/g 2>/tmp/out/g.err; then
      chroot /mnt/sysroot /tmp/g
      echo "VERON-GCC-IN-GUEST ok compiled and ran, rc=$? (expect 42)"
    else
      echo "VERON-GCC-IN-GUEST compile failed: $(head -1 /tmp/out/g.err)"
    fi
  else
    echo "VERON-GCC-IN-GUEST skipped: no gcc in the shared sysroot"
  fi
else
  echo "VERON-GCC-IN-GUEST skipped: no 9p share offered or 9p not in the kernel"
fi

# THE LAST LINE, AND THE BOOT STEP GATES ON IT. Without it there is no way to
# tell a guest that finished from one that died silently after the tests.
echo "VERON-DONE"
echo
poweroff -f 2>/dev/null || { sync; echo o > /proc/sysrq-trigger; }
INIT
  chmod 0755 "$W/ir/init"
  ( cd "$W/ir" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$W/initramfs.cpio.gz" )
  if [ -s "$W/initramfs.cpio.gz" ]; then
    B7=ok; say "    initramfs: $(wc -c < "$W/initramfs.cpio.gz") bytes"
  else
    B7=FAIL; say "    cpio produced nothing"
  fi
fi

# ---------------------------------------------------------------------------
head1 "RUNG B8 -- hand out the image, and hash what left"
# THE BOOT ITSELF CANNOT HAPPEN IN HERE. qemu-system-aarch64 is not in this
# sandbox and should not be: it is a VERIFIER, not a build tool, exactly as
# stage 4 treats it. The workflow runs it outside on what this rung leaves.
#
# THE HASHES ARE THE DETERMINISM CLAIM, and nothing in this job emitted them
# before -- every sha256sum in the workflow was on an INPUT. Two runs of the
# same commit printing the same lines below is the evidence that this chain is
# deterministic. That is a weaker property than a bootstrap fixpoint and a
# cheaper one, and it is the property being claimed.
if [ "$B7" = ok ]; then
  mkdir -p /out
  cp "$W/Image" /out/Image 2>/dev/null
  cp "$W/initramfs.cpio.gz" /out/initramfs.cpio.gz 2>/dev/null
  if [ -s /out/Image ] && [ -s /out/initramfs.cpio.gz ]; then
    B8=ok
  else
    B8=FAIL; say "    nothing landed in /out"
  fi
fi

say ""
say "  --- THE FINAL TOOLCHAIN, HASHED ---"
for f in /usr/bin/gcc /usr/bin/ld /usr/bin/as /usr/lib/libc.so.6 /usr/bin/busybox; do
  if [ -f "$f" ]; then
    printf '    %-24s %12s  %s\n' "$f" "$(wc -c < "$f")" "$(sha256sum "$f" | cut -c1-32)"
  else
    printf '    %-24s %12s\n' "$f" "ABSENT"
  fi
done
# cc1/cc1plus are the compiler proper; the driver is a thin wrapper and two
# different cc1s behind an identical gcc would compare equal above.
for f in $(ls /usr/libexec/gcc/*/*/cc1 /usr/libexec/gcc/*/*/cc1plus 2>/dev/null); do
  printf '    %-24s %12s  %s\n' "${f##*/}" "$(wc -c < "$f")" "$(sha256sum "$f" | cut -c1-32)"
done
say ""
say "  --- WHAT LEFT THE SANDBOX ---"
for f in /out/Image /out/initramfs.cpio.gz; do
  if [ -f "$f" ]; then
    printf '    %-24s %12s  %s\n' "${f##*/}" "$(wc -c < "$f")" "$(sha256sum "$f" | cut -c1-32)"
  fi
done

# ---------------------------------------------------------------------------
head1 "PHASE B -- arm: $ARM"
printf '    %-44s %s\n' "B0  sysroot usable"                    "$B0"
printf '    %-44s %s\n' "B1  prerequisites by gcc pass 2"       "$B1"
printf '    %-44s %s\n' "B2  glibc, native"                     "$B2"
printf '    %-44s %s\n' "B3  binutils, native"                  "$B3"
printf '    %-44s %s\n' "B4  gcc, native -- FINAL COMPILER"     "$B4"
printf '    %-44s %s\n' "B5  busybox, by the final compiler"    "$B5"
printf '    %-44s %s\n' "B6  linux, by the final compiler"      "$B6"
printf '    %-44s %s\n' "B7  initramfs"                         "$B7"
printf '    %-44s %s\n' "B8  handed out"                        "$B8"
say ""
if [ "$B8" = ok ]; then
  say "  EVERYTHING IN /out WAS BUILT BY THE COMPILER B4 INSTALLED,"
  say "  against the glibc B2 installed, with the cross toolchain"
  say "  unreachable from this sandbox's PATH."
else
  say "  The image is incomplete. The first FAIL above is the cause;"
  say "  everything after it was skipped rather than failed."
fi
