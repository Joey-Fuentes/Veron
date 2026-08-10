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
# If something below reaches for $VERON_TOOLCHAIN_TGT-gcc it fails loudly instead of
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

# HASH AND SIZE FOR EVERY OUTPUT, LOGGED AND RECORDED.
#
# Two consumers, one call. The log line is for a human reading the run; the
# TSV in /out is the machine-readable half and is the seed of the `files`
# manifest DERIVATIONS.md specifies for a ledger record.
#
# THE PRINTED HASH IS TRUNCATED AND SAYS SO. The previous reporting used
# `sha256sum | cut -c1-32`, and 32 hex characters is exactly MD5's length --
# so the log showed what read as an md5, was a truncated sha256, and could be
# checked as neither without already knowing the trick. Sixteen characters plus
# an ellipsis cannot be mistaken for a whole hash, and the untruncated value
# goes in the manifest. Artifacts that leave the sandbox get their full sha256
# printed too, because those are the ones someone outside will verify.
#
# WHY SIZE AS WELL AS HASH. A hash says two things differ; a size says by how
# much, and that is often the whole diagnosis. Two gcc builds differing by
# 0.17% are the same version configured differently; two differing by 30% are
# different versions. Without the size that distinction costs a round.
#
# FULL PATHS, NEVER BASENAMES. `${f##*/}` printed two `cc1` lines with
# different hashes and no way to tell which install each came from -- the
# report looked like a reproducibility failure and was a stripped path. If a
# name can collide, print what disambiguates it.
MANIFEST=${MANIFEST:-/out/manifest.tsv}
# Columns: path, exact size in bytes, first 16 hex of sha256 followed by an
# ellipsis. The ellipsis is deliberate -- it makes truncation visible at a
# glance. Full sha256 for every entry is in $MANIFEST.
hashout() {
    # $1 = label (stage/rung), $2 = path
    _p="$2"
    if [ ! -e "$_p" ]; then
        printf '    %-44s %14s\n' "$_p" "ABSENT"
        return 0
    fi
    _sz=$(wc -c < "$_p" 2>/dev/null || echo 0)
    _sh=$(sha256sum "$_p" 2>/dev/null | cut -d" " -f1)
    printf '    %-44s %14s  %s…\n' "$_p" "$_sz" "$(printf '%s' "$_sh" | cut -c1-16)"
    printf '%s\t%s\t%s\t%s\n' "$1" "$_p" "$_sz" "$_sh" >> "$MANIFEST" 2>/dev/null || true
}

# The phase-B half of the same pair. head1 sets RUNG; produced prints an
# artifact with its exact size and full sha256 and records it; consumed records
# an input silently. See rungs.sh for why the label is derived rather than
# passed.
RUNG=B
produced() {
    for _o in "$@"; do
        if [ -e "$_o" ]; then
            printf '    -> %-40s %12s  %s\n' "$_o" \
                "$(wc -c < "$_o" 2>/dev/null || echo 0)" \
                "$(sha256sum "$_o" 2>/dev/null | cut -d' ' -f1)"
            printf 'OUT.%s\t%s\t%s\t%s\n' "$RUNG" "$_o" \
                "$(wc -c < "$_o" 2>/dev/null || echo 0)" \
                "$(sha256sum "$_o" 2>/dev/null | cut -d" " -f1)" >> "$MANIFEST" 2>/dev/null || true
        else
            printf '    -> %-40s %12s\n' "$_o" "ABSENT"
        fi
    done
}
consumed() {
    for _i in "$@"; do
        [ -e "$_i" ] || continue
        printf 'IN.%s\t%s\t%s\t%s\n' "$RUNG" "$_i" \
            "$(wc -c < "$_i" 2>/dev/null || echo 0)" \
            "$(sha256sum "$_i" 2>/dev/null | cut -d" " -f1)" >> "$MANIFEST" 2>/dev/null || true
    done
}

# Every regular file under a tree, for whole-sysroot manifesting. Sorted, so
# two runs produce comparable files rather than filesystem-order noise.
hashtree() {
    # $1 = label, $2 = root
    [ -d "$2" ] || return 0
    find "$2" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r _f; do
        printf '%s\t%s\t%s\t%s\n' "$1" "$_f" \
            "$(wc -c < "$_f" 2>/dev/null || echo 0)" \
            "$(sha256sum "$_f" 2>/dev/null | cut -d" " -f1)" >> "$MANIFEST" 2>/dev/null || true
    done
    printf '    %-44s %14s files manifested\n' "$2" \
        "$(find "$2" -type f 2>/dev/null | wc -l)"
}
head1() { say ""; say "  === $* ==="; }
onedir() { ls -d $1 2>/dev/null | head -1 | sed 's|^\./||'; }

# WHERE IT FAILED, NOT WHAT FINISHED LAST -- the same helper phase A grew, and
# for the same reason: under `make -j` a tail lands on whichever module
# finished last, which is by definition one that SUCCEEDED. A gcc build that
# died in build-fixincludes printed twenty-five lines of gmp's libtool
# succeeding, and the real ld message was never logged.
whyfail() {        # $1 = logfile
    [ -s "$1" ] || { say "      (no $1)"; return; }
    # ANCHOR PATTERNS, NARROWED. This used to include "No such file" and
    # "cannot find", both of which fire constantly in healthy build output --
    # glibc's own build probes /sys/kernel/mm/transparent_hugepage/enabled
    # with grep and gets "No such file or directory" every time. B2 anchored
    # on that, printed the window around a harmless line, and the real
    # failure never reached the log.
    _n=$(grep -nE "error:|Error [0-9]|\*\*\* |undefined reference" "$1" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$_n" ]; then
        _from=1; [ "$_n" -gt 30 ] && _from=$(( _n - 30 ))
        say "      --- $1, around the first error (line $_n of $(wc -l < "$1")) ---"
        sed -n "${_from},$(( _n + 8 ))p" "$1" | sed 's/^/      /'
    else
        say "      --- $1: no line matched an error pattern ---"
    fi
    # AND THE TAIL, ALWAYS. Under `make -j` the failing recipe is usually the
    # last thing written, and an anchor that guesses wrong has now cost three
    # rounds. Two windows cannot both miss.
    say "      --- $1, last 25 lines ---"
    tail -25 "$1" | sed 's/^/      /'
    say "      (full log uploaded as the buildlogs artifact)"
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
  # sh HAS NO --version. busybox ash answers non-zero and prints nothing, so
  # the old line reported a blank and the `|| [ "$_n" = sh ]` escape hatch let
  # it pass without measuring anything. Exercise it instead.
  if [ "$_n" = sh ]; then
    sh -c 'exit 7'; _sr=$?
    if [ "$_sr" = 7 ]; then
      printf '    %-5s runs (sh -c "exit 7" -> 7)\n' "$_n"
    else
      printf '    %-5s DOES NOT RUN (rc=%s)\n' "$_n" "$_sr"; _ok=no
    fi
    continue
  fi
  if "$_n" --version > /dev/null 2>&1; then
    printf '    %-5s %s\n' "$_n" "$("$_n" --version 2>&1 | head -1)"
  else
    printf '    %-5s present, DOES NOT EXECUTE\n' "$_n"; _ok=no
  fi
done
# AND THAT THE CROSS TOOLCHAIN IS UNREACHABLE, which is the property the PATH
# is enforcing. Reported rather than assumed, because a PATH is easy to widen
# by accident and the consequence -- an artifact built by pass 1 -- is silent.
# ASK WHERE IT RESOLVES, NOT WHETHER THE NAME EXISTS.
#
# This used to be `command -v $VERON_TOOLCHAIN_TGT-gcc` and it failed run 120 on a
# correctly built sysroot. gcc pass 2 is configured --target=$VERON_TOOLCHAIN_TGT, so it
# installs its driver under BOTH names: /usr/bin/gcc and
# /usr/bin/x86_64-veron-linux-gnu-gcc. The prefixed name is the SYSROOT's
# own final compiler, not pass 1 -- the check matched on a name the right
# answer also has.
#
# What actually matters is that nothing resolves into /tools, where pass 1
# lives. Both halves of pass 1 are musl-static and would run in here quite
# happily, so this is the only thing keeping "built by the final toolchain"
# enforced rather than assumed.
_xp=$(command -v "${VERON_TOOLCHAIN_TGT:-x86_64-toolchain-linux-gnu}-gcc" 2>/dev/null || true)
case "$_xp" in
  /tools/*) say "    $_xp RESOLVES INTO /tools -- that is pass 1, the cross"
            say "    compiler. Everything below would be built by the wrong"
            say "    toolchain. Not proceeding."
            _ok=no ;;
  "")       say "    no ${VERON_TOOLCHAIN_TGT:-x86_64-toolchain-linux-gnu}-gcc on PATH" ;;
  *)        say "    ${VERON_TOOLCHAIN_TGT:-x86_64-toolchain-linux-gnu}-gcc -> $_xp"
            say "      (the sysroot's own gcc pass 2 under its target name,"
            say "       not /tools -- gcc installs both names)" ;;
esac
case ":$PATH:" in
  *:/tools/bin:*) say "    /tools/bin IS ON PATH -- pass 1 is reachable"; _ok=no ;;
  *)              say "    /tools/bin not on PATH: correct (this is the point)" ;;
esac
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
    # A SYMLINK IS NOT AN INSTALLED PACKAGE, AND THIS IS WHERE busybox LIES.
    #
    # Rung 15 ends with an applet symlink loop, which puts a symlink in
    # /usr/bin for EVERY applet busybox has -- and busybox has bc, dc, patch,
    # awk and more. A probe of "does the name exist and answer --version"
    # therefore reports the applet as the package, and the real one is never
    # built. stage4-complete names that outcome precisely: BusyBox's bc "may
    # well work, but nothing here declared it, which is the failure mode this
    # repository is built to avoid."
    #
    # So the skip requires a REGULAR FILE. An applet symlink falls through to
    # the build, which is what we want.
    _p=$(command -v "$_bin" 2>/dev/null || true)
    if [ -n "$_p" ] && [ ! -L "$_p" ] && "$_bin" "$_vflag" > /dev/null 2>&1; then
      say "    $pk: already in the sysroot as a real binary, and runs"
      continue
    fi
    [ -n "$_p" ] && [ -L "$_p" ] && \
      say "    $pk: /usr/bin/$_bin is a busybox applet symlink -- building the real one"
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
        # -Dcc, NOT CC=. perl's Configure is not autoconf and takes its
        # compiler as a -D flag; CC= in the environment is ignored. Rung 11.5
        # records that.
        #
        # ITS Configure NEEDS split AND comm, WHICH busybox LACKS AT DEFCONFIG.
        # Rung 11.5 hit "./Configure: line 2135: split: not found" and wrote
        # both in C into $PFX. $PFX is not on this PATH and must not be, so
        # rung 15 now compiles the SPLIT and COMM applets into the sysroot's
        # busybox instead. If this rung dies naming either, that is where to
        # look -- not here.
        #
        # -Doptimize IS PASSED EXPLICITLY because Configure otherwise picks
        # its own; rung 11.5 pins it for the same reason. No -Dusedl=undef
        # and no -Dldflags=-static here: those made a static perl for a
        # loader-less box, and this sysroot has a loader.
        # stage4-complete's line, which boots: ./Configure -des -Dprefix=/usr
        # -Dcc=gcc. An earlier revision of this rung added -Doptimize and
        # -Dvendorprefix from nowhere -- rung 11.5 passes -Doptimize because
        # its perl is a static build for a musl box, which this is not.
        ( cd "$_d" && ./Configure -des -Dprefix=/usr -Dcc=gcc \
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
        # DELETE THE APPLET SYMLINKS FIRST, AND NOT FOR TIDINESS.
        #
        # This is stage4-complete's block and its reason is the sharp one:
        # /usr/bin/bc and /usr/bin/dc are symlinks to busybox left by
        # `busybox --install`, so a `make install` that writes to /usr/bin/bc
        # writes THROUGH the link and lands on /usr/bin/busybox -- "which is
        # the shell, ls, sed, grep and tar this box is made of." Unlink, then
        # install.
        #
        # dc MATTERS AS MUCH AS bc AND IS EASIER TO MISS: bc's package
        # installs both, and nothing above probes for dc at all.
        rm -f /usr/bin/bc /usr/bin/dc
        # LFS 8.15 is CC="gcc -std=c99" ./configure --prefix=/usr -G -O3 -r.
        # -r enables readline and this sysroot has none -- LFS builds it
        # earlier in chapter 8 and we build far fewer packages than the book.
        # Dropping -r is a DECLARED SUBSTITUTION: bc here has no line
        # editing, and nothing in a kernel build types at it. stage4-complete
        # drops it for the same reason. Everything else is the book verbatim.
        #
        # -std=c99 IS LOAD-BEARING, not decoration; it is in the book's line.
        ( cd "$_d" && CC="gcc -std=c99" ./configure --prefix=/usr -G -O3 \
              > c.log 2>&1 \
          && make -j"$NP" > b.log 2>&1 && make install > i.log 2>&1 ) ;;
      python)
        # --without-ensurepip: pip is not needed by anything here, and its
        # install phase runs the freshly built interpreter over bundled
        # wheels. Nothing in the chain imports it; glibc only wants python3
        # to exist and answer --version.
        # --disable-test-modules IS RUNG 11.7's, and it removes a large part
        # of a build nothing here runs. --without-ensurepip because pip's
        # install phase runs the interpreter over bundled wheels for no
        # consumer.
        #
        # NOT --disable-shared, AND THAT IS THE ONE DELIBERATE DIVERGENCE.
        # Rung 11.7 forces a fully static interpreter with a hand-written
        # Setup.local because the BOX is musl and its python had to run with
        # no loader. This sysroot has glibc and a real dynamic loader, so an
        # ordinary shared build is correct here and the whole Setup.local
        # apparatus does not apply.
        ( cd "$_d" && ./configure --prefix=/usr --without-ensurepip \
              --disable-test-modules > c.log 2>&1 \
          && make -j"$NP" > b.log 2>&1 && make install > i.log 2>&1 ) ;;
      *)
        # --disable-nls AND MAKEINFO=true ARE RUNG 11.7's, NOT GUESSES. It
        # builds gawk, m4, flex and bison with exactly this line; texinfo is
        # not in this sysroot either, so MAKEINFO=true disposes of the manuals
        # the same way. The only difference here is the prefix and the
        # compiler, which is the point of the rung.
        ( cd "$_d" && ./configure --prefix=/usr --disable-nls > c.log 2>&1 \
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
  # ASSERT bc IS THE REAL ONE. stage4-complete checks exactly this, because
  # if the install did not land the applet is still answering and the
  # substitution is silent again.
  if [ "$b1" = ok ]; then
    if [ -f /usr/bin/bc ] && [ ! -L /usr/bin/bc ]; then
      say "    bc: $(bc --version 2>&1 | head -1)  (a regular file, not an applet)"
    else
      say "    /usr/bin/bc is not a regular file -- busybox still owns it"
      b1=FAIL
    fi
  fi
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
       && make install PERL=/bin/true > i.log 2>&1; then
      B2=ok
      # NOT ldd --version. glibc installs /usr/bin/ldd as a script with a
      # #!/bin/bash line, and there is no bash in this sysroot -- busybox
      # provides sh, not bash. The last run printed
      #   "glibc rebuilt natively: /usr/bin/ldd: not found"
      # which is a check reporting the absence of an interpreter as though it
      # were the glibc version. libc.so.6 states its own version when run,
      # and it is the file that matters.
      say "    glibc rebuilt natively:"

      # PERL=/bin/true, AND IT IS A DECISION WITH NO PRECEDENT IN THIS REPO.
      #
      # glibc's install ends by running its own sanity script:
      #
      #   LD_SO=... CC="gcc" $(PERL) scripts/test-installation.pl ...
      #     ld: cannot find -lnsl
      #     ld: cannot find -lnss_dns
      #     ld: cannot find -lunwind
      #   make[1]: *** [Makefile:111: install] Error 1
      #
      # It links against every library glibc COULD produce. libnsl was split
      # out of glibc years ago and needs --enable-obsolete-nsl; libnss_dns
      # needs NSS modules we do not configure; libunwind is a different
      # project entirely and NO glibc build produces it. The library set is
      # right and the test is wrong for a build this small -- and it cannot
      # be satisfied, because no flag makes libunwind appear.
      #
      # WHY NOTHING ELSE HERE HITS IT. Every other glibc build in this
      # repository -- stage4-complete, hermetic-gcc10/15/47/16,
      # chain/rung2.sh, and phase A's own rung 13 -- passes --host=$VERON_TOOLCHAIN_TGT.
      # glibc guards this check on $(cross-compiling), so a cross build never
      # runs it. B2 is the first NATIVE glibc build in the project, so there
      # was no working example to copy from.
      #
      # PERL= RATHER THAN A PATCH OR A BLANKET SKIP: run 122's i.log has
      # exactly ONE perl invocation in 3086 lines and it is this script, so
      # neutering $(PERL) for the install disables that and nothing else.
      # Measured, not assumed.
      say "    glibc's post-install self-test was skipped (PERL=/bin/true):"
      say "    it links -lnsl -lnss_dns -lunwind, none of which this build"
      say "    produces. Asserting the install directly instead --"

      # BECAUSE WE JUST DISABLED GLIBC'S ASSERTION, WE MAKE OUR OWN.
      _lc=/usr/lib/libc.so.6
      if [ -f "$_lc" ]; then
        say "      $_lc  $(wc -c < "$_lc") bytes"
        say "      says: $("$_lc" 2>&1 | head -1)"
      else
        say "      $_lc IS MISSING -- the install did not land"; B2=FAIL
      fi
      # THE TOOLCHAIN MUST STILL WORK AFTER THE LIBC UNDER IT WAS REPLACED.
      gcc /tmp/b0.c -o /tmp/b2 2>/dev/null && /tmp/b2 > /dev/null 2>&1
      if [ $? = 42 ]; then
        say "      compiled, linked and ran against the libc just installed"
      else
        say "      THE COMPILER NO LONGER RUNS after the glibc install."
        B2=FAIL
      fi
    else
      B2=FAIL; say "    --- glibc errors ---"
      whyfail c.log
      whyfail b.log
      # i.log WAS THE ONE THAT MATTERED AND WAS NEVER PRINTED. glibc's make
      # succeeded and its INSTALL failed; this path showed c.log and b.log
      # and stopped, so run 122 reported a failure with no error anywhere in
      # it. Every rung that runs `make install` needs this line.
      whyfail i.log
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
    # NO --enable-gold AND NO --enable-ld. An earlier revision passed
    # --enable-gold=no --enable-ld=default; neither stage4-complete nor
    # hermetic-gcc15 passes either flag, and neither does the book. It was
    # mine, unsourced, and binutils' own defaults are what the working jobs
    # rely on.
    # --enable-deterministic-archives MAKES `ar` ZERO THE MEMBER HEADERS.
    #
    # This is the fix for the only thing that was not reproducible in the whole
    # ladder. Two runs produced a native cc1 differing in exactly 16 bytes, one
    # contiguous run, in .rodata -- and `nm` names it: `executable_checksum`,
    # gcc's MD5 of its own components, used to decide whether a precompiled
    # header matches the compiler reading it.
    #
    # WHY ONLY THAT. genchecksum hashes the object files AND the archives --
    # libbackend.a, libcommon.a, libcpp.a, libiberty.a. An `ar` member header
    # carries an mtime, uid, gid and mode, so the archives differ between runs
    # even when every object in them is byte-identical. The linker copies only
    # object CONTENTS into the executable, never the archive headers, so the
    # binary came out identical everywhere except the digest computed over data
    # that never entered it.
    #
    # `D` zeroes mtime, uid, gid and mode. Set here at the binutils that BUILDS
    # everything above it, rather than as AR_FLAGS on each package, so it holds
    # for every archive the system ever creates instead of the ones someone
    # remembered to flag.
    # --build/--host/--target MUST MATCH THE gcc B4 BUILDS, and this is what
    # `cannot find 'ld'` meant. gcc searches for its linker under
    # $prefix/<target-triplet>/bin/ before falling back to PATH. B4 now
    # configures gcc as x86_64-veron-linux-gnu, so it looks in
    # /usr/x86_64-veron-linux-gnu/bin/ -- and binutils, configured natively,
    # had installed its copy under whatever config.guess returned instead.
    #
    # The in-guest compile is the only thing that exercises this: the runner
    # never invokes the final gcc, so a mismatch here builds a complete system
    # and fails the first time somebody compiles ON it. That is exactly the
    # test VERON-GCC-IN-GUEST exists to be.
    if "$_d/configure" --prefix=/usr \
         --build=x86_64-veron-linux-gnu \
         --host=x86_64-veron-linux-gnu \
         --target=x86_64-veron-linux-gnu \
         --enable-plugins --enable-shared --disable-werror \
         --enable-deterministic-archives \
         --enable-64-bit-bfd --enable-new-dtags --enable-gprofng=no \
         --disable-nls > c.log 2>&1 \
       && timeout 5400 make -j"$NP" MAKEINFO=true > b.log 2>&1 \
       && make install MAKEINFO=true > i.log 2>&1; then
      B3=ok; say "    binutils: $(ld --version 2>&1 | head -1)"
    else
      B3=FAIL; say "    --- binutils errors ---"
      whyfail b.log
      # i.log TOO: a rung whose make succeeds and whose install fails would
      # otherwise report a failure with no error in the log at all, which is
      # exactly how B2 cost a round.
      whyfail i.log
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
    # THE SAME TWO EDITS RUNG 11 MAKES, because B4 builds gcc again and a
    # tree unpacked here has never seen them.
    #
    # x86_64's file has MULTILIB_OSDIRNAMES where aarch64's has mabi.lp64=,
    # so the anchor differs. Keeping the aarch64 anchor would make this
    # branch print "has no mabi.lp64= line" against a perfectly good
    # t-linux64 and fail B4 for the wrong reason.
    _t="$_d/gcc/config/i386/t-linux64"
    if [ ! -f "$_t" ]; then
      say "    $_t is missing -- gcc has moved this file"; B4=FAIL
    elif ! grep -q 'MULTILIB_OSDIRNAMES' "$_t"; then
      say "    $_t has no MULTILIB_OSDIRNAMES line. It now reads:"
      sed 's/^/      /' "$_t"; B4=FAIL
    else
      sed -i.orig '/MULTILIB_OSDIRNAMES/s|\.\./lib64|../lib|g' "$_t"
      say "    64-bit libdir: $(grep 'MULTILIB_OSDIRNAMES' "$_t" | head -1)"
    fi

    # AND THE ELF INTERPRETER. Without it every binary this gcc links asks
    # for /lib64/ld-linux-x86-64.so.2, which this sysroot deliberately does
    # not have -- the fault that stopped B0 before rung 11 was fixed. B4's
    # gcc is the FINAL compiler, so it matters more here than there.
    _dl="$_d/gcc/config/i386/linux64.h"
    if [ ! -f "$_dl" ]; then
      say "    $_dl is missing -- gcc has moved the dynamic linker define"; B4=FAIL
    elif ! grep -q 'GLIBC_DYNAMIC_LINKER64' "$_dl"; then
      say "    $_dl has no GLIBC_DYNAMIC_LINKER64:"
      grep -n 'DYNAMIC_LINKER' "$_dl" | sed 's/^/      /'; B4=FAIL
    else
      sed -i.orig 's|/lib64/ld-linux-x86-64\.so\.2|/lib/ld-linux-x86-64.so.2|g' "$_dl"
      say "    interpreter: $(grep 'GLIBC_DYNAMIC_LINKER64' "$_dl" | head -1)"
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
    # THE TARGET LIBRARIES RUNG 16 ALREADY DISABLES, DISABLED HERE TOO.
    #
    # B4 disabled none of them and libgomp stopped the build:
    #
    #   libgomp/affinity-fmt.c:330:25: error: initialization discards 'const'
    #     qualifier from pointer target type [-Werror=discarded-qualifiers]
    #     330 |   char *q = strchr (p + 1, '}');
    #
    # That is VERSION SKEW, not a broken toolchain. glibc 2.44 makes the
    # string functions const-correct in C, so strchr() on a const char *
    # returns const char *; gcc 15.2.0 predates that and libgomp assigns the
    # result to char *. libgomp builds with -Werror, so a warning is fatal.
    # Nothing else in the tree failed -- libgcc, libstdc++, libatomic and the
    # rest all got through, and the only *** line was libgomp's.
    #
    # THE LIST IS RUNG 16's, VERBATIM, which is LFS's for gcc pass 2. It is
    # precedented one rung down in this same chain rather than invented here,
    # and it disables exactly the six libraries that are optional runtimes.
    #
    # WHAT THIS COSTS, SAID OUT LOUD: the final compiler has no OpenMP, no
    # sanitizers, no __float128, no libssp and no vtable verification.
    # --enable-default-ssp still works because glibc provides the stack
    # protector symbols -- LFS pairs those two flags for that reason. Nothing
    # stage 4 builds uses any of the six, and stage 4's claim is a kernel and
    # a busybox that boot. STAGE 5 SHOULD REVISIT THIS: a complete system
    # wants a complete compiler, and by then gcc will have caught up with
    # glibc's headers, or the skew will need a real fix rather than a flag.
    # --build/--host/--target ARE THE SYSTEM'S NAME, AND THIS IS THE gcc THAT
    # SHIPS. Phase A's gcc pass 2 is configured --target=$VERON_TOOLCHAIN_TGT, but rung
    # B4 rebuilds gcc natively and OVERWRITES it -- so config.guess decided
    # the triplet and answered x86_64-unknown-linux-gnu. Measured: 678
    # occurrences of that string in a stage-5 diagnostic bundle and no other.
    #
    # A system that does not know its own name is what `gcc -dumpmachine`
    # then reports, and the string is in every path under /usr/lib/gcc/<t>/,
    # /usr/include/c++/<v>/<t>/ and /usr/lib/<t>/. Naming it here is the
    # difference between a distribution and a build directory.
    #
    # THE SCAFFOLDING IS RENAMED IN THE OPPOSITE DIRECTION, in the same
    # change: $VERON_TOOLCHAIN_TGT becomes x86_64-toolchain-linux-gnu, because a cross
    # compiler in /tools called x86_64-veron-linux-gnu-gcc reads as THE Veron
    # compiler and is precisely the one that is not.
    # --enable-libatomic BECAUSE A BROWSER NEEDS IT AND NOTHING ELSE DID.
    #
    # This line read --disable-libatomic, alongside libgomp, libquadmath,
    # libsanitizer, libssp and libvtv. For 119 stage-5 packages that was
    # invisible: every one of them uses word-sized atomics, which aarch64
    # does lock-free inline with no library at all.
    #
    # wpewebkit is the first thing to need SIXTEEN-BYTE atomics.
    # Source/bmalloc/libpas/src/libpas/pas_utils.h declares
    # `typedef __uint128_t pas_pair` and compare-and-swaps it, and on ARMv8.0
    # without LSE those lower to __atomic_*_16 calls that exist ONLY in
    # libatomic. Its configure said so outright:
    #
    #     Performing Test ATOMICS_ARE_BUILTIN - Failed
    #     Performing Test ATOMICS_REQUIRE_LIBATOMIC - Failed
    #     CMake Error: Failed to detect support for atomic variables
    #
    # The SECOND failure is the one that matters: the first is normal on
    # aarch64, which is why upstream wrote a -latomic fallback. The fallback
    # failed because there was no such library. libgcc_s.so.1 and
    # libstdc++.so.6 were both here; the third of GCC's runtime libraries
    # was not.
    #
    # RAISING -march WOULD NOT HAVE BEEN A FIX. LSE (ARMv8.1) and LSE2
    # (ARMv8.4) change libatomic's INTERNAL implementation, chosen by ifunc
    # at runtime -- GCC still emits the library call, so that one process has
    # one ABI. And the test machine is -cpu cortex-a57, ARMv8.0: a binary
    # built for 8.1 would take an illegal instruction in our own VM.
    #
    # NOTHING WAS WATCHING FOR THIS. sysroot-trim.sh:104 already names
    # libatomic.so.1 among the runtime libraries it checks, but it
    # `continue`s when the file is absent -- it asks whether what exists is
    # safe, not whether what should exist does.
    elif "$_d/configure" --prefix=/usr LD=ld \
           --build=x86_64-veron-linux-gnu \
           --host=x86_64-veron-linux-gnu \
           --target=x86_64-veron-linux-gnu \
           --disable-multilib --disable-bootstrap \
         --disable-fixincludes --enable-default-pie \
         --enable-default-ssp --disable-nls --enable-languages=c,c++ \
         --enable-libatomic --disable-libgomp --disable-libquadmath \
         --disable-libsanitizer --disable-libssp --disable-libvtv \
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
      produced /usr/libexec/gcc/*/*/cc1 /usr/libexec/gcc/*/*/cc1plus

      # gcc's SELF-CHECKSUM, PRINTED, because it was the one thing in the whole
      # ladder that varied between runs and it took six runs and an artifact
      # download to find. Sixteen bytes in .rodata out of 397 MB.
      #
      # It is an MD5 over gcc's own objects AND ARCHIVES, used to decide
      # whether a precompiled header matches the compiler reading it. `ar`
      # member headers carry mtimes, so the archives differed run to run while
      # every object in them was identical -- and the linker never copies those
      # headers into the executable, so the binary matched everywhere except
      # the digest computed over data that never entered it.
      # --enable-deterministic-archives on binutils is the fix; this line is
      # how a regression announces itself in the log instead of in an artifact.
      for _c in /usr/libexec/gcc/*/*/cc1 /usr/libexec/gcc/*/*/cc1plus; do
        [ -f "$_c" ] || continue
        _sym=$(nm "$_c" 2>/dev/null | grep -w executable_checksum | cut -d' ' -f1)
        if [ -n "$_sym" ]; then
          printf '    %-46s executable_checksum @ 0x%s\n' "${_c##*/}" "$_sym"
        fi
      done

      # BUILD IT A SECOND TIME AND DIFF, IN THE SAME RUN.
      #
      # THE PROBLEM THIS SOLVES. The native cc1 differs between runs at
      # identical size -- 397720192 bytes both times, f31f0cd9 then 24de3e05 --
      # while the CROSS cc1 from rung 11 is byte-identical. Everything findable
      # from one binary has been ruled out: no __DATE__, no build-id, comp_dir
      # is a fixed /work path, and all 1590 embedded paths are constant.
      #
      # HOLD EVERY VARIABLE BUT THE BUILD ITSELF. The first version of this
      # check did not, and produced a result that could not be read:
      #
      #     A  /usr/libexec/gcc/.../cc1        397720192   installed
      #     B  /work/gcc-repro2/gcc/cc1        397339896   build tree
      #     SIZES DIFFER by -380296 bytes
      #
      # Two things changed at once -- a different build DIRECTORY, and
      # installed-versus-build-tree -- so the 380 KB says nothing about
      # reproducibility. A comparison that alters what it is measuring is
      # worse than no comparison, because it manufactures a number.
      #
      # So: keep build one's binaries, delete its tree, and rebuild in THE
      # SAME PATH. Then compare build tree against build tree. The only
      # difference left is that the build happened twice.
      #
      # WHERE TO LOOK IN THE RESULT. cc1 is 397 MB of which .debug_info alone
      # is 225 MB and .text is 25 MB, so a difference is an order of magnitude
      # more likely to be metadata than code -- and those are different
      # findings. repro-diff.sh reports differing bytes per section.
      #
      # OFF BY DEFAULT: it costs a second full gcc build. Set REPRO_GCC=1.
      if [ "${REPRO_GCC:-0}" = 1 ] && [ "$B4" = ok ]; then
        say ""
        say "  --- REPRO: building the final gcc a SECOND time, same path ---"
        _keep=/work/repro-b1
        rm -rf "$_keep" && mkdir -p "$_keep"
        for _c in cc1 cc1plus; do
          [ -f "$W/b-gcc/gcc/$_c" ] && cp "$W/b-gcc/gcc/$_c" "$_keep/$_c"
        done
        say "    kept build 1 from the build tree:"
        for _c in cc1 cc1plus; do
          [ -f "$_keep/$_c" ] && printf '      %-10s %12s  %s\n' "$_c" \
            "$(wc -c < "$_keep/$_c")" "$(sha256sum "$_keep/$_c" | cut -c1-16)…"
        done

        rm -rf "$W/b-gcc" && mkdir -p "$W/b-gcc" && cd "$W/b-gcc"
        # THE SAME FLAGS, WRITTEN OUT RATHER THAN REFERENCED. A second build
        # configured even slightly differently proves nothing, and a shared
        # variable read from two places is how they drift apart. If the list
        # above changes, this must change with it -- which is why they sit
        # twenty lines apart rather than in separate functions.
        if "$_d/configure" --prefix=/usr LD=ld --disable-multilib --disable-bootstrap \
             --disable-fixincludes --enable-default-pie \
             --enable-default-ssp --disable-nls --enable-languages=c,c++ \
             --enable-libatomic --disable-libgomp --disable-libquadmath \
             --disable-libsanitizer --disable-libssp --disable-libvtv \
             > c2.log 2>&1 \
           && timeout 14400 make -j"$NP" > b2.log 2>&1; then
          for _c in cc1 cc1plus; do
            _a="$_keep/$_c"
            _b="$W/b-gcc/gcc/$_c"
            if [ -f "$_a" ] && [ -f "$_b" ]; then
              say ""
              say "  --- $_c: build 1 vs build 2, same path, same flags ---"
              sh /src/stage4/bridge/repro-diff.sh "$_a" "$_b" 2>&1 | sed 's/^/  /'
            else
              say "    $_c: missing one side ($_a / $_b)"
            fi
          done
        else
          say "    the second build did not complete -- see c2.log / b2.log"
          whyfail b2.log
        fi
        cd /work
      fi
    else
      B4=FAIL; say "    --- gcc errors ---"
      whyfail b.log
      # i.log TOO: a rung whose make succeeds and whose install fails would
      # otherwise report a failure with no error in the log at all, which is
      # exactly how B2 cost a round.
      whyfail i.log
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
    # FEATURE_WGET_HTTPS IS IN THIS LIST BECAUSE IT *select*s TLS.
    # Disabling SSL_CLIENT and TLS is not enough: Kconfig re-derives a
    # selected symbol on the next `oldconfig`, so TLS came straight back and
    # B5's check caught it. Kill what selects it, not just the symbol.
    for _sym in SSL_CLIENT FEATURE_WGET_OPENSSL FEATURE_WGET_HTTPS TLS TC; do
      sed -i "s/^CONFIG_$_sym=y/# CONFIG_$_sym is not set/" .config
    done
    # THE SAME BUILD APPLET LIST AS RUNG 15's, AND FOR A REASON THAT OUTLIVES
    # THE INITRAMFS: this busybox OVERWRITES the sysroot's, so from here on it
    # is what B6's kernel build shells out to. A kernel build calls sed, awk,
    # sort, cut, tr, find and xargs constantly. Shipping a defconfig busybox
    # here would break B6 rather than the image.
    for _sym in SPLIT COMM JOIN PASTE EXPAND UNEXPAND FOLD NL TSORT CMP DIFF PATCH AWK SED GREP SORT UNIQ TR CUT XARGS FIND WHICH ENV BASENAME DIRNAME; do
      sed -i "s/^# CONFIG_$_sym is not set/CONFIG_$_sym=y/" .config
      grep -q "^CONFIG_$_sym=y" .config || echo "CONFIG_$_sym=y" >> .config
    done
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    grep -q '^CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config
    yes '' | make oldconfig > /dev/null 2>&1
    _bad=0
    grep -q '^CONFIG_STATIC=y' .config || { say "    CONFIG_STATIC did not survive oldconfig"; _bad=1; }
    grep -qE '^CONFIG_(TLS|SSL_CLIENT|TC)=y' .config && { say "    TLS/TC came back after oldconfig"; _bad=1; }
    for _sym in SPLIT COMM AWK SED GREP SORT CUT TR FIND XARGS; do
      grep -q "^CONFIG_$_sym=y" .config || { say "    build applet $_sym missing"; _bad=1; }
    done
    if [ "$_bad" != 0 ]; then
      grep -E '^(# )?CONFIG_(STATIC|TLS|SSL_CLIENT|TC|FEATURE_WGET_HTTPS)' .config | sed 's/^/      /'
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
        # THE SAME RELATIVE-SYMLINK LOOP AS RUNG 15, AND FOR ONE REASON MORE.
        #
        # `busybox --install` records its own RESOLVED path as each link's
        # target, so the links only work in the root it ran in. Here that
        # root is the sysroot, so /usr/bin/busybox would be correct in this
        # sandbox and in the guest's chroot over 9p -- this is not the bug
        # that stopped runs 117-119, which was rung 15 running --install from
        # the BOX.
        #
        # It is changed anyway, because this sysroot outlives this sandbox:
        # the workflow caches it, and tool-probe restores it somewhere else.
        # Relative links are correct everywhere absolute ones are, and
        # correct in more places. Two rungs writing the same directory two
        # different ways is also how the next reader gets misled.
        # SAME GUARD AS RUNG 15's. By this rung /usr/bin holds glibc's
        # binaries, binutils pass 2, gcc pass 2, make, and everything B1
        # built -- and busybox has applets named ldd, ar and strings. An
        # unguarded farm would shadow real programs with applets, and the
        # kernel build in B6 runs immediately after.
        ( cd /usr/bin
          _kept=""
          for _a in $(./busybox --list 2>/dev/null); do
            [ "$_a" = busybox ] && continue
            if [ -e "$_a" ] && [ ! -L "$_a" ]; then
              _kept="$_kept $_a"; continue
            fi
            ln -sf busybox "$_a"
          done
          [ -n "$_kept" ] && printf '    kept, already real binaries:%s\n' "$_kept"
          : )
        if [ ! -f /usr/bin/busybox ] || [ -L /usr/bin/busybox ]; then
          say "    /usr/bin/busybox is not a regular file -- it was overwritten"
          B5=FAIL
        else
          B5=ok
        fi
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
# with $VERON_TOOLCHAIN_TGT-gcc -- pass 1, built --without-headers before a libc existed --
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
    # bc AGAINST THE KERNEL'S OWN timeconst.bc, BEFORE BUILDING ANYTHING.
    #
    # kernel/time/Makefile generates timeconst.h by piping CONFIG_HZ through
    # bc. B1 asserted that /usr/bin/bc is a regular file; this asserts it can
    # do the one job the kernel needs, using the kernel's own script rather
    # than a synthetic expression. stage4-complete runs the identical check.
    # It is here rather than in B1 because this is where the kernel tree
    # first exists -- unpacking 158 MB earlier just to test bc would be a
    # worse trade.
    if [ -f kernel/time/timeconst.bc ]; then
      _tc=$(echo 250 | bc -q kernel/time/timeconst.bc 2>/dev/null | head -1)
      if [ -n "$_tc" ]; then
        say "    timeconst check: $_tc"
      else
        say "    bc PRODUCED NOTHING from the kernel's own timeconst.bc."
        say "    The build would fail generating timeconst.h, naming the"
        say "    header rather than bc."
        B6=FAIL
      fi
    else
      say "    kernel/time/timeconst.bc absent -- the kernel has moved it"
    fi
    make ARCH=x86_64 defconfig > /dev/null 2>&1
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
    # DRM AND INPUT, BUILT IN, BECAUSE =m IS THE SAME AS =n IN THIS SYSTEM.
    #
    # Only arch/x86/boot/bzImage leaves this build -- `make modules_install`
    # never runs, no /lib/modules ships, and there is no kmod and no modprobe.
    # So a symbol arm64 defconfig leaves at =m does not merely fail to load,
    # it does not exist. hwdata's stage-5 recipe already declines its
    # modprobe.d file for the same reason.
    #
    # MEASURED, NOT ASSUMED. stage5-spike boots qemu with -device
    # virtio-gpu-pci -device virtio-keyboard-pci and the guest reports what it
    # can see. It said:
    #
    #   VERON-DRM-ABSENT    no /dev/dri/card0
    #   drm modules:        (empty -- nothing in /sys/class/drm)
    #   VERON-EVDEV-OK      1 event node(s)
    #
    # So evdev was already fine and DRM was absent entirely. wlroots with
    # -Dbackends=drm would have built green and found no device to open: the
    # same failure shape as -Dbackends=auto, one layer down and arriving from
    # the kernel rather than from a recipe.
    #
    # INPUT_EVDEV and VIRTIO_INPUT are set even though the probe found an
    # event node, because "it happened to work" and "we chose it" are
    # different claims and only the second survives a defconfig change.
    set_cfg DRM y
    set_cfg DRM_VIRTIO_GPU y
    set_cfg DRM_FBDEV_EMULATION y
    set_cfg INPUT_EVDEV y
    set_cfg VIRTIO_INPUT y
    # THE WRITABLE LAYER. Stage 5's first-boot design is a read-only base plus
    # an overlay, so the image stays byte-identical and `veron compare`
    # against files.tsv keeps working on a RUNNING system -- everything
    # written after boot is visibly in the upper layer by construction.
    # Without OVERLAY_FS the only alternative is a read-write root, which
    # gives up that property.
    set_cfg OVERLAY_FS y
    # USER_NS AND SECCOMP ARE FOR THE BROWSER SANDBOX, NOT FOR THE KERNEL'S
    # OWN SAKE. wpewebkit is built with ENABLE_BUBBLEWRAP_SANDBOX=ON, which
    # puts WPEWebProcess and WPENetworkProcess inside a bwrap container:
    # bwrap needs an unprivileged USER NAMESPACE to drop privileges without
    # being root, and libseccomp needs SECCOMP to install the syscall filter
    # that is the confinement itself.
    #
    # arm64 defconfig may already supply both -- this asks for them rather
    # than assuming, which costs nothing and removes the question. stage 5's
    # guest/init prints VERON-USERNS-OK / VERON-SECCOMP-OK on every boot so
    # the answer is visible rather than inferred.
    #
    # A SANDBOX THAT SILENTLY DOES NOT ENGAGE IS WORSE THAN NO SANDBOX: the
    # browser still runs, every page still loads, and nothing says the
    # confinement a compromised renderer would have to escape is absent.
    set_cfg MULTIUSER y
    set_cfg NAMESPACES y
    set_cfg USER_NS y
    set_cfg SECCOMP y
    # EFI, SO THE IMAGE CAN BOOT ITSELF. Today qemu is handed -kernel and
    # -initrd, which means the image is not bootable on its own and never
    # will be on real hardware. CONFIG_EFI brings the arm64 stub, and
    # EFI_PARTITION is GPT -- without it the kernel cannot even read the
    # partition table an ESP lives in.
    set_cfg EFI y
    set_cfg EFI_STUB y
    # NO CONFIG_CMDLINE, AND THE REASON IS MEASURED.
    #
    # A built-in command line was added here and is now removed. The argument
    # for it was that an EFI-stub boot has no other source for one -- true of
    # the FALLBACK path, not of the mechanism. Tested by booting this kernel
    # from a UEFI Shell with arguments on the line:
    #
    #     Kernel command line: linux console=ttyAMA0 root=/dev/vdb rw ...
    #     VERON-PID1-OK
    #
    # LoadOptions reaches the stub correctly and the kernel needs no help.
    # What was missing is something in the ESP to SET LoadOptions, which is
    # spikes/stage5/boot's job.
    #
    # AND BAKING IT IN WOULD BE ACTIVELY WRONG. root= names one partition, and
    # this kernel has to serve the .img, an ISO whose root is a squashfs, and
    # Android's AVF which passes its own line. One kernel, three roots: the
    # variable part belongs to the wrapper. Stage 4's job ends at a generic
    # kernel.
    set_cfg EFI_PARTITION y
    set_cfg EFIVAR_FS y
    # NETWORKING, AHEAD OF NEED AND DELIBERATELY SO. Nothing in stage 5 uses
    # it yet; STAGE5.md lists it as open and a browser cannot exist without
    # it. The rule elsewhere in this project is to leave out what nothing
    # uses -- this is the exception, and the reason is arithmetic: a kernel
    # symbol costs nothing at runtime and a full chain rerun to add one costs
    # an hour plus everything downstream. PACKET is what a DHCP client needs
    # to see raw frames before an address exists.
    set_cfg VIRTIO_NET y
    set_cfg PACKET y
    make ARCH=x86_64 olddefconfig > /dev/null 2>&1
    _bad=0
    [ "$B6" = FAIL ] && _bad=1
    grep -q "^CONFIG_WERROR=y" .config && { say "    WERROR came back after olddefconfig"; _bad=1; }
    grep -q "^CONFIG_DEVTMPFS_MOUNT=y" .config || { say "    DEVTMPFS_MOUNT did not take"; _bad=1; }
    # HARD, AND =y RATHER THAN MERELY PRESENT. olddefconfig can quietly turn a
    # requested =y into =m when a dependency is modular, and in this system
    # those two are indistinguishable at runtime -- so only a grep for "=y"
    # tells success from silent demotion.
    #
    # Fatal, unlike the 9p symbols below: a missing 9p costs one skipped
    # in-guest test, a missing DRM costs a compositor that builds green and
    # opens nothing.
    #
    # USER_NS AND SECCOMP ARE IN THIS LIST FOR THE SAME REASON AS THE REST,
    # AND ONE MORE: USER_NS sits under `menuconfig NAMESPACES` and depends on
    # MULTIUSER, so olddefconfig will DROP a requested CONFIG_USER_NS=y
    # outright if either is off -- leaving no error and no symbol. Asserting
    # =y afterwards is the only thing that tells a granted request from a
    # silently discarded one.
    for _sym in DRM DRM_VIRTIO_GPU DRM_FBDEV_EMULATION INPUT_EVDEV \
                VIRTIO_INPUT OVERLAY_FS EFI EFI_STUB EFI_PARTITION \
                EFIVAR_FS VIRTIO_NET PACKET USER_NS SECCOMP; do
      grep -q "^CONFIG_$_sym=y" .config || {
        say "    CONFIG_$_sym is not built in (=y)"; _bad=1; }
    done
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
      # DETERMINISM: the kernel embeds the build user, host and timestamp
      # unless told otherwise, and the boot banner proves it --
      #   Linux version 7.1.5 (@runnervma9114) ... Mon Aug  3 09:46:45 UTC 2026
      # Four runs produced four different Images of identical size, which is
      # exactly the signature of fixed-width values written into fixed slots.
      # kbuild wants its own names; SOURCE_DATE_EPOCH is handled below, and
      # conditionally, because in this box it can do more harm than good.
      # A LITERAL DATE STRING, NOT `@0`. kbuild embeds this value verbatim, so
      # `@0` produced a banner reading `#1 SMP PREEMPT @0` -- deterministic,
      # and it looks like a bug every time someone reads it. The kernel does
      # not parse it, so a plain fixed string is both stable and legible.
      export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Thu Jan  1 00:00:00 UTC 1970}"
      export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-veron}"
      export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-veron}"

      # THE BANNER IS NOT THE ONLY THING THAT TIMESTAMP FEEDS, AND THE OTHER
      # CONSUMER WAS SILENTLY FAILING.
      #
      # The kernel builds a small BUILT-IN initramfs -- `dev`, `dev/console`,
      # `root` -- straight into the Image, and its cpio headers carry an mtime.
      # Two Images differed in exactly 32 bytes, and three of the four runs
      # were printable:
      #
      #   070701 000002D1 000041ED ... 6A7131EF 00000000 ...  dev
      #   magic  ino      mode         mtime
      #
      # 0x6A7131EF is 1786773487 -- wall-clock build time. The fourth run was
      # twenty bytes of entropy, a build-id derived from the content, so the
      # mtime was the cause and the digest followed it.
      #
      # WHY IT LEAKED THROUGH. `usr/gen_initramfs.sh` does roughly
      #
      #     timestamp="$(date -d"$KBUILD_BUILD_TIMESTAMP" +%s || :)"
      #
      # and `|| :` swallows the failure. busybox's `date -d` does not parse
      # "Thu Jan  1 00:00:00 UTC 1970", so `timestamp` came out empty, no `-t`
      # was passed to gen_init_cpio, and it used the current time. The banner
      # worked because the banner uses the string verbatim and never parses it.
      #
      # AND THE LONG FORM WAS A SELF-INFLICTED REGRESSION. This value used to be
      # `@0`, which busybox parses, and the Image was reproducible. It was
      # changed to "Thu Jan  1 00:00:00 UTC 1970" purely so the boot banner
      # would read as a date instead of `@0` -- a cosmetic change to a log
      # line, which busybox's `date -d` cannot parse, which silently
      # un-fixed the built-in initramfs and cost four rounds to find again.
      # The Image hash is the proof: b4a145a6 under `@0` before the change,
      # 39442a32 and varying under the long form, b4a145a6 again once the
      # fallback restored it.
      #
      # So: check that the box's own date can parse the value, try progressively
      # cruder forms, and SAY WHICH ONE TOOK. Silent fallback is what cost the
      # round; a legible banner is worth having only if it is also correct.
      if [ "$(date -d "$KBUILD_BUILD_TIMESTAMP" +%s 2>/dev/null)" = 0 ]; then
        say "    KBUILD_BUILD_TIMESTAMP parses to 0 -- built-in initramfs is deterministic"
      elif [ "$(date -d "1970-01-01 00:00:00 UTC" +%s 2>/dev/null)" = 0 ]; then
        export KBUILD_BUILD_TIMESTAMP="1970-01-01 00:00:00 UTC"
        say "    long form unparseable; using ISO 8601, which this date accepts"
      elif [ "$(date -d @0 +%s 2>/dev/null)" = 0 ]; then
        export KBUILD_BUILD_TIMESTAMP="@0"
        say "    only @0 parses here; banner will read '@0'"
      else
        say "    WARNING: no date form this box parses to 0 --"
        say "    the built-in initramfs will carry wall-clock mtimes and Image"
        say "    will not be reproducible. Pass -t to gen_init_cpio instead."
      fi
      # SOURCE_DATE_EPOCH ONLY IF IT SURVIVES THE ROUND TRIP, AND IN THIS BOX
      # IT MAY NOT. Exporting it unconditionally -- which this did -- would have
      # silently re-broken what the block above just fixed.
      #
      # The kernel's top-level Makefile does
      #
      #     ifeq ("$(origin SOURCE_DATE_EPOCH)", "environment")
      #     KBUILD_BUILD_TIMESTAMP := $(shell LC_TIME=C date -u -d@$(SOURCE_DATE_EPOCH))
      #
      # which OVERRIDES whatever KBUILD_BUILD_TIMESTAMP we set, replacing our
      # `@0` with that date's formatted output -- a long string. usr/gen_initramfs.sh
      # then feeds that string back to `date -d`, and busybox cannot parse the
      # long form. Same `|| :`, same silent fallback, same wall-clock mtime.
      #
      # So the value only helps if `date` can read back what `date` writes.
      # Test the round trip instead of assuming it: convert epoch to string and
      # the string back to epoch, and require 0.
      _sde_str=$(LC_TIME=C date -u -d@0 2>/dev/null)
      if [ -n "$_sde_str" ] && [ "$(date -d "$_sde_str" +%s 2>/dev/null)" = 0 ]; then
        export SOURCE_DATE_EPOCH=0
        say "    SOURCE_DATE_EPOCH=0 exported -- date round-trips cleanly"
      else
        unset SOURCE_DATE_EPOCH 2>/dev/null || true
        say "    SOURCE_DATE_EPOCH NOT exported: this date writes '$_sde_str'"
        say "    and cannot read it back, so kbuild would override our timestamp"
        say "    with a string gen_initramfs.sh then fails to parse."
      fi

      # LC_ALL=C for the kernel build. `date -d` parsing is locale-sensitive --
      # the documented failure is `date -d"$(date)"` under a non-C locale -- and
      # every timestamp path above runs through it.
      export LC_ALL=C
      # ARCH, THE TARGET AND THE PATH ARE ALL PER-ARCHITECTURE, and only the
      # first was obvious. The kernel calls its image `Image` on arm64 and
      # riscv and `bzImage` on x86, and puts it under arch/<dir>/boot where
      # <dir> is not the ARCH= string either -- x86_64 builds land in
      # arch/x86. Copying the aarch64 arm left `make ARCH=arm64` here, which
      # would have configured and built a kernel for the wrong machine on a
      # host that had just built a working native toolchain.
      if timeout 7200 make ARCH=x86_64 -j"$NP" bzImage > b.log 2>&1 \
         && [ -f arch/x86/boot/bzImage ]; then
        cp arch/x86/boot/bzImage "$W/Image"; B6=ok
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
# a tmpfs is mounted OVER the read-only tree's /tmp for the output. The VFS
# allows that even on a ro mount, which is stage4-complete's note and its
# construct -- an earlier revision here used `mount --bind` from a scratch
# directory, which was invented rather than taken from the job that boots.
#
# msize=262144 matters: the default 9p transfer unit is small and gcc reads
# several hundred files over this mount. Without it the compile is slow
# enough under TCG to look like a hang.
if mount -t 9p -o trans=virtio,version=9p2000.L,ro,msize=262144 \
         veronsysroot /mnt/sysroot 2>/dev/null; then
  echo "   9p sysroot mounted read-only"
  if [ -x /mnt/sysroot/usr/bin/gcc ]; then
    if mount -t tmpfs none /mnt/sysroot/tmp 2>/dev/null; then
      printf 'int main(void){return 42;}\n' > /mnt/sysroot/tmp/g.c
      echo "   gcc        : $(chroot /mnt/sysroot /usr/bin/gcc --version 2>&1 | head -1)"
      if chroot /mnt/sysroot /usr/bin/gcc -O2 -o /tmp/g /tmp/g.c 2>/mnt/sysroot/tmp/g.err; then
        chroot /mnt/sysroot /tmp/g
        echo "VERON-GCC-IN-GUEST ok compiled and ran, rc=$? (expect 42)"
      else
        echo "VERON-GCC-IN-GUEST compile failed: $(head -1 /mnt/sysroot/tmp/g.err)"
      fi
    else
      echo "VERON-GCC-IN-GUEST skipped: no tmpfs for output"
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
  # DETERMINISM, THREE SOURCES, AND THIS ONE VARIED IN SIZE AS WELL AS HASH
  # across four runs (11945418 / 11945925 / 11945457 / 11945530):
  #
  #   cpio  records each file's mtime in the archive header
  #   find  emits directory order, which is not stable across filesystems
  #   gzip  without -n embeds a timestamp AND the original filename
  #
  # Size varying is the tell: different mtimes compress to different lengths.
  # Normalise all three -- mtimes to the epoch, order by sort, gzip -n.
  # busybox `touch` does not accept `-d @0` in every build, and a silent
  # failure here looks exactly like the fix not working. Try the portable
  # forms in order and say which one took, so the next reader is not left
  # guessing whether the normalisation happened.
  if find "$W/ir" -exec touch -h -d "1970-01-01 00:00:00" {} + 2>/dev/null; then
    say "    mtimes normalised (touch -d)"
  elif find "$W/ir" -exec touch -h -t 197001010000.00 {} + 2>/dev/null; then
    say "    mtimes normalised (touch -t)"
  else
    say "    WARNING: could not normalise mtimes -- initramfs will not be reproducible"
  fi
  # cpio newc RECORDS THE INODE NUMBER, AND THAT IS WHY THIS STILL VARIED.
  #
  # B7 normalises mtimes and sorts the file list, and the archive STILL came
  # out different every run -- 11945631, 11946088, 11946040 bytes. The header
  # is fixed-width, so a varying field cannot change the cpio's length; what
  # changes is its CONTENT, and gzip then compresses it to a different length.
  #
  # newc header, after the `070701` magic, is thirteen 8-hex fields:
  #
  #     ino mode uid gid nlink mtime filesize devmaj devmin rdevmaj rdevmin
  #     namesize check
  #
  # `ino` is first. It comes from the filesystem's allocator and has no reason
  # to repeat between runs. GNU cpio has --reproducible for exactly this;
  # busybox's does not, and busybox is what is in the box.
  #
  # THE KERNEL SHIPS THE RIGHT TOOL. usr/gen_init_cpio.c builds a newc archive
  # from a text spec with a deterministic inode counter and a fixed mtime -- it
  # is what kbuild uses for CONFIG_INITRAMFS_SOURCE. Compiling it with the
  # compiler this chain just built costs one gcc invocation, and the source is
  # already unpacked because B6 built the kernel from it.
  # FOUND BY SEARCHING, NOT BY GUESSING THE PATH. The first version looked in
  # "$W/src/linux-$KERNEL", and `fetch` actually unpacks to "$SRC/linux/<dir>",
  # so the test failed, the fallback ran, and the only sign was one line in a
  # log nobody re-read -- the archive came back byte-for-byte as
  # non-reproducible as before, 419 six-byte runs in exactly the same places.
  #
  # A hardcoded path that is wrong fails the same way as a tool that is
  # missing, which is why this searches and then says which it found.
  _gic=""
  _ksrc=$(find "$SRC" -type f -path '*/usr/gen_init_cpio.c' 2>/dev/null | head -1)
  _ksrc=${_ksrc%/usr/gen_init_cpio.c}
  if [ -n "$_ksrc" ] && [ -f "$_ksrc/usr/gen_init_cpio.c" ]; then
    if gcc -O2 -o "$W/gen_init_cpio" "$_ksrc/usr/gen_init_cpio.c" 2>/dev/null; then
      _gic="$W/gen_init_cpio"
      say "    gen_init_cpio built from $_ksrc -- deterministic inodes"
    else
      say "    gen_init_cpio FAILED TO COMPILE from $_ksrc"
    fi
  else
    say "    gen_init_cpio.c NOT FOUND under $SRC"
  fi

  if [ -n "$_gic" ]; then
    # THE SPEC, GENERATED FROM THE TREE. Sorted, so the order is ours and not
    # the filesystem's. Modes are read from the tree so an executable stays
    # executable; uid and gid are forced to 0 because the builder's identity is
    # not a property of the image.
    _spec="$W/initramfs.spec"; : > "$_spec"
    ( cd "$W/ir" && find . -mindepth 1 | LC_ALL=C sort ) | while IFS= read -r _p; do
      _rel=${_p#.}
      _full="$W/ir$_rel"
      _mode=$(stat -c '%a' "$_full" 2>/dev/null || echo 644)
      if [ -L "$_full" ]; then
        printf 'slink %s %s %s 0 0\n' "$_rel" "$(readlink "$_full")" "$_mode" >> "$_spec"
      elif [ -d "$_full" ]; then
        printf 'dir %s %s 0 0\n' "$_rel" "$_mode" >> "$_spec"
      elif [ -f "$_full" ]; then
        printf 'file %s %s %s 0 0\n' "$_rel" "$_full" "$_mode" >> "$_spec"
      fi
    done
    say "    initramfs spec: $(wc -l < "$_spec") entries"

    # -t 0, AND THE REASON IS A MISTAKE WORTH NOT REPEATING.
    #
    # gen_init_cpio was chosen for its deterministic INODE counter, and that
    # part worked -- the 419 six-byte inode differences went away. But its
    # main() does `default_mtime = time(NULL)` unless -t is given, so the
    # archive simply traded a varying inode for a varying mtime and came out
    # just as unreproducible: 11945869 bytes one run, 11945933 the next.
    #
    # That was asserted from memory rather than checked, which is why the
    # block below exists: the fix no longer depends on anyone being right
    # about what the tool does by default.
    if "$_gic" -t 0 "$_spec" > "$W/ir1.cpio" 2>/dev/null && [ -s "$W/ir1.cpio" ]; then
        _tflag="-t 0"
    else
        say "    gen_init_cpio does not accept -t; mtimes will be wall-clock"
        _tflag=""
        "$_gic" "$_spec" > "$W/ir1.cpio" 2>/dev/null
    fi

    # BUILT TWICE AND COMPARED, IN THIS RUN. Every previous attempt at this
    # archive was declared fixed and found still broken two runs later, because
    # a single build cannot show reproducibility and the check lived in a
    # separate job that ran days apart. gen_init_cpio is deterministic given
    # the same spec, so two invocations here differ only if something in the
    # archive is still time- or environment-derived -- which is exactly the
    # question, and it costs two seconds to ask.
    "$_gic" $_tflag "$_spec" > "$W/ir2.cpio" 2>/dev/null
    if cmp -s "$W/ir1.cpio" "$W/ir2.cpio"; then
        say "    cpio is byte-identical across two invocations"
    else
        say "    WARNING: two cpio invocations from one spec DIFFER --"
        say "    the archive is not reproducible and the cause is still inside it"
        cmp -l "$W/ir1.cpio" "$W/ir2.cpio" 2>/dev/null | head -3 | sed 's/^/      /'
    fi
    rm -f "$W/ir2.cpio"
    gzip -9nc "$W/ir1.cpio" > "$W/initramfs.cpio.gz"
    rm -f "$W/ir1.cpio"
  else
    # FALLBACK, AND IT IS KNOWN NOT TO BE REPRODUCIBLE. Said out loud rather
    # than left for someone to rediscover from three differing sizes.
    say "    gen_init_cpio unavailable -- falling back to cpio (inodes will vary)"
    ( cd "$W/ir" && find . | LC_ALL=C sort | cpio -o -H newc 2>/dev/null \
        | gzip -9n > "$W/initramfs.cpio.gz" )
  fi
  if [ -s "$W/initramfs.cpio.gz" ]; then
    B7=ok
    RUNG=B7; produced "$W/initramfs.cpio.gz"
    # IF THE ARCHIVE VARIES, IS IT THE ARCHIVE OR ITS CONTENTS? The initramfs
    # holds busybox plus the guest test binaries, and a non-deterministic test
    # binary would move the archive's size just as an mtime would. Manifest
    # the inputs so the two cases are distinguishable without another run.
    hashtree B7 "$W/ir"
    # AND PRINT THEM, because a hash written only to a TSV cannot be read from
    # a log. The initramfs has ~418 entries but only ten REGULAR FILES --
    # busybox, eight guest test binaries and init; everything else is a
    # directory or a busybox applet symlink. When the archive differs between
    # runs and `cpio is byte-identical across two invocations` has already
    # cleared the archiver, the cause is one of these ten, and naming them in
    # the log makes two consecutive logs enough to find it.
    # ONE LINE THAT ANSWERS IT. A digest over every input's path, mode, link
    # target and content hash. If this matches between two runs and the archive
    # still differs, the fault is in gen_init_cpio or gzip; if it differs, the
    # fault is upstream in whatever produced that file -- and the per-file list
    # below says which. Two log lines from two runs, no artifacts to download.
    ( cd "$W/ir" && find . -mindepth 1 2>/dev/null | LC_ALL=C sort | while IFS= read -r _e; do
        if [ -L "$_e" ]; then printf 'l %s %s\n' "$_e" "$(readlink "$_e")"
        elif [ -d "$_e" ]; then printf 'd %s %s\n' "$_e" "$(stat -c '%a' "$_e" 2>/dev/null)"
        else printf 'f %s %s %s\n' "$_e" "$(stat -c '%a' "$_e" 2>/dev/null)" \
             "$(sha256sum "$_e" 2>/dev/null | cut -d' ' -f1)"
        fi
      done ) > "$W/ir-inputs.txt"
    say "    initramfs input digest: $(sha256sum "$W/ir-inputs.txt" | cut -c1-32)"
    say "    ($(wc -l < "$W/ir-inputs.txt") entries: $(grep -c '^f ' "$W/ir-inputs.txt") files, $(grep -c '^l ' "$W/ir-inputs.txt") symlinks, $(grep -c '^d ' "$W/ir-inputs.txt") dirs)"

    say "    --- the ten files that go in ---"
    ( cd "$W/ir" && find . -type f 2>/dev/null | LC_ALL=C sort ) | while IFS= read -r _f; do
      printf '      %-32s %10s  %s\n' "${_f#./}" \
        "$(wc -c < "$W/ir/$_f" 2>/dev/null || echo 0)" \
        "$(sha256sum "$W/ir/$_f" 2>/dev/null | cut -c1-32)"
    done
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
  hashout B8 "$f"
done
# cc1/cc1plus are the compiler proper; the driver is a thin wrapper and two
# different cc1s behind an identical gcc would compare equal above.
#
# FULL PATH, NOT BASENAME. This printed `${f##*/}`, so two installs under
# /usr/libexec/gcc/<triplet>/<version>/ both showed as `cc1` with different
# hashes and nothing to tell them apart -- which reads as a reproducibility
# failure and is two different compilers correctly having different bytes.
# The path carries the triplet and the version, which is exactly the missing
# information.
for f in $(ls /usr/libexec/gcc/*/*/cc1 /usr/libexec/gcc/*/*/cc1plus 2>/dev/null); do
  hashout B8 "$f"
done
# AND SAY WHAT EACH INSTALL IS, since the path alone leaves the reader to infer
# it. If two versions or two triplets are present, this is the line that says
# so outright.
say ""
say "  --- gcc INSTALLS PRESENT ---"
for d in $(ls -d /usr/libexec/gcc/*/*/ 2>/dev/null); do
  _t=$(basename "$(dirname "$d")")
  _v=$(basename "$d")
  printf '    %-30s triplet %-28s version %s\n' "$d" "$_t" "$_v"
done
# THE WHOLE SYSROOT, MANIFESTED. Every regular file with its size and hash.
# This is the `files` field DERIVATIONS.md specifies, and it is what makes
# `veron why <file>` possible at all -- without a per-file manifest the graph
# stops at derivations and cannot reach an installed path.
say ""
say "  --- SYSROOT MANIFEST ---"
hashtree B8 /usr
hashtree B8 /lib
say "    manifest: $MANIFEST"

say ""
say "  --- WHAT LEFT THE SANDBOX ---"
for f in /out/Image /out/initramfs.cpio.gz; do
  hashout B8 "$f"
done
# FULL sha256 FOR THE TWO ARTIFACTS THAT LEAVE, because these are the ones
# someone outside will check, and a truncated hash cannot be checked.
say ""
say "  --- FULL sha256, FOR VERIFICATION OUTSIDE THIS RUN ---"
for f in /out/Image /out/initramfs.cpio.gz; do
  [ -f "$f" ] && sha256sum "$f" | sed 's/^/    /'
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
