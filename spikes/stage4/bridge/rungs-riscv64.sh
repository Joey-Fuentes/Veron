#!/bin/sh
# THE RUNGS, FROM A tcc TO gcc 4.7.4, IN A BOX WITH NOTHING BUT busybox.
#
# ONE COPY, TWO ARMS. This script is run unchanged by both
#
#   stage3-to-stage4-reference.yml   CC = a host-built tcc, static against musl
#   stage3-to-stage4-bridge.yml      CC = mc-tcc, built from the seed
#
# and that is the entire point of it being a file rather than a heredoc in each
# workflow. The two arms differ in ONE input -- which tcc -- so any difference
# in the results is attributable to the compiler and to nothing else. A second
# copy of these rungs would drift from the first and the comparison would
# quietly stop meaning anything, which is the failure this repo already records
# for lists kept beside the thing they describe.
#
# THE REFERENCE ARM RUNS FIRST, ON PURPOSE. spikes/stage3/README.md says why,
# about tcc-two-ways: "if the harness is wrong, that is where it shows, on a
# compiler nobody doubts. The first version of that job reported '0 differing
# lines' against a reference file that did not exist, and the control is what
# caught it." Everything below is new harness -- a hand-driven musl build, an
# archiver nothing has exercised, busybox sh running autoconf -- so it needs a
# compiler nobody doubts before it can accuse one.
#
# WHAT THE BOX IS. busybox, the tcc under test, and pinned sources under /in.
# No /usr/include, no crt files, no libc to link against, no binutils, no make.
# Everything on the build path is built here. That is stricter than stage 4,
# which binds host /usr read-only and whose own accounting says the guarantee
# is "no host compiler", not "no host dependencies".
#
# ENVIRONMENT
#   CC_BIN    absolute path to the tcc under test          (required)
#   TCCDIR    tcc's -B directory; libtcc1.a is built into it (required)
#   ARM       a label for the summary, e.g. "reference" or "mc-tcc"
#
# EVERY RUNG REPORTS; NOTHING HERE EXITS NON-ZERO. A rung that fails prints why
# and the rungs above it are skipped with a reason rather than failed. The only
# hard gate lives in the workflow -- the SEAL -- because a host tool leaking in
# is what would make every number below meaningless.

set -u

CC_BIN=${CC_BIN:?CC_BIN must be set}
TCCDIR=${TCCDIR:?TCCDIR must be set}
ARM=${ARM:-unnamed}

# STOP_AFTER LETS A CALLER TAKE THE BOTTOM OF THE LADDER AND NOTHING ELSE.
#
# tool-probe wants a real sysroot -- musl, make, binutils, no host /usr -- so
# it can build one package against the constraints the chain actually has. It
# used to restore that from the reference job's cache, which meant it could not
# run until the reference job had passed the rungs the probe exists to unblock.
# A question that can only be answered after the thing it answers is not a
# question.
#
# Rungs 0-5 produce that sysroot in about a minute, and they are the most
# proven part of this script. So the probe runs THIS FILE with STOP_AFTER=5
# rather than growing a second musl build that would drift from this one.
#
# Empty means run everything, which is what both bridge jobs do.
STOP_AFTER=${STOP_AFTER:-}
stop_here() {
    [ -n "$STOP_AFTER" ] || return 1
    # Rung numbers are not integers -- 3.5, 4.5, 11.7 -- so compare as decimals
    # by scaling. `expr` is in busybox; awk would also work but this is one
    # fewer thing that has to be present.
    _a=$(printf '%s' "$1" | awk -F. '{printf "%d", $1*10 + ($2 ? substr($2 "0",1,1) : 0)}')
    _b=$(printf '%s' "$STOP_AFTER" | awk -F. '{printf "%d", $1*10 + ($2 ? substr($2 "0",1,1) : 0)}')
    [ "$_a" -gt "$_b" ]
}

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

# An INPUT, recorded silently -- the caller has already printed it. Kept
# separate from hashout so the manifest distinguishes what a rung CONSUMED
# from what it PRODUCED, which is the distinction a derivation record is
# built on and which cannot be recovered later from a flat list of hashes.
hashin() {
    [ -e "$2" ] || return 0
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" \
        "$(wc -c < "$2" 2>/dev/null || echo 0)" \
        "$(sha256sum "$2" 2>/dev/null | cut -d" " -f1)" >> "$MANIFEST" 2>/dev/null || true
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
# head1 SETS THE CURRENT RUNG, so hashout and hashin do not have to be told
# which one they are in. Before this, every manifest line would have needed the
# label passed by hand at every call site, and the first one anybody forgot
# would silently attribute an artifact to the wrong rung.
RUNG=start
head1() {
    RUNG=$(printf '%s' "$*" | sed -n 's/^RUNG \([0-9.]*\).*/\1/p')
    [ -n "$RUNG" ] || RUNG=misc
    say ""
    say "  === $* ==="
}

# WHAT A RUNG PRODUCED: printed with its exact size and full sha256, and
# recorded. This replaces lines of the form
#
#     say "    make: $(wc -c < "$PFX/bin/make") bytes"
#
# which gave a size and no hash -- enough to notice something changed size,
# useless for noticing it changed content, and impossible to trace. A rung's
# outputs are the only thing another rung consumes, so they are the edges of
# the whole graph.
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

# WHAT A RUNG CONSUMED. Recorded, not printed -- the tarball list is already
# printed once at the top and repeating twenty-six sha256 lines per rung would
# bury the build. The record is what `veron why` walks.
consumed() {
    for _i in "$@"; do
        [ -e "$_i" ] || continue
        printf 'IN.%s\t%s\t%s\t%s\n' "$RUNG" "$_i" \
            "$(wc -c < "$_i" 2>/dev/null || echo 0)" \
            "$(sha256sum "$_i" 2>/dev/null | cut -d" " -f1)" >> "$MANIFEST" 2>/dev/null || true
    done
}

# THE SYSROOT IS /usr, AND THAT IS THE FIX FOR RUNG 3.
#
# The reference run built crt1.o, crti.o and crtn.o correctly and then failed
# with "file 'crt1.o' not found". -L adds LIBRARY search paths, which is where
# -lc is resolved; tcc looks for crt files in a SEPARATE list, compiled in at
# configure time and not reachable from the command line. So the crt files
# existed and were unfindable.
#
# Rather than reconfigure each arm's compiler -- which would make the two arms
# differ in something other than the compiler -- the libc is installed where
# every tcc already looks: /usr/include and /usr/lib. The box is ours and
# starts with no /usr at all, so what ends up there is only what these rungs
# built. It also means rungs 3.5 and up get a plain working CC, which is what
# autoconf expects: hundreds of conftest cycles will not pass -I and -L for us.
SYS=/usr
PFX=/work/prefix
NP=$(nproc 2>/dev/null || echo 2)
mkdir -p "$SYS/lib" "$SYS/include" "$PFX/bin" /work/src

CC="$CC_BIN -B$TCCDIR"

# EXTRACT THE TARBALL AS SHIPPED, WITH THE FLAG ITS EXTENSION ASKS FOR.
#
# `tar -zxf` is all this ever needed. It extracted musl on every run; the one
# time it failed was when I renamed the pins and wrote `tar xf`, dropping the
# -z, which broke the only rung that had been passing. Everything built on top
# of that -- an od probe that lied, a ustar repack on a theory since disproved,
# an airlock decompress step -- was scaffolding around a mistake, and is gone.
#
# THE ONE THING STILL UNEXPLAINED is why this same call opened musl-1.2.5.tar.gz
# and was refused on make-3.82.tar.gz: correct flag, valid gzip, and a GNU
# tarball which -- verified locally against every GNU tar format -- does carry
# the ustar magic busybox checks for. That is a real unknown about this box and
# it deserves an answer rather than a workaround, so on failure this dumps the
# first 512 bytes and the tar header fields rather than routing around it.
#
# No `od -j` and no `tr -dc '[:print:]'` in the dump: both have already
# produced confident empty readings in this job that were the tool failing
# rather than the data being absent.
untar() {          # $1 = path prefix, e.g. /in/musl
    _t=$(ls "$1"*.tar.gz "$1"*.tar.xz "$1"*.tar.bz2 2>/dev/null | head -1)
    if [ -z "$_t" ]; then
        say "    no tarball matching $1* -- /in holds:"
        ls -1 /in 2>/dev/null | sed 's/^/      /'
        return 1
    fi
    # STDERR TO /tmp, NOT /work. A redirect whose target is not writable makes
    # the whole command fail, so `tar ... 2>/work/x` reports failure when tar
    # SUCCEEDED and only the log could not be opened. A dry run under dash hit
    # exactly that.
    case "$_t" in
        *.tar.gz)  _flag=-zxf ;;
        *.tar.xz)  _flag=-Jxf ;;
        *.tar.bz2) _flag=-jxf ;;
        *)         say "    unknown archive type: $_t"; return 1 ;;
    esac

    # RECORDED HERE, ONCE, RATHER THAN AT EVERY CALL SITE. Every rung that
    # consumes an upstream reaches it through untar, so hooking the record in
    # here means no rung can forget to declare its input -- which is the
    # failure mode of asking twenty call sites to remember.
    consumed "$_t"

    # THE COMMAND, PRINTED BEFORE IT RUNS. Several rounds here have argued
    # about what was being executed rather than reading it. The working
    # directory is printed too, because `tar` extracts relative to it and a
    # failed `cd` earlier in a rung has already sent one extraction somewhere
    # nobody was looking.
    say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: tar $_flag $_t"
    say "    (cwd: $(pwd))"
    tar "$_flag" "$_t" 2>/tmp/untar.err
    _rc=$?
    say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_rc)"

    if [ "$_rc" = 0 ]; then
        # WHAT LANDED, AND WHERE. The cwd line above says where tar was TOLD to
        # write; this says what actually appeared. gcc 10 extracted with rc=0
        # into /work instead of /work/src and nothing noticed until a configure
        # path four lines later spelled the other directory out.
        say "    -> $(ls -dt */ 2>/dev/null | head -1) in $(pwd)"
        return 0
    fi
    say "    tar refused $_t ($(wc -c < "$_t") bytes):"
    sed 's/^/      /' /tmp/untar.err 2>/dev/null | head -3
    # DECOMPRESS SEPARATELY AND LOOK AT THE HEADER. If gunzip is clean and the
    # first block is a well-formed tar header, the fault is in busybox's tar
    # and not in the archive -- which is the question three runs failed to
    # settle.
    case "$_t" in
        *.tar.gz)  gzip  -dc "$_t" > /tmp/probe.tar 2>/dev/null ;;
        *.tar.xz)  xz    -dc "$_t" > /tmp/probe.tar 2>/dev/null ;;
        *.tar.bz2) bzip2 -dc "$_t" > /tmp/probe.tar 2>/dev/null ;;
    esac
    _sz=$(wc -c < /tmp/probe.tar 2>/dev/null || echo 0)
    say "    decompressed: $_sz bytes  512-aligned=$(( _sz % 512 == 0 ))"

    # THE HEADER, FIELD BY FIELD, AND A KNOWN-GOOD ONE BESIDE IT.
    #
    # musl's tarball opens with this exact call and this one does not, so the
    # difference between their first 512 bytes IS the answer. Printing only the
    # broken one has failed to produce it three times.
    #
    # dd's skip is used to carve the field rather than od's -j, because od -j
    # is one of the flags that has already returned a confident empty reading
    # in this job. dd carves; od only formats what it is handed.
    _hdrfield() {   # $1 = file  $2 = offset  $3 = length
        dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -c 2>/dev/null | head -2
    }
    _known=$(ls /in/musl-*.tar.gz 2>/dev/null | head -1)
    if [ -n "$_known" ]; then
        gzip -dc "$_known" > /tmp/good.tar 2>/dev/null
        say "    --- known-good ($_known) ---"
        say "      name  : $(_hdrfield /tmp/good.tar 0 16 | head -1)"
        say "      magic : $(_hdrfield /tmp/good.tar 257 8 | head -1)"
        say "      type  : $(_hdrfield /tmp/good.tar 156 1 | head -1)"
    fi
    say "    --- this one ---"
    say "      name  : $(_hdrfield /tmp/probe.tar 0 16 | head -1)"
    say "      magic : $(_hdrfield /tmp/probe.tar 257 8 | head -1)"
    say "      type  : $(_hdrfield /tmp/probe.tar 156 1 | head -1)"
    say "    first 512 bytes:"
    dd if=/tmp/probe.tar bs=512 count=1 2>/dev/null | od -c 2>/dev/null | head -12 | sed 's/^/      /'

    # AND DOES busybox tar OPEN IT ONCE DECOMPRESSED? If the same tar accepts
    # the uncompressed bytes it just refused compressed, the fault is in the -z
    # path and not in the archive at all.
    if tar xf /tmp/probe.tar 2>/tmp/probe.err; then
        say "    tar xf ON THE DECOMPRESSED FILE SUCCEEDED."
        say "    So the archive is fine and busybox's -z path is what refused it."
    else
        say "    tar xf on the decompressed file also refused:"
        sed 's/^/      /' /tmp/probe.err 2>/dev/null | head -2
    fi
    rm -f /tmp/good.tar
    rm -f /tmp/probe.tar
    return 1
}

onedir() { ls -d $1 2>/dev/null | head -1 | sed 's|^\./||'; }

# WHERE IT FAILED, NOT WHAT FINISHED LAST.
#
# Every rung ends its failure path with `tail -25 b.log`, and under `make -j`
# that is whatever module happened to finish last -- not the one that failed.
# A run died in gcc's build-side fixincludes and printed twenty-five lines of
# gmp's libtool SUCCEEDING, so the actual ld message at line 3831 never
# reached the log and the round after it had nothing to work from.
#
# This finds the first real error line and prints the window around it, which
# is where a compiler or linker puts the message that names the cause.
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

R0=skip; R1=skip; R2=skip; R3=skip; R35=skip; R4=skip; R45=skip; R5=skip; R6=skip; R7=skip; R8=skip; R9=skip; R10=skip; R11=skip; R115=skip; R117=skip; R12=skip; R13=skip; R14=skip; R15=skip; R16=skip; R17=skip; R18=skip; R19=skip; R20=skip

# WHAT IS ACTUALLY IN /in, BEFORE ANYTHING TRIES TO USE IT.
#
# Three runs were spent guessing at an archive nobody had looked at. Printing
# the inventory costs one screen and removes the guessing: name, size, and the
# first four bytes, which say whether a thing is gzip (1f 8b), xz (fd 37),
# bzip2 (42 5a) or something that is not compressed at all.
say ""
# EVERY INPUT, WITH ITS FULL sha256. This printed the first four bytes of each
# file -- the magic number, `fd 37 7a 58` for xz and `1f 8b 08 00` for gzip.
# That is a format check, and it was standing where a hash belongs: four bytes
# that are IDENTICAL for every xz file in the list tell you nothing about which
# tarball you got.
#
# These are the roots of the whole graph. If the sha256 of an input is not in
# the log, nothing built from it can be traced, and the pins in the workflow
# are a claim rather than a record.
say "  === WHAT IS IN /in ==="
printf '    %-32s %12s  %s\n' "file" "bytes" "sha256"
for _f in /in/*; do
    [ -f "$_f" ] || continue
    printf '    %-32s %12s  %s\n' "${_f##*/}" "$(wc -c < "$_f")" \
      "$(sha256sum "$_f" | cut -d' ' -f1)"
    hashin IN "$_f"
done

say ""
say "  arm:      $ARM"
hashout SEED "$CC_BIN"
say "  -B dir:   $TCCDIR"

# ---------------------------------------------------------------------------
head1 "RUNG 0 -- the compiler runs, and libtcc1.a for it to link against"
"$CC_BIN" --version 2>&1 | head -2 | sed 's/^/    /'

# libtcc1.a IS NOT OPTIONAL ONCE ANYTHING IS HOSTED. It carries the helpers the
# backend emits calls to -- 128-bit division, __clear_cache, the soft-float
# entry points -- so a freestanding program can miss it and a real one cannot.
# tcc's arm64 build is `ARM64_O = lib-arm64.o $(COMMON_O)`; reaching for
# libtcc1.c instead gives a misleading "unsupported CPU type" that says nothing
# about the compiler. MICRO-C.md records that trap.
cd "$TCCDIR/lib" 2>/dev/null || { say "    no lib/ under $TCCDIR"; R0=FAIL; }
if [ "$R0" != FAIL ]; then
  # THE LIST WAS SHORT BY THREE, and one of them is why -run did not work.
  #
  # tcc's own lib/Makefile builds, for arm64:
  #     ARM64_O  = lib-arm64.o $(COMMON_O)
  #     COMMON_O = stdatomic.o atomic.o builtin.o alloca.o alloca-bt.o
  #     LIN_O    = dsohandle.o
  #     $(Nat)COMMON_O += runmain.o tcov.o
  # and keeps runmain.o BESIDE the archive rather than in it:
  #     EXTRA_O = runmain.o ...        # not in libtcc1.a
  #
  # We built five of those. Without runmain.o, `-run` cannot start at all:
  #     tcc: error: file 'runmain.o' not found
  #     tcc: error: _runmain not defined
  # which made tcc's test1, test2, test3, hello-run and vla_test-run -- all of
  # which are `tcc -run` -- look unavailable when the file simply had not been
  # compiled. It compiles fine, and so do dsohandle.c and alloca-bt.S.
  #
  # alloca-bt.S AND tcov.c ARE LEFT OUT ON PURPOSE, and both were measured.
  # alloca-bt.S is the bounds-checking alloca and pulls __bound_new_region out
  # of bcheck.o, which this build does not make; adding it broke every link
  # with `undefined symbol '__bound_new_region'`. tcov.c includes <stdio.h>
  # and there is no libc at rung 0; it is only needed for -ftest-coverage.
  #
  # dsohandle.c IS worth having: adding it took tests2 from 105 to 107.
  objs=""
  # SOFT FLOAT GOES IN TOO, and it is not one of tcc's own files.
  #
  # tcc-microc patch 0004 makes tcc's constant folder do floating-point
  # arithmetic in integers, because micro-c has none, which puts calls to
  # sf_add and friends into tcc.c. mc-tcc satisfies them from the bootstrap
  # runtime and gen2/gen3 link runtime.o, so the ordinary build and the
  # self-compilation fixpoint were both fine. `tcc -run tcc.c` links neither:
  #     tcc: error: undefined symbol 'sf_add'
  # and that is tcc's own test1, test2 and test3, all three of which are
  # `tcc -run tcc.c ... -run tcctest.c`.
  #
  # libtcc1 is the right home -- tcc links it into every program it builds,
  # -run included, and soft float is what libgcc and libtcc1 exist to hold.
  if [ -f /src/stage3/micro-c-libc/impl/libtcc1-softfloat.c ]; then
    if $CC -c -o /work/lt-softfloat.o \
           /src/stage3/micro-c-libc/impl/libtcc1-softfloat.c 2>>/work/libtcc1.err
    then
      objs="$objs /work/lt-softfloat.o"
    else
      say "    soft float did NOT build -- tcc -run tcc.c will not link"
    fi
  fi
  # libtcc1.c FIRST, FOR THE REASON THE amd64 ARM DISCOVERED.
  # tcc's lib/Makefile builds every non-arm target from libtcc1.o, which
  # carries the compiler-support helpers a link will otherwise miss. The loop
  # skips absent names, so listing both is free.
  # lib-arm64.c ON riscv64 IS NOT A TYPO -- IT IS WHAT tcc ITSELF DOES.
  #
  # tcc's lib/Makefile:42 reads
  #     RISCV64_O = lib-arm64.o $(COMMON_O)
  # so the file named for arm64 is the runtime for riscv64 as well. It is
  # portable C: 18 functions, two mentions of arm64 in the whole file, one of
  # them the header comment.
  #
  # RENAMING IT lib-riscv64.c WAS MY SUBSTITUTION AND IT COST RUNG 3. The
  # loop below skips names that are not present, so the file was silently
  # never compiled, and run 85000965675 built musl completely and then could
  # not link a hosted program:
  #     tcc: error: undefined symbol '__addtf3'
  #     ... __extenddftf2 __multf3 __netf2 __subtf3 __fixtfsi __floatsitf
  # Those are the soft-float binary128 helpers -- RISC-V's long double is
  # 128-bit -- and lib-arm64.c defines every one of them.
  #     lib/Makefile:42  RISCV64_O = lib-arm64.o $(COMMON_O)
  # alloca-bt.S is in COMMON_O and stays OUT for the measured reason above.
  for f in libtcc1.c lib-arm64.c stdatomic.c atomic.c builtin.c va_list.c alloca.S \
           dsohandle.c \
           armeabi.c alloca-arm.S armflush.c; do
    [ -f "$f" ] || continue
    o="/work/lt-$(basename "$f" | tr '.' '_').o"
    # $CC IS TWO WORDS -- the binary and its -B. Quoting it makes the shell
    # look for a command literally named "/work/ref-tcc -B/work/tccsrc", which
    # is what the reference run reported six times as "not found". Every other
    # rung had it unquoted; this one did not.
    if $CC -c -o "$o" "$f" 2>>/work/libtcc1.err; then objs="$objs $o"; fi
  done
  # runmain.o goes NEXT TO the archive, not inside it -- tcc looks it up by
  # name when -run is given, exactly as its own Makefile arranges.
  if [ -f runmain.c ]; then
    if $CC -c -o "$TCCDIR/runmain.o" runmain.c 2>>/work/libtcc1.err; then
      say "    runmain.o built -- -run can start"
      produced "$TCCDIR/runmain.o"
    else
      say "    runmain.o: does NOT build -- -run will not start"
    fi
  fi
  if [ -n "$objs" ] && "$CC_BIN" -ar rcs "$TCCDIR/libtcc1.a" $objs 2>>/work/libtcc1.err; then
    say "    libtcc1.a from $(echo $objs | wc -w) objects"
    produced "$TCCDIR/libtcc1.a"
    R0=ok
  else
    R0=FAIL
    say "    libtcc1.a FAILED -- tcc -ar is the only archiver in this box"
    grep -av '^[A-Z][0-9]*$' /work/libtcc1.err 2>/dev/null | head -8 | sed 's/^/      /'
  fi
fi
cd /work

# ---------------------------------------------------------------------------
head1 "RUNG 1 -- freestanding compile and link, no libc at all"
# The shape every stage-3 measurement used. If this fails the compiler did not
# survive the trip into the box and nothing above it means anything.
cd /work
# THE SAME TEST, IN THIS ARCHITECTURE'S REGISTERS AND SYSCALL NUMBERS.
# The aarch64 arm uses x8/x0/x1/x2 and `svc #0`. RISC-V uses the same
# register NAMES for the syscall ABI -- a7 for the number, a0-a2 for the
# arguments -- and traps with `ecall`. The numbers are the same as aarch64's
# because both use the generic asm-generic/unistd.h table: write=64, exit=93.
cat > r1.c <<'EOF'
static long sys3(long n, long a, long b, long c)
{
    register long a7 __asm__("a7") = n;
    register long a0 __asm__("a0") = a;
    register long a1 __asm__("a1") = b;
    register long a2 __asm__("a2") = c;
    __asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
    return a0;
}
void _start(void) { sys3(64, 1, (long)"rung1 ok\n", 9); sys3(93, 0, 0, 0); }
EOF
if $CC -nostdlib -static -o r1.bin r1.c 2>r1.err && ./r1.bin >r1.out 2>&1; then
  say "    $(cat r1.out)"; R1=ok
else
  R1=FAIL; say "    FAILED"
  grep -av '^[A-Z][0-9]*$' r1.err | head -8 | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
head1 "RUNG 2 -- musl, built WITHOUT make"
# THE LIBC RUNG, HAND-DRIVEN ON PURPOSE. Nothing above can link without a libc
# -- binutils, make and gcc are all ordinary C programs needing one for their
# own binaries -- and make cannot come first because it needs the libc too.
# live-bootstrap breaks that circle with kaem: a flat list of literal commands,
# no Makefile, no variables, no dependency graph. This is the same thing in
# busybox sh, which is already declared. musl's build is small enough to spell
# out: two generated headers, every .c compiled once, an archive, the crt files.
#
# sources/musl.toml declares the substitutions -- 9 aarch64 .s files that fall
# back to portable C, and src/complex/*.c for _Complex.
if [ "$R1" = ok ]; then
  cd /work/src
  # A STRAY `fi` HERE CLOSED THE RUNG-1 GUARD EARLY, so rung 2 would have run
  # even after rung 1 failed. Caught by counting if/fi rather than by trusting
  # `sh -n`, which passed: the counts balanced, the nesting did not.
  if ! untar /in/musl-; then R2=FAIL; fi
  _md=$(onedir 'musl-* ./musl-*')
  if [ "$R2" != FAIL ]; then
    if [ -z "$_md" ] || ! cd "$_md"; then
      say "    no musl directory after extraction"; R2=FAIL
    fi
  fi
  if [ "$R2" != FAIL ]; then
  # DO NOT DELETE THE ARCH ASSEMBLY UNTIL IT HAS ACTUALLY REFUSED TO BUILD.
  #
  # sources/musl.toml declares 9 aarch64 .s files dropped, on the grounds that
  # "tcc's arm64 assembler cannot assemble these; musl ships portable C for
  # each, so the C fallback is used". The first half was measured; THE SECOND
  # HALF IS NOT TRUE FOR ALL NINE, and the last run is what showed it:
  #
  #     rung 3: static binary, 80 KB, no interpreter, SIGNAL 11 on startup
  #
  # A static musl binary that links and dies immediately is the signature of
  # TLS never being set up. `__set_thread_area` sets the thread pointer --
  # `msr tpidr_el0, x0` on aarch64 -- and that CANNOT be written in portable C,
  # so there is no fallback for it to fall back to. Without it `__init_tls`
  # leaves the thread pointer unset and the first touch of errno segfaults,
  # which is exactly where a hello world dies.
  #
  # SO ASSEMBLE THEM AND FIND OUT. The tcc arm64 assembler this repo carries
  # exists precisely for files like these -- five patches of it -- and the drop
  # list may predate it or have been inherited rather than measured. Each file
  # is attempted; only the ones that genuinely refuse are dropped, and they are
  # named. That turns a declared substitution into a checked one.
  say "    --- the 9 declared-dropped .s files, attempted rather than assumed ---"
  : > /work/asm-failed.txt
  nasm_ok=0; nasm_bad=0
  for s in src/fenv/riscv64/fenv.s src/ldso/riscv64/tlsdesc.s \
           src/process/riscv64/vfork.s src/setjmp/riscv64/longjmp.s \
           src/signal/riscv64/restore.s src/thread/riscv64/__set_thread_area.s \
           src/thread/riscv64/__unmapself.s src/thread/riscv64/clone.s \
           src/thread/riscv64/syscall_cp.s; do
    [ -f "$s" ] || continue
    if $CC -c -o /tmp/asmprobe.o "$s" 2>/tmp/asmprobe.err; then
      nasm_ok=$((nasm_ok + 1))
      printf '      %-44s assembles\n' "$s"
    else
      nasm_bad=$((nasm_bad + 1))
      printf '      %-44s REFUSED: %s\n' "$s" \
        "$(grep -a 'error' /tmp/asmprobe.err 2>/dev/null | head -1 | sed 's/^.*error: //' | cut -c1-40)"
      echo "$s" >> /work/asm-failed.txt
      rm -f "$s"
    fi
  done
  say "    $nasm_ok assemble, $nasm_bad refused"

  # THE ONE THAT MAKES THE LIBC UNUSABLE, CALLED OUT SEPARATELY. The others
  # cost a feature -- setjmp, vfork, signal return, threads. This one costs
  # every program, because nothing runs without a thread pointer.
  if grep -q '__set_thread_area' /work/asm-failed.txt 2>/dev/null; then
    say ""
    say "    __set_thread_area REFUSED, AND THERE IS NO PORTABLE C FOR IT."
    say "    The thread pointer is never set, __init_tls leaves it null, and"
    say "    the first access to errno segfaults. EVERY hosted program built"
    say "    against this libc dies on startup regardless of the codegen."
    say "    sources/musl.toml's claim that all nine have a C fallback is"
    say "    wrong for this file and should be corrected."
  fi

  rm -f src/complex/*.c
  say "    src/complex dropped (_Complex unsupported), as declared"

  # TWO RISC-V FIXES, BOTH TESTED AGAINST A LOCALLY BUILT tcc AT OUR PIN
  # (spikes/toolbox/tcc-5ec0e6f8-arm64-configured.tar.gz, --cpu=riscv64).
  #
  # 1. tlsdesc.s USES add AND sll WITH IMMEDIATES, WHICH ARE addi AND slli.
  #
  #        src/ldso/riscv64/tlsdesc.s:13: error: 'add': Expected second
  #            source operand that is a register or immediate
  #        line 13:  add sp,sp,-16
  #        line 22:  sll a0,a0,3
  #
  #    GNU as accepts `add rd,rs,imm` and quietly assembles it as addi; tcc
  #    does not, and says so. The immediate forms are the real instructions
  #    and mean exactly the same thing -- this is a spelling fix, not a
  #    behaviour change. With both substituted the file assembles to 959
  #    bytes; run 84995533778 had it REFUSED, which cost the whole rung.
  if [ -f src/ldso/riscv64/tlsdesc.s ]; then
    sed -i -e 's/^\tadd \(sp,sp,-\?[0-9]\)/\taddi \1/' \
           -e 's/^\tsll \(a0,a0,[0-9]\)/\tslli \1/' src/ldso/riscv64/tlsdesc.s
    say "    tlsdesc.s: add/sll with immediates rewritten as addi/slli"
  fi

  # 2. src/fenv/riscv64 IS CSR INSTRUCTIONS tcc DOES NOT IMPLEMENT.
  #
  #        src/fenv/riscv64/fenv.S:52: error: ',' expected (got '\n')
  #        line 52:  fscsr t1
  #    plus csrc, csrs and frflags earlier in the file.
  #
  #    DROPPED RATHER THAN REWRITTEN, because musl ships a generic
  #    replacement and says what it is for: "Dummy functions for archs
  #    lacking fenv implementation". src/fenv/fenv.c defines the SAME SEVEN
  #    symbols this file does -- feclearexcept, feraiseexcept, fetestexcept,
  #    fegetround, __fesetround, fegetenv, fesetenv -- checked, not assumed.
  #    Floating-point exception flags stop being reported; nothing in this
  #    chain reads them.
  _fdropped=$(ls src/fenv/riscv64/* 2>/dev/null | wc -l)
  rm -f src/fenv/riscv64/*
  say "    src/fenv/riscv64 dropped ($_fdropped files): CSR instructions tcc"
  say "    does not implement. musl's generic dummy fenv.c is used instead."

  # THE TWO GENERATED HEADERS. musl's Makefile builds these with sed before
  # anything compiles. Nothing includes them until they exist and every later
  # compile fails obscurely if they do not, so they are checked, not assumed.
  mkdir -p obj/include/bits
  sed -f tools/mkalltypes.sed arch/riscv64/bits/alltypes.h.in \
      include/alltypes.h.in > obj/include/bits/alltypes.h 2>/dev/null
  cp arch/riscv64/bits/syscall.h.in obj/include/bits/syscall.h 2>/dev/null
  sed -n 's/__NR_/SYS_/p' arch/riscv64/bits/syscall.h.in \
      >> obj/include/bits/syscall.h 2>/dev/null
  for h in alltypes.h syscall.h; do
    [ -s "obj/include/bits/$h" ] || say "    WARN: obj/include/bits/$h is empty"
  done
  say "    generated: $(ls obj/include/bits 2>/dev/null | tr '\n' ' ')"

  # LONG DOUBLE IS EIGHT BYTES IN THIS COMPILER, AND musl's HEADER SAYS 113.
  #
  # tcc-microc patch 0001 sets LDOUBLE_SIZE to 8 and predicts this in as many
  # words: "a program using long double and linking against a normally-built
  # libc would disagree about the size". musl is not normally built here -- it
  # is built BY that compiler -- so its long double really is eight bytes, and
  # only its header disagrees:
  #
  #     mc-tcc        sizeof(long double) == 8
  #     musl/arch/riscv64/bits/float.h    LDBL_MANT_DIG 113
  #
  # musl branches on that macro throughout. frexpl, fmodl, scalbnl and the
  # float printer each carry a `#if LDBL_MANT_DIG == 113` arm, so a 113-bit
  # algorithm ran over a 64-bit value and printf("%f") produced 0.000000 for a
  # number whose bits were exactly right -- measured, with the same value
  # reported correctly as `5.008 raw bits = 40140831 26e978d5` two lines above.
  #
  # THE REPLACEMENT IS musl's OWN, not something invented here. Every
  # architecture where long double is double -- arm, i386's soft variants,
  # riscv32 -- ships exactly these values, and every `#if LDBL_MANT_DIG == 53`
  # arm in musl's math is written for it. So this selects a configuration musl
  # already supports rather than inventing a fourth one.
  #
  # DECLARED, LIKE sys/cdefs.h. It is a substitution and it is reported, so it
  # cannot pass for something that came out of the tarball.
  # ASK THE COMPILER, DO NOT ASSUME IT. This file is shared by three ladders:
  # stage3-to-stage4-reference runs it with a HOST-BUILT tcc whose long double
  # really is binary128, and stage0-stage4-complete runs it with mc-tcc, whose
  # long double is eight bytes. Rewriting the header unconditionally fixes the
  # second and BREAKS THE FIRST -- it would tell musl 53 bits while the
  # compiler gives 113, the same mismatch in the other direction.
  #
  # A compile-only probe answers it: the array size is negative, and the
  # translation unit therefore invalid, unless long double is eight bytes.
  # Nothing needs to run, so this works at rung 2 where nothing is linkable
  # yet.
  printf 'int _ldprobe[sizeof(long double) == 8 ? 1 : -1];\n' > /tmp/ldsize.c
  if $CC -c -o /tmp/ldsize.o /tmp/ldsize.c 2>/dev/null; then
    LD_IS_DOUBLE=yes
  else
    LD_IS_DOUBLE=no
  fi
  rm -f /tmp/ldsize.c /tmp/ldsize.o
  if [ "$LD_IS_DOUBLE" = no ]; then
    say "    bits/float.h: LEFT ALONE -- this compiler's long double is not 8"
    say "                  bytes, so musl's own aarch64 header already matches"
  fi
  if [ "$LD_IS_DOUBLE" = yes ] && [ -f arch/riscv64/bits/float.h ]; then
    cat > arch/riscv64/bits/float.h <<'FLOATH'
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
    say "    bits/float.h: long double declared as double (LDBL_MANT_DIG 53)"
    say "                  -- matches this compiler's 8-byte long double,"
    say "                     declared substitution, see the note in rungs.sh"
  fi

  # THE INCLUDE ORDER IS THE WHOLE THING, AND GETTING IT WRONG COST A RUN.
  #
  # musl ships TWO features.h. include/features.h is the public one;
  # src/include/features.h is the internal one and it is the only place
  # `hidden` is defined. Put -Iinclude first and <features.h> resolves to the
  # public header, `hidden` never gets defined, and
  #
  #     extern hidden struct __libc __libc;        src/internal/libc.h:37
  #
  # parses as a declaration whose type is the unknown identifier `hidden`,
  # giving "';' expected (got 'struct')". 664 of 803 objects failed that way
  # in the reference run and every one of them was this.
  #
  # This is musl's own order, from its Makefile's CFLAGS_ALL: arch, generic,
  # the generated internal dir, src/include, src/internal, generated include,
  # then the public include LAST.
  #
  # -nostdinc matters for the same class of reason: without it the compiler's
  # own headers are on the path and a musl source file can pick up a
  # declaration musl did not write. -D_XOPEN_SOURCE=700 is what musl compiles
  # itself with and several files gate declarations on it.
  mkdir -p obj/src/internal
  printf '#define VERSION "%s"\n' "$(cat VERSION 2>/dev/null || echo 0)" \
    > obj/src/internal/version.h
  INC="-Iarch/riscv64 -Iarch/generic -Iobj/src/internal -Isrc/include -Isrc/internal -Iobj/include -Iinclude"
  MUSLCF="-std=c99 -nostdinc -D_XOPEN_SOURCE=700"
  # THE FILE SET IS PER-ARCHITECTURE, AND `find` IS NOT IT.
  #
  # `find src crt -name '*.c'` walks into src/math/i386, src/fenv/powerpc64,
  # src/linux/x32 and every other architecture's directory. The reference run
  # compiled all of them and reported 57 failures -- "unknown constraint 't'",
  # "invalid clobber register 'st'", "unrecognized opcode bsr" -- which are
  # x86 and ppc inline asm being fed to an aarch64 compiler. None of them were
  # about the compiler under test.
  #
  # WORSE THAN NOISE. musl's rule is that an arch file REPLACES the generic
  # file of the same name, and `find` includes both. Any other-arch file that
  # happened to compile would land in the archive beside the generic one, and
  # which of the two a link picks up is whichever comes first. That is a wrong
  # libc that builds cleanly.
  #
  # musl's Makefile:
  #     BASE_SRCS     = src/*/*.c  ldso/*.c          -- ONE level under src/
  #     ARCH_SRCS     = src/*/$(ARCH)/*.[csS]
  #     REPLACED_OBJS = the generic objects those arch files replace
  #     ALL_OBJS      = BASE - REPLACED + ARCH
  #
  # The 9 aarch64 .s files sources/musl.toml declares as dropped were deleted
  # above, so the generic C is what stands in for them -- which is exactly what
  # that declaration says happens, and it falls out of this rule for free
  # rather than needing a second list.
  # SKIPPING A GENERIC FILE ONLY HELPS IF ITS REPLACEMENT IS ACTUALLY BUILT.
  #
  # The last run skipped src/string/memset.c because src/string/riscv64/memset.S
  # exists -- and then never compiled memset.S, because the arch glob was *.c
  # only. memset and memcpy ended up in NEITHER, and rung 3 failed with
  # "undefined symbol 'memset'" against a 3.2 MB libc.a. The earlier `find`
  # version masked this by compiling everything, so tightening the file set is
  # what exposed it.
  #
  # THE ARCH FILES ARE ASSEMBLY. .S is preprocessed assembly and .s is plain;
  # tcc assembles both with the integrated assembler the arm64 patch series
  # supplies, which is one of the things this rung is here to exercise. The 9
  # .s files sources/musl.toml declares dropped were deleted above, so they
  # match nothing here and their generic C is used instead -- which is what the
  # declaration says happens.
  #
  # TWO DIRECTORIES ARE NOT ONE LEVEL UNDER src/ AND ARE EASY TO MISS:
  #   src/malloc/mallocng/   musl's allocator since 1.2 -- __libc_free lives
  #                          here, and it was the third undefined symbol
  #   compat/time32/         the 32-bit time shims, referenced by dispatch
  : > /work/srclist
  for f in src/*/*.c src/malloc/mallocng/*.c ldso/*.c compat/time32/*.c; do
    [ -f "$f" ] || continue
    d=$(dirname "$f"); b=$(basename "$f" .c)
    # Replaced by an aarch64 version? Skip the generic ONLY if the replacement
    # is one this loop will actually compile.
    if [ -f "$d/riscv64/$b.c" ] || [ -f "$d/riscv64/$b.s" ] || [ -f "$d/riscv64/$b.S" ]; then
      continue
    fi
    echo "$f" >> /work/srclist
  done
  for f in src/*/riscv64/*.c src/*/riscv64/*.s src/*/riscv64/*.S \
           crt/*.c crt/riscv64/*.c crt/riscv64/*.s crt/riscv64/*.S; do
    [ -f "$f" ] && echo "$f" >> /work/srclist
  done
  say "    file set: $(wc -l < /work/srclist) sources (aarch64, arch files replacing generic)"

  nc=0; nf=0
  : > /work/musl-fail.txt
  : > /work/musl-why.txt
  for f in $(sort /work/srclist); do
    # .c, .s and .S all land on the same object name, which is how musl's own
    # REPLACED_OBJS rule collapses an arch file onto the generic one it stands
    # in for.
    o="obj/${f%.*}.o"; mkdir -p "$(dirname "$o")"
    # musl's Makefile adds -DCRT for the crt objects; without it crt1.c
    # compiles to something that is not a crt file.
    case "$f" in crt/*) X=-DCRT ;; *) X= ;; esac
    # PER-FILE STDERR AND EXIT STATUS, NOT ONE SHARED LOG.
    #
    # This appended every message to one file and reported the distinct
    # `error:` lines from it. That is right when a compile FAILS and says why,
    # and silent when it CRASHES -- a signal writes nothing. Nine musl files
    # would not compile and the error summary printed nothing at all, so the
    # log said "9 failed" and gave no way to tell a missing macro from a
    # segfault. Recording the status per file separates them.
    if $CC $MUSLCF $INC $X -c -o "$o" "$f" 2>/work/one.err; then
      nc=$((nc + 1))
      cat /work/one.err >> /work/musl-cc.err
    else
      _rc=$?
      nf=$((nf + 1)); echo "$f" >> /work/musl-fail.txt
      cat /work/one.err >> /work/musl-cc.err
      _msg=$(grep -a "error:" /work/one.err 2>/dev/null | head -1 | sed 's/^.*error:/error:/')
      if [ -z "$_msg" ]; then
        if [ "$_rc" -gt 128 ]; then
          _msg="SIGNAL $((_rc - 128)) -- no diagnostic"
        else
          _msg="rc=$_rc, no diagnostic"
        fi
      fi
      printf '%s\t%s\n' "$f" "$_msg" >> /work/musl-why.txt
    fi
  done
  say "    compiled $nc objects, $nf failed"
  if [ "$nf" -gt 0 ]; then
    # src/thread/__unmapself.c IS EXPECTED TO FAIL and is not a compiler
    # defect: sources/musl.toml declares the aarch64 __unmapself.s dropped, so
    # the generic C stands in, and that generic C is inline asm tcc does not
    # parse. It costs the thread-exit unmapping path, which nothing below gcc
    # exercises. Named here so it stops looking like a finding every run.
    say "    --- files that would not compile, and why (first 12 of $nf) ---"
    head -12 /work/musl-why.txt 2>/dev/null \
      | awk -F'\t' '{ printf "      %-34s %s\n", $1, substr($2,1,58) }'
    # DISTINCT MESSAGES, WITH COUNTS. The first twelve lines of the error log
    # are usually twelve copies of one fault, which reads as twelve problems
    # and sends the next round in twelve directions. 664 failures in the
    # reference run were ONE missing macro.
    say "    --- distinct errors, by count ---"
    grep -a "error:" /work/musl-cc.err 2>/dev/null \
      | sed 's/^.*error:/error:/' | sort | uniq -c | sort -rn | head -10 | sed 's/^/      /'

    # AND PRINT THE SHORT ONES, BECAUSE A FILENAME IS NOT EVIDENCE.
    #
    # Run 84995533783 compiled 1348 of 1349 objects and rung 4 then died on
    # `undefined symbol 'sigsetjmp'` -- traced back to the single failure
    # here, src/signal/x86_64/sigsetjmp.s, "error: end of line expected".
    # Deciding what to do about that needs the file, and guessing at its
    # contents from the filename is how three attempts at an unrelated patch
    # went wrong earlier in this project. Assembly stubs are a few dozen
    # lines; printing them costs nothing and means the next round starts
    # with the source in hand rather than a name.
    if [ "${nf:-0}" -le 4 ]; then
      while IFS="$(printf '\t')" read -r _bad _rest; do
        [ -f "$_bad" ] || continue
        _n=$(wc -l < "$_bad")
        if [ "$_n" -le 60 ]; then
          # THE RAW ERROR FIRST, WITH ITS LINE NUMBER. The summary above
          # strips everything before "error:", which is right for counting
          # distinct faults and wrong for fixing one: run 84997925140 printed
          # sigsetjmp.s in full and "error: end of line expected", and the
          # 24-line file has three constructs that could produce it --
          # `call setjmp@PLT`, `.hidden __sigsetjmp_tail`, and `popq 64(%rdi)`.
          # Choosing between them by reading is guessing; tcc already said
          # which line, and the summary threw it away.
          say "    --- what tcc said about $_bad ---"
          grep -a -- "$_bad" /work/musl-cc.err 2>/dev/null | head -4 | sed 's/^/      /'
          say "    --- $_bad ($_n lines, numbered) ---"
          awk '{ printf "      %3d  %s\n", NR, $0 }' "$_bad"
        else
          say "    --- $_bad is $_n lines, not printed ---"
        fi
      done < /work/musl-why.txt
    fi
  fi

  # NO ar IN THIS BOX -- binutils is rung 4. tcc has its own archiver, which is
  # the whole reason `tcc -ar` exists. It is untested on a seed-built tcc, so a
  # failure here is a finding rather than a surprise.
  find obj/src -name '*.o' > /work/objlist.txt
  if "$CC_BIN" -ar rcs "$SYS/lib/libc.a" $(cat /work/objlist.txt) 2>/work/ar.err; then
    say "    libc.a from $(wc -l < /work/objlist.txt) objects"
    produced "$SYS/lib/libc.a"
  else
    say "    ar FAILED"
    grep -av '^[A-Z][0-9]*$' /work/ar.err | head -6 | sed 's/^/      /'
  fi
  # ASK THE COMPILER WHERE IT LOOKS. DO NOT ASSUME.
  #
  # The last run built crt1.o, crti.o and crtn.o correctly, put them in
  # /usr/lib, and still got "file 'crt1.o' not found". tcc's crt search path is
  # compiled in at configure time and is NOT reachable from -L; on a Debian or
  # Ubuntu host tcc's configure picks up the multiarch layout and sets it to
  # something like /usr/lib/riscv64-linux-gnu, not /usr/lib.
  #
  # Guessing that path is how this rung failed twice. The compiler will say:
  # -print-search-dirs is exactly the question, and it is answered by both arms
  # -- MICRO-C.md records it working on mc-tcc. So the crt files are installed
  # into every directory the compiler names, plus /usr/lib as the conventional
  # one. The box is ours and contains only what these rungs built, so writing
  # to several of its directories costs nothing and removes an assumption.
  say "    --- where this compiler looks ---"
  $CC -print-search-dirs > /work/searchdirs.txt 2>&1 || true
  sed 's/^/      /' /work/searchdirs.txt | head -20

  crtdirs="$SYS/lib"
  for d in $(tr -s ' :=' '\n' < /work/searchdirs.txt | grep '^/' | sort -u); do
    case "$d" in */lib*|*/tcc*) crtdirs="$crtdirs $d" ;; esac
  done
  say "    installing crt into: $crtdirs"

  for c in crt1 crti crtn Scrt1 rcrt1; do
    for src in "obj/crt/riscv64/$c.o" "obj/crt/$c.o"; do
      [ -f "$src" ] || continue
      for d in $crtdirs; do
        mkdir -p "$d" 2>/dev/null
        cp "$src" "$d/" 2>/dev/null || true
      done
    done
  done
  # libc.a goes beside them, so -lc resolves wherever the crt files were found.
  for d in $crtdirs; do
    [ -f "$SYS/lib/libc.a" ] && cp "$SYS/lib/libc.a" "$d/" 2>/dev/null || true
  done
  cp -a include/. "$SYS/include/" 2>/dev/null || true
  cp -a arch/riscv64/bits "$SYS/include/" 2>/dev/null || true
  cp -a arch/generic/bits "$SYS/include/" 2>/dev/null || true
  mkdir -p "$SYS/include/bits"
  cp -a obj/include/bits/. "$SYS/include/bits/" 2>/dev/null || true

  # SIZE IS NOT COMPLETENESS. The last run archived 1265 objects into 3.2 MB
  # and was missing memset. These four are what any hosted program needs
  # immediately, so their absence is worth naming here rather than discovering
  # as a link error one rung later.
  say "    --- symbols every hosted program needs ---"
  for sym in memset memcpy malloc free printf __libc_start_main; do
    if "$CC_BIN" -ar t "$SYS/lib/libc.a" >/dev/null 2>&1; then :; fi
    if grep -aq "$sym" "$SYS/lib/libc.a" 2>/dev/null; then
      printf '      %-20s present\n' "$sym"
    else
      printf '      %-20s MISSING\n' "$sym"
    fi
  done
  # THE EMPTY STUB ARCHIVES musl's OWN install CREATES.
  #
  # gcc links a generator with -lm and got
  #
  #     tcc: error: library 'm' not found
  #
  # musl has no separate libm: the math lives in libc.a. But every autoconf
  # project on earth passes -lm, so musl's Makefile makes eight EMPTY archives
  # for exactly this --
  #
  #     EMPTY_LIB_NAMES = crypt dl m pthread resolv rt util xnet
  #     $(EMPTY_LIBS): rm -f $@; $(AR) rc $@
  #
  # -- and a link against an empty archive succeeds and contributes nothing,
  # which is the point.
  #
  # Rung 2 hand-drives musl's COMPILE, so it never ran musl's install and never
  # made these. An empty ar archive is literally the eight bytes "!<arch>\n",
  # so they can be written directly rather than through tcc -ar, which has no
  # reason to be asked for an archive with no members.
  for _l in crypt dl m pthread resolv rt util xnet; do
    printf '!<arch>\n' > "$SYS/lib/lib$_l.a"
  done
  say "    empty stubs: $(ls "$SYS/lib"/lib*.a 2>/dev/null | wc -l) archives in $SYS/lib (libc.a + 8 stubs)"

  # A MINIMAL sys/cdefs.h, DECLARED, BECAUSE musl DELIBERATELY OMITS IT.
  #
  # Four separate failures so far have been one cause: old GNU source treats
  # "not glibc" as "not much of a libc", and reaches for glibc-only spelling
  # helpers that live in <sys/cdefs.h>:
  #
  #     make.h:40      alloca            (its own declaration, wrong prototype)
  #     make.h         strncasecmp       (its own declaration, int vs size_t)
  #     glob.c:289     getlogin          (its own declaration)
  #     glob.c:294     __P               (glibc macro, used unconditionally)
  #     glob.c:303     __ptr_t           (same family)
  #
  # musl omits sys/cdefs.h on purpose -- none of it is standard, and __P is a
  # K&R compatibility macro that does nothing on an ANSI compiler. But omitting
  # the header does not stop 1990s source from using its contents, and patching
  # each symbol in each file has now cost four rounds in one file.
  #
  # So supply the header once, with only the DECORATIVE macros: the ones that
  # expand to nothing, to their argument, or to a token paste. Nothing here
  # claims a libc feature exists.
  #
  # __ptr_t IS DELIBERATELY NOT HERE. It is a TYPE, not a decoration, and
  # sources that want it write `typedef void *__ptr_t;` guarded on their own
  # terms -- defining it as a macro would turn that line into
  # `typedef void *void *;`. Type-level collisions stay per-file.
  mkdir -p "$SYS/include/sys"
  if [ ! -f "$SYS/include/sys/cdefs.h" ]; then
    cat > "$SYS/include/sys/cdefs.h" <<'CDEFS'
/* Minimal <sys/cdefs.h> for a musl sysroot.
 *
 * musl omits this header deliberately: nothing in it is standard, and the
 * macros are K&R-era spelling helpers that expand to nothing useful on an
 * ANSI compiler. Old GNU source uses them anyway. Only decorative macros are
 * defined here: __ptr_t is a MACRO in glibc's version too, so it introduces no
 * type name of its own, and nothing here asserts a libc feature.
 */
#ifndef _SYS_CDEFS_H
#define _SYS_CDEFS_H 1

#ifdef __cplusplus
# define __BEGIN_DECLS extern "C" {
# define __END_DECLS   }
#else
# define __BEGIN_DECLS
# define __END_DECLS
#endif

#define __P(args)     args
#define __PMT(args)   args
#define __CONCAT(a,b) a ## b
#define __STRING(x)   #x

#ifndef __THROW
# define __THROW
#endif
#ifndef __THROWNL
# define __THROWNL
#endif
#ifndef __nonnull
# define __nonnull(params)
#endif
#ifndef __attribute_pure__
# define __attribute_pure__
#endif
#ifndef __attribute_const__
# define __attribute_const__
#endif
#ifndef __attribute_malloc__
# define __attribute_malloc__
#endif
#ifndef __wur
# define __wur
#endif

/* __ptr_t IS A MACRO IN glibc's OWN <sys/cdefs.h>, and it is safe here now.
 *
 * It was deliberately left out while make's BUNDLED glob was being compiled:
 * glob/glob.h contains `typedef void *__ptr_t;` under its own not-glibc guard,
 * and a macro would have turned that into `typedef void *void *;`.
 *
 * make_cv_sys_gnu_glob=yes stopped that directory being built at all, so
 * nothing typedefs it any more -- and make's own dir.c needs it:
 *
 *     dir.c:1181: error: ';' expected (got 'open_dirstream')
 *
 * which is `static __ptr_t open_dirstream (const char *);` failing to parse
 * because the return type is an unknown identifier. On glibc it arrives
 * through <glob.h>; musl's has no reason to carry it.
 *
 * A macro, not a typedef, exactly as glibc does it -- so any header that still
 * writes `typedef ... __ptr_t` will break loudly rather than silently disagree.
 */
#define __ptr_t    void *
#define __const    const
#define __signed   signed
#define __volatile volatile

#endif /* _SYS_CDEFS_H */
CDEFS
    say "    sys/cdefs.h: written ($(wc -l < "$SYS/include/sys/cdefs.h") lines) -- declared substitution"
  fi

  say "    headers: $(find "$SYS/include" -name '*.h' 2>/dev/null | wc -l) files"
  say "    crt:     $(ls "$SYS/lib"/crt*.o 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
  # SAY WHICH HALF IS MISSING, HERE, RATHER THAN LETTING THE WRAPPER SAY IT
  # FIFTEEN LINES LATER. The first seed-built run of this rung produced a
  # 3.2 MB libc.a from 1273 objects and no crt1.o, and the only visible
  # consequence was `tcc: error: file 'crt1.o' not found` under a heading about
  # the compiler wrapper -- which reads as a path problem and is a compile
  # failure in crt/crt1.c.
  if [ ! -s "$SYS/lib/libc.a" ]; then
    say "    RUNG 2 STOPS HERE: no libc.a was produced"
  elif [ ! -f "$SYS/lib/crt1.o" ]; then
    say "    RUNG 2 STOPS HERE: libc.a is present and crt1.o is NOT."
    say "      crt1.o comes from crt/crt1.c. Nothing can be LINKED without it,"
    say "      so every rung above this one fails at the link and not at the"
    say "      compile. Look for crt/crt1.c in the failure list above."
  fi
  if [ -s "$SYS/lib/libc.a" ] && [ -f "$SYS/lib/crt1.o" ]; then R2=ok; else R2=FAIL; fi
  fi
  cd /work
fi

HOSTED="-I$SYS/include -L$SYS/lib"

# EVERY AUTOCONF RUNG LINKS STATICALLY, AND THAT IS NOT AN OPTIMISATION.
#
# make's configure got this far:
#
#     checking whether the C compiler works... yes
#     checking for C compiler default output file name... a.out
#     checking whether we are cross compiling... error: cannot run C
#         compiled programs.  If you meant to cross compile, use `--host'.
#
# It LINKS and it cannot EXECUTE. rung 2 builds musl as libc.a only -- there is
# no libc.so and no dynamic loader anywhere in this box -- so a dynamically
# linked binary has a PT_INTERP pointing at /lib/ld-musl-aarch64.so.1, which
# does not exist, and the kernel refuses it before main runs.
#
# rung 3 passes because it passes -static explicitly. autoconf does not: it
# compiles conftest with plain $CC and then runs it, and that is the check that
# fails. So -static belongs in CC itself, where every conftest inherits it.
#
# This is also just correct for a bootstrap. Static is what the box can
# actually run, and it is what the binaries built here -- make, then binutils,
# then gcc -- need to be in order to keep working as the sysroot changes
# underneath them. rung 3's own diagnostic already prints "interp: PRESENT --
# this binary is DYNAMIC and the box has no loader" for exactly this shape.
CCAUTO="$CC $HOSTED -static"

# -static IN CC IS NOT ENOUGH; IT HAS TO BE IN LDFLAGS TOO.
#
# libtool does not pass $CC's flags through to the link. It parses the compile
# command, keeps what it recognises, and builds its own link line -- so
# `-static` set in CC reaches every compile and none of the links. binutils'
# `as` came out DYNAMIC, wanting /lib/ld-musl-aarch64.so.1, which this box does
# not have because rung 2 builds libc.a and no shared library. It then failed
# to exec with "Permission denied", which is what a shell reports for a binary
# whose interpreter is missing:
#
#     /work/bld/gcc/as: exec: .../riscv64-unknown-linux-gnu/bin/as:
#                             Permission denied
#
# and rung 3's own dynamic probe had already said "does NOT run (expected:
# libc.a only, no loader in the box)" two rungs earlier.
#
# LDFLAGS is the variable libtool DOES honour, so -static goes there as well.
# Belt and braces on purpose: some of these builds link through $CC directly
# and never involve libtool at all.
LDF="-static"

# A WRAPPER, BECAUSE NEITHER CC NOR LDFLAGS SURVIVED.
#
#   -static in CC       libtool parses the compile command, keeps what it
#                       recognises, and builds its OWN link line. Stripped.
#   -static in LDFLAGS  passed to configure, and binutils STILL produced a
#                       dynamic as:
#
#                           interp: PRESENT -- ld-linux-aarch64.so.1
#                           /work/prefix/bin/as  rc=126  Permission denied
#
# So stop trying to persuade the build system and remove the choice. cc-static
# is a two-line script that appends -static to whatever it is handed, and it is
# what CC points at. libtool can rewrite the argument list however it likes;
# the flag is not in the argument list, it is in the compiler.
#
# This is the same move as tcc-ar: when a build system insists on calling a
# tool by name with flags of its own choosing, give it a tool that already does
# the right thing.
mkdir -p "$PFX/bin"
# -include sys/cdefs.h, BECAUSE PUTTING IT IN THE SYSROOT WAS NOT ENOUGH.
#
# Rung 2 writes a minimal <sys/cdefs.h> into the sysroot and make's dir.c still
# failed with the same line twice:
#
#     dir.c:1181: error: ';' expected (got 'open_dirstream')
#
# which is `static __ptr_t open_dirstream (const char *);`. The shim defines
# __ptr_t. The problem is that NOTHING INCLUDES THE SHIM: musl's headers do not
# reference <sys/cdefs.h>, because on musl it does not exist. On glibc these
# macros reach a source file whether or not it asks -- glibc's own headers pull
# cdefs.h in -- so old GNU code uses them without including anything, and that
# habit is invisible until the libc changes.
#
# Forcing it into every translation unit is the same class-level fix as writing
# the header in the first place: the alternative is patching __ptr_t into dir.c,
# then into the next file, exactly as glob.c went five rounds. Everything in the
# shim is an #ifndef-guarded macro with no type names, so a unit that does not
# need it is unaffected.
#
# ONLY THE AUTOCONF RUNGS GET THIS. musl at rung 2 is compiled with $CC
# directly, not through this wrapper, so the libc is still built against its own
# headers and nothing else.
#
# THE FLAG ORDER IS LOAD-BEARING. -I/usr/include used to come BEFORE "$@", so
# the sysroot was searched ahead of the project's own -I. and -Ilib. make 4.4
# bundles gnulib, gnulib ships its own <glob.h>, and musl's won:
#
#     glob.c:379: error: '__GLOB_FLAGS' undeclared
#
# __GLOB_FLAGS is defined in gnulib's glob.h and in glibc's; it is not in
# musl's, and gnulib's glob.c expects to be reading its own. Include paths are
# searched in command-line order, so the project's directories have to precede
# the sysroot. -L and -static are order-insensitive and stay at the end;
# -include is processed before the main file regardless of position.
#
# This was shadowing every project header, not just glob.h -- anything a build
# ships its own copy of was silently losing to the sysroot version.
# mallocng NEEDED ITS OBJECTS NAMED HERE, AND NO LONGER DOES.
#
# musl selects its allocator with `#define malloc __libc_malloc_impl`
# (mallocng/glue.h:23), so mallocng defines that symbol strongly while
# lite_malloc.c carries a weak_alias for it. mc-tcc emitted the weak alias as
# GLOBAL, so malloc and free could come from different allocators and rung 3
# segfaulted. Naming the six objects worked around it.
#
# AND A CORRECTION, BECAUSE THE FIRST EXPLANATION HERE WAS WRONG. It said the
# fix made mallocng get used. It does not. Measured afterwards, with markers
# compiled into both allocators:
#
#     static malloc/free   ->  A LITE B C
#
# `malloc` still resolves to __simple_malloc in lite_malloc.c -- a bump
# allocator -- and mallocng's malloc.o is never extracted from the archive at
# all. Extraction is driven by undefined symbols, `malloc` is defined (weakly)
# in lite_malloc.o, and that satisfies it before mallocng is ever considered.
#
# What the weak/strong fix actually bought is CONSISTENCY: malloc and free now
# come from the same place. That is why rung 3 and the GNU make link started
# passing, and the measurements below are unaffected. But mallocng has never
# run in this project, and the first thing to reach it -- tcc's -run, which
# resolves symbols differently -- crashes immediately. Recorded here so the
# next person does not re-derive it from a wrong premise.
#
# THE CAUSE IS FIXED, in micro-c, by EXPERIMENT-zzzv: a compound assignment to
# a bitfield is a read-modify-write, and `sa->weak |= sa1->weak` had been
# landing on bit zero. The workaround is gone. Measured on pristine musl 1.2.5
# at its pinned sha256, from a plain libc.a with nothing named:
#
#     __acquire_ptc     lock_ptc.o GLOBAL, pthread_create.o WEAK
#     __release_ptc     lock_ptc.o GLOBAL, pthread_create.o WEAK
#     __malloc_atfork   mallocng GLOBAL,   fork.o WEAK
#     malloc/free, calloc/realloc, fork, pthread_create+join, printf %f
#                       all link and run
NGOBJ=""

cat > "$PFX/bin/cc-static" <<CCWRAP
#!/bin/sh
exec CCBIN -B TCCDIR -include sys/cdefs.h "\$@" -I/usr/include -L/usr/lib -static
CCWRAP
sed -i -e "s|CCBIN|$CC_BIN|g" -e "s|-B TCCDIR|-B$TCCDIR|g" "$PFX/bin/cc-static"
chmod 0755 "$PFX/bin/cc-static"
CCAUTO="$PFX/bin/cc-static"

say ""
say "  === the compiler every autoconf rung will use ==="
sed 's/^/    /' "$PFX/bin/cc-static"
# PROVE THE WRAPPER PRODUCES A STATIC BINARY before four rungs depend on it.
( cd /tmp && rm -f w.c w.bin
  # The probe uses __ptr_t WITHOUT including anything, which is exactly what
  # make's dir.c does and exactly what failed twice. If the force-include is
  # not working this says so here, not four rungs later.
  # Two things the probe has to prove, both of which have already been wrong:
  #   __ptr_t with no include   -- the force-included shim is reaching the unit
  #   a local stdio.h wins      -- the sysroot is NOT shadowing project headers
  mkdir -p ownhdr
  printf '#define VERON_OWN_HEADER 1\n' > ownhdr/probe.h
  printf '#include <probe.h>\nstatic __ptr_t p(void){return 0;}\n#include <stdio.h>\nint main(void){printf("wrapper ok %%d %%d\\n", p()?1:0, VERON_OWN_HEADER);return 0;}\n' > w.c
  if "$CCAUTO" -Iownhdr -o w.bin w.c 2>/tmp/w.err && ./w.bin >/tmp/w.out 2>&1; then
    printf '    compiles and runs: %s\n' "$(cat /tmp/w.out)"
    if grep -aq 'ld-musl\|ld-linux' w.bin; then
      say "    STILL DYNAMIC -- the wrapper is not taking"
    else
      say "    statically linked: yes"
    fi
  else
    say "    WRAPPER FAILED:"
    head -3 /tmp/w.err | sed 's/^/      /'
  fi
  rm -rf w.c w.bin ownhdr )

# THE LFS SHAPE: DECLARE A CROSS BUILD SO autoconf STOPS RUNNING ITS TESTS.
#
# make's configure died here:
#
#     checking whether we are cross compiling... configure: error: cannot run
#     C compiled programs.  If you meant to cross compile, use `--host'.
#
# That message is the instruction. LFS chapter 5 builds its toolchain with a
# DELIBERATELY DIFFERENT TRIPLET -- x86_64-lfs-linux-gnu rather than the host's
# x86_64-pc-linux-gnu -- and chapter 6 passes --host with it. The architecture
# is identical; the point is to declare "you cannot run what you build here",
# which makes autoconf skip every run test and take its answers from the
# cross-compilation defaults instead.
#
# --host MUST DIFFER FROM --build AS A STRING. If they match, autoconf decides
# the build is native and runs the tests anyway, which is the failure above.
# riscv64-toolchain-linux-musl differs from riscv64-unknown-linux-gnu, and it is
# also honest about the libc, which several configure scripts key on.
#
# BOTH ANSWERS ARE TRIED, in this order, and the log says which worked:
#   1. native + -static     the box IS the target, so a static binary really
#                           does run here; letting configure measure beats
#                           letting it guess
#   2. LFS cross triplets   for anything -static does not save
# BUILDTRIP IS THE BOX, NOT THE PRODUCT, AND STAYS `unknown` DELIBERATELY.
# It is what phase A tells configure the BUILD machine is, and phase A's box
# is a scratch environment with no identity worth asserting. The system's name
# is set where the system is built -- rung B4 in rungs-sysroot.sh, which
# configures gcc --build/--host/--target=riscv64-veron-linux-gnu. The paths at
# $PFX/riscv64-unknown-linux-gnu/ below belong to phase A's own gcc 4.7 and
# are thrown away with the box.
BUILDTRIP=riscv64-unknown-linux-gnu
HOSTTRIP=riscv64-toolchain-linux-musl

# Run configure natively; on the specific "cannot run" failure, retry the LFS
# way. $1 is a label, the rest are the package's own configure arguments.
cfg_try() {
    _lbl=$1; shift
    say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: ./configure $* CC=\"$CCAUTO\""
    say "    (cwd: $(pwd))"
    ./configure "$@" CC="$CCAUTO" LDFLAGS="$LDF" > cfg.log 2>&1
    _cfgrc=$?
    say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_cfgrc)"
    if [ "$_cfgrc" = 0 ]; then
        say "    $_lbl: configured NATIVE (-static was enough)"
        return 0
    fi
    # NO ld IN THE BOX, AND THAT IS AN ORDERING PROBLEM, NOT A FLAG.
    #
    #     checking for non-GNU ld... no
    #     configure: error: no acceptable ld found in $PATH
    #
    # binutils is rung 4 and make is rung 3.5, so there is no ld yet. tcc does
    # not need one -- it has an internal linker, which is how rungs 0-3 linked
    # anything at all -- but autoconf's AC_LIB_PROG_LD (pulled in by gettext
    # even under --disable-nls) searches for one independently of whether the
    # compiler wants it.
    #
    # AC_LIB_PROG_LD TAKES $LD IF IT IS SET and skips the search. Pointing LD
    # at the compiler is honest here: tcc IS the linker in this box, and the
    # build never invokes $LD directly -- it links through $CC, which links
    # internally. This is the same shape as tcc -ar standing in for binutils'
    # ar at rung 2.
    #
    # If that is not enough, live-bootstrap's answer is to not run make's
    # configure at all: steps/make-3.82/pass1.kaem compiles make directly from
    # a flat command list, precisely because configure asks for things that do
    # not exist yet. That is the fallback if LD= does not carry it.
    if grep -q "no acceptable ld found" cfg.log 2>/dev/null; then
        say "    $_lbl: configure wants an ld and rung 4 has not built one yet"
        say "    retrying with LD pointed at the compiler (tcc links internally)"
        say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: ./configure $* CC=\"$CCAUTO\" LD=\"$CC_BIN\""
        ./configure "$@" CC="$CCAUTO" LDFLAGS="$LDF" LD="$CC_BIN" > cfg.log 2>&1
        _cfgrc=$?
        say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_cfgrc)"
        if [ "$_cfgrc" = 0 ]; then
            say "    $_lbl: configured with LD=$CC_BIN"
            return 0
        fi
        say "    still failing after LD= -- tail:"
        tail -12 cfg.log 2>/dev/null | sed 's/^/      /'
    fi
    if grep -q "cannot run C compiled programs" cfg.log 2>/dev/null; then
        say "    $_lbl: native configure cannot run its tests -- retrying the LFS way"
        say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: ./configure --build=$BUILDTRIP --host=$HOSTTRIP $* CC=\"$CCAUTO\""
        ./configure --build="$BUILDTRIP" --host="$HOSTTRIP" "$@" \
            CC="$CCAUTO" LDFLAGS="$LDF" > cfg.log 2>&1
        _cfgrc=$?
        say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_cfgrc)"
        if [ "$_cfgrc" = 0 ]; then
            say "    $_lbl: configured CROSS (--build/--host, LFS style)"
            return 0
        fi
    fi
    say "    $_lbl: configure FAILED rc=$_cfgrc"
    say "    --- cfg.log tail ---"
    tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
    say "    --- config.log: the failing test ---"
    grep -nE "error|cannot|failed|No such" config.log 2>/dev/null | head -12 | sed 's/^/      /'
    say "    --- config.log tail ---"
    tail -25 config.log 2>/dev/null | sed 's/^/      /'
    return 1
}

# ---------------------------------------------------------------------------
head1 "RUNG 3 -- a HOSTED program: #include <stdio.h>, real crt, real libc"
# THE PIVOT. Everything stage 3 has ever measured is -nostdlib -static
# single-file freestanding. This is the first time the compiler has to resolve
# a real header, pull crt1.o and link a libc -- which is what stage 4's rung 1
# asks of $TCC on every one of its hundreds of autoconf conftest cycles.
if [ "$R2" = ok ]; then
  cd /work
  cat > r3.c <<'EOF'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
    char *p = malloc(32);
    strcpy(p, "hosted");
    printf("%s ok argc=%d\n", p, argc);
    free(p);
    return 0;
}
EOF
  # COMPILE AND RUN ARE SEPARATE QUESTIONS AND WERE BEING ASKED AS ONE.
  #
  # The last run printed "plain: FAILED" with no error beneath it, because the
  # test was `$CC ... && ./r3.bin` and only the COMPILER's stderr was captured.
  # An empty error list there does not mean no error -- it means the compile
  # SUCCEEDED and the binary did not run, which is a completely different
  # finding and the more interesting one. Each step now reports its own rc.
  #
  #   plain     what autoconf will do -- `$CC prog.c -o prog`, nothing else
  #   explicit  crt files named on the command line, -nostdlib, libc by path
  #
  # If plain fails and explicit works, the libc is fine and the compiler cannot
  # FIND it -- still fatal above, since configure will not pass paths for us.
  try_r3() {
    _lbl="$1"; shift
    rm -f r3.bin r3.out r3.err
    "$@" 2>r3.err; _crc=$?
    if [ "$_crc" != 0 ] || [ ! -s r3.bin ]; then
      printf '    %-9s COMPILE rc=%s\n' "$_lbl" "$_crc"
      grep -av '^[A-Z][0-9]*$' r3.err | head -8 | sed 's/^/      /'
      return 1
    fi
    chmod 0755 r3.bin
    ./r3.bin >r3.out 2>&1; _rrc=$?
    if [ "$_rrc" = 0 ]; then
      printf '    %-9s compiled AND ran: %s\n' "$_lbl" "$(cat r3.out)"
      return 0
    fi
    # A BINARY THAT LINKS AND WILL NOT RUN. Report the signal, the first bytes
    # of the ELF header and whether an interpreter was baked in -- a tcc that
    # ignored -static leaves a PT_INTERP pointing at a dynamic loader this box
    # does not have, and that looks identical to a crash from the outside.
    if [ "$_rrc" -gt 128 ]; then
      printf '    %-9s COMPILED, then SIGNAL %s on run\n' "$_lbl" "$((_rrc - 128))"
    else
      printf '    %-9s COMPILED, then exited %s\n' "$_lbl" "$_rrc"
    fi
    [ -s r3.out ] && sed 's/^/      /' r3.out | head -6
    printf '      ELF:    %s\n' "$(od -An -tx1 -N16 r3.bin | tr -s ' ')"
    printf '      size:   %s bytes\n' "$(wc -c < r3.bin)"
    if grep -aq 'ld-musl\|ld-linux' r3.bin; then
      printf '      interp: PRESENT -- this binary is DYNAMIC and the box has no loader\n'
      grep -ao 'ld-[a-z0-9./-]*' r3.bin | head -2 | sed 's/^/              /'
    else
      printf '      interp: none found -- statically linked\n'
    fi
    return 1
  }

  # AND THE DYNAMIC CASE, BECAUSE THAT IS WHAT autoconf ACTUALLY DOES.
  # rung 3 passed for four runs on -static while every configure below it was
  # about to fail on the same compiler, because autoconf compiles conftest with
  # a plain $CC and then RUNS it. Testing only the static case measured the one
  # shape nothing above uses.
  say "    --- no -static, which is how autoconf compiles conftest ---"
  if $CC -o r3dyn.bin r3.c 2>/dev/null && ./r3dyn.bin >/dev/null 2>&1; then
    say "    dynamic: compiled AND ran -- a loader exists in this box"
  else
    say "    dynamic: does NOT run (expected: libc.a only, no loader in the box)"
    say "             this is why every configure needs -static in CC"
  fi
  rm -f r3dyn.bin

  # $NGOBJ IS EMPTY NOW and stays on the line deliberately: when it held the
  # mallocng objects it was added to the cc-static WRAPPER only, which is what
  # configure gets as CC, while these two lines use $CC directly. Rung 3 then
  # failed exactly as before while the log reported "6 objects named on every
  # link" -- the measurement and the fix were looking at different compilers.
  if try_r3 "plain:" $CC -static -o r3.bin r3.c $NGOBJ; then
    R3=ok
  elif try_r3 "explicit:" $CC $HOSTED -nostdlib -static -o r3.bin \
         "$SYS/lib/crt1.o" "$SYS/lib/crti.o" r3.c $NGOBJ -lc "$TCCDIR/libtcc1.a" \
         "$SYS/lib/crtn.o"; then
    R3=FAIL
    say ""
    say "    THE LIBC IS GOOD AND THE COMPILER CANNOT FIND IT. A search-path"
    say "    problem, not a codegen one -- but it still stops every rung above,"
    say "    because autoconf will not pass paths."
  else
    R3=FAIL
    say "    both routes failed -- read the rc and the ELF line above"
    # WHICH PART, and the ladder is ordered so the first failure names it.
    #
    # r3.c does malloc, strcpy, printf, free and then RETURNS. When it prints
    # its line correctly and dies afterwards, main ran and the fault is in what
    # musl does on the way out: __funcs_on_exit, __libc_exit_fini and
    # __stdio_exit, none of which a freestanding test has ever reached. Each
    # rung below removes one of those, so the first one that RUNS is the
    # boundary.
    #
    #   bare        crt1 -> main -> exit, and nothing else
    #   _Exit       skips atexit handlers, _fini and the stdio flush entirely
    #   print+_Exit stdio on the way in, none of it on the way out
    #   print+ret   stdio both ways -- the flush is the only thing added
    #   heap+_Exit  malloc and free, without the exit path
    #
    # A _Exit that runs where a return does not is musl's exit path. A bare
    # return that does not run is crt1 or _fini and nothing to do with stdio.
    say "    --- narrowing: the same program with pieces removed ---"
    _r3rung() {
      _n="$1"; _body="$2"
      # THE HEADERS MATTER HERE MORE THAN USUAL. An implicit malloc returns
      # int, so the pointer is truncated to 32 bits and the crash that follows
      # is the test's own and not the compiler's.
      { echo '#include <stdio.h>'
        echo '#include <stdlib.h>'
        printf 'int main(void)\n{\n%s\n}\n' "$_body"
      } > r3n.c
      rm -f r3n.bin r3n.out
      # $NGOBJ here too: the ladder must link the same way rung 3 does, or it
      # measures a different program from the one that failed. Empty now.
      if ! $CC -static -o r3n.bin r3n.c $NGOBJ 2>/dev/null || [ ! -s r3n.bin ]; then
        printf '      %-26s did not compile\n' "$_n"
        return
      fi
      chmod 0755 r3n.bin
      ./r3n.bin >r3n.out 2>&1; _q=$?
      if [ "$_q" = 0 ]; then
        printf '      %-26s RAN ok  %s\n' "$_n" "$(head -1 r3n.out)"
      elif [ "$_q" -gt 128 ]; then
        printf '      %-26s SIGNAL %s  %s\n' "$_n" "$((_q - 128))" "$(head -1 r3n.out)"
      else
        printf '      %-26s exit %s  %s\n' "$_n" "$_q" "$(head -1 r3n.out)"
      fi
    }
    _r3rung "bare return 0"       '    return 0;'
    _r3rung "_Exit(0)"            '    _Exit(0);'
    _r3rung "print then _Exit(0)" '    printf("p\n"); _Exit(0);'
    _r3rung "print then return 0" '    printf("p\n"); return 0;'
    _r3rung "malloc/free, _Exit"  '    void *q = malloc(32); free(q); _Exit(0);'
    # AND IF THE HEAP IS THE ONE THAT FAILS, WHICH HALF. musl's allocator is
    # mallocng: a size-class table, a bitmap per group and a meta area reached
    # through it. malloc alone touches the group machinery; free walks back to
    # the meta and updates the bitmap, so the two fail for different reasons
    # and want different reductions. Printing between them also says whether
    # the pointer that came back is usable at all.
    _r3rung "malloc only, _Exit"  '    void *q = malloc(32); if (!q) return 9; _Exit(0);'
    _r3rung "malloc + write"      '    char *q = malloc(32); if (!q) return 9; q[0] = 1; q[31] = 2; _Exit(q[0] + q[31] - 3);'
    _r3rung "malloc then free"    '    void *q = malloc(32); free(q); return 0;'
    _r3rung "two mallocs, no free" '    void *a = malloc(32); void *b = malloc(64); if (!a || !b) return 9; _Exit(0);'
    _r3rung "malloc large, _Exit" '    void *q = malloc(200000); if (!q) return 9; _Exit(0);'
    _r3rung "calloc/free"         '    void *q = calloc(4, 8); free(q); _Exit(0);'
    # AND WHICH free. mallocng has two entirely separate paths: a small
    # allocation lives in a GROUP and free walks an in-band header back to the
    # meta; a large one is its own mmap and free unmaps it. free(0) is
    # required to be a no-op and touches neither. Splitting them says whether
    # the fault is in the group bookkeeping, in the unmap, or in getting into
    # free at all.
    #
    # THE SIGNAL ALREADY RULES ONE THING OUT. mallocng crashes DELIBERATELY on
    # its own consistency checks, through a_crash(), which on aarch64 is
    # `brk 0` and raises SIGTRAP -- signal 5. Every failure here is signal 11.
    # So this is not musl noticing corruption and stopping; it is a genuine
    # wild dereference, and the bookkeeping it walks through is the thing to
    # look at rather than the check that would have caught it.
    _r3rung "free(0)"             '    free(0); _Exit(0);'
    _r3rung "free a LARGE block"  '    void *q = malloc(200000); if (!q) return 9; free(q); _Exit(0);'
    _r3rung "malloc, write, free" '    char *q = malloc(32); if (!q) return 9; q[0] = 1; q[31] = 2; free(q); _Exit(0);'
    _r3rung "realloc then free"   '    void *q = malloc(32); q = realloc(q, 64); if (!q) return 9; free(q); _Exit(0);'
    rm -f r3n.c r3n.bin r3n.out
  fi

  # ---- FLOATING POINT, ASKED HERE RATHER THAN AT RUNG 11.5 ----
  #
  # This probe used to live in the perl rung, forty minutes into the ladder,
  # because that is where the symptom appeared: perl refused to build with
  # "Perl v8.0.0 required--this is only v5.42.2", which is `use 5.008` compared
  # against a $] that was FORMATTED from a double.
  #
  # Nothing in it depends on anything above rung 3. It needs a compiler, a libc
  # and the ability to link a hosted program, all of which exist right here. So
  # it asks in the first minute instead of the fortieth, and a regression shows
  # up next to the thing that caused it.
  #
  # AT THIS RUNG THERE IS ONLY tcc, which is the useful half: musl's
  # vfprintf.c was compiled by tcc, so if a tcc-built program formats wrongly
  # against it the fault is in the formatting code and no gcc is needed to say
  # so. The gcc comparison still happens later, where a gcc exists.
  # THE ANSWER: THE MANTISSA IS LOST, THE EXPONENT SURVIVES.
  #
  #     manual whole.frac  = 5.008000   CORRECT -- the double is intact
  #     snprintf %.6f      = 8.000000
  #     (double)5 printed  = 8.0
  #     two doubles        = 2.000 4.000   (expect 1.500 2.500)
  #     int then double    = 7 4.000       (expect 7 3.500)
  #
  # Every printed value is the next POWER OF TWO at or above the real one:
  # 1.5 -> 2, 2.5 -> 4, 3.5 -> 4, 5.0 -> 8, 5.008 -> 8. The exponent field
  # arrives correctly and the mantissa does not.
  #
  # AND THE MANUAL DECOMPOSITION IS RIGHT, which is what makes this precise:
  # `(long)a` and `(a - whole) * 1000000` both give the correct answer, so the
  # double in memory is sound. It is damaged between the caller and printf --
  # i.e. in variadic argument passing, where aarch64 puts doubles in v0-v7 and
  # the callee reads them back through the va_list.
  #
  # `int then double = 7 4.000` narrows it further: the INTEGER argument is
  # correct in the same call that mangles the double. So the general-purpose
  # register path works and only the SIMD one is wrong -- which is why every
  # non-printing operation in the whole chain has been fine, and why gcc built
  # gcc built gcc without noticing.
  #
  # WHO IS AT FAULT IS STILL OPEN, and the tcc comparison below is what
  # separates them: musl's vfprintf.c reading the va_list wrongly, or the
  # caller placing the value wrongly. musl was compiled by tcc at rung 2;
  # everything above was compiled by gcc. If tcc's own binary formats
  # correctly against the same musl, the formatting code is sound.
  #
  # THE ANSWER, FROM THE RUN THAT FIRST ASKED:
  #
  #     literal 5.008      = 8.000000   (expect 5.008000)
  #     strtod("5.008")    = 8.000000   (expect 5.008000)
  #     (int)(5.008*1000)  = 5008       correct
  #     5.008 > 5.007      = 1          correct
  #     5.008 == strtod    = 1          correct
  #
  # THE VALUE IS FINE. It is stored, multiplied, truncated and compared
  # correctly -- every operation that keeps the double in a register or
  # converts it to an integer gives the right answer. Only PRINTING it is
  # wrong, and it is wrong by losing the integer part.
  #
  # That is not codegen. It is the VARIADIC CALLING CONVENTION: on aarch64 a
  # double passed to a `...` function goes in v0-v7, not x0-x7, and the callee
  # walks the va_list expecting it there. Getting 8.000000 from 5.008 is what a
  # printf reading the wrong register file produces.
  #
  # WHICH EXPLAINS PERL EXACTLY. `use 5.008` compares against $], and perl
  # builds $] by FORMATTING a double. The version string is printed wrongly, so
  # the comparison is against v8.0.0 -- and every other perl operation works,
  # which is why it got as far as running miniperl.
  #
  # WHERE IT COMES FROM IS STILL OPEN. gcc 10 built these objects, but its
  # libgcc soft-float helpers descend from tcc's, and musl's printf is compiled
  # by the same chain. The probe below now separates those: if snprintf into a
  # buffer is also wrong the fault is in musl's formatting code, and if only
  # the variadic path is wrong it is the ABI.
  say "    --- can this compiler do floating point? ---"
  # fp.c SURVIVES THIS SUBSHELL. The tcc comparison below compiles the SAME
  # file, and it used to run first -- before this heredoc had written it:
  #     tcc: error: file 'fp.c' not found
  # It only looked like it worked at rung 11.5 because a leftover fp.c from an
  # earlier round was still in /tmp.
  ( cd /tmp && rm -f fp.bin
    cat > fp.c <<'FPC'
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
/* THE SAME VARIADIC PATH musl's printf TAKES: a double passed through `...`,
 * read back with va_arg through a POINTER, exactly as pop_arg does. */
static void vgrab(unsigned int *hi, unsigned int *lo, ...)
{
    va_list ap;
    union { double d; unsigned int u[2]; } v;
    va_start(ap, lo);
    v.d = va_arg(ap, double);
    va_end(ap);
    *hi = v.u[1];
    *lo = v.u[0];
}
static unsigned int vbits_hi(double d) { unsigned int a, b; vgrab(&a, &b, d); return a; }
static unsigned int vbits_lo(double d) { unsigned int a, b; vgrab(&a, &b, d); return b; }

int main(void)
{
    double a = 5.008;
    double b = strtod("5.008", 0);
    double c = 12.5;
    printf("      literal 5.008      = %.6f  (expect 5.008000)\n", a);
    printf("      strtod(\"5.008\")    = %.6f  (expect 5.008000)\n", b);
    printf("      (int)(5.008*1000)  = %d       (expect 5008)\n", (int)(a * 1000.0));
    printf("      (long)12.5         = %ld       (expect 12)\n", (long)c);
    printf("      5.008 > 5.007      = %d        (expect 1)\n", a > 5.007);
    printf("      5.008 == strtod    = %d        (expect 1)\n", a == b);

    /* IS IT THE VARIADIC ABI OR THE FORMATTING CODE?
     *
     * printf is variadic: a double goes in v0-v7 on aarch64 and the callee
     * reads the va_list expecting it there. snprintf is variadic too, so both
     * exercise the same path -- but vsnprintf called through an explicit
     * va_list, and a manual decomposition that uses no formatting at all,
     * do not.
     *
     * If the manual decomposition is right while %f is wrong, the double is
     * intact in memory and only the ARGUMENT PASSING is broken. If the
     * decomposition is also wrong, the value itself is damaged and the earlier
     * comparisons were lucky. */
    {
        char buf[64];
        long whole = (long)a;
        long frac  = (long)((a - (double)whole) * 1000000.0 + 0.5);
        snprintf(buf, sizeof buf, "%.6f", a);
        printf("      snprintf %%.6f     = %s  (expect 5.008000)\n", buf);
        printf("      manual whole.frac  = %ld.%06ld  (expect 5.008000)\n", whole, frac);
        printf("      (double)5 printed  = %.1f       (expect 5.0)\n", (double)5);
        printf("      two doubles        = %.3f %.3f  (expect 1.500 2.500)\n", 1.5, 2.5);
        printf("      int then double    = %d %.3f     (expect 7 3.500)\n", 7, 3.5);

        /* THE BITS, WHICH SAY WHETHER IT IS THE VALUE OR THE PATH.
         *
         * Printed as two 32-bit integers through the INTEGER argument path,
         * which the line above shows is working. If these are the correct IEEE
         * 754 bits for 5.008 then the double is intact everywhere except the
         * variadic float path, and the fault is the calling convention. If
         * they are wrong, the value itself was damaged earlier and every
         * comparison above was coincidence. */
        {
            union { double d; unsigned int u[2]; } bits;
            bits.d = 5.008;
            printf("      5.008 raw bits     = %08x %08x\n", bits.u[1], bits.u[0]);
            printf("      (expect              40140831 26e978d5)\n");
        }
        /* THE SIZE AND THE HEADER, SIDE BY SIDE. When the bits above are
         * exact and printf still says 0.000000, the value is right and the
         * FORMATTER is wrong -- and the reason is almost always that musl's
         * long double branches were compiled for a width this compiler does
         * not have. Two numbers say so immediately; without them it took a
         * ladder and a round to get here. */
        printf("      sizeof(long double) = %d, LDBL_MANT_DIG = %d\n",
               (int)sizeof(long double), (int)LDBL_MANT_DIG);
        printf("      (8 and 53 agree; 8 and 113 do not, and %%f will be wrong)\n");
        /* DOES THE DOUBLE ARRIVE, OR IS THE FORMATTER WRONG? Those are the
         * only two possibilities left and printf cannot tell them apart --
         * both look like 0.000000. This receives a double through the same
         * variadic path musl's printf uses and reports its BITS with integer
         * formatting, which is known to work. Bits right means the value
         * arrived and musl's fmt_fp is at fault; bits wrong means the
         * argument never got there and printf is innocent. */
        printf("      through varargs   = %08x %08x\n",
               vbits_hi(5.008), vbits_lo(5.008));
        printf("      (expect             40140831 26e978d5)\n");
    }
    return 0;
}
FPC
    if $CC $HOSTED -static -o fp.bin fp.c 2>/tmp/fp.err && ./fp.bin; then
      :
    else
      say "      the float probe would not build or run:"
      head -5 /tmp/fp.err 2>/dev/null | sed 's/^/        /'
    fi
    rm -f fp.bin )

  # WHICH printf IS THIS? ASK BEFORE INTERPRETING THE NUMBERS.
  #
  # Two candidates and they need different fixes:
  #
  #   musl's, compiled by TCC at rung 2. src/stdio/vfprintf.c is present --
  #   sources/musl.toml drops only src/complex/*.c and rung 2 reports
  #   1349/1349 compiled -- so if this is the fault it is tcc miscompiling
  #   float formatting, and it would be a stage 3 bug visible here.
  #
  #   the ABI, in which case musl's code is correct and the double never
  #   arrives where the callee looks for it.
  #
  # THE SAME PROGRAM COMPILED BY tcc DIRECTLY tells them apart from the other
  # end: if tcc's own output formats correctly against the same musl, the
  # formatting code is sound and gcc 10's variadic path is the suspect. If both
  # are wrong, the fault is underneath both -- in the libc that rung 2 built.
  # THE gcc COMPARISON HAPPENS WHERE A gcc EXISTS, NOT HERE.
  #
  # This block used to recompile the same file with $CC and call it "the tcc
  # comparison". At rung 3 that IS $CC -- there is no other compiler in the box
  # yet -- so it compiled the identical program with the identical compiler and
  # proved nothing. It also ran before the heredoc above had written fp.c:
  #     tcc: error: file 'fp.c' not found
  #
  # The useful comparison is tcc's answer HERE against gcc 10's answer at rung
  # 9, and the two numbers are already printed in the same log. Keep the file
  # so a later rung can reuse it rather than pretending to compare now.
  cp /tmp/fp.c /work/fp.c 2>/dev/null || true
  say "    (the same probe runs again at rung 9, compiled by gcc 10 --"
  say "     if these numbers differ, the fault is the calling convention;"
  say "     if they agree, it is musl's formatting as tcc compiled it)"
  rm -f /tmp/fp.c
fi


# ---------------------------------------------------------------------------
# === RUNG 3.2 -- tcctest.c, WHICH IS test1, test2 AND test3 ===
#
# tcc's own suite begins with this one file. stage3-hermetic-arm64 has only
# ever COMPILED it, and said so plainly:
#
#     tcctest.c: COMPILES -- 264818 byte object
#     test1/test2/test3 are reachable; they need -run and a libc
#
# They needed a libc, and rung 2 has just built one. This is the first place
# tcctest.c can be LINKED and RUN, and running it exercises far more of the
# compiler than the whole of tests2: variadics, promotions, bitfields, long
# long, structs by value, casts, computed goto.
#
# REPORTED, NOT A GATE. The diff against gcc contains tcc-versus-gcc
# differences that tcc's own Makefile filters and this does not, so a raw count
# would fail forever for the wrong reason. The line to watch is whether it runs
# to completion at all, and then whether the count comes down.
if [ "$R3" = ok ] && [ -f /in/tcc-src/tests/tcctest.c ]; then
  head1 "RUNG 3.2 -- tcctest.c, the file test1, test2 and test3 all begin with"
  ( cd /work && rm -f tt.bin tt.out tt.err
    set +e
    timeout 300 $CC -I/in/tcc-src -w -static -o tt.bin \
            /in/tcc-src/tests/tcctest.c > tt.err 2>&1
    _rc=$?
    set -e
    if [ "$_rc" = 0 ] && [ -s tt.bin ]; then
      echo "    links: $(wc -c < tt.bin) bytes"
      chmod +x tt.bin
      set +e
      timeout 300 ./tt.bin > tt.out 2>&1
      _rr=$?
      set -e
      if [ "$_rr" = 0 ]; then
        echo "    RUNS to completion: $(wc -l < tt.out) lines of output"
      elif [ "$_rr" -gt 128 ]; then
        echo "    ran and died: SIGNAL $((_rr - 128)) after $(wc -l < tt.out) lines"
      else
        echo "    ran, exit $_rr, $(wc -l < tt.out) lines"
      fi
      echo "    last line: $(tail -1 tt.out | cut -c1-60)"
    else
      echo "    does NOT link, rc=$_rc"
      head -4 tt.err | sed "s/^/      /"
    fi )
fi

head1 "RUNG 3.5 -- GNU make 3.82, by literal commands (live-bootstrap's recipe)"
# NO configure. THIS IS steps/make-3.82/pass1.kaem, TRANSCRIBED.
#
# make's own configure cannot run here and the reason is structural, not a
# flag: AC_LIB_PROG_LD -- pulled in by gettext even under --disable-nls --
# searches for an `ld` in PATH, and binutils is rung 4. tcc needs no ld, it
# links internally, but autoconf checks anyway.
#
# live-bootstrap hits the same wall and does not argue with it. It never runs
# make's configure at all: steps/make-3.82/pass1.kaem is a flat list of tcc
# invocations, one per source file, with every setting that configure would
# have discovered passed as a -D on the command line. `catm config.h` creates
# an EMPTY config.h -- the file exists so #include finds it, and contains
# nothing.
#
# Their file is reproduced below command for command. Their `tcc` is our $CC;
# their ${BINDIR} and ${PREFIX} are our $PFX. NOTHING ELSE IS CHANGED --
# not a flag, not an order, not a define. It carries no patches, which is
# itself worth knowing: make 3.82 needs none when built this way.
#
# THE FLAGS ARE NOT DECORATION. -Dvfork=fork on function.c and job.c because
# tcc's vfork semantics are not make's; -DFILE_TIMESTAMP_HI_RES=0 because
# there is no high-resolution stat; -DSCCS_GET, -DLOCALEDIR, -DPACKAGE point
# at names that do not need to exist. Guessing at these is what configure was
# for, and this list is the answer configure would have produced.
if [ "$R3" = ok ]; then
  cd /work/src
  if ! untar /in/make-3.82; then
    say "    make-3.82 did not extract"
    R35=FAIL
  else
    _mkd=$(onedir 'make-3.82 ./make-3.82')
    if [ -z "$_mkd" ] || ! cd "$_mkd"; then
      say "    no make-3.82 directory after extraction"; R35=FAIL
    fi
  fi
fi

if [ "$R3" = ok ] && [ "$R35" != FAIL ]; then
  say "    building $(pwd) with live-bootstrap's command list"

  # catm config.h -- an EMPTY config.h. Every HAVE_* arrives as -D below.
  : > config.h

  # THE ONE DELTA FROM live-bootstrap's LIST, AND IT IS THE libc.
  #
  #     make.h:40: error: incompatible types for redefinition of 'alloca'
  #     ... 22 of 27 files
  #
  # make.h declares `char *alloca ();` itself unless HAVE_ALLOCA_H is set. musl
  # already declares `void *alloca(size_t)` via its headers, so the two
  # collide. live-bootstrap never sees this because at their make rung the libc
  # is MES-LIBC, not musl -- which is the divergence spikes/livebootstrap/
  # ORDER.md already records: they build make before musl exists, we cannot,
  # because M2libc is inside mc-tcc rather than installed and cannot carry make.
  #
  # HAVE_ALLOCA_H makes make.h include <alloca.h> instead of declaring it, and
  # musl ships that header. One define, applied to every compile -- harmless
  # where alloca is unused, and cheaper than reasoning about which of the 27
  # pull in make.h.
  # ONE ROUND PER MISSING DEFINE IS THE WRONG LOOP. alloca cost a run;
  # strncasecmp cost the next. Both are the same shape: make.h declares a
  # function ITSELF when the matching HAVE_* is unset, musl already declares
  # it, and the two disagree -- make's strncasecmp takes `int n` where musl's
  # takes size_t.
  #
  # The under-defining also shows up as the getopt.c warnings: "implicit
  # declaration of strcmp / strncmp / strlen", because HAVE_STRING_H was not
  # set so make.h never included <string.h>.
  #
  # SO DEFINE WHAT configure WOULD HAVE FOUND. musl is a complete POSIX libc;
  # a real configure run against it would answer yes to essentially all of
  # these. live-bootstrap needs only a handful because mes-libc HAS only a
  # handful -- their short list is a description of mes-libc, not of make.
  #
  # OVER-DEFINING IS THE SAFER DIRECTION HERE. A HAVE_* set for something musl
  # lacks surfaces as an undefined symbol at link time, which is one clear
  # error naming the function. Leaving one unset surfaces as a type conflict
  # inside a header, which is what these two rounds were.
  MUSLDEFS="-DHAVE_ALLOCA_H -DSTDC_HEADERS
            -DHAVE_STRING_H -DHAVE_STRINGS_H -DHAVE_STDLIB_H -DHAVE_UNISTD_H
            -DHAVE_LIMITS_H -DHAVE_MEMORY_H -DHAVE_SYS_PARAM_H -DHAVE_SYS_WAIT_H
            -DHAVE_SYS_TIME_H -DHAVE_TIME_H -DTIME_WITH_SYS_TIME=1
            -DHAVE_LOCALE_H -DHAVE_SYS_FILE_H
            -DHAVE_STRCASECMP -DHAVE_STRNCASECMP -DHAVE_STRERROR -DHAVE_STRSIGNAL
            -DHAVE_STRDUP -DHAVE_STRNDUP -DHAVE_STRCHR -DHAVE_STRRCHR
            -DHAVE_MEMCPY -DHAVE_MEMMOVE -DHAVE_MEMSET
            -DHAVE_DUP2 -DHAVE_GETCWD -DHAVE_GETGROUPS -DHAVE_GETTIMEOFDAY
            -DHAVE_MKSTEMP -DHAVE_MKTEMP -DHAVE_REALPATH -DHAVE_SETVBUF
            -DHAVE_SETLINEBUF -DHAVE_SIGACTION -DHAVE_SIGSETMASK -DHAVE_ISATTY
            -DHAVE_TTYNAME -DHAVE_ATEXIT -DHAVE_PIPE -DHAVE_FORK -DHAVE_WAITPID
            -DHAVE_STRTOLL -DHAVE_VPRINTF -DHAVE_STDARG_H -DHAVE_ANSI_COMPILER"


  _cc_fail=0
  # $1 = the source file, rest = its flags. Named so a failure says which file.
  mk_cc() {
    _src=$1; shift
    # shellcheck disable=SC2086 -- MUSLDEFS is a word list on purpose
    if ! $CC -c $MUSLDEFS "$@" "$_src" 2>>/work/make-cc.err; then
      say "      FAILED: $_src"
      _cc_fail=$((_cc_fail + 1))
    fi
  }

  say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: 26 x \$CC -c ... (pass1.kaem)"
  say "    (cwd: $(pwd))  CC=$CC"

  mk_cc getopt.c
  mk_cc getopt1.c
  mk_cc ar.c        -I. -Iglob -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DHAVE_STDINT_H
  mk_cc arscan.c    -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DHAVE_FCNTL_H
  mk_cc commands.c  -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DFILE_TIMESTAMP_HI_RES=0
  mk_cc default.c   -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DSCCS_GET=\"/nullop\"
  mk_cc dir.c       -I. -Iglob -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DHAVE_DIRENT_H
  mk_cc expand.c    -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc file.c      -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DFILE_TIMESTAMP_HI_RES=0
  mk_cc function.c  -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -Dvfork=fork
  mk_cc implicit.c  -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc job.c       -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DHAVE_DUP2 -DHAVE_STRCHR -Dvfork=fork
  mk_cc main.c      -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DLOCALEDIR=\"/fake-locale\" -DPACKAGE=\"fake-make\" -DHAVE_MKTEMP -DHAVE_GETCWD
  mk_cc misc.c      -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DHAVE_STRERROR -DHAVE_VPRINTF -DHAVE_ANSI_COMPILER -DHAVE_STDARG_H
  mk_cc read.c      -I. -Iglob -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DINCLUDEDIR=\"$PFX/include\"
  mk_cc remake.c    -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART -DFILE_TIMESTAMP_HI_RES=0 -DHAVE_FCNTL_H -DLIBDIR=\"$PFX/lib\"
  mk_cc rule.c      -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc signame.c   -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc strcache.c  -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc variable.c  -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc version.c   -I. -DVERSION=\"3.82\"
  mk_cc vpath.c     -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc hash.c      -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc remote-stub.c -I. -DHAVE_INTTYPES_H -DHAVE_SA_RESTART
  mk_cc getloadavg.c  -DHAVE_FCNTL_H
  # THE glob FILES DO NOT GET MUSLDEFS, AND live-bootstrap SAYS WHY BY OMISSION.
  #
  # Their line for glob.c is `-Iglob -DHAVE_STRDUP -DHAVE_DIRENT_H` -- no
  # STDC_HEADERS, while fnmatch.c right above it has it. That asymmetry is
  # deliberate: glob.c guards `#include <stdlib.h>` on STDC_HEADERS, and
  # pulling musl's stdlib.h in gives
  #
  #     /usr/include/bits/alltypes.h:15: error: incompatible redefinition
  #                                            of 'wchar_t'
  #
  # because glob.c has already established a wchar_t of its own. Blanket-
  # applying MUSLDEFS re-broke a file that was compiling, which is the cost of
  # treating their per-file flags as noise rather than as answers.
  #
  # HAVE_ALLOCA_H still applies -- glob.c needed it and got it in the round
  # before this one. Everything else is theirs, verbatim.
  mk_cc_glob() { _s=$1; shift
    if ! $CC -c -DHAVE_ALLOCA_H "$@" "$_s" 2>>/work/make-cc.err; then
      say "      FAILED: $_s"; _cc_fail=$((_cc_fail + 1)); fi; }
  mk_cc_glob glob/fnmatch.c -Iglob -DSTDC_HEADERS
  mk_cc_glob glob/glob.c    -Iglob -DHAVE_STRDUP -DHAVE_DIRENT_H

  say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  ($_cc_fail of 27 failed)"

  if [ "$_cc_fail" != 0 ]; then
    R35=FAIL
    say "    --- distinct errors, by count ---"
    grep -a "error:" /work/make-cc.err 2>/dev/null \
      | sed 's/^.*error:/error:/' | sort | uniq -c | sort -rn | head -12 | sed 's/^/      /'
    say "    --- first errors verbatim ---"
    grep -av '^[A-Z][0-9]*$' /work/make-cc.err 2>/dev/null | head -15 | sed 's/^/      /'
  else
    mkdir -p "$PFX/bin"
    say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: \$CC -static -o $PFX/bin/make <27 objects>"
    $CC -static -o "$PFX/bin/make" \
      getopt.o getopt1.o ar.o arscan.o commands.o default.o dir.o expand.o \
      file.o function.o implicit.o job.o main.o misc.o read.o remake.o rule.o \
      signame.o strcache.o variable.o version.o vpath.o hash.o remote-stub.o \
      getloadavg.o fnmatch.o glob.o 2>/work/make-ld.err
    _lrc=$?
    say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_lrc)"
    if [ "$_lrc" = 0 ] && [ -x "$PFX/bin/make" ]; then
      produced "$PFX/bin/make"
      # live-bootstrap's own test, verbatim: `make --version`
      # STATIC? make links through $CC directly, not libtool, so -static in CC
      # reaches it -- but binutils proved that assumption wrong one rung later,
      # so it is checked rather than assumed for everything the box builds.
      if grep -aq 'ld-musl\|ld-linux' "$PFX/bin/make" 2>/dev/null; then
        say "    make is DYNAMIC -- it will not run in this box"
      else
        say "    make is static"
      fi
      if "$PFX/bin/make" --version > /work/mkver.txt 2>&1; then
        say "    --- make --version ---"
        head -3 /work/mkver.txt | sed 's/^/      /'
        R35=ok
      else
        R35=FAIL
        say "    make built but will not run:"
        head -5 /work/mkver.txt | sed 's/^/      /'
      fi
    else
      R35=FAIL
      say "    link FAILED:"
      grep -av '^[A-Z][0-9]*$' /work/make-ld.err 2>/dev/null | head -12 | sed 's/^/      /'
    fi
  fi
  cd /work
fi

PATH="$PFX/bin:$PATH"; export PATH

# ---------------------------------------------------------------------------
head1 "RUNG 4 -- binutils.  BUILT, NEVER BORROWED."
# as, ld, ar and ranlib decide what bytes end up in an object, so they are tier
# 1 by definition and cannot come from the host. gcc cannot be built without
# them: it emits assembly and shells out.
if [ "$R35" = ok ]; then
  cd /work/src
  untar /in/binutils- || { R4=FAIL; say "    binutils did not extract"; }
  mkdir -p b-binutils && cd b-binutils
  # busybox's SHELL DISPATCHES APPLETS INTERNALLY, BYPASSING PATH.
  #
  # The box deliberately does not symlink busybox's `ar` -- it can only read
  # archives, not create them, and it is tier 1 by this job's own definition.
  # The SEAL confirms 269 applets linked with ar excluded. And the smoke test
  # still got:
  #
  #     ar cru  -> FAIL ar: invalid option -- 'r'
  #
  # which is busybox ar's message. Ubuntu's busybox-static is built with
  # FEATURE_SH_STANDALONE, so its ash runs any applet it knows by name without
  # consulting PATH at all. NOT LINKING AN APPLET DOES NOT REMOVE IT. That is
  # worth knowing well beyond this rung: every claim in this job of the form
  # "the box does not have X" is only true if busybox does not have X.
  #
  # SO THE SHIM DOES NOT COMPETE FOR THE NAME. It is called tcc-ar, which
  # busybox has no applet for, and configure is told about it explicitly with
  # AR= and RANLIB=. libtool records whatever configure found -- the failing
  # line was `libtool: link: ar rc .libs/libbfd.a ...`, bare `ar`, because
  # configure had found busybox's.
  #
  # tcc -ar is the archiver either way: it already wrote musl's 3.2 MB libc.a
  # from 1277 objects at rung 2.
  mkdir -p "$PFX/bin"
  cat > "$PFX/bin/tcc-ar" <<'ARSHIM'
#!/bin/sh
# tcc -ar standing in for binutils ar until rung 4 builds a real one.
#
# TWO THINGS tcc -ar DOES NOT DO, AND BOTH BIT.
#
# 1. IT DOES NOT UNDERSTAND libtool's FLAGS. libtool calls `ar cru`, `ar cq`,
#    `ar cr`; tcc -ar accepts `rcs` and prints usage for anything else. Every
#    creation mode means the same thing here -- replace members, create if
#    absent, write an index -- so they all map to rcs. Extraction modes are NOT
#    translated: tcc cannot do them and doing something else quietly would
#    corrupt a build rather than stop it.
#
# 2. IT CREATES RATHER THAN APPENDS, which is the one that cost a run. libtool
#    builds a large archive with REPEATED ar calls -- a batch of objects at a
#    time -- and real ar's `r` replaces-or-appends into the existing archive.
#    tcc -ar rewrites it from just the objects on that command line, so every
#    batch but the last is silently discarded:
#
#        libbfd.a  823842 bytes, members: elf64-gen.o elf32-gen.o plugin.o
#                  cpu-aarch64.o cpu-arm.o        <- the TAIL of bfd's objects
#        minimal link against it: undefined symbol 'bfd_init'
#
#    The archive had a valid header and a symbol index, so it looked fine.
#    It was simply missing nearly all of its members.
#
#    So this keeps a sidecar list per archive and rebuilds from the full
#    accumulated set each time. Order is preserved and duplicates collapse,
#    which is what `r` means. The objects are still on disk in the build tree,
#    so re-reading them costs time and nothing else.
_flags=$1
case "$_flags" in
  -*) _flags=${_flags#-} ;;
esac
case "$_flags" in
  *x*|*t*|*p*|*d*|*m*)
      echo "tcc-ar: cannot do '$_flags' (extract/list/delete)" >&2
      exit 1 ;;
esac
shift

_out=$1; shift
_lst="$_out.tcc-ar-members"

# Accumulate. A member named twice keeps its first position, which is `r`.
for _o in "$@"; do
    grep -qxF -- "$_o" "$_lst" 2>/dev/null || printf '%s\n' "$_o" >> "$_lst"
done

# Drop anything that has since disappeared, or the rebuild fails on a stale
# entry rather than on anything the caller did.
: > "$_lst.live"
while IFS= read -r _o; do
    [ -f "$_o" ] && printf '%s\n' "$_o" >> "$_lst.live"
done < "$_lst"
mv "$_lst.live" "$_lst"

set -- $(cat "$_lst")
exec CCBIN -ar rcs "$_out" "$@"
ARSHIM
  sed -i "s|CCBIN|$CC_BIN|" "$PFX/bin/tcc-ar"
  printf '#!/bin/sh\nexit 0\n' > "$PFX/bin/tcc-ranlib"
  chmod 0755 "$PFX/bin/tcc-ar" "$PFX/bin/tcc-ranlib"
  PATH="$PFX/bin:$PATH"; export PATH
  AR="$PFX/bin/tcc-ar";      export AR
  RANLIB="$PFX/bin/tcc-ranlib"; export RANLIB

  # SMOKE-TEST THE SHIM BY ITS FULL PATH, which is how configure will call it.
  say "    --- tcc-ar smoke test ---"
  ( cd /tmp && rm -f as.c as.o as.a
    printf 'int shim_probe(void){return 7;}\n' > as.c
    $CC -c -o as.o as.c 2>/dev/null
    for _f in cru cq cr rcs; do
      rm -f as.a
      if "$AR" "$_f" as.a as.o 2>/tmp/ar.err; then
        printf '      tcc-ar %-4s -> ok   (%s bytes)\n' "$_f" "$(wc -c < as.a 2>/dev/null || echo 0)"
      else
        printf '      tcc-ar %-4s -> FAIL %s\n' "$_f" "$(head -1 /tmp/ar.err)"
      fi
    done
    # AND THAT REPEATED CALLS ACCUMULATE, which is how libtool builds a large
    # archive and is what silently truncated libbfd.a to its last five members.
    rm -f as.a as.a.tcc-ar-members
    printf 'int p2(void){return 2;}\n' > as2.c; $CC -c -o as2.o as2.c 2>/dev/null
    "$AR" cru as.a as.o  >/dev/null 2>&1
    "$AR" cru as.a as2.o >/dev/null 2>&1
    _n=$(grep -c . as.a.tcc-ar-members 2>/dev/null || echo 0)
    if [ "$_n" = 2 ]; then
      say "      two ar calls -> $_n members accumulated  ok"
    else
      say "      two ar calls -> $_n members  EXPECTED 2 -- archives will truncate"
    fi
    rm -f as.c as.o as2.c as2.o as.a as.a.tcc-ar-members )
  say "    AR=$AR  RANLIB=$RANLIB"

  _busrc="../$(cd .. && onedir 'binutils-* ./binutils-*')"
  cfg_binutils() {
      say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: $_busrc/configure $* CC=\"$CCAUTO\""
      "$_busrc/configure" "$@" --prefix="$PFX" --disable-nls --disable-werror \
        --enable-deterministic-archives \
        --disable-gdb --disable-gdbserver --disable-libdecnumber --disable-readline \
        CC="$CCAUTO" LDFLAGS="$LDF" AR="$AR" RANLIB="$RANLIB" > cfg.log 2>&1
      _r=$?; say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r)"; return $_r
  }
  if cfg_binutils; then
      say "    binutils: configured NATIVE"
  elif grep -q "cannot run C compiled programs" cfg.log 2>/dev/null \
       && cfg_binutils --build="$BUILDTRIP" --host="$HOSTTRIP"; then
      say "    binutils: configured CROSS (LFS style)"
  else
      R4=FAIL
      say "    binutils: configure FAILED"
      tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
      grep -nE "error|cannot" config.log 2>/dev/null | head -10 | sed 's/^/      /'
  fi
  # MAKEINFO=true: texinfo is borrowed by stage 4 and absent here. See rung 6.
  if timeout 3000 make -j"$NP" MAKEINFO=true AR="$AR" RANLIB="$RANLIB" > build.log 2>&1 \
     && make install MAKEINFO=true AR="$AR" RANLIB="$RANLIB" > /dev/null 2>&1; then
    # ok MEANS THE TOOLS RUN, NOT THAT THE FILES EXIST. The last run reported
    # rung 4 ok and rung 5 ok while `as` could not be executed at all, so the
    # frontier was reported three rungs further along than it was.
    R4=ok
    for t in as ld ar ranlib; do
      if [ ! -x "$PFX/bin/$t" ]; then
        printf '    %-8s ABSENT\n' "$t"; R4=FAIL; continue
      fi
      if "$PFX/bin/$t" --version >/dev/null 2>&1; then
        printf '    %-8s %10s bytes  runs\n' "$t" "$(wc -c < "$PFX/bin/$t")"
      else
        printf '    %-8s %10s bytes  WILL NOT RUN (rc=%s)\n' "$t" \
          "$(wc -c < "$PFX/bin/$t")" "$("$PFX/bin/$t" --version >/dev/null 2>&1; echo $?)"
        R4=FAIL
      fi
    done

    # POPULATE THE TOOLDIR gcc WILL ACTUALLY LOOK IN.
    #
    # libgcc's configure runs the freshly built xgcc with
    #
    #     -B$PFX/riscv64-unknown-linux-gnu/bin/  -isystem .../include
    #     -B$PFX/riscv64-unknown-linux-gnu/lib/  -isystem .../sys-include
    #
    # and it died with
    #
    #     /work/bld/gcc/as: exec: /work/prefix/riscv64-unknown-linux-gnu/bin/as:
    #                             Permission denied
    #
    # -- so something IS at that path and cannot be executed, while
    # include/ and sys-include/ do not exist at all. binutils here is configured
    # NATIVE, without --target, so whatever it put in the tooldir is incidental;
    # nothing ever arranged it deliberately.
    #
    # THIS IS THE HALF OF LFS I SAID WE COULD SKIP. LFS builds its toolchain
    # with --with-sysroot and a $VERON_TOOLCHAIN_TGT directory precisely so the target's
    # tools and headers sit where gcc expects them. I argued the box IS the
    # target so the layout did not matter. It matters: gcc asks for the target
    # tooldir by construction, whether or not the target is the same machine.
    # THE SHIM RETIRES HERE. binutils just built a real ar; keep using tcc-ar
    # and the next rung finds out the hard way:
    #
    #     libtool: link: (cd .libs/libstdc++.lax/... && tcc-ar x "...convenience.a")
    #     tcc-ar: cannot do 'x' (extract/list/delete)
    #
    # libtool merges "convenience" archives by EXTRACTING their members and
    # re-archiving them, and tcc -ar cannot extract. The shim refuses rather
    # than guessing, which is why that reads clearly instead of producing a
    # libstdc++.a with the wrong contents.
    #
    # tcc-ar existed for exactly one reason: to build binutils when there was
    # no ar. That reason is now gone. Leaving a bootstrap tool in place after
    # the real one exists is how a limitation outlives its cause -- and this
    # one would have been blamed on gcc, four rungs from where it was set.
    AR="$PFX/bin/ar";         export AR
    RANLIB="$PFX/bin/ranlib"; export RANLIB
    say "    AR/RANLIB now the real binutils: $AR"
    if "$AR" --version >/dev/null 2>&1; then
      say "      $("$AR" --version 2>&1 | head -1)"
    else
      say "      but it will not run -- keeping tcc-ar"
      AR="$PFX/bin/tcc-ar"; RANLIB="$PFX/bin/tcc-ranlib"; export AR RANLIB
    fi
    # And prove the thing tcc-ar could not do now works, since that is the
    # capability the next rung needs and nothing has ever exercised it.
    ( cd /tmp && rm -rf arx && mkdir -p arx/out && cd arx
      printf 'int q(void){return 1;}\n' > q.c
      $CC -c -o q.o q.c 2>/dev/null
      "$AR" rcs qq.a q.o 2>/dev/null
      # Extract into an EMPTY directory, or the member that was already there
      # passes the test for you. The first version of this checked for q.o in
      # the same directory it had just compiled q.o into.
      if ( cd out && "$AR" x ../qq.a 2>/dev/null ) && [ -f out/q.o ]; then
        say "      ar x: works (libtool needs it for convenience archives)"
      else
        say "      ar x: FAILED -- libstdc++ will not link"
      fi
      cd /tmp && rm -rf arx )

    _TD="$PFX/riscv64-unknown-linux-gnu"
    say "    --- tooldir as binutils left it ---"
    ls -l "$_TD/bin" 2>/dev/null | head -12 | sed 's/^/      /' || say "      (no $_TD/bin)"
    mkdir -p "$_TD/bin" "$_TD/lib"
    for _t in as ld ar ranlib nm objcopy objdump strip readelf strings; do
      [ -x "$PFX/bin/$_t" ] || continue
      rm -f "$_TD/bin/$_t"
      ln -s "$PFX/bin/$_t" "$_TD/bin/$_t"
    done
    # The target's headers are musl's, installed at /usr by rung 2. gcc looks
    # for them under the tooldir, so point it there rather than reconfiguring
    # gcc -- one symlink instead of a different recipe from stage 4's.
    rm -rf "$_TD/sys-include"
    ln -s /usr/include "$_TD/sys-include"
    # THE SAME TOOLDIR UNDER EACH gcc PREFIX. gcc looks in $prefix/$target/,
    # and rung 6 installs gcc to /work/out, so populating only $PFX's leaves
    # gcc looking at an empty directory. That is exactly what happened when
    # gcc moved off $PFX: libstdc++'s libtool stopped finding a real `ar` and
    # fell back to the AR in the environment.
    for _p in /work/out /work/out2 /work/out10; do
      mkdir -p "$_p/riscv64-unknown-linux-gnu/bin" "$_p/riscv64-unknown-linux-gnu/lib"
      for _t in as ld ar ranlib nm objcopy objdump strip readelf strings; do
        [ -x "$PFX/bin/$_t" ] || continue
        rm -f "$_p/riscv64-unknown-linux-gnu/bin/$_t"
        ln -s "$PFX/bin/$_t" "$_p/riscv64-unknown-linux-gnu/bin/$_t"
      done
      rm -rf "$_p/riscv64-unknown-linux-gnu/sys-include"
      ln -s /usr/include "$_p/riscv64-unknown-linux-gnu/sys-include"
    done
    say "    tooldirs populated: $PFX and /work/out{,2,10}"

    say "    --- tooldir after ---"
    ls -l "$_TD/bin" 2>/dev/null | head -12 | sed 's/^/      /'
    printf '      %-14s %s\n' sys-include "-> $(readlink "$_TD/sys-include" 2>/dev/null)"
    # DOES binutils' as RUN AT ALL? Everything so far has only established
    # that a 15 MB file exists with the execute bit set. `command -v as`
    # answers yes for a file that cannot run, and the previous check threw the
    # error away with >/dev/null 2>&1 and reported a bare NO.
    #
    # Two separate questions, asked separately:
    #   does $PFX/bin/as run          -- is the binary we BUILT any good
    #   does $_TD/bin/as run          -- did the symlink arrangement work
    say "    --- can the assembler we built actually run? ---"
    for _cand in "$PFX/bin/as" "$_TD/bin/as"; do
      _out=$("$_cand" --version 2>&1); _rc=$?
      if [ "$_rc" = 0 ]; then
        printf '      %-46s rc=0  %s\n' "$_cand" "$(printf '%s' "$_out" | head -1)"
      else
        printf '      %-46s rc=%s\n' "$_cand" "$_rc"
        printf '%s' "$_out" | head -3 | sed 's/^/        /'
      fi
    done
    # AND IS IT A WELL-FORMED aarch64 ELF? "Permission denied" from exec is
    # what a shell reports for several different faults, and a bad ELF header
    # is one of them. e_machine 0xB7 is AArch64; e_type 2 is EXEC, 3 is DYN.
    say "      first 20 bytes of $PFX/bin/as:"
    dd if="$PFX/bin/as" bs=1 count=20 2>/dev/null | od -An -tx1 | sed 's/^/        /'
    printf '      %-20s %s\n' "size" "$(wc -c < "$PFX/bin/as")"
    if grep -aq 'ld-musl\|ld-linux' "$PFX/bin/as" 2>/dev/null; then
      say "      interp: PRESENT -- as is DYNAMIC and this box has no loader"
      grep -ao 'ld-[a-z0-9./-]*' "$PFX/bin/as" | head -1 | sed 's/^/        /'
    else
      say "      interp: none -- statically linked"
    fi
  else
    R4=FAIL
    # ARE THE SYMBOLS IN THE ARCHIVE, OR IS THE ARCHIVE WRONG?
    #
    # 21 undefined bfd_* symbols at the as-new link, from an archive tcc-ar
    # created. Two very different faults look identical from here: the members
    # are missing, or they are present and the archive's SYMBOL INDEX is not.
    # tcc's linker resolves an archive through that index, so an archive with
    # good members and no index links like an empty one.
    #
    # grep on the raw archive answers it without needing nm: if the string is
    # in the file at all, the member is there and the index is the suspect.
    for _a in ../bfd/.libs/libbfd.a bfd/.libs/libbfd.a; do
      [ -f "$_a" ] || continue
      say "    --- $_a: $(wc -c < "$_a") bytes ---"
      say "        members (first bytes of each header):"
      "$CC_BIN" -ar t "$_a" 2>/dev/null | head -5 | sed 's/^/          /' \
        || say "          (tcc -ar t not supported -- using grep instead)"
      for _s in bfd_init bfd_errmsg _bfd_std_section; do
        if grep -aq "$_s" "$_a"; then
          say "        $_s: PRESENT in the archive bytes"
        else
          say "        $_s: ABSENT -- the member itself is missing"
        fi
      done
      # An archive index lives in a member literally named "/" or "__.SYMDEF".
      if head -c 200 "$_a" | grep -aq "^!<arch>"; then
        say "        header:  !<arch> ok"
      else
        say "        header:  NOT an ar archive"
      fi
      if head -c 200 "$_a" | grep -aqE "^/ |__\.SYMDEF"; then
        say "        index:   present"
      else
        say "        index:   MISSING -- tcc -ar wrote no symbol table, so the"
        say "                 linker cannot resolve members out of it"
      fi
      # AND A MINIMAL REPRODUCTION, which is the thing that can be argued about
      # afterwards. One object referencing one bfd symbol, linked against the
      # same archive. If this fails, the fault is tcc's archive handling and
      # has nothing to do with binutils; if it succeeds, the fault is in how
      # libtool assembled the real link line.
      ( cd /tmp && rm -f pb.c pb.o pb.bin
        printf 'extern void bfd_init(void);\nint main(void){ bfd_init(); return 0; }\n' > pb.c
        if $CC -c -o pb.o pb.c 2>/dev/null; then
          if $CC -static -o pb.bin pb.o "$OLDPWD/$_a" 2>/tmp/pb.err; then
            say "        minimal link against this archive: OK"
          else
            say "        minimal link against this archive: FAILED"
            grep -a "error" /tmp/pb.err 2>/dev/null | head -3 | sed 's/^/          /'
          fi
        fi
        rm -f pb.c pb.o pb.bin )
      break
    done
    say "    --- the failing command ---"
    grep -nE "^(libtool|/bin/sh|ar |.*ar-shim)" build.log 2>/dev/null | tail -6 | sed 's/^/      /'
    say "    --- where it stopped ---"
    grep -nE "error:|Error [0-9]|undefined reference|ar-shim" build.log 2>/dev/null | head -15 | sed 's/^/      /'
    tail -15 build.log 2>/dev/null | sed 's/^/      /'
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 4.5 -- rebuild make PROPERLY, now that binutils exists"
# make 3.82 GOT US HERE AND CANNOT GO FURTHER.
#
# It came up first because it is the only one that can: live-bootstrap's kaem
# command list compiles it with no configure, no ld and no ar, which is exactly
# the situation at rung 3.5. It then drove musl's install, binutils and the
# arithmetic libraries without complaint.
#
# Then gcc's libgcc killed it:
#
#     Makefile:979: warning: overriding recipe for target `crti.o'
#     ... twenty more like it ...
#     make[1]: *** [all-target-libgcc] Bus error (core dumped)
#
# 3.82 is a known-bad release -- LFS carries make-3.82-upstream_fixes-3.patch
# for its pattern-rule handling, and live-bootstrap rebuilds it for the same
# reason, in almost these words: "GNU make is now rebuilt properly using the
# build system and GCC, which means that it does not randomly segfault while
# building the Linux kernel."
#
# WE COULD NOT DO THIS BEFORE AND CAN NOW. 3.82 had to be hand-compiled because
# its configure wanted an ld that rung 4 had not built yet. binutils exists now,
# so 4.4 configures the ordinary way -- and this is the first rung where the
# thing being built uses tools this box produced rather than tools it borrowed.
if [ "$R4" = ok ]; then
  cd /work/src
  if ! untar "/in/make-$MAKE_ALT"; then
    say "    make $MAKE_ALT did not extract"; R45=FAIL
  else
    _m4=$(onedir "make-$MAKE_ALT ./make-$MAKE_ALT")
    if [ -z "$_m4" ] || ! cd "$_m4"; then
      say "    no make-$MAKE_ALT directory"; R45=FAIL
    else
      # ONE DECLARED SUBSTITUTION, AND IT IS THE libc AGAIN.
      #
      #     glob.c:289: error: incompatible types for redefinition of 'getlogin'
      #
      # make 4.2.1 bundles its own glob, and that glob declares getlogin and
      # getlogin_r ITSELF inside a `#ifndef __GNU_LIBRARY__` guard -- i.e. "if
      # this is not glibc, assume the libc does not declare these". musl does
      # not define __GNU_LIBRARY__ and DOES declare both, with different
      # prototypes, so the two collide.
      #
      # live-bootstrap does not hit this: their pass1.sh runs `autoreconf-2.69
      # -fi` first, which regenerates the build system. We have no autotools in
      # this box, so the source is used as shipped and the conflict stands.
      #
      # The declarations are simply redundant here -- musl's unistd.h already
      # has both -- so they are removed by content rather than by line number.
      # Deleting a wrong declaration is smaller and more honest than defining
      # __GNU_LIBRARY__ to make glob.c believe it is on glibc, which would turn
      # on a dozen other paths nobody has looked at.
      # THE glob SUBSTITUTIONS ONLY APPLY IF THERE IS A BUNDLED glob. 4.4 has
      # none -- that is the point of using it -- so this whole block is skipped
      # and says so, rather than silently reporting "removed 0" three times and
      # looking like it did something.
      if [ ! -f glob/glob.c ]; then
        say "    no bundled glob in $_m4 -- gnulib's is used, nothing to patch"
      else
      say "    --- declared substitutions in glob/glob.c ---"

      # 1. ITS OWN getlogin DECLARATIONS. Redundant on musl, and the wrong
      #    prototype, so they collide with unistd.h's.
      _before=$(grep -c "^extern .*getlogin" glob/glob.c 2>/dev/null || true)
      sed -i '/^extern int getlogin_r/d; /^extern char \*getlogin/d' glob/glob.c 2>/dev/null || true
      say "      getlogin declarations removed: $_before"

      # 2. __P COMES FROM sys/cdefs.h NOW. Rung 2 installs a minimal one into
      #    the sysroot, so the injection that used to live here is gone --
      #    fixing the class beat fixing the fourth instance.

      # 3. THE DUPLICATE __ptr_t TYPEDEF.
      #
      #        glob.c:303: error: redeclaration of '__ptr_t'
      #
      #    glob/glob.h and glob/glob.c BOTH define it, each under its own
      #    "am I on glibc" guard. On glibc neither fires; on musl both do, and
      #    C89 does not allow a typedef to be repeated. This is a TYPE, so it
      #    cannot be handled in cdefs.h -- defining __ptr_t as a macro would
      #    turn `typedef void *__ptr_t;` into `typedef void *void *;`.
      #
      #    Removing glob.c's copy keeps glob.h's, which is the one every other
      #    file in that directory includes.
      _pt=$(grep -c "^typedef.*__ptr_t;" glob/glob.c 2>/dev/null || true)
      sed -i '/^typedef .*__ptr_t;$/d' glob/glob.c 2>/dev/null || true
      say "      __ptr_t typedefs removed from glob.c: $_pt"
      say "      __P now supplied by $SYS/include/sys/cdefs.h: $( [ -f "$SYS/include/sys/cdefs.h" ] && echo yes || echo MISSING )"
      fi

      # STOP BUILDING THE BUNDLED glob. FIVE PATCHES IN ONE FILE IS THE SIGNAL.
      #
      #     getlogin      incompatible types for redefinition
      #     getlogin_r    same
      #     __P           ';' expected -- glibc's <sys/cdefs.h> macro
      #     __ptr_t       redeclaration
      #     ...           and no reason to think that is the last one
      #
      # Every one is the same wrong assumption -- glob.c's `#ifndef
      # __GNU_LIBRARY__` branch treats "not glibc" as "a libc from 1991" and
      # supplies its own versions of things musl already has, correctly. Each
      # fix is two lines and each one uncovers the next; that is a losing shape.
      #
      # make's configure has a switch for exactly this. make_cv_sys_gnu_glob
      # asks "does the system libc have a GNU-quality glob"; when it is yes the
      # glob/ subdirectory is not built at all and <glob.h> is used instead.
      # musl's glob is POSIX and complete, which is what make actually needs.
      #
      # THIS MAY NOT HOLD, and the failure will be specific and readable if it
      # does not: make uses glob_pattern_p, which is a GNU extension musl does
      # not export, so this either links or stops with one undefined symbol
      # naming it. That is a better next log than a sixth parse error. If it
      # does stop there, make 4.3 dropped the bundled glob entirely and is the
      # next thing to try rather than a sixth patch.
      # make_cv_sys_gnu_glob IS GONE. It told configure musl's glob is GNU
      # quality; dir.c then asked for gl_opendir and musl's glob_t does not
      # have it. 4.4 does not have the question at all.
      if cfg_try "make $MAKE_ALT" --prefix="$PFX" --disable-nls; then
        # MAKEINFO=true, as live-bootstrap's own steps/make-4.2.1/pass1.sh does
        # -- texinfo is not in this box and make builds its manual otherwise.
        if timeout 1800 make -j"$NP" MAKEINFO=true > build.log 2>&1 && [ -x ./make ]; then
          # Replace the bootstrap make with the real one, and say so, because
          # everything above this line was driven by the other binary.
          cp ./make "$PFX/bin/make"
          produced "$PFX/bin/make"
          "$PFX/bin/make" --version 2>&1 | head -1 | sed 's/^/      /'
          if grep -aq 'ld-musl\|ld-linux' "$PFX/bin/make"; then
            say "    DYNAMIC -- will not run in this box"; R45=FAIL
          else
            R45=ok
          fi
        else
          R45=FAIL; say "    --- where it stopped ---"
          grep -nE "error:|Error [0-9]|undefined symbol" build.log 2>/dev/null | head -12 | sed 's/^/      /'
          if grep -q "glob_pattern_p" build.log 2>/dev/null; then
            say "    ^ glob_pattern_p is the GNU extension musl does not export."
            say "      make 4.3 dropped the bundled glob entirely; that is the"
            say "      next version to try rather than another patch here."
          fi
          tail -15 build.log 2>/dev/null | sed 's/^/      /'
        fi
      else
        R45=FAIL
      fi
    fi
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 4.6 -- give libc.a the compiler-support symbols gcc will not have"

# WHY THIS RUNG EXISTS, MEASURED AT RUNG 6 AND TRACED BACK TO HERE.
#
# musl's libc.a is compiled by tcc. tcc emits CALLS to compiler-support
# helpers where gcc emits instructions -- on x86_64 the 80-bit x87 long
# double conversions especially. Those helpers live in libtcc1.a, which every
# tcc link picks up automatically, so rungs 3 through 5 never noticed.
#
# Rung 6 hands that same libc.a to xgcc, and gcc's libgcc does NOT define
# them, because on x86_64 gcc converts long double inline (fistpll) and never
# needs a helper. Run 85011262228:
#
#     configure:19256: xgcc ... -o conftest -static conftest.c
#     /lib/x86_64-linux-gnu/libc.a(vfprintf.o): In function `fmt_fp':
#     src/stdio/vfprintf.c: undefined reference to `__fixxfdi'
#     collect2: error: ld returned 1 exit status
#     configure:19256: $? = 1
#
# -- which surfaced as "configure: error: computing EOF failed", a message
# about a stdio constant that had nothing to do with stdio constants.
#
# WHETHER THIS TARGET NEEDS IT IS NOT ASSUMED. RISC-V's long double is
# binary128 like aarch64's, so gcc's libgcc should ship the soft-float
# helpers and the overlap below may well be empty -- in which case this rung
# prints "nothing to add" and costs a second. The measurement is cheap and
# the alternative is finding out at rung 6 again.
#
# WHAT THIS DOES: computes which symbols libc.a needs and libtcc1.a defines --
# no fixed list, because a list would go stale the moment musl or tcc changed
# -- and adds only those objects to libc.a. After this, libc.a is
# self-contained for any linker, which is what an archive of a C library
# ought to be.
#
# IT RUNS AFTER RUNG 4 because it needs binutils' nm and ar. tcc has an
# archiver but no nm, and the whole point here is to measure rather than list.
R46=skip
if [ "$R4" = ok ]; then
  R46=ok
  _need=/work/lt-need.txt
  _have=/work/lt-have.txt
  _add=/work/lt-add.txt
  : > "$_add"
  # UNDEFINED IN libc.a ...
  "$PFX/bin/nm" -u "$SYS/lib/libc.a" 2>/dev/null | awk '/^ *U /{print $2}' | sort -u > "$_need" || true
  # ... AND DEFINED IN libtcc1.a
  "$PFX/bin/nm" -g --defined-only "$TCCDIR/libtcc1.a" 2>/dev/null \
    | awk '$2 ~ /^[TtDdBbRrWw]$/ {print $3}' | sort -u > "$_have" || true
  comm -12 "$_need" "$_have" > "$_add" || true
  _n=$(grep -c . "$_add" || true)
  say "    libc.a needs $(grep -c . "$_need" || true) symbols it does not define"
  say "    libtcc1.a can supply $_n of them:"
  sed 's/^/      /' "$_add"
  if [ "${_n:-0}" -gt 0 ]; then
    # ADD WHOLE OBJECTS, not symbols: an archive member is the unit a linker
    # pulls, and libtcc1.a is small enough that adding its members whole costs
    # nothing. The linker still takes only what it needs.
    rm -rf /work/ltx && mkdir -p /work/ltx && cd /work/ltx
    "$AR" x "$TCCDIR/libtcc1.a" 2>/dev/null || true
    _objs=$(ls ./*.o 2>/dev/null | tr '\n' ' ')
    if [ -n "$_objs" ]; then
      "$AR" r "$SYS/lib/libc.a" $_objs > /dev/null 2>&1 \
        && say "    added $(echo $_objs | wc -w) libtcc1 objects to libc.a" \
        || { say "    ar could not update libc.a"; R46=FAIL; }
      # AND THE COPIES: rung 2 put libc.a beside every crt directory it found.
      for _d in $crtdirs; do
        [ -f "$_d/libc.a" ] && cp "$SYS/lib/libc.a" "$_d/libc.a" 2>/dev/null || true
      done
      # ASK WHETHER THEY ARE DEFINED NOW, NOT WHETHER ANYTHING STILL
      # REFERENCES THEM. The first version re-ran `nm -u` and reported "2
      # still unresolved" after a successful update -- which is exactly what
      # `nm -u` on an ARCHIVE means: it lists undefined symbols PER MEMBER,
      # and vfprintf.o goes on referencing __fixxfdi whatever else the
      # archive holds. The linker resolves across members; nm -u does not
      # pretend to.
      _def=$("$PFX/bin/nm" -g --defined-only "$SYS/lib/libc.a" 2>/dev/null \
             | awk '$2 ~ /^[TtDdBbRrWw]$/ {print $3}' | sort -u \
             | comm -12 "$_add" - | grep -c . || true)
      say "    of the $_n symbols added, $_def are now defined in libc.a (expect $_n)"
    else
      say "    libtcc1.a produced no objects"; R46=FAIL
    fi
    cd /work
  else
    say "    nothing to add -- libc.a needs no libtcc1 symbol"
  fi
else
  say "    skipped: binutils did not finish"
fi

# ---------------------------------------------------------------------------
head1 "RUNG 4.7 -- m4, because gmp's configure refuses to run without it"

# MEASURED, NOT ANTICIPATED. Run 84999333959 cleared binutils and make and
# then died here:
#
#     checking for suitable m4... configure: error: No usable m4 in $PATH
#         or /usr/5bin (see config.log for reasons).
#     gmp: configure FAILED rc=1
#
# with --disable-assembly already on the configure line. The aarch64 arm does
# not hit this and builds m4 much later, at rung 11.7, for glibc's benefit --
# so this rung exists only because gmp 6.3.0 asks for m4 on this target and
# not on that one. Whether that is an x86_64 asm-path difference inside gmp's
# configure is not established here; what is established is that gmp will not
# configure without m4, and m4 is small and builds with what this box already
# has.
#
# THE BUILD SHAPE IS LIFTED FROM RUNG 11.7 rather than invented: same
# configure flags, same static link, same MAKEINFO=true.
R47=skip
if [ "$R45" = ok ]; then
  R47=ok
  cd /work/src
  rm -rf /work/src/m4-t && mkdir -p /work/src/m4-t
  # THE OLD m4, NOT THE ONE RUNG 11.7 USES. `untar /in/m4-` would match
  # whichever sorts first; naming the version is what makes this rung use
  # 1.4.7 and 11.7 use 1.4.21. See the workflow's M4_BOOT_VER for why.
  ( cd /work/src/m4-t && untar "/in/m4-${M4_BOOT_VER}" ) \
    || { R47=FAIL; say "    m4-$M4_BOOT_VER did not extract"; }
  # --build IS SPELLED OUT HERE, AND ONLY ON THIS TARGET.
  #
  # m4 1.4.7 is from 2006 and its bundled config.guess predates RISC-V by a
  # decade, so it cannot recognise the machine it is running on:
  #     configure: error: cannot guess build type; you must specify one
  # (run 85004867294). Telling it the triple skips the guess entirely.
  #
  # The amd64 arm does not need this -- a 2006 config.guess knows x86_64
  # perfectly well -- which is why the flag is here and not there.
  if [ "$R47" = ok ]; then
    _m4d=$(cd /work/src/m4-t && onedir "m4-$M4_BOOT_VER ./m4-$M4_BOOT_VER")
    ( cd "/work/src/m4-t/$_m4d" \
      && ./configure --prefix=/work/prefix --disable-nls \
           --build=riscv64-unknown-linux-gnu \
           CC="/work/prefix/bin/cc-static" LDFLAGS="-static" > cfg.log 2>&1 \
      && timeout 2400 make -j"$NP" MAKEINFO=true > b.log 2>&1 \
      && make install MAKEINFO=true > /dev/null 2>&1 ) \
      || { R47=FAIL
           say "    m4 NOT INSTALLED"
           tail -12 "/work/src/m4-t/$_m4d/cfg.log" 2>/dev/null | sed 's/^/      /'
           tail -12 "/work/src/m4-t/$_m4d/b.log" 2>/dev/null | sed 's/^/      /'; }
  fi
  if [ "$R47" = ok ]; then
    if [ -x /work/prefix/bin/m4 ]; then
      say "    m4: $(/work/prefix/bin/m4 --version 2>&1 | head -1)"
      PATH="/work/prefix/bin:$PATH"; export PATH
      say "    /work/prefix/bin is on PATH for the rungs below"
    else
      say "    m4 installed but /work/prefix/bin/m4 is not there"; R47=FAIL
    fi
  fi
else
  say "    skipped: rung 4.5 did not finish"
fi

# ---------------------------------------------------------------------------
head1 "RUNG 4.8 -- flex, because this target's gcc source is a git tree"

# MEASURED AT RUNG 6, ANSWERED HERE.
#
# The probe added to rung 6 reported, in run 85020156486:
#
#     gcc/gengtype-lex.c: ABSENT -- a generated file this tree does not carry.
#     gcc/gengtype-parse.c: 23297 bytes
#
# gengtype-parse.c is hand-written and present; gengtype-lex.c is generated
# from gengtype-lex.l by flex, and a git tree does not carry build products.
# The amd64 arm untars a gnu.org RELEASE, which ships it, so that arm has
# never needed flex and does not build it. This target's bottom gcc is a
# clone of Ekaitz's fork, so it does.
#
# Without it the build got configure rc=0, built genhooks and genmodes, and
# then died on
#     tcc: error: undefined symbol 'lexer_line'  'yybegin'  'yylex'  'yyend'
# -- the names flex emits.
#
# flex NEEDS m4 AT RUNTIME, not just to build: its skeleton is processed by
# m4. Rung 4.7 built m4 1.4.7 and put /work/prefix/bin on PATH, so this rung
# must come after it. That ordering is the whole reason this is 4.8 and not
# 4.55.
R48=skip
if [ "$R47" = ok ]; then
  R48=ok
  cd /work/src
  rm -rf /work/src/flex-t && mkdir -p /work/src/flex-t
  ( cd /work/src/flex-t && untar /in/flex- ) \
    || { R48=FAIL; say "    flex did not extract"; }
  if [ "$R48" = ok ]; then
    _fd=$(cd /work/src/flex-t && onedir 'flex-* ./flex-*')
    # --disable-nls AND NO DOCS. flex's configure wants help2man for its man
    # page and texinfo for its manual; neither is in this box, and MAKEINFO=true
    # covers the second the way every other rung here does.
    # CC IN THE ENVIRONMENT, NOT ONLY ON THE COMMAND LINE.
    #
    # Run 85023417880 got this sequence out of flex's configure:
    #     checking for gcc... (cached) /work/prefix/bin/cc-static
    #     ...
    #     checking for gcc... no
    #     checking for cc... no
    #     checking for cl.exe... no
    #     configure: error: no acceptable C compiler found in $PATH
    # -- AC_PROG_CC ran twice, and the second time CC was empty. That is what
    # `config.status --recheck` does: it replays configure with the
    # ENVIRONMENT it was given and does NOT carry command-line assignments.
    # m4 never tripped it because nothing made m4 re-check.
    #
    # Exporting them satisfies both paths at once, and passing them as
    # arguments too costs nothing.
    # INSIDE THE SUBSHELL, so it does not outlive this rung. CC is a
    # load-bearing variable here: rungs 7 and up want the gcc that rung 6
    # built, and an exported CC pointing at cc-static would quietly override
    # them. configure, config.status and make all run within these parens, so
    # the export reaches everything that needs it and nothing that does not.
    # A `gcc` ON PATH, WHICH IS WHAT flex's configure IS ACTUALLY ASKING FOR.
    #
    # Exporting CC did not help, so the earlier reading -- that
    # `config.status --recheck` was dropping a command-line assignment -- was
    # wrong. Run 85030076718 repeats the same shape with CC exported:
    #
    #     checking for gcc... (cached) /work/prefix/bin/cc-static
    #     ...
    #     checking for gcc... no
    #     checking for cc... no
    #     checking for cl.exe... no
    #     configure: error: no acceptable C compiler found in $PATH
    #
    # AC_PROG_CC runs twice and the second search ignores $CC entirely and
    # looks for the NAMES on PATH. Which macro re-runs it is not established
    # here, and does not need to be: the fix is to make the name exist.
    #
    # THE REFERENCE ALREADY DOES THIS, at rungs.sh:3954, for perl:
    #
    #     ./Configure: ./UU/checkcc: line 10: gcc: not found
    #
    # with the reasoning worked out there too -- rung 6 installs its gcc into
    # /work/out/bin and rung 8 into /work/out2/bin, never $PFX/bin, so the
    # name is free and pointing it at the box's compiler means every path
    # reaches the same one.
    # IN A DIRECTORY THAT LIVES ONLY FOR THIS RUNG, not in $PFX/bin.
    #
    # The reference puts its `gcc` name straight into $PFX/bin, and can:
    # rung 11.5 runs AFTER the real compilers exist in /work/out and
    # /work/out2, so a `gcc` in the tools directory is unambiguous. This rung
    # is 4.8 -- rung 6 has not built anything yet, and a `gcc` on PATH from
    # here to the end of the script would answer for tcc every time something
    # later looked one up by name. A directory prepended to PATH inside the
    # subshell disappears with it.
    rm -rf /work/ccnames && mkdir -p /work/ccnames
    for _n in gcc cc; do
      ln -sf /work/prefix/bin/cc-static "/work/ccnames/$_n"
    done
    say "    gcc, cc -> cc-static, in /work/ccnames (this rung only)"
    ( cd "/work/src/flex-t/$_fd" \
      && PATH="/work/ccnames:$PATH" && export PATH \
      && CC="/work/prefix/bin/cc-static" && export CC \
      && LDFLAGS="-static" && export LDFLAGS \
      && M4=/work/prefix/bin/m4 && export M4 \
      && ./configure --prefix=/work/prefix --disable-nls --disable-shared \
           --build=riscv64-unknown-linux-gnu \
           CC="/work/prefix/bin/cc-static" LDFLAGS="-static" \
           M4=/work/prefix/bin/m4 > cfg.log 2>&1 \
      && timeout 2400 make -j"$NP" MAKEINFO=true help2man=true > b.log 2>&1 \
      && make install MAKEINFO=true help2man=true > /dev/null 2>&1 ) \
      || { R48=FAIL
           say "    flex NOT INSTALLED"
           tail -12 "/work/src/flex-t/$_fd/cfg.log" 2>/dev/null | sed 's/^/      /'
           tail -12 "/work/src/flex-t/$_fd/b.log" 2>/dev/null | sed 's/^/      /'; }
  fi
  if [ "$R48" = ok ]; then
    if [ -x /work/prefix/bin/flex ]; then
      say "    flex: $(/work/prefix/bin/flex --version 2>&1 | head -1)"
      # AND PROVE IT GENERATES, because installing is not the thing we need.
      printf '%%%%\n.  { return 1; }\n' > /tmp/probe.l
      if /work/prefix/bin/flex -o /tmp/probe.c /tmp/probe.l 2>/tmp/probe.err \
         && grep -q 'yylex' /tmp/probe.c; then
        say "    generates a lexer defining yylex ($(wc -l < /tmp/probe.c) lines)"
      else
        say "    flex ran but produced no yylex:"
        sed 's/^/      /' /tmp/probe.err 2>/dev/null | head -4
        R48=FAIL
      fi
    else
      say "    flex installed but /work/prefix/bin/flex is not there"; R48=FAIL
    fi
  fi
else
  say "    skipped: rung 4.7 did not finish"
fi

# ---------------------------------------------------------------------------
head1 "RUNG 5 -- gmp, mpfr, mpc.  gcc's arithmetic dependencies."
# Same three, same versions, same configure shape as
# spikes/stage4/chain/rung1.sh. If they build here and there, the overlap is
# real rather than nominal.
if [ "$R45" = ok ]; then
  # THESE CONFIGURE LINES ARE STAGE 4's, NOT MINE.
  #
  # spikes/stage4/chain/rung1.sh's header says "Every configure line here is
  # that job's, verbatim", and the same discipline has to hold in this
  # direction or the overlap is nominal. If this job configures gcc differently
  # from stage 4, then "reaches gcc 4.7.4" means two different things in the two
  # jobs and neither substitutes for the other. Copied from rung1.sh:124-138
  # and rung1.sh:144-166; the prefix is /work/prereq there and here.
  cd /work/src
  untar /in/gmp-   && mv "$(onedir 'gmp-* ./gmp-*')"   gmp
  untar /in/mpfr-  && mv "$(onedir 'mpfr-* ./mpfr-*')"  mpfr
  untar /in/mpc-   && mv "$(onedir 'mpc-* ./mpc-*')"   mpc
  mkdir -p /work/prereq
  r5=ok
  for pk in gmp mpfr mpc; do
    [ "$r5" = ok ] || break
    case "$pk" in
      gmp)  EXTRA="--disable-assembly" ;;
      mpfr) EXTRA="--with-gmp=/work/prereq" ;;
      mpc)  EXTRA="--with-gmp=/work/prereq --with-mpfr=/work/prereq" ;;
    esac
    ( cd "$pk" \
      && cfg_try "$pk" --disable-shared $EXTRA --prefix=/work/prereq \
      && timeout 1800 make -j"$NP" MAKEINFO=true > build.log 2>&1 \
      && make install MAKEINFO=true > /dev/null 2>&1 ) \
      || { r5=FAIL
           say "    $pk NOT INSTALLED"
           grep -nE "error:|Error [0-9]" "$pk/build.log" 2>/dev/null | head -8 | sed 's/^/      /'
           tail -12 "$pk/build.log" 2>/dev/null | sed 's/^/      /'; }
    [ "$r5" = ok ] && say "    $pk ok"
  done
  R5=$r5
  [ "$R5" = ok ] && say "    prereq/lib: $(ls /work/prereq/lib 2>/dev/null | tr '\n' ' ')"
  cd /work
fi

# ---------------------------------------------------------------------------
if stop_here 6; then
  say ""
  say "  === stopping after rung $STOP_AFTER, as asked ==="
else
head1 "RUNG 6 -- gcc 4.7.4.  THE OVERLAP WITH stage4-complete."
# The rung stage 4 already reaches with a host-gcc-built tcc, against host
# glibc and host binutils. Reaching it here -- from this box, with a libc, a
# make and a binutils all built inside it -- is what makes the two jobs one
# ladder.
if [ "$R5" = ok ]; then
  cd /work/src
  # STOCK gcc PLUS TWO DECLARED PATCHES, APPLIED HERE BY busybox.
  #
  # gcc 4.7.4 has no aarch64 backend of its own -- aarch64 arrived in 4.8, and
  # stock 4.7.4 reports `aarch64 mentions in config.gcc: 0`, so configure would
  # refuse the target outright. The delta comes in as two pinned inputs derived
  # in the airlock and applied in here with nothing but busybox:
  #
  #   gcc47-aarch64-newfiles.tar.gz   the aarch64 backend files 4.7.4 lacks
  #   gcc47-aarch64-changed.patch     the splices into files it already had
  #
  # SPLIT BECAUSE THE TWO HALVES WANT DIFFERENT TOOLS. busybox tar is proven in
  # this box -- it has already unpacked musl, make, binutils, gmp, mpfr, mpc
  # and gcc. Asking busybox patch to create 37 files from /dev/null instead
  # would lean on it far harder, for no benefit; the patch it does get is a
  # handful of files and is readable as a review artifact.
  # THE BOTTOM GCC HERE IS NOT 4.7.4 AND IS NOT A GNU TARBALL.
  #
  # gcc 4.7.4 has no RISC-V port; it reached gcc upstream in 7.1, five years
  # later, and 4.8 is already past what a C compiler can build. The tree
  # staged into /in by the workflow is Ekaitz Zarraga's backport of RISC-V
  # into a C-only gcc 4.6.4, at tag working-compiler-c++, UNPATCHED -- the
  # deltas arrive separately as riscv-bottom-gcc.patch and are applied below,
  # so they stay reviewable rather than hiding inside the tree.
  if ! untar /in/riscv-bottom-gcc; then
    say "    the riscv bottom gcc did not extract"; R6=FAIL
  fi
  g47=$(onedir 'gbot ./gbot')
  if [ -z "$g47" ]; then
    say "    no gbot directory after extraction"; R6=FAIL
  else
    say "    bottom gcc: $(cat "$g47/gcc/BASE-VER" 2>/dev/null || echo unknown)"

    # THE FLEX-GENERATED SOURCES, CHECKED BEFORE THEY ARE MISSED.
    #
    # gcc's build links build/gengtype from gengtype-lex.o, whose C source is
    # generated from gengtype-lex.l by flex. RELEASE TARBALLS SHIP THE
    # GENERATED .c; git trees do not, because it is a build product. This
    # target's bottom gcc is a GIT CLONE of Ekaitz's fork where the amd64 arm
    # untars a gnu.org release -- exactly the kind of difference that does not
    # announce itself.
    #
    # Run 85015824106 got configure rc=0, built genhooks and genmodes, and
    # then died four hundred lines later on
    #     tcc: error: undefined symbol 'lexer_line'
    #     tcc: error: undefined symbol 'yybegin'  'yylex'  'yyend'
    # -- the names flex emits. Saying it here, by name, costs one ls.
    for _gen in gcc/gengtype-lex.c gcc/gengtype-parse.c; do
      if [ -f "$g47/$_gen" ]; then
        say "    $_gen: $(wc -c < "$g47/$_gen") bytes"
      else
        say "    $_gen: ABSENT -- a generated file this tree does not carry."
        say "    Release tarballs ship it; git trees do not. Without flex in"
        say "    the box, whatever links against it fails on yylex."
      fi
    done
  fi

  if [ "$R6" != FAIL ]; then
    # grep -c PRINTS 0 AND EXITS 1 when there are no matches, so `|| echo 0`
    # appended a second zero and the log read "stock 4.7.4: 0\n0 aarch64
    # mentions". `|| true` keeps the count and drops the duplicate.
    say "    stock 4.7.4: $(grep -c aarch64 "$g47/gcc/config.gcc" 2>/dev/null || true) aarch64 mentions in config.gcc (expect 0)"

    # DECLARED SUBSTITUTION: libstdc++ MUST NOT ASSUME glibc's ctype INTERNALS.
    #
    #     bits/ctype_base.h:58: error: '_IScntrl' was not declared in this scope
    #     ... _ISpunct, _ISalpha, _ISdigit
    #
    # Those are values from glibc's INTERNAL ctype bitmask enum. libstdc++
    # reads them because configure.host chose os/gnu-linux for its OS config,
    # and it chose that because the target triple ends in -gnu:
    #
    #     gnu* | linux* | kfreebsd*-gnu | knetbsd*-gnu)
    #         os_include_dir="os/gnu-linux"
    #
    # gcc 4.7 PREDATES musl -- musl support landed in 4.9 -- so there is no
    # musl case to fall into and no triple we could pass that would find one.
    # os/generic is the configuration written for exactly this: a POSIX libc
    # that is not glibc. A modern gcc reaches it through a `linux-musl*` arm
    # that does not exist here yet.
    #
    # One sed, in the box, reported. Not folded into the aarch64 backport patch
    # because it is a different thing: that patch adds a CPU gcc never knew
    # about, this one corrects an assumption about the C library.
    if [ -f "$g47/libstdc++-v3/configure.host" ]; then
      _og=$(grep -c 'os_include_dir="os/gnu-linux"' "$g47/libstdc++-v3/configure.host" 2>/dev/null || true)
      sed -i 's|os_include_dir="os/gnu-linux"|os_include_dir="os/generic"|' \
        "$g47/libstdc++-v3/configure.host"
      _ge=$(grep -c 'os_include_dir="os/generic"' "$g47/libstdc++-v3/configure.host" 2>/dev/null || true)
      say "    libstdc++ os config: gnu-linux -> generic  ($_og replaced, $_ge generic entries now)"
    else
      say "    libstdc++-v3/configure.host not found -- cannot retarget the OS config"
    fi

    # THIS TARGET DOES NOT BACKPORT -- IT SWAPS THE BOTTOM GCC ENTIRELY.
    #
    # gcc 4.7.4 has no RISC-V port: RISC-V reached gcc upstream in 7.1, five
    # years later, and 4.8 is already past what a C compiler can build. So
    # there is nothing to transplant INTO. The bottom rung here is Ekaitz
    # Zarraga's NLnet-funded backport of RISC-V into a C-only gcc 4.6.4,
    # staged into /in by the workflow and unpacked as $g47 above.
    #
    # PATCHES FROM /in, NOT A PRE-PATCHED TREE, for the reason the reference
    # arm gives: "a patched tarball hides the delta inside an opaque blob and
    # there is nothing left to review."
    _nr=$(grep -ci riscv "$g47/gcc/config.gcc" 2>/dev/null || true)
    say "    bottom gcc: $(cat "$g47/gcc/BASE-VER" 2>/dev/null || echo unknown)"
    say "    $_nr riscv mentions in config.gcc (expect many -- that is the fork)"
    if [ "${_nr:-0}" -lt 1 ]; then
      say "    THIS TREE HAS NO RISCV BACKEND -- wrong source staged into /in"
      R6=FAIL
    fi
    if [ -f /in/riscv-bottom-gcc.patch ]; then
      say "    applying riscv-bottom-gcc.patch ($(wc -l < /in/riscv-bottom-gcc.patch) lines)"
      ( cd "$g47" && patch -p1 -i /in/riscv-bottom-gcc.patch ) > /tmp/bp.out 2>&1 \
        || { say "      PATCH FAILED:"; sed 's/^/        /' /tmp/bp.out | head -8; R6=FAIL; }
      _hw=$(grep -c 'define HOST_WIDE_INT_1' "$g47/gcc/hwint.h" 2>/dev/null || true)
      say "    HOST_WIDE_INT_1 definitions in hwint.h after patch: $_hw (expect 2)"
      [ "${_hw:-0}" -ge 2 ] || { say "    THE PATCH DID NOT LAND"; R6=FAIL; }
    else
      say "    /in/riscv-bottom-gcc.patch is missing"; R6=FAIL
    fi
  fi

  mkdir -p /work/bld && cd /work/bld
  # STAGE 4's configure_47, rung1.sh:144-166, VERBATIM.
  #
  # --enable-languages=c,c++ IS LOAD-BEARING and I had trimmed it to c. Stage
  # 4's own comment: "All of gcc 4.7 is C, INCLUDING cc1plus, which is the
  # whole reason 4.7 is the entry point: a C compiler yields a C++98 compiler."
  # Building only the C frontend would reach something called gcc 4.7.4 that is
  # not the rung stage 4 stands on.
  #
  # CFLAGS_FOR_TARGET / LDFLAGS_FOR_TARGET, ALSO FORCED BY THE BOX.
  #
  # gcc builds xgcc, then uses it to configure its TARGET libraries -- libgcc,
  # libmudflap, libstdc++. Those configures call xgcc directly, not through
  # cc-static, so nothing was making their link tests static, and:
  #
  #     ld: .eh_frame_hdr refers to overlapping FDEs.
  #     ld: final link failed: Bad value
  #     configure: error: C compiler cannot create executables
  #
  # then every later target configure inherited GCC_NO_EXECUTABLES and refused
  # to run link tests at all, which is what stopped libstdc++.
  #
  # CXXFLAGS_FOR_TARGET IS HERE FOR THE SAME REASON AND WAS MISSING.
  # The comment above names libstdc++ as what this fixed, but only the C flags
  # were set -- and libstdc++'s configure compiles its tests as C++. Run
  # 85004867327 cleared every earlier rung and stopped on
  #
  #     checking for the value of EOF... configure: error: computing EOF failed
  #
  # which is AC_COMPUTE_INT's RUN test: it builds a program that writes EOF to
  # conftest.val and executes it. Rung 3 already measured why that cannot work
  # unless linked statically -- "dynamic: does NOT run (expected: libc.a only,
  # no loader in the box)". A C++ conftest built without -static is a dynamic
  # binary in a box that has no loader.
  #
  # gcc emits --eh-frame-hdr for a DYNAMIC link and not for a static one, so
  # the section that is being rejected is only built on the path this box
  # cannot use anyway: there is no loader here, so a dynamic conftest could not
  # have run even if it linked. *_FOR_TARGET are the variables gcc passes down
  # to exactly those configures.
  #
  # WHETHER THE OVERLAP IS ALSO A REAL DEFECT IS STILL OPEN. musl's crt files
  # were assembled by tcc, and malformed .eh_frame in crti.o/crtn.o would
  # produce exactly this message. Going static sidesteps the section rather
  # than fixing it; if anything later needs a dynamic link, this comes back.
  #
  # AND AT RUNG 8 TOO, WHICH THE FIRST VERSION MISSED.
  #
  # Rung 8 builds the same gcc 4.7.4 again with the gcc tcc produced, so it
  # configures libgcc the same way and hits the same libbid. Adding the flag
  # only at rung 6 got run 85013789443 through rungs 6 and 7 and then straight
  # back into the ten FE_* errors at rung 8. Any flag that exists because of
  # what 4.7.4 assumes about its libc belongs on every 4.7.4 configure.
  #
  # --disable-libitm, BECAUSE ITS HEADERS ASSUME glibc.
  #
  # libitm is the transactional-memory runtime and was the only target
  # library not on this disable list. Run 85012267756:
  #
  #     libitm/config/linux/x86/tls.h:28:46: error: missing binary operator
  #         before token "("
  #
  # -- the signature of a function-like macro used in an #if and never
  # defined, which here is __GLIBC_PREREQ. musl does not have it.
  #
  # THE aarch64 ARM NEVER SEES IT: gcc 4.7's libitm ships configs for x86 and
  # a few others and none for aarch64, so it disables itself for an
  # unsupported target. Naming the flag makes both arms agree on purpose
  # rather than by accident.
  #
  # --disable-libmudflap, FORCED BY THE BOX AND COSTING NOTHING.
  #
  #     libmudflap/mf-runtime.c:2357:1: error: conflicting types for
  #                                            '__assert_fail'
  #
  # libmudflap redeclares glibc's __assert_fail, whose third parameter is
  # `unsigned int`; musl's is `int`. Stage 4 never sees it because its libc IS
  # glibc and the declarations agree.
  #
  # libmudflap is gcc 4.7's pointer-and-bounds debugging runtime -- a
  # -fmudflap option that was removed entirely in gcc 4.9. Nothing between here
  # and gcc 10 uses it, and stage 4 does not build anything with it. Disabling
  # is the whole fix; patching a declaration to match musl would be carrying a
  # delta for a feature that is deleted two releases later.
  #
  # --disable-nls IS NOT IN STAGE 4's LINE, AND IS FORCED BY THE BOX.
  #
  # Without it gcc builds its own bundled intl/ and stops at
  #
  #     intl/gettext.c:58: error: 'LC_MESSAGES' undeclared
  #
  # gcc's configure decides to build that copy when the libc's gettext does not
  # satisfy it. Stage 4 never sees this because its box has glibc, whose full
  # NLS support makes the bundled intl unnecessary; musl's is minimal, so gcc
  # falls back to its own and that copy does not compile here.
  #
  # This is the same category as -static and MAKEINFO=true: a difference the
  # box forces, not a drift from stage 4's recipe. It also matches what LFS
  # and live-bootstrap both do for an early toolchain -- neither wants message
  # catalogues from a compiler that exists to build the next compiler. binutils
  # above already carries it for the same reason.
  #
  # --with-sysroot is NOT here, and I had added it. With the libc installed at
  # /usr -- where this box's compiler already looks -- a sysroot is both
  # unnecessary and wrong: it would prefix every system path again.
  # CC="$CCAUTO", NOT "$CC". Stage 4's line is CC="$1" and its $1 is a tcc
  # against host glibc, which HAS a dynamic loader -- so its conftests run
  # either way and -static never came up. This box has libc.a and no loader, so
  # the same configure would stop at "cannot run C compiled programs" exactly
  # as make's did. The difference is forced by the box, not a drift from stage
  # 4's recipe.
  # A config.site FOR THE TARGET LIBRARY CONFIGURES, AND WHY IT IS NOT A HACK.
  #
  # libstdc++-v3's configure calls GLIBCXX_COMPUTE_STDIO_INTEGER_CONSTANTS
  # (libstdc++-v3/acinclude.m4, added by Paolo Carlini in July 2010). It sets
  # three cache variables with AC_COMPUTE_INT:
  #
  #     glibcxx_cv_stdio_eof        -> _GLIBCXX_STDIO_EOF
  #     glibcxx_cv_stdio_seek_cur   -> _GLIBCXX_STDIO_SEEK_CUR
  #     glibcxx_cv_stdio_seek_end   -> _GLIBCXX_STDIO_SEEK_END
  #
  # AC_COMPUTE_INT RUNS A PROGRAM when --build == --host, which this is. Run
  # 85007759919 got as far as
  #
  #     configure:19256: xgcc ... -o conftest -static  -static conftest.cpp
  #     configure:19259: error: computing EOF failed
  #
  # -- the link line is static, so CXXFLAGS_FOR_TARGET reached it, and the
  # failure is at the run or immediately after.
  #
  # --disable-hosted-libstdcxx WOULD NOT HELP: the `if test "$is_hosted" =
  # yes` guard around this whole block was added in GCC 12 (r12-6409,
  # "libstdc++: Fix and simplify freestanding configuration [PR103866]"). In
  # 4.7 the test runs unconditionally.
  #
  # THE VALUES ARE FIXED BY THE C STANDARD AND IDENTICAL IN musl FOR EVERY
  # ARCHITECTURE -- EOF is -1, SEEK_CUR is 1, SEEK_END is 2 -- so supplying
  # them is stating a known constant, not guessing at a measurement.
  # Autoconf's cache-variable mechanism exists for exactly this: GLib's own
  # cross-compiling documentation describes it as the way to give configure
  # what it cannot compute in a constrained environment.
  #
  # CONFIG_SITE RATHER THAN THE ENVIRONMENT, because the top-level Makefile
  # invokes each target library's configure itself and does not pass this
  # shell's variables through. Every configure autoconf runs reads $CONFIG_SITE.
  #
  # AND A CAVEAT WORTH KEEPING: if conftest genuinely cannot RUN, this only
  # moves the failure to the next libstdc++ test that runs a program, and
  # there are several. The `$? =` lines printed on failure say which case
  # this is -- 0 after the link and non-zero after ./conftest means runs are
  # broken and these three are a plaster.
  mkdir -p /work/site
    # THE HEREDOC BODY SITS AT COLUMN 0 AND MUST. An indented terminator
    # does not close a <<'X' heredoc, and every value inside would carry
    # its leading spaces into the cache variable.
  cat > /work/site/config.site <<'SITEEOF'
glibcxx_cv_stdio_eof=-1
glibcxx_cv_stdio_seek_cur=1
glibcxx_cv_stdio_seek_end=2
SITEEOF
  CONFIG_SITE=/work/site/config.site
  export CONFIG_SITE
  say "    CONFIG_SITE: EOF=-1 SEEK_CUR=1 SEEK_END=2 preseeded for target configures"

  "/work/src/$g47/configure" \
    CC="$CCAUTO" LDFLAGS="$LDF" \
    CFLAGS_FOR_TARGET="-static" CXXFLAGS_FOR_TARGET="-static" LDFLAGS_FOR_TARGET="-static" \
    --build=riscv64-unknown-linux-gnu \
    --host=riscv64-unknown-linux-gnu \
    --target=riscv64-unknown-linux-gnu \
    --prefix=/work/out --enable-languages=c,c++ \
    --disable-nls --disable-libmudflap \
    --disable-multilib --disable-bootstrap --disable-werror \
    --disable-libsanitizer --disable-libgomp --disable-libquadmath \
    --disable-libssp --disable-libatomic --disable-libitm --disable-shared \
    --with-gmp=/work/prereq --with-mpfr=/work/prereq --with-mpc=/work/prereq \
    > cfg.log 2>&1
  say "    configure rc=$?"
  # MAKEINFO=true BECAUSE texinfo IS ON STAGE 4's BORROW LIST AND NOT IN THIS
  # BOX. env0.sh borrows `texinfo`, so makeinfo is simply present there and gcc
  # builds its docs. Here it is absent, and gcc's make would stop on the info
  # targets having compiled the entire compiler -- a failure about
  # documentation that reads like a failure about the compiler.
  # WHAT xgcc WILL BE HANDED WHEN IT BUILDS libgcc.
  #
  # libgcc's configure runs the freshly built xgcc with
  #
  #     -B$PFX/riscv64-unknown-linux-gnu/bin/  -B.../lib/
  #     -isystem .../include  -isystem .../sys-include
  #
  # Those four directories are gcc's idea of "the target's toolchain and
  # headers". binutils here was configured WITHOUT --target, so it is a native
  # binutils and installed to $PFX/bin -- nothing was ever put under
  # $PFX/riscv64-unknown-linux-gnu/. Printing it before the build turns a
  # "cannot compute suffix of object files" forty minutes in into one line
  # here.
  say "    --- what xgcc will be given for the target ---"
  for _d in "$PFX/riscv64-unknown-linux-gnu/bin" "$PFX/riscv64-unknown-linux-gnu/lib" \
            "$PFX/riscv64-unknown-linux-gnu/include" "$PFX/riscv64-unknown-linux-gnu/sys-include"; do
    if [ -d "$_d" ]; then
      printf '      %-52s %s entries\n' "${_d#$PFX/}" "$(ls "$_d" 2>/dev/null | wc -l)"
    else
      printf '      %-52s MISSING\n' "${_d#$PFX/}"
    fi
  done
  printf '      %-52s %s\n' "as / ld reachable on PATH" \
    "$(command -v as >/dev/null 2>&1 && echo yes || echo NO) / $(command -v ld >/dev/null 2>&1 && echo yes || echo NO)"
  printf '      %-52s %s\n' "cc1 built" "$( [ -x gcc/cc1 ] && echo yes || echo not-yet )"
  # CAN xgcc LINK AT ALL, EITHER WAY? Asked BOTH ways so the answer separates
  # "dynamic is broken" from "linking is broken".
  #
  # NOTE THIS RUNS BEFORE make, so on a first pass xgcc does not exist yet and
  # the block is skipped -- which it did last run, silently. Saying so is worth
  # a line: an absent probe reads exactly like a passing one.
  if [ -x gcc/xgcc ]; then
    ( cd /tmp && rm -f xg.c xg.bin
      printf 'int main(void){return 0;}\n' > xg.c
      for _m in "" "-static"; do
        if "$OLDPWD/gcc/xgcc" -B"$OLDPWD/gcc/" $_m -o xg.bin xg.c 2>/tmp/xg.err; then
          printf '      %-52s ok\n' "xgcc link ${_m:-dynamic}"
        else
          printf '      %-52s FAILED\n' "xgcc link ${_m:-dynamic}"
          grep -aE "error|overlapping|Bad value" /tmp/xg.err | head -2 | sed 's/^/        /'
        fi
      done
      rm -f xg.c xg.bin )
  else
    printf '      %-52s %s\n' "xgcc link probe" "skipped -- xgcc not built yet"
  fi

  # THE ONE THAT ACTUALLY FAILED LAST TIME. Existing is not enough; libgcc's
  # configure execs it, and it answered "Permission denied".
  if "$PFX/riscv64-unknown-linux-gnu/bin/as" --version >/dev/null 2>&1; then
    printf '      %-52s %s\n' "tooldir as EXECUTES" yes
  else
    printf '      %-52s %s\n' "tooldir as EXECUTES" "NO -- libgcc will fail"
  fi

  if [ "$R6" != FAIL ] && timeout 5400 make -j"$NP" MAKEINFO=true > build.log 2>&1; then
    say "    xgcc:    $( [ -x gcc/xgcc ] && wc -c < gcc/xgcc || echo ABSENT )"
    say "    cc1:     $( [ -x gcc/cc1 ]  && wc -c < gcc/cc1  || echo ABSENT )"
    say "    cc1plus: $( [ -x gcc/cc1plus ] && wc -c < gcc/cc1plus || echo ABSENT )"

    # AND INSTALL IT, which the first version of this rung did not do.
    #
    # `make` alone leaves the compiler as /work/bld/gcc/xgcc and nothing else.
    # Rung 7 then reported "no gcc at /work/prefix/bin/gcc -- rung 6 installed
    # nothing", which was exactly right: a built compiler is not an installed
    # one, and `R6=ok` was asserting the wrong thing. Stage 4's stage 1 ends by
    # reporting `out/bin/g++ : present`, which is the check that matters.
    #
    # PREFIX IS /work/out, NOT $PFX. $PFX holds binutils and make -- the tools
    # this box built to get here. Stage 4 keeps each compiler in its own tree:
    # out for stage 1, out2 for stage 2, out10 for gcc 10. Installing gcc over
    # the tools would make "which gcc built this" unanswerable the moment there
    # are two of them.
    make install MAKEINFO=true > install.log 2>&1
    say "    install rc=$?"
    say "    --- what stage 1 produced ---"
    for b in gcc g++ cpp; do
      printf '      %-8s %s\n' "$b" \
        "$( [ -x /work/out/bin/$b ] && echo present || echo missing )"
    done
    if [ -x /work/out/bin/gcc ] && [ -x /work/out/bin/g++ ]; then
      R6=ok
      /work/out/bin/gcc --version 2>&1 | head -1 | sed 's/^/      /'
    else
      R6=FAIL
      say "    installed no gcc/g++ -- install tail:"
      tail -12 install.log 2>/dev/null | sed 's/^/      /'
    fi
  else
    R6=FAIL
    # THE REASON IS IN THE SUB-CONFIGURE'S config.log, NOT IN build.log.
    #
    # gcc builds xgcc and then uses it to configure libgcc, libstdc++ and the
    # rest. When one of those stops at "cannot compute suffix of object files:
    # cannot compile", build.log carries only that sentence -- the failing
    # command and its error are in that subdirectory's own config.log, which
    # nothing has been printing.
    say "    --- every config.log under /work/bld, newest first ---"
    find /work/bld -name config.log -newer /work/bld/Makefile 2>/dev/null \
      | sed 's|/work/bld/||; s|/config.log||' | sed 's/^/      /'
    for _cl in $(find /work/bld -name config.log -newer /work/bld/Makefile 2>/dev/null); do
      _d=$(dirname "$_cl")
      # THE FILTER SKIPPED THE ONE LOG THAT MATTERED. autoconf writes its
      # own fatal line as "configure: error: ..." and grep -q "error:" does
      # match that -- but libstdc++-v3's config.log records the failure as
      # "configure: error: computing EOF failed" only in the terminal output,
      # not necessarily in a line this pattern reaches first. Run 85003591221
      # printed six config.logs and libstdc++-v3's was not among them, so the
      # test that actually failed was never shown. Widened, and the failing
      # subdirectory is named unconditionally below.
      grep -qE "error|failed|cannot" "$_cl" 2>/dev/null || continue
      say "    --- $_d/config.log ---"
      # PRINT THE LINES AROUND THE FAILURE, NOT EVERY ERROR IN THE FILE.
      #
      # Grepping the whole config.log for "error" surfaces autoconf's own
      # harmless probes -- `-V`, `-qversion`, a deliberate `choke me` -- and
      # buries the one message that matters. config.log is chronological: the
      # failing conftest command, then the compiler's output, then
      # "configure: error:". So find that last line and print what precedes it.
      _ln=$(grep -n "^configure:[0-9]*: error:" "$_cl" 2>/dev/null | head -1 | cut -d: -f1)
      if [ -n "$_ln" ]; then
        _from=$((_ln - 30)); [ "$_from" -lt 1 ] && _from=1
        sed -n "${_from},${_ln}p" "$_cl" 2>/dev/null | sed 's/^/          /'
        # AND THE CONFTEST COMMANDS BY NAME, because in a window this
        # size they are easy to lose among the source.
        # THE TWO LINES THAT SAY WHETHER IT LINKED OR WHETHER IT RAN.
        # config.log writes `$? = N` after every command, and for a RUN test
        # (AC_COMPUTE_INT computes EOF by executing a program) those two
        # statuses are the whole answer. They sit hundreds of lines above the
        # error, past the echo of confdefs.h, so no readable window reaches
        # them -- three attempts at widening one proved that.
        # SIX LINES BEFORE EACH *FAILING* COMMAND, NOT THE STATUS ALONE.
        #
        # The status by itself answered one question and raised the next. Run
        # 85010387663 gave
        #     configure:19256: $? = 1
        #     configure: program exited with status 1
        # and 19256 is the LINK line -- so the program never ran, the link
        # failed. But the linker's own output sits BETWEEN the command and its
        # status, and printing the status alone threw it away. -B6 catches the
        # command, the error and the verdict together.
        grep -n -B6 -E "^configure:[0-9]+: \\$\\? = [1-9]" "$_cl" 2>/dev/null \
          | tail -24 | sed 's/^/          /'
        # AND THE FATAL LINE WITH ITS OWN CONTEXT, SEPARATELY.
        #
        # The failing-status grep above keeps the LAST two dozen, and a
        # configure log is mostly negative feature tests -- "does the
        # assembler support .uleb128", no, recorded, carry on. Run
        # 85015824106 filled that window with exactly those and pushed the
        # one line that stopped the build off the top:
        #
        #     configure:8578: error: in `/work/bld/gcc':
        #
        # 8578 is early; 21844 and 26353 are late and harmless. The fatal
        # marker is `configure:N: error:` at the start of a line, and it
        # deserves its own look rather than a place in a queue ordered by
        # position.
        say "    --- the line that stopped it, in $_d ---"
        grep -n -B8 -E "^configure:[0-9]+: error:" "$_cl" 2>/dev/null \
          | grep -avE "^[0-9]+-\\| " | tail -14 | sed 's/^/          /'
        say "    --- conftest commands in $_d ---"
        grep -nE "^configure:[0-9]+: .*(gcc|g\+\+|xgcc|xg\+\+|cc-static)" "$_cl" 2>/dev/null \
          | tail -6 | sed 's/^/          /'
      else
        tail -25 "$_cl" 2>/dev/null | sed 's/^/          /'
      fi
    done
    say "    --- where it stopped ---"
    grep -nE "error:|internal compiler error|undefined reference" build.log 2>/dev/null \
      | grep -v 'make\[' | head -20 | sed 's/^/      /'
    grep -oE '^[^ :]+\.(c|h):[0-9]+:[0-9]*:? *error:' build.log 2>/dev/null \
      | cut -d: -f1 | sort | uniq -c | sort -rn | head -10 | sed 's/^/      /'
    tail -20 build.log 2>/dev/null | sed 's/^/      /'

    # AN ICE NAMES ITS OWN SOURCE LINE. PRINT IT.
    #
    # gcc aborts with `internal compiler error: in FUNC, at FILE:LINE`, and
    # FILE:LINE is a line of the tree WE BUILT -- 4.7.4 plus the aarch64
    # backport -- which is sitting under /work/src right here. Reading it
    # looked like it needed a donor tarball fetched from outside only because
    # nothing ever printed it.
    #
    # This matters more than usual for the rung 6 ICE, which reports
    #     internal compiler error: in ?, at config/riscv64/aarch64-builtins.c:944
    # `?` is what fancy_abort substitutes when its __FUNCTION__ argument is
    # NULL, so the one field that would name the failing path is itself
    # missing -- plausibly a second defect in the gcc mc-tcc built. The source
    # window is the way round it: the enclosing function is visible in the
    # text even when the binary could not name it.
    #
    # Searched for rather than hardcoded, so it keeps working when the line
    # moves or a different ICE appears.
    # SEARCH THE config.log FILES TOO, NOT JUST build.log.
    #
    # The first version looked only in build.log and matched only the
    # `in FUNC, at FILE:LINE` form. Both halves were wrong for this failure:
    #
    #   build.log            <built-in>:0:0: internal compiler error:
    #                        Segmentation fault          -- no FILE:LINE at all
    #   libgcc/config.log    <built-in>:0:0: internal compiler error:
    #                        in ?, at config/riscv64/aarch64-builtins.c:944
    #
    # so the one message carrying a source location was in a file this never
    # opened, and the window printed nothing. Both are the same fault -- xgcc
    # dying at <built-in>:0:0 on empty input, before a line of real source is
    # read -- but only one of them names a line.
    _ice=$( { grep -hoE 'internal compiler error: in [^,]*, at [^ :]+:[0-9]+' build.log 2>/dev/null
              find /work/bld -name config.log -exec grep -hoE 'internal compiler error: in [^,]*, at [^ :]+:[0-9]+' {} + 2>/dev/null
            } | head -1 )
    if [ -n "$_ice" ]; then
      _if=$(printf '%s' "$_ice" | sed 's/.* at \([^ :]*\):[0-9]*$/\1/')
      _il=$(printf '%s' "$_ice" | sed 's/.*:\([0-9]*\)$/\1/')
      say "    --- the ICE names $_if:$_il -- here it is, from OUR tree ---"
      _src=$(find /work/src -path "*/$_if" -type f 2>/dev/null | head -1)
      if [ -n "$_src" ]; then
        _a=$((_il - 25)); [ "$_a" -lt 1 ] && _a=1
        _b=$((_il + 8))
        sed -n "${_a},${_b}p" "$_src" 2>/dev/null \
          | awk -v n="$_a" -v hit="$_il" '{ printf "      %s%5d  %s\n", (n==hit ? ">>" : "  "), n, $0; n++ }'
        say "    --- the enclosing function, which \`in ?\` did not name ---"
        awk -v hit="$_il" 'NR<=hit && /^[A-Za-z_].*\(/ { l=NR": "$0 } END { print "      " l }' \
          "$_src" 2>/dev/null
      else
        say "      $_if not found under /work/src"
      fi
    fi

    # THE SMALLEST FAILING INVOCATION, RUN AGAIN ON PURPOSE.
    #
    # build.log shows xgcc dying on
    #     echo | xgcc -B... -E -dM -
    # which is EMPTY INPUT, preprocess-only, dump macros. No source, no
    # codegen, no libgcc -- so whatever is broken is broken before gcc reads
    # anything. That is a much smaller thing to debug than "gcc miscompiles
    # libgcc", and it costs one command to confirm rather than inferring it
    # from a build log.
    _xg=/work/bld/gcc/xgcc
    if [ -x "$_xg" ]; then
      say "    --- the smallest failing xgcc invocation ---"
      say "      echo | xgcc -E -dM -   (empty input, no codegen)"
      echo | "$_xg" -B/work/bld/gcc/ -E -dM - > /tmp/dM.out 2>/tmp/dM.err
      say "      rc=$?  stdout=$(wc -l < /tmp/dM.out) lines"
      head -3 /tmp/dM.err 2>/dev/null | sed 's/^/        /'
      say "      and with -v, to see how far it gets:"
      echo | "$_xg" -B/work/bld/gcc/ -v -E -dM - > /dev/null 2>/tmp/dMv.err
      tail -12 /tmp/dMv.err 2>/dev/null | sed 's/^/        /'
    fi
  fi
  cd /work
fi

fi

# ---------------------------------------------------------------------------
if stop_here 7; then
  say ""
  say "  === stopping after rung $STOP_AFTER, as asked ==="
else
head1 "RUNG 7 -- gmp/mpfr/mpc REBUILT by the gcc we just made"
# tcc-BUILT LIBRARIES ARE NOT USABLE BY gcc, AND STAGE 4 ALREADY PROVED IT.
#
# Its stage-2 preflight runs the exact check gcc's configure runs, against the
# gmp/mpfr/mpc that tcc built, in a box that has glibc:
#
#     against prefix/ (built by TCC): rc=1  NO BINARY
#         undefined reference to `alloca'
#         /usr/bin/ld: .eh_frame_hdr refers to overlapping FDEs
#         final link failed: bad value
#
# Two faults, both in tcc's output rather than in the libraries. `alloca` is
# emitted as a call tcc never resolves, and the .eh_frame tcc writes overlaps.
# THAT SECOND ONE IS THE ERROR RUNG 6 HIT, and seeing it here corrects a guess
# in this job's README: it is not musl's crt files, because stage 4 has glibc
# and hits it anyway. It is tcc-produced objects.
#
# Rung 6 went static to avoid --eh-frame-hdr, which got gcc built. It does not
# make the tcc-built archives sound, and gcc 10 will link against them for
# real. So they are rebuilt with a compiler that does not have the defect --
# which is exactly what stage 4 does at every rung: "prerequisites, rebuilt by
# the tcc-built gcc", then again "rebuilt by the stage-2 gcc".
if [ "$R6" = ok ]; then
  GCC1=/work/out/bin/gcc
  if [ ! -x "$GCC1" ]; then
    say "    no gcc at $GCC1 -- rung 6 built one but installed nothing"
    R7=FAIL
  else
    say "    builder: $("$GCC1" --version 2>&1 | head -1)"
    say "    (this is the gcc tcc built; there is no host gcc in this box)"

    # PREFLIGHT, VERBATIM FROM STAGE 4: can the new gcc link at all, and can it
    # link the tcc-built prerequisites? The second is expected to FAIL and is
    # run anyway -- a failure here is the measurement, not an accident.
    say "    --- preflight 1: can the tcc-built gcc link anything? ---"
    ( cd /tmp && rm -f p1.c p1.bin
      printf 'int main(void){return 42;}\n' > p1.c
      "$GCC1" -static -o p1.bin p1.c 2>/tmp/p1.err
      say "      compile+link rc=$?"
      ./p1.bin; say "      ran: exit=$? (expect 42)"
      rm -f p1.c p1.bin )

    # AND A PROGRAM THAT DOES SOMETHING, because `return 42` proves almost
    # nothing about a compiler.
    #
    # Run 85034305609 passed preflight 1, then gmp's own generators -- built
    # by this gcc, from gmp's C -- died the moment they ran:
    #     ./gen-fac 64 0 >fac_table.h
    #     Segmentation fault
    #     ./gen-sieve 64 >sieve_table.h
    #     Segmentation fault
    # Compilation and linking are fine; execution is not, and a `main` that
    # returns a constant exercises neither the stack, nor printf, nor any
    # library call, nor the soft-float helpers.
    #
    # THE SOFT-FLOAT HELPERS ARE THE FIRST SUSPECT AND THIS NAMES THEM.
    # Rung 4.6 merged 19 of them out of libtcc1.a into libc.a because
    # tcc-compiled musl called them. Those objects are TCC's, and RISC-V's
    # long double is binary128 -- if tcc and gcc disagree about how a 128-bit
    # float is passed, a gcc-compiled caller reaching a tcc-compiled helper is
    # exactly the kind of fault that links cleanly and crashes at run time.
    # gcc's own libgcc should define them too, and whichever the linker
    # reaches first wins.
    #
    # Each line prints BEFORE the thing it tests, so a crash names the
    # construct rather than leaving a bare "Segmentation fault" against a
    # whole program.
    #
    # C89 DECLARATIONS, BECAUSE THIS COMPILER IS gcc 4.6.4 AND DEFAULTS TO
    # gnu89. The first version wrote `for (int i = 0; ...)` and run
    # 85043627188 refused it:
    #     p1b.c:21: error: 'for' loop initial declarations are only allowed
    #                      in C99 mode
    # A preflight that will not compile tests nothing, and it hid the very
    # question it was added to answer. Declaring the counter up front costs
    # nothing and keeps the program buildable by the oldest compiler in the
    # chain -- which is the compiler under test here.
    ( cd /tmp && rm -f p1b.c p1b.bin
      cat > p1b.c <<'P1BEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void)
{
    /* ALL DECLARATIONS FIRST, because gcc 4.6.4 defaults to gnu89 and
       rejected `for (int i = ...)` outright. Verified against gnu89 rather
       than assumed: this compiles clean and runs. It is not strict C90 --
       `long long` is a gnu89 extension -- and it does not need to be; gnu89
       is the mode the compiler under test actually uses. */
    char buf[64];
    void *p;
    double d;
    long double L;
    long long n;
    int i;

    printf("      stdio ok\n");
    memset(buf, 0, sizeof buf);
    snprintf(buf, sizeof buf, "%d", 12345);
    printf("      snprintf ok (%s)\n", buf);
    p = malloc(4096);
    if (!p) { printf("      malloc FAILED\n"); return 1; }
    memset(p, 0xa5, 4096);
    free(p);
    printf("      malloc/memset/free ok\n");
    d = 1.5;
    printf("      double ok (%f)\n", d * 2.0);
    L = 1.5L;
    printf("      long double ok (%Lf)\n", L * 2.0L);
    n = 1;
    for (i = 0; i < 40; i++) n *= 2;
    printf("      64-bit arith ok (%lld)\n", n);
    return 0;
}
P1BEOF
      # BOTH LANGUAGE MODES, BECAUSE THAT IS THE ONE VARIABLE LEFT.
      #
      # Run 85049598425 ran every line of this program under the default mode
      # -- stdio, malloc, double, LONG DOUBLE, 64-bit arithmetic, exit 0 --
      # and gmp's generators segfaulted anyway. So the soft-float helpers
      # rung 4.6 merged are not the fault, and neither is anything else this
      # program touches.
      #
      # What gmp does differently is visible in its own command line:
      #     gcc -static -std=gnu99 gen-fac.c -o gen-fac
      # gcc 4.6.4 defaults to gnu89. -std=gnu99 changes inline semantics and
      # a good deal else, and it is the only difference between a program
      # that runs here and one that crashes there.
      #
      # If the gnu99 build crashes and the default one does not, the fault is
      # in this compiler's C99 mode and the next question is which construct.
      # If both run, the fault is in gmp's source rather than in the language
      # mode, and this rules out a whole direction cheaply.
      for _std in "" "-std=gnu99"; do
        _lbl="${_std:-default (gnu89)}"
        if "$GCC1" -static $_std -o p1b.bin p1b.c 2>/tmp/p1b.err; then
          say "      --- built with $_lbl ---"
          ./p1b.bin > /tmp/p1b.out 2>&1
          _rc=$?
          sed 's/^/  /' /tmp/p1b.out
          say "      exit=$_rc (expect 0)"
        else
          say "      $_lbl did not compile:"
          head -6 /tmp/p1b.err | sed 's/^/        /'
        fi
      done
      rm -f p1b.c p1b.bin )

    say "    --- preflight 2: the tcc-built gmp/mpfr/mpc, as configure checks them ---"
    ( cd /tmp && rm -f p2.c p2.bin
      printf '#include <mpc.h>\nint main(void){ mpc_t x; mpc_init2(x, 53); return 0; }\n' > p2.c
      if "$GCC1" -static -o p2.bin p2.c -I/work/prereq/include -L/work/prereq/lib \
           -lmpc -lmpfr -lgmp 2>/tmp/p2.err; then
        say "      against /work/prereq (built by tcc): LINKS"
        say "      (stage 4 gets NO BINARY here -- undefined alloca and"
        say "       overlapping FDEs. Everything in this box is static, so"
        say "       --eh-frame-hdr is never emitted and that link succeeds."
        say "       Rebuilding below anyway: linking once is not evidence the"
        say "       archives are sound, and gcc 10 will use them for real.)"
      else
        say "      against /work/prereq (built by tcc): NO BINARY -- as expected"
        grep -aE "undefined reference|eh_frame|final link" /tmp/p2.err 2>/dev/null \
          | head -5 | sed 's/^/        /'
      fi
      rm -f p2.c p2.bin )

    say "    --- prerequisites, rebuilt by the tcc-built gcc ---"
    mkdir -p /work/prereq2
    r7=ok
    for pk in gmp mpfr mpc; do
      [ "$r7" = ok ] || break
      case "$pk" in
        gmp)  EXTRA="--disable-assembly" ;;
        mpfr) EXTRA="--with-gmp=/work/prereq2" ;;
        mpc)  EXTRA="--with-gmp=/work/prereq2 --with-mpfr=/work/prereq2" ;;
      esac
      # FRESH TREE, NOT `make distclean`. Stage 4's reason, verbatim: "Fresh
      # trees from the tarballs, so no object built by a different compiler
      # survives into an archive this rung attributes to stage 2's gcc."
      # USE THE HELPER. This was `tar xf ...` and got "tar: invalid tar magic",
      # because /in still holds COMPRESSED pins -- gmp is .tar.xz -- and
      # busybox does not autodetect. untar picks the flag from the extension
      # and has been doing it correctly for eight rungs; reaching past it for a
      # raw tar was reintroducing a bug this job already fixed twice.
      # TRY gmp's OWN -O2, THEN -O0, AND SAY WHICH WORKED.
      #
      # Two preflights have now cleared this compiler of everything they can
      # reach. Run 85049598425: stdio, malloc, double, LONG DOUBLE, 64-bit
      # arithmetic, all fine -- so the soft-float helpers rung 4.6 merged into
      # libc.a are not the fault. Run 85054319715: the same program built BOTH
      # in the default gnu89 and in -std=gnu99, both exit 0 -- so the language
      # mode gmp uses is not the fault either.
      #
      # What still fails is gmp's own generators:
      #     ./gen-fac 64 0 >fac_table.h
      #     Segmentation fault
      #     ./gen-sieve 64 >sieve_table.h
      #     Segmentation fault
      # Both #include dumbmp.c, gmp's minimal bignum used only while
      # bootstrapping, and gmp's configure compiles them at the -O2 it picks
      # for gcc. Nothing the preflights reach looks like that code.
      #
      # SO CHANGE ONE THING. If -O0 builds what -O2 could not, the finding is
      # precise: the gcc tcc built miscompiles at -O2 on this target -- which
      # is exactly what rung 8 exists for, since "the first carries whatever
      # tcc got wrong". If -O0 fails too, the optimiser is not the fault and
      # this rules the direction out for a few minutes of build time.
      #
      # A SLOW gmp COSTS NOTHING HERE. These archives exist to build gcc 4.7.4
      # at rung 8, and rung 9 rebuilds them again with that compiler.
      _built=
      for _opt in "" "-O0"; do
        [ -n "$_built" ] && break
        _tag="${_opt:-gmp's own -O2}"
        rm -rf "/work/src/$pk-g1" && mkdir -p "/work/src/$pk-g1"
        ( cd "/work/src/$pk-g1" && untar "/in/$pk-" ) \
          || { say "      $pk did not extract"; break; }
        _pd=$(cd "/work/src/$pk-g1" && onedir "$pk-* ./$pk-*")
        if ( cd "/work/src/$pk-g1/$_pd" \
             && ./configure CC="$GCC1 -static" ${_opt:+CFLAGS="$_opt"} \
               --disable-shared $EXTRA \
               --prefix=/work/prereq2 > cfg2.log 2>&1 \
             && timeout 1800 make -j"$NP" MAKEINFO=true > build2.log 2>&1 \
             && make install MAKEINFO=true > /dev/null 2>&1 ); then
          _built="$_tag"
        else
          say "      $pk did NOT build with $_tag"
          grep -aE "Segmentation|Error [0-9]|error:" \
            "/work/src/$pk-g1/$_pd/build2.log" 2>/dev/null | head -6 | sed 's/^/        /'
        fi
      done
      if [ -n "$_built" ]; then
        say "      $pk INSTALLED (built with $_built)"
      else
        r7=FAIL
        say "      $pk NOT INSTALLED at any optimisation level"
      fi
    done
    R7=$r7
    [ "$R7" = ok ] && say "    prereq2/lib: $(ls /work/prereq2/lib 2>/dev/null | tr '\n' ' ')"
  fi
  cd /work
fi

fi

# ---------------------------------------------------------------------------
if stop_here 8; then
  say ""
  say "  === stopping after rung $STOP_AFTER, as asked ==="
else
head1 "RUNG 8 -- gcc 4.7.4 AGAIN, built by the gcc tcc built"
# THE SECOND 4.7.4 IS NOT REDUNDANT. Stage 4's own diagram:
#
#     tcc -> gcc 4.7.4 (c,c++) -> gcc 4.7.4 again -> gcc 10.2.0
#            stage 1              stage 2            stage 3
#
# The first 4.7.4 is built by tcc and carries whatever tcc got wrong -- the
# preflight above shows what that looks like in a library. The second is built
# by the first, with a compiler that does not have those defects, and it is the
# one anything above depends on. Nothing from here up involves tcc directly.
#
# 4.7 is the last gcc written in C, which is why tcc can reach it at all; its
# C++ front end is built FROM that C, and the g++ that yields is what carries
# the chain upward.
if [ "$R7" = ok ]; then
  mkdir -p /work/bld2 && cd /work/bld2
  say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: gcc 4.7.4 configure, builder=$GCC1"
  "/work/src/$g47/configure" \
    CC="$GCC1 -static" CXX="/work/out/bin/g++ -static" \
    --build=riscv64-unknown-linux-gnu \
    --host=riscv64-unknown-linux-gnu \
    --target=riscv64-unknown-linux-gnu \
    --prefix=/work/out2 --enable-languages=c,c++ \
    --disable-nls --disable-libmudflap \
    --disable-multilib --disable-bootstrap --disable-werror \
    --disable-libsanitizer --disable-libgomp --disable-libquadmath \
    --disable-libssp --disable-libatomic --disable-libitm --disable-shared \
    --disable-decimal-float \
    CFLAGS_FOR_TARGET="-static" CXXFLAGS_FOR_TARGET="-static" LDFLAGS_FOR_TARGET="-static" \
    --with-gmp=/work/prereq2 --with-mpfr=/work/prereq2 --with-mpc=/work/prereq2 \
    > cfg.log 2>&1
  _c8=$?
  say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_c8)"
  if [ "$_c8" != 0 ]; then
    R8=FAIL
    tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
  elif timeout 5400 make -j"$NP" MAKEINFO=true > build.log 2>&1 \
       && make install MAKEINFO=true > /dev/null 2>&1; then
    R8=ok
    say "    --- what stage 2 produced ---"
    for b in gcc g++ cpp; do
      printf '      %-8s %s\n' "$b" "$( [ -x /work/out2/bin/$b ] && echo present || echo ABSENT )"
    done
    /work/out2/bin/gcc --version 2>&1 | head -1 | sed 's/^/      /'
  else
    R8=FAIL; say "    --- where it stopped ---"
    grep -nE "error:|Error [0-9]|internal compiler error" build.log 2>/dev/null \
      | grep -v 'make\[' | head -15 | sed 's/^/      /'
    tail -20 build.log 2>/dev/null | sed 's/^/      /'
  fi
  cd /work
fi

fi

# ---------------------------------------------------------------------------
if stop_here 9; then
  say ""
  say "  === stopping after rung $STOP_AFTER, as asked ==="
else
head1 "RUNG 9 -- gcc 10.2.0, built by g++ (GCC) 4.7.4"
# THIS IS WHAT THE WHOLE 4.7 DETOUR WAS FOR.
#
# 4.7 is the last gcc written in C, which is why tcc can reach it. Its C++ front
# end is built from that C, and THAT g++ is what carries the chain upward --
# every gcc after 4.7 is C++ and cannot be built by a C compiler at all.
#
#     tcc --C--> gcc 4.7.4 --C--> gcc 4.7.4 --C++--> gcc 10.2.0
#
# --disable-bootstrap is what makes this a MEASUREMENT of our g++ rather than
# of a modern one: with bootstrap enabled gcc would rebuild itself with itself
# twice and the result would say nothing about the compiler that started it.
# Stage 4 says the same thing in the same place.
#
# PREREQUISITES REBUILT A THIRD TIME, by the compiler about to use them, from
# fresh tarballs. Rung 7 proved why once; this is the same rule applied again
# rather than an assumption that prereq2 is good enough.
#
# --disable-libvtv IS NEW HERE -- gcc 10 has it and 4.7 does not.
#
# WHAT WE DO NOT NEED THAT STAGE 4 DOES: it exports
# LD_LIBRARY_PATH=/work/out2/lib64 because its gcc 10 binaries are linked
# against out2's libstdc++.so and the build then RUNS them. Everything in this
# box is --disable-shared and -static, so there is no .so to find. That is one
# failure mode this arm cannot have.
if [ "$R8" = ok ]; then
  GCC2=/work/out2/bin/gcc
  GXX2=/work/out2/bin/g++
  if [ ! -x "$GXX2" ]; then
    say "    no stage-2 g++ at $GXX2"
    R9=FAIL
  else
    say "    builder: $("$GXX2" --version 2>&1 | head -1)"
    say "    (descended from tcc; there is no host compiler in this box)"
    export LD_LIBRARY_PATH=/work/out2/lib64:/work/out2/lib

    say "    --- prerequisites, rebuilt by the stage-2 gcc ---"
    mkdir -p /work/prereq3
    r9=ok
    for pk in gmp mpfr mpc; do
      [ "$r9" = ok ] || break
      case "$pk" in
        gmp)  EXTRA="--disable-assembly" ;;
        *)    EXTRA="--with-gmp=/work/prereq3" ;;
      esac
      [ "$pk" = mpc ] && EXTRA="--with-gmp=/work/prereq3 --with-mpfr=/work/prereq3"
      rm -rf "/work/src/$pk-g2" && mkdir -p "/work/src/$pk-g2"
      ( cd "/work/src/$pk-g2" && untar "/in/$pk-" ) || { r9=FAIL; say "      $pk did not extract"; break; }
      _pd2=$(cd "/work/src/$pk-g2" && onedir "$pk-* ./$pk-*")
      ( cd "/work/src/$pk-g2/$_pd2" \
        && ./configure CC="$GCC2 -static" --disable-shared $EXTRA \
             --prefix=/work/prereq3 > cfg3.log 2>&1 \
        && timeout 1800 make -j"$NP" MAKEINFO=true > build3.log 2>&1 \
        && make install MAKEINFO=true > /dev/null 2>&1 ) \
        || { r9=FAIL
             say "      $pk NOT INSTALLED"
             tail -12 "/work/src/$pk-g2/$_pd2/build3.log" 2>/dev/null | sed 's/^/        /'; }
      [ "$r9" = ok ] && say "      $pk INSTALLED"
    done

    if [ "$r9" = ok ]; then
      # cd FIRST. Rung 8 ends at /work, so this extracted gcc 10 into /work
      # while every path below assumed /work/src -- the tar reported rc=0 and
      # the sed on configure.host even worked, because that was resolved
      # relative to the same wrong directory. Only the configure call, which
      # spells the path out, disagreed:
      #
      #     tar -Jxf /in/gcc-10.2.0.tar.xz   (cwd: /work)
      #     /work/src/gcc-10.2.0/configure: not found
      #
      # The `(cwd: ...)` line the JOE markers print is what made that one line
      # of reading rather than a round.
      cd /work/src
      if ! untar /in/gcc-10; then
        say "    gcc 10 did not extract"; r9=FAIL
      else
        g10=$(onedir 'gcc-10* ./gcc-10*')
        say "    tree: /work/src/$g10"
        # SAME libstdc++ RETARGET AS 4.7. gcc 10 DOES know musl -- but only
        # through a `linux-musl*` arm, and this triple says -gnu, so it picks
        # os/gnu-linux and reaches for glibc's internal ctype enum exactly as
        # 4.7 did. Switching the triple would be the cleaner fix and needs
        # config.sub to accept linux-musl; until that is checked, one sed.
        if [ -f "/work/src/$g10/libstdc++-v3/configure.host" ]; then
          sed -i 's|os_include_dir="os/gnu-linux"|os_include_dir="os/generic"|' \
            "/work/src/$g10/libstdc++-v3/configure.host"
          say "    libstdc++ os config: gnu-linux -> generic"
        else
          say "    NO libstdc++-v3/configure.host under /work/src/$g10"
        fi
        mkdir -p /work/bld10 && cd /work/bld10
        say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: gcc 10 configure, CXX=$GXX2"
        "/work/src/$g10/configure" \
          CC="$GCC2 -static" CXX="$GXX2 -static" \
          --build=riscv64-unknown-linux-gnu \
          --host=riscv64-unknown-linux-gnu \
          --target=riscv64-unknown-linux-gnu \
          --prefix=/work/out10 --enable-languages=c,c++ \
          --disable-multilib --disable-bootstrap --disable-werror \
          --disable-libsanitizer --disable-libvtv --disable-libgomp \
          --disable-libquadmath --disable-nls --disable-shared \
          CFLAGS_FOR_TARGET="-static" CXXFLAGS_FOR_TARGET="-static" LDFLAGS_FOR_TARGET="-static" \
          --with-gmp=/work/prereq3 \
          --with-mpfr=/work/prereq3 \
          --with-mpc=/work/prereq3 \
          > conf10.log 2>&1
        _c9=$?
        say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_c9)"
        if [ ! -f Makefile ]; then
          r9=FAIL
          say "    no Makefile -- configure tail:"
          tail -20 conf10.log 2>/dev/null | sed 's/^/      /'
          grep -nE "error:|cannot find|undefined reference" config.log 2>/dev/null \
            | tail -15 | sed 's/^/      /'
        else
          # -k SO ONE BROKEN TARGET LIBRARY DOES NOT HIDE THE REST, and three
          # hours because this is the longest rung in the job.
          timeout 10800 make -k -j"$NP" -Otarget MAKEINFO=true > build10.log 2>&1
          _m9=$?
          say "    make rc=$_m9  ($(wc -l < build10.log) lines)"
          make install MAKEINFO=true > /dev/null 2>&1
          if [ -x /work/out10/bin/gcc ] && [ -x /work/out10/bin/g++ ]; then
            r9=ok
            say "    --- what stage 3 produced ---"
            for b in gcc g++ cpp; do
              printf '      %-8s %s\n' "$b" \
                "$( [ -x /work/out10/bin/$b ] && echo present || echo missing )"
            done
            /work/out10/bin/gcc --version 2>&1 | head -1 | sed 's/^/      /'

            # THE SAME FLOAT PROBE, NOW COMPILED BY gcc 10.
            #
            # Rung 3 ran this source with tcc against the musl tcc built. This
            # runs the identical file with gcc 10 against the same musl, and
            # that pair is what decides:
            #
            #   both wrong      -> musl's vfprintf.c, as tcc compiled it
            #   only gcc wrong  -> the variadic calling convention
            #   only tcc wrong  -> tcc's own float codegen, and gcc 10 is clean
            #
            # Both numbers now land in one log, four rungs apart, instead of
            # being compared across runs from memory.
            if [ -f /work/fp.c ]; then
              say "    --- the float probe, compiled by gcc 10 this time ---"
              ( cd /tmp && rm -f fpg.bin
                if /work/out10/bin/gcc -static -O0 -o fpg.bin /work/fp.c 2>/tmp/fpg.err \
                   && ./fpg.bin 2>&1 | sed 's/^/    /'; then
                  :
                else
                  say "      would not build with gcc 10:"
                  head -4 /tmp/fpg.err 2>/dev/null | sed 's/^/        /'
                fi
                rm -f fpg.bin )
            fi
          else
            r9=FAIL
            # THE TWO FAILURES WORTH TELLING APART, in stage 4's words: gcc 10's
            # own sources refusing to compile under an old C++ compiler shows up
            # in gcc/*.c; a 2020 tree meeting a libc it does not expect shows up
            # in the headers. Different fixes, same message.
            say "    --- compiler diagnostics ---"
            grep -nE "error:|internal compiler error" build10.log 2>/dev/null \
              | grep -v 'make\[' | head -15 | sed 's/^/      /'
            say "    --- where the errors are ---"
            grep -oE '^[^ :]+\.(c|cc|h|H):[0-9]+:[0-9]*:? *error:' build10.log 2>/dev/null \
              | cut -d: -f1 | sort | uniq -c | sort -rn | head -12 | sed 's/^/      /'
            say "    --- tail ---"
            tail -20 build10.log 2>/dev/null | sed 's/^/      /'
          fi
        fi
      fi
    fi
    R9=$r9
  fi
  cd /work
fi

fi

# ---------------------------------------------------------------------------
if stop_here 10; then
  say ""
  say "  === stopping after rung $STOP_AFTER, as asked ==="
else
head1 "RUNG 10 -- LFS 5.2: binutils pass 1, cross to \$VERON_TOOLCHAIN_TGT"
# FROM HERE THE ORDER IS LFS's AND IT IS NOT NEGOTIABLE.
#
#   5.2 binutils pass 1   5.3 gcc pass 1   5.4 linux headers
#   5.5 glibc             5.6 libstdc++    ch6 binutils/gcc pass 2
#
# headers before glibc, glibc before libstdc++, libstdc++ before pass 2. Stage 4
# runs exactly this with gcc 10 as the host compiler (CHAIN_CC=out10/bin/gcc),
# which is the compiler rung 9 just produced.
#
# VERON_TOOLCHAIN_TGT IS DELIBERATELY NOT THE HOST TRIPLE. That is the book's device: a
# toolchain targeting riscv64-veron-linux-gnu cannot silently reach anything
# built for riscv64-unknown-linux-gnu, so a leak from the old sysroot becomes a
# link error instead of a subtly wrong binary. It also settles a question left
# open earlier in this file -- a non-standard vendor travels fine through
# gcc 15, so config.sub was never the obstacle.
#
# THIS IS WHERE musl LEAVES THE CHAIN. Chapter 5 builds glibc into $S, and
# everything above is glibc. musl carried the stretch where nothing else could
# be built, which is what spikes/livebootstrap/ORDER.md argues it is for.
VERON_TOOLCHAIN_TGT=riscv64-toolchain-linux-gnu
S=/work/lfs

# THE SYSROOT HAS TO BE SHAPED LIKE A ROOT, AND NOTHING HERE WAS DOING IT.
#
# $S is not just a staging directory. Phase B binds it AS `/` and runs the
# toolchain natively inside it, which is the only way a glibc toolchain built
# --prefix=/usr can function: its PT_INTERP, its library search path and its
# header search path are all absolute and all assume it is the root.
#
# glibc installs its loader to $S/usr/lib (libc_cv_slibdir=/usr/lib, rung 13),
# but every binary it links carries the interpreter as /lib/ld-linux-aarch64.so.1.
# Without $S/lib -> usr/lib that path does not exist even once $S IS the root,
# and every dynamic binary fails to exec with ENOENT -- which a shell reports
# as "gcc: not found", the message for a missing PROGRAM.
#
# This is LFS 4.2 and it is also hermetic-gcc15.yml's layout step, which does
# the identical thing beside box15.sh:
#
#     for i in bin lib sbin; do ln -sfnv usr/$i "$S/$i"; done
#
# That job binds the sysroot as / and works. This one wrote in_sysroot instead
# -- a PATH -- and skipped the layout, so neither half was present.
#
# NO /usr/lib64, DELIBERATELY, and the book is blunt about why: "The LFS editors
# have deliberately decided not to use a /usr/lib64 directory ... If for any
# reason this directory appears it may break your system." aarch64 has no lib64
# in the first place; the note matters because gcc's t-riscv64-linux is what
# would create one, and rung 11 already patches it for that reason.
# $S/tmp IS IN THIS LIST FOR A REASON THAT ONLY SHOWS UP AT BOOT.
#
# qemu shares this sysroot with the guest over 9p READ-ONLY, and the guest
# mounts a tmpfs over its /tmp so the in-guest compile has somewhere to
# write. `mount -t tmpfs none /mnt/sysroot/tmp` needs that directory to
# EXIST on disk -- a mount point cannot be created on a read-only tree.
# Without it the guest reports "skipped: no tmpfs for output" and the
# VERON-GCC-IN-GUEST test silently never runs, which reads as a 9p problem.
mkdir -p "$S/etc" "$S/var" "$S/usr/bin" "$S/usr/lib" "$S/usr/sbin" \
         "$S/tools" "$S/tmp"
for _i in bin lib sbin; do
  [ -e "$S/$_i" ] || ln -sfn "usr/$_i" "$S/$_i"
done
say ""
say "  sysroot layout at $S:"
for _i in bin lib sbin; do
  printf '    /%-5s -> %s\n' "$_i" "$(readlink "$S/$_i" 2>/dev/null || echo 'NOT A SYMLINK')"
done

# A WRAPPER FOR gcc 10, THE SAME MOVE cc-static MADE FOR tcc.
#
# Everything from rung 10 up is built by gcc 10 through the tcc-built binutils
# 2.30, whose ld writes overlapping FDEs into .eh_frame_hdr. Rungs 10 and 11
# pass -Wl,--no-eh-frame-hdr through LDFLAGS, which autoconf honours.
#
# PERL DOES NOT READ LDFLAGS. Its Configure is 30,000 lines of hand-written
# shell, not autoconf: no CC, no CFLAGS, no LDFLAGS from the environment, and
# -Dldflags applies to linking perl itself rather than to the compiler probes
# that run first. This one died in a probe:
#
#     ld: .eh_frame_hdr refers to overlapping FDEs.
#     You need to find a working C compiler.
#
# -- which is a spectacularly misleading conclusion to draw from one failed
# link, since that compiler had just built two other compilers and a binutils.
#
# So do what worked twice already and remove the choice. chain-cc appends the
# flag to every invocation; nothing a build system does to its argument list
# can drop a flag that is not in the argument list. The autoconf rungs use it
# too, which means they stop depending on LDFLAGS being honoured -- one fewer
# thing that has to be true.
mkdir -p "$PFX/bin"
cat > "$PFX/bin/chain-cc" <<CHAINCC
#!/bin/sh
# THE KERNEL HEADERS, IF RUNG 12 HAS INSTALLED THEM YET.
#
# Rung 12 puts 1003 linux API headers in the box's own include directory. gcc
# 10 does not find them otherwise -- it searches its own /usr/include, which is
# the musl sysroot from rung 2 with no kernel headers at all.
#
# THIS DIRECTORY HOLDS KERNEL HEADERS AND NOTHING ELSE, deliberately. It used
# to be the sysroot's include tree, which was true until glibc was installed
# into it and every build-side compile started seeing glibc's headers while
# linking musl. m4's gnulib wants <linux/fs.h>
# and failed three runs running: once for ordering, once because installing
# them is not the same as finding them, and once because I added the flag to
# one of two configure lines and did not check which.
#
# Putting it in the WRAPPER ends that: every consumer gets it, present or
# absent, and there is no second line to forget. The test is what makes it
# safe to do unconditionally -- rungs 10 and 11 run before rung 12 and simply
# see nothing there.
#
# -isystem rather than -I: these are system headers, and -isystem keeps them
# out of the warning and dependency paths where a project's own -I belongs.
if [ -d SYSROOTINC ]; then
    exec CHAINCCBIN "\$@" -isystem SYSROOTINC -Wl,--no-eh-frame-hdr
fi
exec CHAINCCBIN "\$@" -Wl,--no-eh-frame-hdr
CHAINCC
# $PFX/include, NOT $S/usr/include, AND THE DIFFERENCE IS A LIBC.
#
# This pointed at the sysroot when rung 12 was the only thing that had ever
# written there -- 1003 kernel headers and nothing else, which is exactly what
# the box needed and could not otherwise find.
#
# RUNG 13 THEN FILLS THE SAME DIRECTORY WITH GLIBC'S ENTIRE HEADER TREE.
# stdio.h, features.h, stdlib.h, all of it. From that rung on, every chain-cc
# compile was getting GLIBC headers -- ahead of the default search path,
# because -isystem precedes it -- while still linking against MUSL in
# /usr/lib. Headers from one libc, libraries from another.
#
# Nothing before rung 16 could have shown it: rung 11.7 is the only other
# heavy chain-cc consumer and it runs before glibc is installed. Rung 16's
# build side is the first thing to compile against the mixture, and it is
# where the run stopped.
#
# So the kernel headers get a private copy that only the box uses, and the
# sysroot's include tree stops being on the box compiler's search path at all.
sed -i -e "s|CHAINCCBIN|/work/out10/bin/gcc|g" \
       -e "s|SYSROOTINC|$PFX/include|g" "$PFX/bin/chain-cc"
chmod 0755 "$PFX/bin/chain-cc"

# PROVE IT BEFORE FIVE RUNGS DEPEND ON IT. A wrapper that silently does not
# apply its flag looks exactly like one that does -- the same failure mode as
# CFLAGS_EXTRA vs EXTRA_CFLAGS, which cost stage 4 two runs.
if [ -x /work/out10/bin/gcc ]; then
  ( cd /tmp && rm -f wc.c wc.bin
    printf 'int main(void){return 0;}\n' > wc.c
    if "$PFX/bin/chain-cc" -static -o wc.bin wc.c 2>/tmp/wc.err; then
      say "  chain-cc: compiles and links ok"
    else
      say "  chain-cc: FAILED -- five rungs depend on this"
      head -4 /tmp/wc.err | sed 's/^/    /'
    fi
    rm -f wc.c wc.bin )
fi
if [ "$R9" = ok ]; then
  CHAIN_CC=/work/out10/bin/gcc
  CHAIN_CXX=/work/out10/bin/g++
  export PATH="$S/tools/bin:$PATH"
  mkdir -p "$S/tools"
  say "    chapter 5 compiler: $("$CHAIN_CC" --version 2>&1 | head -1)"
  say "    VERON_TOOLCHAIN_TGT: $VERON_TOOLCHAIN_TGT   sysroot: $S"

  cd /work/src
  # BINUTILS_LFS, NOT the 2.30 rung 4 built. 2.30 is pinned by tcc's ceiling
  # and nothing in chapter 5 is built by tcc; stage 4 uses 2.46 here.
  if ! untar "/in/binutils-$BINUTILS_LFS"; then
    say "    binutils $BINUTILS_LFS did not extract"; R10=FAIL
  else
    _bu=$(onedir "binutils-$BINUTILS_LFS ./binutils-$BINUTILS_LFS")
    rm -rf /work/b-binutils1 && mkdir -p /work/b-binutils1 && cd /work/b-binutils1
    say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: binutils pass 1 configure"
    say "    (cwd: $(pwd))"
    # THE eh_frame OVERLAP IS ld's, NOT THE COMPILER's, AND THIS RUNG PROVED IT.
    #
    #     CCLD  as-new
    #     ld: .eh_frame_hdr refers to overlapping FDEs.
    #     ld: final link failed: Bad value
    #
    # Every object in that link was compiled by gcc 10. The linker was
    # binutils 2.30 -- the one tcc built at rung 4, reached through gcc 10's
    # own -B path. So the malformed section is not something tcc emitted into
    # an object; it is something tcc's binutils emits when it MERGES them.
    #
    # That corrects the note in this file's README twice over: it is not musl's
    # crt files, and it is not tcc's .eh_frame either. Rung 6 hid it by going
    # -static, which suppresses --eh-frame-hdr; here the link is static too and
    # it still fires, because gas's own objects carry enough CFI to trip it.
    #
    # --disable-werror ALONE IS NOT ENOUGH -- this is a link failure, not a
    # warning. -Wl,--no-eh-frame-hdr tells the driver not to build the section
    # at all. Nothing in a static binary reads it: it exists so a dynamic
    # unwinder can find FDEs quickly, and there is no loader in this box.
    #
    # THE REAL FIX IS UPWARD. Chapter 5 is building a NEW binutils; once
    # $VERON_TOOLCHAIN_TGT-ld exists, everything above uses it and this stops mattering.
    # This flag only has to carry the one link that produces that ld.
    "/work/src/$_bu/configure" \
      CC="$PFX/bin/chain-cc -static" CXX="$CHAIN_CXX -static -Wl,--no-eh-frame-hdr" \
      LDFLAGS="-static -Wl,--no-eh-frame-hdr" \
      --prefix="$S/tools" \
      --with-sysroot="$S" \
      --target="$VERON_TOOLCHAIN_TGT" \
      --disable-nls --enable-gprofng=no --disable-werror \
      --enable-deterministic-archives \
      --enable-new-dtags --enable-default-hash-style=gnu \
      > cfg.log 2>&1
    _r10=$?
    say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r10)"
    if [ "$_r10" != 0 ]; then
      R10=FAIL; tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
    # MAKEINFO=true AND THE perl WARNINGS. `/bin/sh: perl: not found` and
    # `pod2man: not found` appear above the real error and are IGNORED by
    # binutils itself -- "Error 127 (ignored)" -- because they only build man
    # pages. Worth naming so the next reader does not chase perl: it is a real
    # missing tool, and it is not what stopped this rung.
    elif timeout 3600 make -j"$NP" MAKEINFO=true > b.log 2>&1 && make install > i.log 2>&1; then
      if [ -x "$S/tools/bin/$VERON_TOOLCHAIN_TGT-ld" ]; then
        R10=ok
        say "    $VERON_TOOLCHAIN_TGT-ld, -as, -ar installed:"
        for b in ld as ar ranlib; do
          printf '      %-28s %s\n' "$VERON_TOOLCHAIN_TGT-$b" \
            "$( [ -x "$S/tools/bin/$VERON_TOOLCHAIN_TGT-$b" ] && echo present || echo missing )"
        done
      else
        R10=FAIL; say "    installed no $VERON_TOOLCHAIN_TGT-ld"
        tail -12 i.log 2>/dev/null | sed 's/^/      /'
      fi
    else
      R10=FAIL; say "    --- errors ---"
      grep -nE "error:|Error [0-9]|configure: error" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      tail -25 b.log 2>/dev/null | sed 's/^/      /'
    fi
  fi
  cd /work
fi

fi

# ---------------------------------------------------------------------------
head1 "RUNG 11 -- LFS 5.3: gcc pass 1, no headers and no libc yet"
# --without-headers/--with-newlib because there IS no libc yet; c,c++ because
# binutils pass 2 and much else needs a C++ compiler and libstdc++ comes at 5.6.
#
# gmp/mpfr/mpc GO IN-TREE, not into a prefix. That is what the book does and
# stage 4 follows it: "simpler and more reliable than a separate prefix".
#
# THE t-riscv64-linux SED IS OURS, NOT THE BOOK'S. LFS seds
# gcc/config/i386/t-linux64 for x86_64; the aarch64 file doing the same job is
# t-riscv64-linux. Without it glibc lands in /usr/lib and libstdc++ in
# /usr/lib64 -- a directory this sysroot has no symlink to. g++ still LINKS;
# the program dies at exec with "error while loading shared libraries:
# libstdc++.so.6", which reads as a broken C++ runtime rather than a misplaced
# file.
#
# ASSERT THE ANCHOR, which is stage 4's rule and worth adopting everywhere:
# a sed that matches nothing ships an unchanged file and looks exactly like a
# sed that worked. So the file must exist and the pattern must be found, or
# this rung fails here rather than at exec time six rungs later.
if [ "$R10" = ok ]; then
  cd /work/src
  if ! untar /in/gcc-15; then
    say "    gcc 15 did not extract"; R11=FAIL
  else
    g15=$(onedir 'gcc-15* ./gcc-15*')
    # FIND THE FILE, DO NOT NAME IT. gcc keeps its riscv64 support under
      # gcc/config/riscv -- the run's own tmake_file list shows
      # $(srcdir)/config/riscv/t-linux -- but the FILENAME differs per
      # architecture and per release. The aarch64 arm seds
      # t-aarch64-linux and its `mabi.lp64=` line; LFS seds
      # config/i386/t-linux64 for x86_64, whose line is MULTILIB_OSDIRNAMES.
      # Substituting the arch into the aarch64 path produced
      #     /work/src/gcc-15.2.0/gcc/config/x86_64/t-x86_64-linux is missing
      # (run 85015318677) -- a directory gcc has never had.
      #
      # WHAT MATTERS IS THE lib64 IN A MULTILIB DIRECTORY NAME, whatever file
      # carries it. Search for that, sed every hit, and print each one. The
      # rule the aarch64 arm states still holds: a sed that matches nothing
      # ships an unchanged file and looks exactly like a sed that worked, so
      # finding zero files is a failure here rather than at exec time six
      # rungs later.
    _cd="/work/src/$g15/gcc/config/riscv"
    if [ ! -d "$_cd" ]; then
      say "    $_cd is missing -- gcc has moved this target's config"
      say "    directories present:"
      ls "/work/src/$g15/gcc/config" | sed 's/^/      /' | head -30
      R11=FAIL
    else
      _hits=$(grep -l 'lib64' "$_cd"/t-* 2>/dev/null || true)
      if [ -z "$_hits" ]; then
        say "    no t-* file under $_cd mentions lib64. Present:"
        ls "$_cd"/t-* 2>/dev/null | sed 's/^/      /'
        say "    (if this target has no multilib lib64 split there is nothing"
        say "     to sed, but say so deliberately rather than by silence)"
        R11=FAIL
      else
        for _t in $_hits; do
          sed -i.orig 's|lib64|lib|g' "$_t"
        say "    $(basename "$_t"): $(grep -c 'lib' "$_t") lib lines, lib64 removed"
          grep -n 'MULTILIB_OSDIRNAMES\|mabi' "$_t" 2>/dev/null | head -4 | sed 's/^/      /'
        done
      fi
      fi
  fi

  if [ "$R11" != FAIL ]; then
    # In-tree prerequisites, as the book does it.
    for pk in gmp mpfr mpc; do
      ( cd "/work/src/$g15" && untar "/in/$pk-" \
        && mv "$(onedir "$pk-* ./$pk-*")" "$pk" ) >/dev/null 2>&1 \
        || { say "    $pk did not go in-tree"; R11=FAIL; }
    done
    say "    in-tree: $(ls -d /work/src/$g15/gmp /work/src/$g15/mpfr /work/src/$g15/mpc 2>/dev/null | wc -l) of 3"
  fi

  if [ "$R11" != FAIL ]; then
    rm -rf /work/b-gcc1 && mkdir -p /work/b-gcc1 && cd /work/b-gcc1
    say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: gcc 15 pass 1 configure"
    # SAME FLAG AS RUNG 10, SAME REASON. gcc 15's own binaries are linked by
    # the tcc-built ld too -- $VERON_TOOLCHAIN_TGT-ld exists now but is the CROSS linker
    # and is not what links the compiler itself.
    "/work/src/$g15/configure" \
      CC="$PFX/bin/chain-cc -static" CXX="$CHAIN_CXX -static -Wl,--no-eh-frame-hdr" \
      LDFLAGS="-static -Wl,--no-eh-frame-hdr" \
      --target="$VERON_TOOLCHAIN_TGT" \
      --prefix="$S/tools" \
      --with-glibc-version="$GLIBC" \
      --with-sysroot="$S" \
      --with-newlib --without-headers \
      --enable-default-pie --enable-default-ssp \
      --disable-nls --disable-shared --disable-multilib \
      --disable-threads --disable-libatomic --disable-libgomp \
      --disable-libquadmath --disable-libssp --disable-libvtv \
      --disable-libstdcxx --enable-languages=c,c++ \
      > cfg.log 2>&1
    _r11=$?
    say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r11)"
    if [ "$_r11" != 0 ]; then
      R11=FAIL; tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
    elif timeout 7200 make -j"$NP" > b.log 2>&1 && make install > i.log 2>&1; then
      # THE limits.h REASSEMBLY, AND IT IS NOT OPTIONAL.
      #
      # --without-headers installs a self-contained limits.h that knows nothing
      # of the system one, so PATH_MAX is simply absent. binutils pass 2 then
      # dies on
      #     ld/ldmain.c:646: error: 'PATH_MAX' undeclared
      # which names a macro rather than the include chain that lost it.
      # Concatenating the three fragments produces the full header, which
      # #include_next's through to glibc's once 5.5 has built one.
      LIMH=$(dirname "$("$VERON_TOOLCHAIN_TGT-gcc" -print-libgcc-file-name 2>/dev/null)")
      for d in include include-fixed; do
        [ -d "$LIMH/$d" ] || continue
        cat "/work/src/$g15/gcc/limitx.h" "/work/src/$g15/gcc/glimits.h" \
            "/work/src/$g15/gcc/limity.h" > "$LIMH/$d/limits.h"
        say "    full limits.h written to $d/ ($(wc -l < "$LIMH/$d/limits.h") lines)"
      done
      if [ -x "$S/tools/bin/$VERON_TOOLCHAIN_TGT-gcc" ]; then
        R11=ok
        "$S/tools/bin/$VERON_TOOLCHAIN_TGT-gcc" --version 2>&1 | head -1 | sed 's/^/      /'
        "$S/tools/bin/$VERON_TOOLCHAIN_TGT-gcc" -dumpmachine 2>&1 | sed 's/^/      targets: /'
      else
        R11=FAIL; say "    no $VERON_TOOLCHAIN_TGT-gcc installed"
      fi
    else
      R11=FAIL; say "    --- errors ---"
      grep -nE "error:|Error [0-9]|configure: error" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      tail -30 b.log 2>/dev/null | sed 's/^/      /'
    fi
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 11.5 -- perl, because everything above this wants it"
# NOT WHERE LFS PUTS IT, AND FOR A REASON LFS DOES NOT HAVE.
#
# The book builds perl in chapter 7, inside the chroot, because chapters 5 and
# 6 can borrow the HOST's. This box has no host, and rung 10 already showed
# what that looks like:
#
#     /bin/sh: perl: not found
#     make[4]: [Makefile:2267: doc/as.1] Error 127 (ignored)
#
# binutils ignored it -- that was only a man page -- so it was not what stopped
# that rung. But it stops being ignorable immediately above: glibc's build
# scripts use perl, and the kernel needs it for kconfig and much of scripts/.
# Building it here rather than discovering it twice more is the cheaper order.
#
# ONE VERSION, BUILT ONCE. live-bootstrap climbs 5.000 -> 5.003 -> 5.005_03 ->
# 5.6.2 because they build perl BEFORE binutils and gcc, with tcc and mes-libc,
# where modern perl cannot go. We have gcc 10 and a full binutils, so perl
# 5.42.0 builds in one step -- which is what stage 4 does, with the same
# tarball and a three-flag Configure. spikes/livebootstrap/ORDER.md records
# this as one of three places their constraints were imported wrongly.
#
# -Dcc, NOT CC=. perl's Configure is not autoconf; it takes its compiler as a
# -D option and ignores the environment variable. Passing CC= would look like
# it worked and silently use whatever `cc` resolves to.
if [ "$R11" = ok ]; then
  # TWO POSIX FILTERS THIS busybox WAS COMPILED WITHOUT.
  #
  #     ./Configure: line 2135: split: not found
  #     I don't know where 'comm' is, and my life depends on it.
  #
  # Both are real busybox applets and both are compile-time options; Ubuntu's
  # busybox-static ships neither. `busybox --list` reported 269 and all 269
  # were linked, so nothing in the box assembly was wrong -- these were never
  # on the list.
  #
  # WHY NOT BUILD coreutils. That is 100+ programs and an autoconf run to get
  # two filters that are twenty lines each, and it would land in the box as a
  # much larger unreviewed surface. These two are written here, in C, compiled
  # by the chain's own gcc, and they are auditable in one screen -- which is
  # the same argument the tcc-test-shim makes for not being a libc.
  #
  # THEY IMPLEMENT ONLY WHAT Configure USES. `split` with no options (1000-line
  # pieces named x??) and `comm` with -12/-13/-23. Anything else exits non-zero
  # rather than guessing, for the reason the shim's printf does: a filter that
  # quietly did the wrong thing would make perl's Configure reach a wrong
  # conclusion, and that is far harder to see than a missing tool.
  mkdir -p "$PFX/bin"
  if [ ! -x "$PFX/bin/split" ]; then
    cat > /tmp/split.c <<'SPLITC'
/* split(1), the subset perl's Configure uses: read stdin, write 1000-line
 * pieces named xaa, xab, ... in the current directory. No options. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv)
{
    char line[65536];
    long n = 0, per = 1000;
    int a = 0, b = 0;
    FILE *out = NULL;
    FILE *in = stdin;
    const char *pre = "x";
    char name[64];
    /* perl's Configure calls this BOTH ways -- `split -50` and `split -l 50`
     * appear in the same script -- so all three spellings are accepted:
     *   -lN   -l N   -N
     * The first version handled only -lN. Its own self-test then used -2 and
     * reported "made 0 chunks", which read as a broken split when it was a
     * broken test of a split that was merely incomplete. */
    /* THE FILE AND PREFIX ARGUMENTS ARE NOT OPTIONAL, AND OMITTING THEM HUNG.
     *
     * The first version read stdin unconditionally and ignored everything that
     * was not an option. Given `split -2 s1 x` it therefore blocked on a stdin
     * nobody was writing to -- forever. The self-test reported "made 0 chunks",
     * which reads as a split that produced nothing rather than one that never
     * returned, and that is a much worse failure to have in a rung: a hang has
     * no error message at all.
     *
     * perl's Configure uses both forms -- the trap log from tool-probe shows
     * `split -50` and `split -l 50` -- and coreutils split takes an optional
     * file and an optional prefix after the options. All of it is handled. */
    {
        int i = 1;
        while (i < argc && argv[i][0] == '-' && argv[i][1]) {
            char *p = argv[i] + 1;
            if (*p == 'l') {
                p++;
                if (*p) per = atol(p);
                else if (i + 1 < argc) per = atol(argv[++i]);
            } else if (*p >= '0' && *p <= '9') {
                per = atol(p);
            }
            i++;
        }
        if (i < argc && strcmp(argv[i], "-") != 0) {
            in = fopen(argv[i], "r");
            if (!in) { perror(argv[i]); return 1; }
        }
        if (i < argc) i++;
        if (i < argc) pre = argv[i];
    }
    if (per < 1) per = 1000;
    while (fgets(line, sizeof line, in)) {
        if (!out || n % per == 0) {
            if (out) fclose(out);
            sprintf(name, "%.32s%c%c", pre, 'a' + a, 'a' + b);
            if (++b == 26) { b = 0; a++; }
            out = fopen(name, "w");
            if (!out) { perror(name); return 1; }
        }
        fputs(line, out);
        n++;
    }
    if (out) fclose(out);
    if (in != stdin) fclose(in);
    return 0;
}
SPLITC
    "$CHAIN_CC" -static -O1 -o "$PFX/bin/split" /tmp/split.c 2>/tmp/sc.err \
      && say "    split: built ($(wc -c < "$PFX/bin/split") bytes)" \
      || { say "    split FAILED to build:"; head -5 /tmp/sc.err | sed 's/^/      /'; }
  fi
  if [ ! -x "$PFX/bin/comm" ]; then
    cat > /tmp/comm.c <<'COMMC'
/* comm(1), the subset perl's Configure uses. Two sorted files, three columns;
 * -1/-2/-3 suppress a column. Lines are compared with strcmp, which is what
 * comm does in the C locale. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static char *rd(FILE *f, char *buf, int n)
{
    if (!fgets(buf, n, f)) return NULL;
    { size_t l = strlen(buf); if (l && buf[l-1] == '\n') buf[l-1] = 0; }
    return buf;
}
int main(int argc, char **argv)
{
    int s1 = 0, s2 = 0, s3 = 0, i, fi = 0;
    char *fn[2] = { NULL, NULL };
    char a[65536], b[65536];
    char *pa, *pb;
    FILE *f1, *f2;
    for (i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1]) {
            char *p = argv[i] + 1;
            while (*p) { if (*p=='1') s1=1; else if (*p=='2') s2=1;
                         else if (*p=='3') s3=1; else return 2; p++; }
        } else if (fi < 2) fn[fi++] = argv[i];
        else return 2;
    }
    if (fi != 2) return 2;
    f1 = strcmp(fn[0], "-") ? fopen(fn[0], "r") : stdin;
    f2 = strcmp(fn[1], "-") ? fopen(fn[1], "r") : stdin;
    if (!f1 || !f2) return 1;
    pa = rd(f1, a, sizeof a);
    pb = rd(f2, b, sizeof b);
    while (pa || pb) {
        int c;
        if (!pb) c = -1; else if (!pa) c = 1; else c = strcmp(pa, pb);
        if (c < 0)      { if (!s1) printf("%s\n", pa);            pa = rd(f1,a,sizeof a); }
        else if (c > 0) { if (!s2) printf("%s%s\n", s1?"":"\t", pb); pb = rd(f2,b,sizeof b); }
        else            { if (!s3) printf("%s%s%s\n", s1?"":"\t", s2?"":"\t", pa);
                          pa = rd(f1,a,sizeof a); pb = rd(f2,b,sizeof b); }
    }
    return 0;
}
COMMC
    "$CHAIN_CC" -static -O1 -o "$PFX/bin/comm" /tmp/comm.c 2>/tmp/cc.err \
      && say "    comm: built ($(wc -c < "$PFX/bin/comm") bytes)" \
      || { say "    comm FAILED to build:"; head -5 /tmp/cc.err | sed 's/^/      /'; }
  fi
  # PROVE THEM, because a filter that runs and answers wrongly is worse than
  # one that is missing -- Configure would reach a wrong conclusion silently.
  ( cd /tmp && rm -rf ctest && mkdir ctest && cd ctest
    printf 'a\nb\nc\n' > f1; printf 'b\nc\nd\n' > f2
    _only1=$(comm -23 f1 f2 2>/dev/null | tr -d '\n')
    _both=$(comm -12 f1 f2 2>/dev/null | tr -d '\n')
    # TEST EVERY SPELLING perl USES, not just the one that happened to work.
    # The first version tested -l2 here and -2 elsewhere, and the -2 test
    # reported "0 chunks" against a split that genuinely did not accept it --
    # a real gap, found by accident, reported as if the tool were broken.
    _sp_ok=yes
    for _f in "-l2" "-2"; do
      rm -f x??
      printf 'l1\nl2\nl3\n' | split $_f 2>/dev/null
      [ -f xaa ] && [ -f xab ] || { _sp_ok="no ($_f)"; }
    done
    rm -f x??
    printf 'l1\nl2\nl3\n' | split -l 2 2>/dev/null
    [ -f xaa ] && [ -f xab ] || _sp_ok="no (-l 2)"
    # AND THE FILE FORM, WHICH IS THE ONE THAT HUNG. Every test above pipes
    # stdin, so none of them could have caught a split that ignores its file
    # argument and blocks forever. `timeout` and `</dev/null` are both here on
    # purpose: without them a regression stops the rung with no message rather
    # than failing it with one.
    rm -f x?? pfx??
    printf 'l1\nl2\nl3\nl4\n' > sf
    timeout 10 split -2 sf pfx </dev/null 2>/dev/null
    [ -f pfxaa ] && [ -f pfxab ] || _sp_ok="no (file + prefix)"
    rm -f sf
    _pieces=$(ls x?? pfx?? 2>/dev/null | tr '\n' ' ')
    say "    comm -23: [$_only1] (expect a)   comm -12: [$_both] (expect bc)"
    say "    split: [$_pieces] and all of -l2 / -l 2 / -2 accepted: $_sp_ok"
    [ "$_only1" = a ] && [ "$_both" = bc ] || say "    ONE OF THESE IS WRONG -- Configure will conclude something false"
    cd /tmp && rm -rf ctest )

  # DOES THIS COMPILER GET DOUBLES RIGHT? ASKED BEFORE perl, NOT AFTER.
  #
  # perl's failure is a version comparison, which is a double comparison, and
  # the answer to "is floating point sound" should not depend on perl building
  # successfully -- that is the thing being explained.
  #
  # 5.008 is the exact value perl compares. It is not representable in binary
  # floating point, so what matters is whether string-to-double, double
  # arithmetic and double-to-integer all agree with the same operations on a
  # compiler nobody doubts.
  cd /work/src
  if ! untar "/in/perl-$PERL_VER"; then
    say "    perl did not extract"; R115=FAIL
  else
    _pl=$(onedir "perl-$PERL_VER ./perl-$PERL_VER")
    cd "/work/src/$_pl"
    # perl's Configure NEEDS TWO TOOLS busybox DOES NOT HAVE.
    #
    #     ./Configure: line 2135: split: not found
    #     I don't know where 'comm' is, and my life depends on it.
    #
    # Configure is a 1990s shell script that shells out to about forty
    # utilities and dies on the first one missing. It is not autoconf and there
    # is no --without to give it.
    #
    # ONE IMPLEMENTATION OF EACH, AND THAT IS THE POINT OF THIS COMMENT.
    # Three accumulated here across three rounds -- a C split, an awk split, an
    # sh comm -- because each round added one without deleting the last. The
    # awk split was dead code (the C one is built first, so its branch never
    # ran) but its SELF-TEST still ran, against a form the C version did not
    # accept. That is where "split -2: made 0 chunks" came from: not a broken
    # split, but a test of one implementation aimed at another.
    #
    # Worse, the form it tested -- `split -2 s1 x`, with a FILE -- made the C
    # version block on a stdin nobody was writing to. It did not produce zero
    # chunks; it never returned. A hang has no error message at all, and the
    # only reason the rung continued is that the subshell had no stdin.
    #
    # So: one split, one comm, both C, both handling every form Configure uses.
    mkdir -p "$PFX/bin"
    # THE MARKER MUST MATCH THE COMMAND. This said -Dldflags=-static and
    # nothing about -Doptimize, while the command below passed both -- so a log
    # showing "no -Doptimize" was the marker being stale, not the flag being
    # absent, and it cost a round of reading. Built from the same variables the
    # command uses.
    _pcfg="-des -Dprefix=$PFX -Dcc=$PFX/bin/chain-cc -Dusedl=undef -Dldflags=-static -Doptimize=-O0 -fno-strict-aliasing -fwrapv"
    say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: ./Configure $_pcfg"
    say "    (cwd: $(pwd))"
    # -Dprefix is $PFX, not /usr: this perl is a BUILD TOOL for the rungs above,
    # not part of the sysroot being assembled at $S. Chapter 7's perl, which is
    # the one the final system gets, is a different build with different paths.
    # -Dldflags, BECAUSE Configure LINKS WITH THE BARE COMPILER.
    #
    #     ld: .eh_frame_hdr refers to overlapping FDEs.
    #     You need to find a working C compiler.
    #
    # That is the tcc-built binutils 2.30 again -- the same fault rungs 10 and
    # 11 carry -Wl,--no-eh-frame-hdr for. Those pass it through LDFLAGS to an
    # autoconf configure; perl is not autoconf and reads none of CC, CFLAGS or
    # LDFLAGS from the environment. Everything has to be a -D.
    #
    # AND THE MESSAGE IS ACTIVELY MISLEADING. Configure concludes "You need to
    # find a working C compiler" from one failed link, when gcc 10 had just
    # built two compilers and a binutils. The compiler is fine; its linker is
    # not, on this one section, and only until $VERON_TOOLCHAIN_TGT-ld takes over.
    # -O0 DID NOT FIX IT, AND THAT IS THE USEFUL RESULT.
    #
    # The compiles came out as
    #     chain-cc -c -DPERL_CORE -fwrapv -fno-strict-aliasing -pipe ...
    # with no -O at all, so the flag took -- and miniperl still read
    # `use 5.008` as v8.0.0. Optimisation is ruled out. A miscompile that
    # survives -O0 is in code generation itself, not in an optimiser pass.
    #
    # WHAT `use 5.008` ACTUALLY DOES: it is `require 5.008`, and perl
    # implements that by comparing a DOUBLE against $]. 5.008 is not
    # representable exactly in binary floating point, so the comparison depends
    # on the exact double produced by string-to-number conversion. Reading it
    # as v8.0.0 is what happens when the integer part is lost -- which is the
    # shape of a floating-point conversion fault, not an integer one.
    #
    # THAT MATTERS BECAUSE OF WHERE THIS gcc CAME FROM. It descends from
    # tcc through gcc 4.7, and MICRO-C.md records that micro-c has no working
    # floating point at all -- `double a = 12.5; (long)a == 12` is false in a
    # binary mc-tcc produces. This is the REFERENCE arm, so mc-tcc is not in
    # this chain -- but tcc's own soft-float helpers in libtcc1.a are, and
    # every gcc above was built by something built by tcc.
    #
    # So the probe below asks perl directly about the arithmetic rather than
    # about versions. If 5.008 does not round-trip, the answer is floating
    # point and it is a compiler question; if it does, the fault is in perl's
    # version parsing and is a different investigation entirely.
    #
    # -Doptimize IS KEPT. It costs nothing on a build tool, and it removes a
    # variable from every future reading of this rung.
    #
    # -Doptimize="-O0", AND THIS IS NOT ABOUT SPEED.
    #
    # At -O2 perl configures, compiles, links miniperl, RUNS it -- and then:
    #
    #     Perl v8.0.0 required--this is only v5.42.0, stopped at
    #     dist/constant/lib/constant.pm line 2.
    #
    # Line 2 of constant.pm is `use 5.008;` -- perl 5.8. Something read 5.008
    # as v8.0.0. That comparison is done by miniperl against $], and getting it
    # wrong means the freshly built interpreter is computing a version
    # comparison incorrectly -- which is a MISCOMPILE, not a missing tool.
    #
    # perl is unusually exposed to this: its numeric conversion, its string-to
    # -version parsing and its integer arithmetic all go through code that
    # aggressive optimisation is known to break on compilers that mishandle
    # strict-aliasing or signed overflow. perl's own hints files disable
    # optimisation for exactly this reason on compilers it does not trust, and
    # this gcc 10 was built by a gcc 4.7 that was built by tcc.
    #
    # -O0 removes the variable. If perl then builds, the fault is optimisation
    # on this toolchain and is worth knowing precisely; if it fails the same
    # way, the fault is elsewhere and -O0 has cost only build time on a package
    # that is a BUILD TOOL -- nothing ships it and nothing measures its speed.
    #
    # -fno-strict-aliasing is what perl's own Configure adds for gcc and what
    # every distribution builds it with; leaving it to chance here would be
    # relying on Configure detecting a compiler it has never seen.
    # A `gcc` ON PATH TOO. perl's Configure writes helper scripts -- UU/checkcc
    # and siblings -- that spell `gcc` literally, and there is no -D for those:
    #
    #     ./Configure: ./UU/checkcc: line 10: gcc: not found
    #
    # NOTHING IS CLOBBERED. Rung 6 installs its gcc into /work/out/bin and
    # rung 8 into /work/out2/bin -- never $PFX/bin, which holds the tools
    # (binutils, make) rather than any compiler. So this name is free, and
    # pointing it at chain-cc means every path perl takes reaches the SAME
    # compiler -Dcc already names.
    ln -sf "$PFX/bin/chain-cc" "$PFX/bin/gcc" 2>/dev/null || true
    # -Dusedl=undef: NO DYNAMIC EXTENSIONS, BECAUSE THERE IS NO LOADER.
    #
    # perl configured, built miniperl, ran it, processed the Unicode tables --
    # and then died building lib/auto/B/B.so and its siblings:
    #
    #     collect2: error: ld returned 1 exit status
    #     make[1]: *** [Makefile:482: ../../lib/auto/B/B.so] Error 1
    #
    # Those are perl's extension modules, built as SHARED OBJECTS. Everything
    # in this box is static -- rung 2 builds musl as libc.a with no libc.so,
    # and rung 3 measures that a dynamic binary cannot run here at all. A .so
    # could not be loaded even if it linked.
    #
    # usedl=undef makes perl link every extension INTO the interpreter instead.
    # That is what a static perl is, it is what every embedded and bootstrap
    # perl does, and the result is a single binary rather than a binary plus a
    # tree of .so files nothing can open.
    #
    # THE FLAGS BELOW ARE NOT REDUNDANT WITH IT. usedl controls extensions;
    # -Dldflags=-static controls how perl itself links. Both are needed and
    # they answer different questions.
    ./Configure -des -Dprefix="$PFX" -Dcc="$PFX/bin/chain-cc" \
      -Dusedl=undef \
      -Dldflags="-static" \
      -Doptimize="-O0 -fno-strict-aliasing -fwrapv" > c.log 2>&1
    _rp=$?
    say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_rp)"
    if [ "$_rp" != 0 ]; then
      R115=FAIL; tail -20 c.log 2>/dev/null | sed 's/^/      /'
    elif timeout 5400 make -j"$NP" > b.log 2>&1 && make install > i.log 2>&1; then
      if [ -x "$PFX/bin/perl" ]; then
        R115=ok
        # THE EXACT COMPARISON THAT FAILED, ASKED DIRECTLY. `use 5.008` is
        # implemented as a numeric compare against $], so if the interpreter
        # gets this right the miscompile is gone; if it gets it wrong while
        # still building, we would have a perl that works until something
        # compares versions -- far worse than one that fails loudly.
        say "    --- the comparison that failed at -O2 ---"
        "$PFX/bin/perl" -e 'printf("      $] = %s\n", $]);' 2>&1
        # ONE -e, AND THE require FIRST. Two -e blocks are concatenated in
        # order, so the previous form printed "ok" before testing anything.
        if "$PFX/bin/perl" -e 'require 5.008; print "      require 5.008 ok\n"' 2>&1; then
          :
        else
          say "      require 5.008 STILL FAILS -- not an optimisation problem"
        fi
        # AND THE ARITHMETIC UNDERNEATH IT, because "5.008 read as v8.0.0" is a
        # symptom and this is the operation. If these disagree with the
        # expected values the fault is in numeric conversion, which is a
        # codegen answer rather than a perl one.
        "$PFX/bin/perl" -e 'printf("      5.008 as a number: %s (expect 5.008)\n", 5.008)' 2>&1
        "$PFX/bin/perl" -e 'printf("      int(5.008*1000):   %s (expect 5008)\n", int(5.008*1000))' 2>&1
        "$PFX/bin/perl" -e 'printf("      sprintf %%vd 5.8.0:  %s (expect 5.8.0)\n", sprintf("%vd", v5.8.0))' 2>&1
        say "    perl: $("$PFX/bin/perl" --version 2>&1 | grep -o 'v5[0-9.]*' | head -1)"
        # PROVE IT RUNS AND CAN BE FOUND BY NAME, which is how every consumer
        # above will reach it. `perl -e` failing here is a different problem
        # from `perl` not being on PATH, and the rungs above cannot tell them
        # apart from a "not found".
        if perl -e 'print "perl on PATH ok\n"' 2>/dev/null; then
          say "    perl on PATH: yes"
        else
          say "    perl installed but NOT on PATH -- the rungs above will not find it"
          R115=FAIL
        fi
      else
        R115=FAIL; say "    no perl at $PFX/bin/perl"
        tail -12 i.log 2>/dev/null | sed 's/^/      /'
      fi
    else
      R115=FAIL; say "    --- errors ---"
      # THE VERSION MESSAGE IS A MISCOMPILE, NOT A VERSION PROBLEM. Say so
      # here, because "Perl v8.0.0 required--this is only v5.42.0" reads like a
      # dependency and sends the next round looking for a newer perl.
      if grep -q "required--this is only" b.log 2>/dev/null; then
        # NO BACKTICKS IN A say STRING. The first version wrote `use 5.008`
        # with backticks for emphasis and the shell RAN it:
        #     rungs.sh: line 2661: use: not found
        # -- and the message then printed with an empty gap where the text
        # should have been. A diagnostic that mangles itself is the third one
        # in this job, after tr -dc and od -j.
        say "    ^ miniperl parsed a version wrongly: use 5.008 read as"
        say "      v8.0.0. That is the interpreter we just built computing a"
        say "      comparison incorrectly, i.e. a codegen fault in the chain,"
        say "      not a missing or too-old perl."
        grep -a "required--this is only" b.log | head -2 | sed 's/^/      /'
      fi
      # THE LINE ABOVE collect2 IS THE ONE THAT SAYS WHY. `collect2: error: ld
      # returned 1 exit status` is the driver reporting that the linker failed;
      # ld's own message -- "cannot find -lfoo", "undefined reference",
      # "relocation R_... against ..." -- is printed immediately before it and
      # was being dropped by a grep that only matched "error:".
      grep -B3 -a "collect2: error" b.log 2>/dev/null | grep -avE "^--|collect2" \
        | tail -8 | sed 's/^/      /'
      grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      tail -25 b.log 2>/dev/null | sed 's/^/      /'
    fi
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 12 -- LFS 5.4: linux API headers"
# THIS RUNS BEFORE 11.7 NOW, AND m4 IS WHY.
#
#     stackvma.c:327: fatal error: linux/fs.h: No such file or directory
#
# m4's bundled gnulib includes <linux/fs.h> to use PROCMAP_QUERY. Those are
# the API headers this rung installs, so m4 was being built one rung too
# early. The numbering is left alone -- 11.7 still reads as "the packages
# glibc demands" and 12 as "LFS 5.4" -- because renumbering would break every
# reference to them in the logs and the README for no gain.
#
# LFS DOES NOT HIT THIS: chapter 5.4 comes before anything in chapter 6 that
# could want kernel headers, and its m4 is chapter 6. Ours moved earlier
# because glibc's configure names it, so it landed on the wrong side of 5.4.
# TWO KERNELS, AND THEY ARE NOT THE SAME ONE. KHDR supplies the API headers
# glibc is compiled against; KERNEL is the image that boots. A kernel may
# always be newer than the headers its libc was built against, and stage 4
# keeps them separate precisely so a libc/kernel disagreement can be fixed by
# changing one number rather than rebuilding both.
if [ "$R115" = ok ]; then
  cd /work/src
  if ! untar "/in/linux-$KHDR"; then
    say "    linux $KHDR did not extract"; R12=FAIL
  else
    _lx=$(onedir "linux-$KHDR ./linux-$KHDR")
    ( cd "/work/src/$_lx"
      make mrproper > /dev/null 2>&1
      make headers > /dev/null 2>&1
      # Everything that is not a header is build residue; LFS deletes it
      # rather than copy it into the sysroot.
      find usr/include -type f ! -name '*.h' -delete
      mkdir -p "$S/usr"
      cp -r usr/include "$S/usr"
      # A SECOND COPY, FOR THE BOX, KEPT APART FROM THE SYSROOT'S.
      #
      # $S/usr/include is the SYSROOT's include tree and rung 13 is about to
      # put the whole of glibc in it. chain-cc -- the box's gcc 10, linking
      # musl -- must not see that, so it gets these headers at $PFX/include
      # where nothing else is ever installed.
      mkdir -p "$PFX/include"
      cp -r usr/include/. "$PFX/include/" )
    _nh=$(find "$S/usr/include" -name '*.h' 2>/dev/null | wc -l)
    _nb=$(find "$PFX/include" -name '*.h' 2>/dev/null | wc -l)
    say "    box copy at $PFX/include: $_nb headers (chain-cc reads these,"
    say "    and NOT the sysroot tree, which glibc is about to fill)"
    say "    API headers from linux $KHDR (the image will be linux $KERNEL)"
    say "    headers: $_nh files"
    # The macro stage 4 records here, for the same reason: it makes the next
    # libc/kernel disagreement a one-line diff rather than a rebuild.
    grep -rn "define OPEN_TREE_CLONE" "$S/usr/include/linux/mount.h" 2>/dev/null \
      | sed 's/^/      /' || true
    [ "$_nh" -gt 100 ] && R12=ok || { say "    too few headers -- make headers did not run"; R12=FAIL; }
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 11.7 -- m4, flex, bison, python: what glibc's configure demands"
# MEASURED, NOT INFERRED. glibc 2.43's own configure, run by tool-probe in a
# box with a controlled PATH:
#
#     *** These critical programs are missing or too old:
#         make gawk bison python
#
# LFS builds Python in chapter 7, for the chroot, before chapter 8's glibc --
# and never needs it at chapter 5 because chapter 5 runs on the HOST, which has
# one. We have no host at either point, so it moves here. That is the third
# time this chain has had to leave the book for the same reason, and the first
# time we had a measurement rather than an argument.
#
# make and gawk are already answered: rung 4.5 built make 4.4, and busybox awk
# handles what these configures use (ENVIRON, -f, gsub, printf, match, all
# measured) with a gawk wrapper in the box. glibc names gawk because it runs
# `gawk --version` and parses the number.
#
# THE SYSROOT HEADERS COME FROM chain-cc ITSELF, not from a flag here -- see
# the wrapper's own comment. Three runs were lost to this: ordering, then
# "installed is not found", then adding the flag to one of two configure lines.
#
# THE ORDER IS FORCED. m4 first, because bison and flex both need it. flex
# before bison, because BOTH stop at
#     configure: error: cannot find output from flex; giving up
# -- bison's scanner ships pre-generated so it would BUILD without flex, but
# its configure checks anyway and there is no --without to give it.
#
# Python last, and A STRIPPED PYTHON IS ENOUGH -- measured, not assumed.
#
# tool-probe read glibc's own source: every python script its makefiles invoke,
# and every module those import. The whole set is
#
#     argparse collections difflib inspect itertools json os re string struct
#     subprocess sys time unicodedata
#     + glibc's own glibcelf, glibcpp, glibcextract, abnf, unicode_utils
#
# Not one needs zlib, ssl, ctypes, libffi or anything else this box does not
# build. So python configures without those four, builds ~36 modules, reports
# "Could not build the ssl module", and is still exactly what glibc needs.
#
# CONFIRMED FROM THE OTHER DIRECTION TOO. tool-probe ran python's own configure
# in a sealed box with libz, libffi, libssl and libcrypto all absent, and it
# returned rc=0 -- python does not merely tolerate their absence, it does not
# stop for it. Two independent measurements, one reading glibc's source and one
# running python's configure, agreeing that these four are not needed here.
#
# (That probe then failed to COMPILE, on
#     pyatomic.h:588: #error "no available pyatomic implementation"
#  -- python 3.14 requires C11 atomics and tcc has none on aarch64. That is a
#  fact about tcc, not about this rung, which uses gcc 10.)
#
# "48 failed on import" in that build summary is not an error either: a static
# python cannot dlopen its shared extension modules, so they are reported
# unimportable and the interpreter works without them.
#
# The check after install still names what is missing. Being right about this
# once does not make it true forever, and a later rung may want more.
if [ "$R12" = ok ]; then
  r117=ok
  # GAWK FIRST, AND IT IS NOT OPTIONAL.
  #
  # The box ships a gawk wrapper around busybox awk. tool-probe measured that
  # busybox awk handles ENVIRON, -f, gsub, printf and match -- everything m4
  # and bison probe for -- and that measurement was correct. The inference
  # beyond it was not: glibc 2.44's own build scripts use more.
  #
  #     awk: bad regex '\/[^': Invalid regular expression
  #     awk: scripts/sysd-rules.awk:31: Call to undefined function
  #
  # A regex busybox's engine rejects, and a function it does not implement.
  # There is no flag for either.
  #
  # $PFX/bin PRECEDES /bin ON PATH, so the real gawk built here shadows the
  # wrapper automatically and nothing else needs changing. The wrapper stays
  # for the rungs below this one, which run before gawk exists and only need
  # what busybox awk genuinely provides.
  for pk in gawk m4 flex bison; do
    [ "$r117" = ok ] || break
    cd /work/src
    rm -rf "/work/src/$pk-t" && mkdir -p "/work/src/$pk-t"
    ( cd "/work/src/$pk-t" && untar "/in/$pk-" ) || { r117=FAIL; say "    $pk did not extract"; break; }
    _td=$(cd "/work/src/$pk-t" && onedir "$pk-* ./$pk-*")
    ( cd "/work/src/$pk-t/$_td" \
      && ./configure --prefix="$PFX" --disable-nls \
           CC="$PFX/bin/chain-cc -static" LDFLAGS="-static" > cfg.log 2>&1 \
      && timeout 2400 make -j"$NP" MAKEINFO=true > b.log 2>&1 \
      && make install MAKEINFO=true > /dev/null 2>&1 ) \
      || { r117=FAIL
           say "    $pk NOT INSTALLED"
           tail -12 "/work/src/$pk-t/$_td/cfg.log" 2>/dev/null | sed 's/^/      /'
           tail -12 "/work/src/$pk-t/$_td/b.log" 2>/dev/null | sed 's/^/      /'; }
    if [ "$r117" = ok ]; then
      # RUN IT, not just check the file. Three rungs in this job reported ok
      # for a binary that could not execute.
      say "    $pk: $("$PFX/bin/$pk" --version 2>&1 | head -1)"
    fi
  done

  if [ "$r117" = ok ]; then
    cd /work/src
    rm -rf /work/src/py && mkdir -p /work/src/py
    ( cd /work/src/py && untar "/in/Python-$PYTHON_VER" ) || { r117=FAIL; say "    python did not extract"; }
    _pyd=$(cd /work/src/py && onedir "Python-* ./Python-*")
    if [ "$r117" = ok ] && [ -n "$_pyd" ]; then
      say "    --- libraries python wants that this box does not have ---"
      for _l in libz libffi libssl libcrypto; do
        ls "$SYS/usr/lib/$_l"* "/usr/lib/$_l"* >/dev/null 2>&1 \
          || printf '      %s\n' "$_l"
      done
      # EACH PHASE REPORTS ITS OWN RESULT.
      #
      # The previous version chained configure && make && install and printed
      # the tail of b.log on any failure. The last run showed Python's module
      # SUMMARY -- "Checked 114 modules ... 48 failed on import" -- which is
      # what the end of a SUCCESSFUL build looks like, and no error at all. So
      # make had worked and `make install` was the thing that failed, and the
      # log said nothing about it.
      #
      # "48 failed on import" is also not an error: a statically linked Python
      # cannot dlopen its shared extension modules, so they are reported as
      # unimportable and the interpreter is fine without them.
      ( cd "/work/src/py/$_pyd"
        # ax_cv_c_float_words_bigendian IS PRESET HERE TOO, and it is cheap
        # insurance rather than a known need.
        #
        # tool-probe hit "Unknown float word ordering" building python with
        # tcc: the macro compiles a magic string and greps the object for it,
        # and tcc's layout defeats the grep. gcc 10 is expected to be fine --
        # but "expected" is what the last several rounds have been made of,
        # and the value is not a guess: aarch64 is little-endian in both word
        # and byte order.
        #
        # A preset autoconf cache variable is skipped, not overridden, when
        # the probe would have succeeded -- so this costs nothing if gcc 10
        # never needed it.
        # --disable-shared AND Setup.local: NO EXTENSION MODULES AS .so.
        #
        # The build succeeded and `make install` did not:
        #
        #     install: can't stat 'Modules/array.cpython-314.so': No such file
        #     make: *** [Makefile:2528: sharedinstall] Error 1
        #     ModuleNotFoundError: No module named '_struct'
        #
        # sharedinstall installs extension modules as .so files, and a static
        # python never produced any -- they are linked INTO the interpreter.
        # The ModuleNotFoundError is the same thing from the other side: the
        # install step runs the new python to byte-compile the stdlib, and it
        # cannot dlopen _struct because there is nothing to open.
        #
        # This is exactly perl's -Dusedl=undef one package later, and the same
        # reason: rung 2 builds musl as libc.a with no libc.so, and rung 3
        # measures that a dynamic binary cannot run in this box at all.
        #
        # Modules/Setup.local with "*static*" tells the build to link every
        # module in rather than emit .so files, which is what CPython's own
        # instructions say for a static interpreter. --disable-shared stops
        # libpython itself being shared.
        # Setup.local IS WRITTEN AFTER configure, NOT BEFORE, AND IT NEEDS
        # MODULE LINES.
        #
        # The previous version wrote just "*static*" before configure. That
        # marker sets the mode for the lines that FOLLOW it, and there were
        # none -- so it did nothing at all, and CPython 3.12+ went on to
        # generate Modules/Setup.stdlib from configure and build the extension
        # modules its own way.
        #
        # The install then succeeded, the interpreter ran, and glibc died on
        #
        #     ModuleNotFoundError: No module named '_posixsubprocess'
        #
        # reached through scripts/glibcextract.py -> import subprocess ->
        # from _posixsubprocess import fork_exec. A static python cannot
        # dlopen it, and the module list this rung prints never mentioned it
        # because that list was a set of names I chose rather than a
        # measurement.
        #
        # So: configure first, then take the module lines configure generated
        # and re-declare every one of them static.
        :
        # MODULE_BUILDTYPE=static IS THE SUPPORTED SWITCH, AND IT IS ONE WORD.
        #
        # Read out of CPython's configure.ac:
        #
        #     MODULE_BUILDTYPE=${MODULE_BUILDTYPE:-shared}     (line 8311)
        #
        #     if WASI or MODULE_BUILDTYPE = static:
        #         LIBHACL_LDEPS_LIBTYPE=STATIC     -> an .a archive
        #     else
        #         LIBHACL_LDEPS_LIBTYPE=SHARED     -> raw .o files  (line 8568)
        #
        # It reads the ENVIRONMENT, generates Modules/Setup.stdlib with every
        # module already under *static*, AND switches the HACL* crypto sources
        # to link as archives rather than loose objects.
        #
        # THAT SECOND PART IS WHY HAND-EDITING Setup.local FAILED. Rewriting
        # *shared* to *static* moved the modules but left LIBHACL_*_LDFLAGS
        # pointing at the raw objects configure had already chosen, so each
        # one arrived on the link line twice:
        #
        #     Modules/_hacl/Hacl_Hash_Blake2b.o: multiple definition of
        #     '_Py_LibHacl_Hacl_Hash_Blake2b_hash_with_key'
        #
        # My diagnosis then was "static _hacl modules cannot work", and that
        # was wrong -- a normal Ubuntu python has _blake2, _sha3, _md5, _sha1
        # and _sha2 all built in. The modules were never the problem; editing
        # one half of a two-part configure decision was.
        MODULE_BUILDTYPE=static \
        ax_cv_c_float_words_bigendian=no \
        ./configure --prefix="$PFX" --without-ensurepip --disable-test-modules \
          --disable-shared \
          CC="$PFX/bin/chain-cc -static" LDFLAGS="-static" > cfg.log 2>&1
        _c=$?; echo "      configure rc=$_c"
        [ "$_c" = 0 ] || { grep -aiE "error|cannot find|not found" cfg.log \
                             | tail -8 | sed 's/^/        /'; exit 1; }

        # EVERY MODULE configure DECIDED ON, FORCED STATIC.
        #
        # Modules/Setup.stdlib is generated by configure and lists each
        # extension module with its sources. Copying those lines under a
        # *static* marker is CPython's own documented way to link them into
        # the interpreter instead of emitting .so files.
        # (Setup.local is no longer written by hand -- MODULE_BUILDTYPE
        # below does the whole job coherently. See the configure line.)
        if [ -f Modules/Setup.stdlib ]; then
          echo "      Setup.stdlib sections, as configure generated them:"
          for _sec in static shared disabled; do
            printf '        %-9s %s\n' "$_sec" \
              "$(awk -v s="\\*$_sec\\*" '$0~s{m=1;next} /^\*/{m=0} m&&/^[a-zA-Z_]/{n++} END{print n+0}' Modules/Setup.stdlib) modules"
          done
          # THE ONE THAT SENT US HERE. glibc's scripts/glibcextract.py imports
          # subprocess, which does `from _posixsubprocess import fork_exec`.
          printf '        _posixsubprocess is: %s\n' \
            "$(awk '/^\*/{sec=$0} /^_posixsubprocess/{print sec; exit}' Modules/Setup.stdlib)"
        fi
        timeout 3600 make -j"$NP" > b.log 2>&1
        _m=$?; echo "      make rc=$_m"
        if [ "$_m" != 0 ]; then
          grep -aE "^[^ ]*error:|Error [0-9]|undefined reference" b.log \
            | head -10 | sed 's/^/        /'
          tail -10 b.log | sed 's/^/        /'
          exit 1
        fi
        # `make install` NOT `make install`, DELIBERATELY: altinstall and the
        # ensurepip/compileall phases both RUN the interpreter that was just
        # built, and a statically linked python cannot dlopen its shared
        # extension modules -- which is exactly the "48 failed on import" the
        # build summary reports. If the install trips on that, the answer is
        # to skip the byte-compilation rather than to make python dynamic,
        # because this box has no loader at all.
        # THE FALLBACKS ARE AIMED AT THE TWO THINGS THAT ACTUALLY FAILED.
        #
        #   sharedinstall  installs .so modules a static build never made
        #   libinstall     byte-compiles the stdlib by RUNNING the new python
        #
        # If Setup.local did its job neither arises. If it did not, skipping
        # them still yields a working interpreter -- byte-compilation is a
        # speed optimisation, and there are no .so files to miss.
        make install > i.log 2>&1 \
          || make install COMPILEALL_OPTS=-x'.*' > i.log 2>&1 \
          || { make -k install > i.log 2>&1
               # -k keeps going past sharedinstall; the interpreter and the
               # stdlib are installed by other targets and are what we need.
               [ -x "$PFX/bin/python3" ] || [ -x "$PFX/bin/python3.14" ]; }
        _i=$?; echo "      install rc=$_i"
        [ "$_i" = 0 ] || { grep -aiE "error|cannot|permission|no such" i.log \
                             | tail -10 | sed 's/^/        /'
                           tail -10 i.log | sed 's/^/        /'; exit 1; }
        exit 0 ) \
        || { r117=FAIL; say "    python NOT INSTALLED"; }
      if [ "$r117" = ok ]; then
        _py=$(ls "$PFX/bin"/python3* 2>/dev/null | head -1)
        # THE PLAIN NAMES, BECAUSE glibc's configure LOOKS FOR THEM.
        #
        #     checking for python3... no
        #     checking for python... no
        #     *** These critical programs are missing or too old: gawk python
        #
        # CPython installs the versioned binary -- python3.14 -- and creates
        # the python3 and python symlinks in a later phase of `make install`.
        # This box takes the `make -k install` fallback when sharedinstall
        # fails, and -k does not guarantee those links were reached.
        #
        # So make them here rather than depend on which install phase ran.
        # Both names: glibc checks python3 first and python second, and
        # nothing is served by having only one.
        if [ -n "$_py" ]; then
          for _n in python3 python; do
            [ -e "$PFX/bin/$_n" ] || ln -sf "$(basename "$_py")" "$PFX/bin/$_n"
          done
          say "    names on PATH: $(ls "$PFX/bin"/python* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
        fi
        say "    python: $("$_py" --version 2>&1 | head -1)"
        # WHAT IT BUILT WITHOUT. glibc only needs the interpreter, so a Python
        # missing zlib is fine HERE -- but saying so now is cheaper than
        # discovering it when something above wants to read a .zip.
        # WHAT glibc ASKS OF THIS PYTHON, ASKED DIRECTLY.
        #
        # glibc 2.44 runs scripts/gen-tunable-list.py during its build. That
        # script uses re, os and sys and nothing else -- no zlib, no ssl, no
        # ctypes. So a python missing 48 importable extension modules is very
        # likely still enough, and this is the test that says so rather than
        # leaving it to the module count.
        say "    --- can it run what glibc will run? ---"
        "$_py" -c 'import re,os,sys; print("      re/os/sys ok, python", sys.version.split()[0])' 2>&1 \
          | sed 's/^/  /' || say "      IT CANNOT -- glibc will fail at gen-tunable-list.py"
        # WHAT IS ACTUALLY BUILT IN, MEASURED. The previous check tested a
        # list of names I picked -- zlib, ssl, ctypes, readline, sqlite3, bz2,
        # lzma -- and _posixsubprocess was not among them, so glibc found the
        # gap instead. Ask the interpreter what it has rather than asking
        # about the modules I happened to think of.
        say "    --- built-in modules ($("$_py" -c 'import sys;print(len(sys.builtin_module_names))' 2>/dev/null) of them) ---"
        "$_py" -c 'import sys;print("     ", " ".join(sorted(sys.builtin_module_names)))' 2>&1 \
          | fold -w 74 -s | sed 's/^/  /'
        # AND THE ONES glibc REACHES THROUGH ITS OWN IMPORTS. subprocess is a
        # .py file that imports a C extension; so is os, and so are several
        # others. Importing the module is the only honest test.
        say "    --- can it import what glibc's scripts import? ---"
        for _m in re os sys subprocess collections argparse json struct \
                  itertools difflib inspect time string; do
          "$_py" -c "import $_m" 2>/dev/null \
            || say "      CANNOT IMPORT: $_m  -- glibc will fail on this"
        done
        say "      (nothing listed means every one of them imports)"
        say "    --- modules that did NOT build ---"
        "$_py" -c 'import importlib.util as u
for m in ("zlib","ssl","ctypes","readline","sqlite3","bz2","lzma"):
    print("     ", m) if not u.find_spec(m) else None' 2>&1 | head -8
      fi
    fi
  fi
  R117=$r117
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 13 -- LFS 5.5: glibc, cross-compiled into the sysroot"
# THIS IS THE RUNG THAT DECIDES WHETHER python COMES EARLIER THAN THE BOOK PUTS
# IT.
#
# LFS builds glibc twice -- chapter 5 here, chapter 8 again -- and there is a
# Python available both times: the HOST's at chapter 5, and chapter 7's
# (Bison, Perl, Python, Texinfo, together) before chapter 8. The book never
# builds glibc without one; it just gets the first for free.
#
# This box has no host, so if chapter 5's glibc actually invokes python3, bison
# or gawk, this fails with "not found" -- specific and legible -- and those
# move earlier than LFS puts them, for a reason LFS never has to face. If it
# does not, we follow the book's shape exactly.
#
# Either answer is one run. Nothing here should be guessed at.
if [ "$R117" = ok ]; then
  cd /work/src
  if ! untar "/in/glibc-$GLIBC"; then
    say "    glibc did not extract"; R13=FAIL
  else
    _gl=$(onedir "glibc-$GLIBC ./glibc-$GLIBC")
    cd "/work/src/$_gl"
    # ONE PATCH NOW, AND THE OTHER ONE'S DISAPPEARANCE IS THE STORY.
    #
    # glibc-2.43-upstream_fixes-1.patch was "THE PRICE OF LINUX 7" -- it
    # reconciled a 2.43 glibc with a 7.x kernel's headers. Two runs died
    # fetching it with a 404 while every other file came down from the same
    # directory, and the newer book says why: r13.0-167 moved to GLIBC 2.44,
    # which needs no such reconciliation, and dropped the patch from section
    # 3.3 entirely.
    #
    # So the fix for a missing patch was to stop needing it. glibc-fhs-1.patch
    # is still listed, still the same digest, and still downloads.
    for _pt in glibc-fhs-1.patch; do
      if [ -f "/in/$_pt" ]; then
        if patch -Np1 -i "/in/$_pt" > /tmp/gp.log 2>&1; then
          say "    applied $_pt"
        else
          say "    $_pt DID NOT APPLY:"; tail -6 /tmp/gp.log | sed 's/^/      /'
          R13=FAIL
        fi
      else
        say "    $_pt not in /in -- fetch it"; R13=FAIL
      fi
    done

    if [ "$R13" != FAIL ]; then
      rm -rf /work/b-glibc && mkdir -p /work/b-glibc && cd /work/b-glibc
      # WHAT glibc IS ABOUT TO LOOK FOR, CHECKED FIRST.
      #
      # Its configure reported "These critical programs are missing or too old:
      # gawk python" and stopped -- after rung 11.7 had built and installed
      # both. gawk failed a VERSION PARSE and python was installed under its
      # versioned name only. Neither was a missing package, and neither was
      # visible until glibc said so.
      say "    --- the four programs glibc checks ---"
      for _t in gawk bison python3 make; do
        if command -v "$_t" >/dev/null 2>&1; then
          printf '      %-8s %-34s %s\n' "$_t" \
            "$("$_t" --version 2>&1 | head -1)" "$(command -v "$_t")"
        else
          printf '      %-8s NOT ON PATH\n' "$_t"
        fi
      done

      # AND IS THAT gawk A REAL ONE? The version string is not enough: the box
      # ships a wrapper that ANSWERS "GNU Awk 5.3.1" while being busybox awk,
      # and glibc's configure accepted it and then its build died on
      #
      #     awk: bad regex '\/[^': Invalid regular expression
      #     awk: scripts/sysd-rules.awk:31: Call to undefined function
      #
      # So exercise the two things that failed rather than trusting the
      # banner.
      #
      # THESE ARE WEAK PROBES AND THAT IS WORTH SAYING. Both constructs pass
      # on mawk, which is not gawk either -- they discriminate against an awk
      # MORE limited than mawk, which is what busybox's is. They would not
      # catch a missing gawk-only extension like gensub or asort.
      #
      # The strong check is the one below it: is the gawk on PATH the one rung
      # 11.7 built, or the wrapper the box assembly wrote. That is exact, and
      # these two are the cheap confirmation that it behaves.
      say "    --- is that gawk real, or the wrapper? ---"
      # THE EXACT QUESTION: which file is it. The wrapper lives in /bin and
      # the built gawk in $PFX/bin, which precedes it on PATH.
      _gp=$(command -v gawk 2>/dev/null)
      case "$_gp" in
        "$PFX"/bin/*) say "      $_gp -- the gawk rung 11.7 built" ;;
        *)            say "      $_gp -- THE WRAPPER, not a real gawk."
                      say "      rung 11.7 did not install one, and glibc's"
                      say "      build scripts will fail on regex and function"
                      say "      support busybox awk does not have."
                      R13=FAIL ;;
      esac
      if echo | gawk 'function f(x) { return x + 1 } { print f(1) }' 2>/dev/null | grep -qx 2; then
        say "      user-defined functions: yes"
      else
        say "      user-defined functions: NO -- this is not a usable gawk"
        say "      glibc will fail at scripts/sysd-rules.awk"
        R13=FAIL
      fi
      if echo 'a/b' | gawk '/[^\/]/ { print "ok" }' 2>/dev/null | grep -qx ok; then
        say "      bracket expressions with escaped slash: yes"
      else
        say "      bracket expressions with escaped slash: NO"
        say "      glibc will fail at scripts/gen-sorted.awk"
        R13=FAIL
      fi

      say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: glibc configure"
      "/work/src/$_gl/configure" \
        --prefix=/usr \
        --host="$VERON_TOOLCHAIN_TGT" \
        --build="$(/work/src/$_gl/scripts/config.guess)" \
        --enable-kernel="$ENABLE_KERNEL" \
        --with-headers="$S/usr/include" \
        --disable-nscd \
        libc_cv_slibdir=/usr/lib \
        > cfg.log 2>&1
      _r13=$?
      say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r13)"
      if [ "$_r13" != 0 ]; then
        R13=FAIL
        # NAME THE MISSING TOOL IF THAT IS WHAT IT IS, because that is the
        # whole question this rung was built to answer.
        grep -aiE "python|bison|gawk|not found|no acceptable" cfg.log 2>/dev/null \
          | head -8 | sed 's/^/      /'
        tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
      elif timeout 7200 make -j"$NP" > b.log 2>&1 \
           && make DESTDIR="$S" install > i.log 2>&1; then
        R13=ok
        say "    glibc installed into $S"
        say "    libc.so.6: $( [ -f "$S/usr/lib/libc.so.6" ] && wc -c < "$S/usr/lib/libc.so.6" || echo ABSENT )"
      else
        R13=FAIL; say "    --- errors ---"
        grep -aiE "python|bison|gawk|command not found" b.log 2>/dev/null | head -6 | sed 's/^/      /'
        grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
        # Stage 4's own diagnosis for the one failure it expects here.
        if grep -q "redefined \[-Werror\]" b.log 2>/dev/null; then
          say "    --- this is a libc/kernel-header pairing failure ---"
          say "    glibc $GLIBC built against linux $KHDR headers. The"
          say "    glibc $GLIBC is the version the book pairs with linux $KHDR,"
          say "    so this pairing is the one upstream tests. If it still fails,"
          say "    the fault is ours rather than a version mismatch -- the"
          say "    2.43-era upstream_fixes patch no longer exists because 2.44"
          say "    does not need it."
        fi
        tail -25 b.log 2>/dev/null | sed 's/^/      /'
      fi
    fi
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 14 -- LFS 5.6: libstdc++ from the gcc 15 tree"
# gcc pass 1 was built --disable-libstdcxx because there was no libc. There is
# one now, so libstdc++ is built on its own, against it, from the SAME gcc tree
# -- not a separate download, which is why the book builds it here rather than
# with the compiler.
if [ "$R13" = ok ]; then
  rm -rf /work/b-libstdcxx && mkdir -p /work/b-libstdcxx && cd /work/b-libstdcxx
  say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: libstdc++ configure"
  "/work/src/$g15/libstdc++-v3/configure" \
    --host="$VERON_TOOLCHAIN_TGT" --build="$(/work/src/$g15/config.guess)" \
    --prefix=/usr --disable-multilib --disable-nls \
    --disable-libstdcxx-pch \
    --with-gxx-include-dir="/tools/$VERON_TOOLCHAIN_TGT/include/c++/$GCC15" \
    > cfg.log 2>&1
  _r14=$?
  say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r14)"
  if [ "$_r14" != 0 ]; then
    R14=FAIL; tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
  elif timeout 3600 make -j"$NP" > b.log 2>&1 \
       && make DESTDIR="$S" install > i.log 2>&1; then
    R14=ok
    # THE MARKER, WRITTEN ONLY HERE. Chapter 5 is complete: a cross toolchain
    # and a glibc sysroot. The workflow caches $S only when this file exists,
    # so a half-built sysroot can never be restored as a good one -- which
    # would fail three rungs above where the wrong thing was restored and look
    # like a compiler bug. Same discipline as stage 4's "sysroot marked
    # complete".
    printf 'chapter 5 complete: binutils pass 1, gcc 15 pass 1, linux %s headers, glibc %s, libstdc++\n' \
      "$KHDR" "$GLIBC" > "$S/.chapter5-complete"
    say "    marked $S/.chapter5-complete"
    say "    libstdc++ installed into $S"
    ls "$S/usr/lib"/libstdc++* 2>/dev/null | sed 's/^/      /' | head -4
  else
    R14=FAIL; say "    --- errors ---"
    grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
    tail -25 b.log 2>/dev/null | sed 's/^/      /'
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 15 -- LFS chapter 6: busybox, in place of seventeen packages"
# A DECLARED SUBSTITUTION, AND IT IS STAGE 4's. LFS chapter 6 builds seventeen
# packages -- m4, ncurses, bash, coreutils, diffutils, file, findutils, gawk,
# grep, gzip, make, patch, sed, tar, xz -- to get a shell and the text tools.
# BusyBox is one package that supplies sh, sed, grep, awk, tar and the
# coreutils, and tcc-userland-arm64 already proved it builds and boots.
#
# This box has been driven by the HOST's busybox since rung 0. The one built
# here is different: it goes in the SYSROOT, cross-compiled by $VERON_TOOLCHAIN_TGT-gcc,
# and it is what the booted kernel runs. Building it also means the box could
# stop borrowing the host's -- BUDGET_DRIVER reaching empty is a later rung,
# but this is the piece that makes it possible.
#
# THE TWO TRAPS ARE STAGE 4's, RECORDED AFTER IT HIT BOTH:
#
#   ORDER. Seds must come AFTER `make oldconfig`, not before -- oldconfig
#   re-derives selected symbols and CONFIG_TLS came straight back, failing
#   identically. Configure first, disable second, then VERIFY.
#
#   CFLAGS_EXTRA, NOT EXTRA_CFLAGS. BusyBox's Makefile.flags does
#   `CFLAGS += $(CFLAGS_EXTRA)`; there is no EXTRA_CFLAGS anywhere in its build
#   system. Two consecutive "fixes" spelled into a variable nothing reads did
#   nothing at all, and the same error came back verbatim each time. A flag
#   that is silently ignored looks exactly like a flag that did not help.
# THIS BUSYBOX IS A CHAPTER 6 PACKAGE, AND IT IS NOT THE ONE THAT SHIPS.
#
# It is CROSS-compiled by $VERON_TOOLCHAIN_TGT-gcc -- gcc 15 pass 1 -- and installed into
# the sysroot, and it is never executed on this side. That is exactly what LFS
# chapter 6 is: "Those utilities are installed into their final location, but
# cannot be used yet ... Using the utilities will be possible in the next
# chapter after entering the chroot environment."
#
# Its only job is to give phase B a shell. Phase B runs configure scripts with
# the sysroot bound as /, and a configure script is a shell script: without
# /usr/bin/sh there is nothing to run one with. The applet symlink loop is what
# creates that name, and copying the binary alone does not.
#
# THE ONE THAT SHIPS IS BUILT IN PHASE B, by the final gcc, and overwrites this
# one. Do not read this rung as the initramfs busybox. An earlier revision
# tried to build the shipping copy here with pass 2 and could not, because pass
# 2 does not execute on this side of the boundary at all.
#
# make IS THE BOX's, NOT THE SYSROOT's. $PFX/bin/make is the musl-static 4.4
# from rung 4.5 and it runs here; the sysroot's make is glibc-linked and does
# not. Only the COMPILER is the cross one.
if [ "$R14" = ok ]; then
  cd /work/src
  if ! untar /in/busybox-; then
    say "    busybox did not extract"; R15=FAIL
  else
    _bb=$(onedir 'busybox-* ./busybox-*')
    cd "/work/src/$_bb"
    _BBMAKE="make ARCH=riscv CROSS_COMPILE=$VERON_TOOLCHAIN_TGT- HOSTCC=$PFX/bin/chain-cc"
    $_BBMAKE defconfig > /dev/null 2>&1
    yes '' | $_BBMAKE oldconfig > /dev/null 2>&1
    # CONFIG_SSL_CLIENT is the applet that drags in networking/tls*.c, which
    # reaches for LONG_BIT without the feature macro. A build sysroot has no
    # use for HTTPS; drop the applet rather than patch a feature-test mismatch.
    # AND CONFIG_TC, WHICH THE AIRLOCK BUSYBOX BUILD ALREADY DISABLES.
    #
    #     networking/tc.c:236: 'TCA_CBQ_MAX' undeclared
    #     invalid application of 'sizeof' to incomplete type 'struct tc_cbq_lssopt'
    #
    # CBQ traffic control was removed from the kernel and busybox 1.36.1
    # predates that, so tc.c cannot compile against linux 7.1.5 headers at all.
    # The airlock step that builds the box's own busybox disables it and has
    # done since that failure was first seen -- this build did not, because the
    # two configurations are written out separately and only one was fixed.
    #
    # Same shape as the -isystem flag that took three rounds: a fix applied to
    # one of two places that need it. Both busybox configurations should be
    # read together whenever either changes.
    for _sym in SSL_CLIENT FEATURE_WGET_OPENSSL TLS TC; do
      sed -i "s/^CONFIG_$_sym=y/# CONFIG_$_sym is not set/" .config
    done
    # THE BUILD APPLETS, AND THIS IS THE SAME LIST THE AIRLOCK busybox USES.
    #
    # defconfig was right when this busybox only had to be an initramfs shell.
    # It is now the SYSROOT's entire userland: phase B runs configure scripts
    # with $S bound as /, and a configure script shells out to dozens of
    # ordinary utilities.
    #
    # split AND comm ARE THE NAMED CASE, and phase A already paid for it.
    # perl's Configure is a 1990s shell script that calls both, busybox has
    # NEITHER at defconfig, and rung 11.5 had to write them in C into $PFX to
    # get past "./Configure: line 2135: split: not found". $PFX is not on
    # phase B's PATH and must not be -- so the applets have to be here.
    #
    # ASSERTED AFTER oldconfig, because oldconfig re-derives symbols and has
    # silently undone edits in this file before.
    for _sym in SPLIT COMM JOIN PASTE EXPAND UNEXPAND FOLD NL TSORT CMP DIFF PATCH AWK SED GREP SORT UNIQ TR CUT XARGS FIND WHICH ENV BASENAME DIRNAME; do
      sed -i "s/^# CONFIG_$_sym is not set/CONFIG_$_sym=y/" .config
      grep -q "^CONFIG_$_sym=y" .config || echo "CONFIG_$_sym=y" >> .config
    done
    # VERIFY AFTER, because a sed that matches nothing is silent and
    # oldconfig is what undid the same edit three runs running.
    _missing=""
    for _sym in SPLIT COMM AWK SED GREP SORT CUT TR FIND XARGS; do
      grep -q "^CONFIG_$_sym=y" .config || _missing="$_missing $_sym"
    done
    if [ -n "$_missing" ]; then
      say "    THESE BUILD APPLETS DID NOT SURVIVE oldconfig:$_missing"
      say "    perl's Configure needs split and comm; the rest are what any"
      say "    configure script shells out to. Phase B would fail on the"
      say "    first package and name the package, not the missing applet."
      R15=FAIL
    fi
    if grep -qE "^CONFIG_(SSL_CLIENT|TLS)=y" .config; then
      say "    TLS symbols came back after oldconfig:"
      grep -E "^CONFIG_(SSL_CLIENT|TLS|FEATURE_WGET_OPENSSL)" .config | sed 's/^/      /'
      R15=FAIL
    fi
    if [ "$R15" != FAIL ]; then
      # THE TWO BUSYBOX CONFIGURATIONS DIFFER ON PURPOSE, AND ONLY HERE.
      #
      #   airlock  the box's own toolbox. Turns SPLIT, COMM, JOIN, PASTE and a
      #            dozen others ON, because the BUILD needs them -- perl's
      #            Configure wants split and comm, and Ubuntu's busybox has
      #            neither.
      #   rung 15  the initramfs. Needs an init, a shell and enough to prove
      #            the kernel booted. defconfig covers that.
      #
      # What they must NOT differ on is what cannot COMPILE: TLS and TC are
      # disabled in both, and this rung failed because TC was fixed in one of
      # them only.
      #
      # CONFIG_STATIC, ASSERTED. The last run reported "static: NO" and this
      # sed is why: it rewrites "# CONFIG_STATIC is not set", and if oldconfig
      # has already written "CONFIG_STATIC=n" -- or written nothing at all --
      # it matches nothing and says nothing. A sed that matches nothing ships
      # an unchanged file and looks exactly like one that worked, which is the
      # rule this file states three rungs earlier and did not apply here.
      sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
      grep -q '^CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config
      # AND AGAIN AFTER oldconfig RE-DERIVES, which is what undid the TLS
      # symbols three runs running.
      yes '' | $_BBMAKE oldconfig > /dev/null 2>&1
      if ! grep -q '^CONFIG_STATIC=y' .config; then
        say "    CONFIG_STATIC did not survive oldconfig:"
        grep -E '^(# )?CONFIG_STATIC' .config | sed 's/^/      /'
        say "    A dynamic busybox in the initramfs needs a loader and a libc"
        say "    that the initramfs does not contain, so it cannot run at all."
        R15=FAIL
      fi
      if timeout 3600 $_BBMAKE \
           CFLAGS_EXTRA="-D_GNU_SOURCE" -j"$NP" > b.log 2>&1 && [ -x busybox ]; then
        mkdir -p "$S/usr/bin"
        cp busybox "$S/usr/bin/busybox"
        # --install, WHICH THE SYSROOT IS USELESS WITHOUT.
        #
        # Copying the binary gives the sysroot ONE file called busybox. Every
        # other name -- sh, cat, mount, mkdir -- is a symlink to it, and
        # nothing creates those symlinks except this.
        #
        # Rungs 16 and 17 run configure scripts INSIDE the sysroot, and a
        # configure script is a shell script: without /usr/bin/sh there is
        # nothing to run it with. stage4-complete does this immediately after
        # the copy and asserts the count; we copied and did not.
        #
        # NOT `busybox --install`, AND THAT IS THE WHOLE OF THIS FIX.
        #
        # `busybox --install -s DIR` does not write the literal string
        # "busybox" as each link's target. It resolves its OWN path first --
        # xmalloc_readlink(bb_busybox_exec_path), i.e. /proc/self/exe -- and
        # records that. Run from this box, every applet link came out
        # pointing at /work/lfs/usr/bin/busybox.
        #
        # That path is correct HERE and nowhere else. Phase B binds the
        # sysroot AS /, so the same file is /usr/bin/busybox and /work/lfs
        # does not exist. Runs 117, 118 and 119 all died at
        #
        #     bwrap: execvp /usr/bin/sh: No such file or directory
        #
        # before a single phase B rung ran -- a symlink that exists but whose
        # target does not resolve gives exactly ENOENT on exec. Phase A never
        # noticed because `[ -e ]` FOLLOWS the link, and in this box the
        # target does resolve.
        #
        # hermetic-gcc15.yml uses --install and is fine, which stalled the
        # diagnosis for two rounds: it runs the command from INSIDE box15.sh,
        # where the sysroot is already /, so the path it records is correct
        # in the namespace that later uses it. Same command, different
        # sandbox, opposite result.
        #
        # `ln -sf busybox "$_a"` writes the literal target and resolves
        # against the link's own directory in ANY root. That is what the
        # initramfs loop in hermetic-gcc15.yml does, for the same reason.
        #
        # SKIP THE busybox ENTRY. It IS in --list, and `ln -sf busybox
        # busybox` would replace the real binary with a link to itself --
        # the whole sysroot userland gone in one loop iteration.
        # DO NOT LINK OVER A REAL BINARY THAT IS ALREADY THERE.
        #
        # Rung 13 installed glibc into this directory ~18 binaries ago, and
        # busybox has an applet called `ldd` -- so an unguarded loop replaces
        # glibc's ldd with a busybox symlink. `--install` did that too, which
        # made it easy to wave through as "not a regression"; it is still a
        # package's file being silently replaced by a different program.
        #
        # The guard is general rather than an ldd special case: anything that
        # is already a regular file here was installed by a rung that meant
        # it, and an applet must not shadow it. Symlinks ARE overwritten, so
        # re-running over a restored sysroot still refreshes the farm.
        ( cd "$S/usr/bin"
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
        # R15=ok GOES HERE, BEFORE THE CHECKS, NOT AFTER THEM.
        #
        # It used to sit below the applet-count test, so a run that linked
        # nothing set R15=FAIL and then had it overwritten by R15=ok two
        # lines later. Every check from here down can override it, which is
        # what the static test below has always assumed.
        R15=ok
        _n=$(ls "$S/usr/bin" | wc -l)
        say "    applets linked into the sysroot: $_n"
        if [ "$_n" -lt 100 ]; then
          say "    TOO FEW -- the sysroot has no shell, and phase B runs"
          say "    configure scripts inside it. Not continuing."
          R15=FAIL
        fi
        # THE ONE THAT MATTERS MOST, AND `-e` IS THE WRONG QUESTION.
        #
        # This was `[ -e "$S/usr/bin/sh" ]`, which FOLLOWS the symlink and so
        # answered yes about a sysroot phase B could not enter. Read the
        # TARGET instead: it must be relative, or it is only valid in this
        # box. Set after R15=ok, matching the static check below.
        _lt=$(readlink "$S/usr/bin/sh" 2>/dev/null || true)
        case "$_lt" in
          busybox)
            say "    /usr/bin/sh -> busybox   (relative; resolves in any root)" ;;
          "")
            say "    /usr/bin/sh IS NOT A SYMLINK -- the applet loop did not run"
            R15=FAIL ;;
          /*)
            say "    /usr/bin/sh -> $_lt"
            say "    ABSOLUTE, so it names a path that exists only in this box."
            say "    Phase B binds the sysroot as / and bwrap cannot exec it."
            R15=FAIL ;;
          *)
            say "    /usr/bin/sh -> $_lt   (unexpected target)"
            R15=FAIL ;;
        esac
        # AND THE BINARY EVERY ONE OF THOSE LINKS POINTS AT.
        if [ ! -f "$S/usr/bin/busybox" ] || [ -L "$S/usr/bin/busybox" ]; then
          say "    /usr/bin/busybox is not a regular file -- it was overwritten"
          R15=FAIL
        fi
        produced busybox
        say "    applets: $(./busybox --list 2>/dev/null | wc -l)"
        # THE BINARY ITSELF, not a grep for a substring. A static ELF has no
        # PT_INTERP program header; readelf says so exactly.
        if "$S/tools/bin/$VERON_TOOLCHAIN_TGT-readelf" -l busybox 2>/dev/null | grep -q "interpreter"; then
          say "    static:  NO -- this busybox needs a dynamic loader"
          "$S/tools/bin/$VERON_TOOLCHAIN_TGT-readelf" -l busybox 2>/dev/null \
            | grep -A1 "interpreter" | head -2 | sed 's/^/      /'
          R15=FAIL
        else
          say "    static:  yes (no PT_INTERP)"
        fi
      else
        R15=FAIL; say "    --- errors ---"
        grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
        tail -25 b.log 2>/dev/null | sed 's/^/      /'
      fi
    fi
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 16 -- LFS 6.x: binutils pass 2 and gcc pass 2"
# PASS 2 IS BUILT BY THE CROSS TOOLCHAIN, FOR THE SYSROOT. Pass 1 produced a
# cross compiler running on this box; pass 2 produces the tools the SYSTEM has,
# linked against the glibc rung 13 installed.
#
# limits.h HAS TO HAVE BEEN REASSEMBLED AT RUNG 11 or binutils pass 2 dies on
#     ld/ldmain.c:646: error: 'PATH_MAX' undeclared
# which names a macro rather than the include chain that lost it. That is why
# rung 11 concatenates limitx.h/glimits.h/limity.h instead of leaving gcc's
# --without-headers stub in place.
if [ "$R14" = ok ]; then
  # BOTH HALVES MUST EXIST BEFORE ANY configure ASKS FOR THEM. gcc 15 pass 1
  # was built --enable-languages=c,c++, so $VERON_TOOLCHAIN_TGT-g++ should be there; a
  # missing one would otherwise surface as configure's "no C++14 compiler",
  # which is the message that sent this rung looking in the wrong place twice.
  for _c in "$VERON_TOOLCHAIN_TGT-gcc" "$VERON_TOOLCHAIN_TGT-g++"; do
    if command -v "$_c" > /dev/null 2>&1; then
      printf '    %-28s %s\n' "$_c" "$("$_c" --version 2>&1 | head -1)"
    else
      say "    $_c IS NOT ON PATH -- chapter 6 has no build-side compiler."
      say "    It comes from rung 11 (gcc 15 pass 1, --enable-languages=c,c++)"
      say "    and lives in $S/tools/bin."
      R16=FAIL
    fi
  done
  rm -rf /work/b-binutils2 && mkdir -p /work/b-binutils2 && cd /work/b-binutils2

  # THE BUILD TRIPLE, ASKED ONCE, FROM A TREE THAT IS KNOWN TO BE THERE.
  #
  # Every --build below used to call a DIFFERENT config.guess, each at a path
  # assumed rather than checked -- make's at build-aux/config.guess, which is
  # where make 4.4 keeps it and where 3.82 does not, and where nothing in this
  # script had ever looked. A `$(...)` on a missing file is not an error under
  # `set -u`: it is the empty string, so the flag becomes a bare `--build=`
  # and configure stops on "invalid value" three screens later, naming the
  # option rather than the missing file.
  #
  # binutils' config.guess is at the top of its tree, rung 10 already ran it,
  # and every package here is being built for the same machine -- so one
  # answer serves all of them and the assumption is made once, out loud.
  _BUILD_TRIPLE=$("/work/src/$_bu/config.guess" 2>/dev/null || true)
  if [ -z "$_BUILD_TRIPLE" ]; then
    say "    config.guess produced nothing at /work/src/$_bu/config.guess"
    say "    Every --build below would have been passed empty. Stopping here"
    say "    rather than letting three configures fail on the same cause."
    R16=FAIL
  else
    say "    build triple: $_BUILD_TRIPLE   host: $VERON_TOOLCHAIN_TGT"
  fi
  # make INTO THE SYSROOT FIRST, BECAUSE EVERYTHING BELOW NEEDS ONE.
  #
  # stage4-complete builds make 4.4.1 in chapter 6 and we did not. Rung 4.5's
  # make lives in $PFX and runs in the BOX; the sysroot has no make at all, and
  # rungs 17 and 18 run `make` inside it -- the kernel build is nothing but
  # make. busybox has no make applet and never has.
  #
  # Cross-built like everything else here: --host=$VERON_TOOLCHAIN_TGT so it runs in the
  # sysroot, --build from config.guess so configure knows it is cross.
  if [ "$R16" != FAIL ]; then
    # ITS OWN EXTRACTION DIRECTORY. Rung 4.5 already built make 4.4 IN TREE
    # under /work/src, so extracting there again gave configure a tree that
    # had been configured once already:
    #
    #     configure: error: source directory already configured;
    #     run "make distclean" there first
    #
    # And `onedir` globs /work/src, which by now holds a dozen unpacked
    # packages -- it returned busybox-1.36.1, so the untar line reported
    # extracting make and named busybox. Every other rung that unpacks a
    # second copy uses a private directory; this one did not.
    rm -rf /work/src/make-p2 && mkdir -p /work/src/make-p2
    if ! ( cd /work/src/make-p2 && untar "/in/make-$MAKE_ALT" ); then
      say "    make did not extract"; R16=FAIL
    else
      _mk=$(cd /work/src/make-p2 && onedir "make-$MAKE_ALT ./make-$MAKE_ALT")
      rm -rf /work/b-make2 && mkdir -p /work/b-make2 && cd /work/b-make2
      if "/work/src/make-p2/$_mk/configure" --prefix=/usr \
           --host="$VERON_TOOLCHAIN_TGT" \
           --build="$_BUILD_TRIPLE" \
           CC_FOR_BUILD="$PFX/bin/chain-cc -static" \
           --disable-nls > c.log 2>&1 \
         && timeout 1800 make -j"$NP" > b.log 2>&1 \
         && make DESTDIR="$S" install > i.log 2>&1; then
        say "    make $MAKE_ALT installed into $S"
      else
        say "    make pass 2 NOT INSTALLED"
        tail -12 c.log 2>/dev/null | sed 's/^/      /'
        tail -12 b.log 2>/dev/null | sed 's/^/      /'
        R16=FAIL
      fi
      cd /work
    fi
  fi

  # THE BUILD-SIDE COMPILER IS gcc 10, AND PASS 1 IS THE WRONG ANSWER HERE.
  #
  # configure needs two compilers for a cross build: one for --host (the
  # programs being built) and one for --build (the little test programs and
  # generators it runs during the build). It finds $VERON_TOOLCHAIN_TGT-gcc for the host
  # side on its own, because $S/tools/bin is on PATH -- and falls back to bare
  # `gcc`/`g++` for the build side, which in this box is gcc 4.7.4 from rung 6:
  #
  #     checking whether riscv64-veron-linux-gnu-g++ supports C++14 ... yes
  #     checking whether g++ supports C++14 ... no
  #     configure: error: A compiler with support for C++14 is required
  #
  # --disable-fixincludes, AND IT IS THE BOOK'S FLAG FOR THE MODULE THAT FAILED.
  #
  #     make[1]: *** [Makefile:3114: all-build-fixincludes] Error 2
  #
  # fixincludes exists to rewrite a HOST DISTRO's broken system headers. There
  # is no host distro here, so the module has nothing to do and its build-side
  # binary is pure cost. LFS r13.0-167 passes --disable-fixincludes on gcc
  # pass 1 AND on pass 2; this rung had it on neither.
  #
  # WHAT THIS DOES NOT CLAIM. The underlying ld error was never printed -- the
  # failure path tailed a parallel build and caught gmp finishing instead --
  # so this removes the module that failed rather than repairing a fault
  # anyone has read. whyfail() exists so the next one is legible.
  #
  # A PREVIOUS REVISION SET CC_FOR_BUILD=$VERON_TOOLCHAIN_TGT-gcc AND THAT CANNOT WORK.
  # Pass 1 was configured --with-sysroot=$S, so what it emits is glibc-linked
  # against the sysroot and carries /lib/ld-linux-aarch64.so.1 as its
  # interpreter. Build-side programs are generators -- genmodes, gengtype,
  # genattrtab -- that gcc RUNS DURING THIS BUILD, on this side, where that
  # path does not resolve. The build would die on its own generators.
  #
  # The build side must produce binaries that run in THE BOX, and the box's
  # native libc is musl. chain-cc is gcc 10.2.0 driving musl, statically
  # linked, and it has built every rung from 10 up. gcc 10 does C++14, which is
  # the only thing the error below was actually complaining about:
  #
  #     checking whether riscv64-veron-linux-gnu-g++ supports C++14 ... yes
  #     checking whether g++ supports C++14 ... no
  #     configure: error: A compiler with support for C++14 is required
  #
  # gcc 4.7.4 is what bare `g++` resolves to here, and 4.7 predates C++14. The
  # fix is to name a build-side compiler, not to reach for the newest one.
  #
  # THIS DOES NOT TAINT THE OUTPUT. Build-side generators emit source and
  # tables consumed by the host-side compile; none of them ends up in an
  # artifact, and the host side is $VERON_TOOLCHAIN_TGT-gcc throughout. LFS uses the HOST
  # DISTRO's gcc for this same role -- Ubuntu's 13, entirely outside the chain
  # -- so using gcc 10 from our own ladder is strictly stricter than the book.
  # THE BUILD DIRECTORY, RE-ENTERED, AND THIS IS A FIX RATHER THAN A FLOURISH.
  #
  # /work/b-binutils2 is created and entered ~70 lines above, before the make
  # pass-2 block. That block then does `cd /work/b-make2` and, on its way out,
  # `cd /work` -- so by the time this configure ran the working directory was
  # /work, not the build directory. binutils would have configured and built
  # IN THE WORK ROOT, beside src/ and out/ and lfs/, with cfg.log and b.log
  # written where the failure paths below do not look for them.
  #
  # It is the same shape as `onedir` returning busybox: the rung names one
  # directory and operates on another, and nothing in the output says so. Rung
  # 10 prints its cwd for this reason; so does this one now.
  if ! cd /work/b-binutils2; then
    say "    could not enter /work/b-binutils2"; R16=FAIL
  fi
fi

# GUARDED, BECAUSE A FAILED make pass 2 USED TO FALL THROUGH INTO AN HOUR OF
# binutils. The make block above sets R16=FAIL and the two configures below
# were outside every check of it, so a run that had already lost its make went
# on to build binutils and gcc against it and reported the later, less useful
# failure.
if [ "$R14" = ok ] && [ "$R16" != FAIL ]; then
  say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: binutils pass 2 configure"
  say "    (cwd: $(pwd))"
  "/work/src/$_bu/configure" \
    --prefix=/usr \
    --build="$_BUILD_TRIPLE" \
    --host="$VERON_TOOLCHAIN_TGT" \
    CC_FOR_BUILD="$PFX/bin/chain-cc -static" \
    CXX_FOR_BUILD="$CHAIN_CXX -static -Wl,--no-eh-frame-hdr" \
    --disable-nls --enable-shared --enable-gprofng=no \
    --disable-werror --enable-64-bit-bfd --enable-new-dtags \
    --enable-default-hash-style=gnu \
    > cfg.log 2>&1
  _r16=$?
  say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r16)"
  if [ "$_r16" != 0 ]; then
    R16=FAIL
    grep -aiE "PATH_MAX|not found|no acceptable" cfg.log 2>/dev/null | head -6 | sed 's/^/      /'
    tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
  elif timeout 3600 make -j"$NP" > b.log 2>&1 \
       && make DESTDIR="$S" install > i.log 2>&1; then
    say "    binutils pass 2 installed into $S"
    # gcc pass 2, in the same rung because neither is useful alone.
    rm -rf /work/b-gcc2 && mkdir -p /work/b-gcc2 && cd /work/b-gcc2
    say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: gcc pass 2 configure"
    "/work/src/$g15/configure" \
      --build="$_BUILD_TRIPLE" \
      --host="$VERON_TOOLCHAIN_TGT" \
      --target="$VERON_TOOLCHAIN_TGT" \
      CC_FOR_BUILD="$PFX/bin/chain-cc -static" \
      CXX_FOR_BUILD="$CHAIN_CXX -static -Wl,--no-eh-frame-hdr" \
      LDFLAGS_FOR_TARGET="-L$PWD/$VERON_TOOLCHAIN_TGT/libgcc" \
      --prefix=/usr \
      --with-build-sysroot="$S" \
      --enable-default-pie --enable-default-ssp \
      --disable-fixincludes \
      --disable-nls --disable-multilib --disable-libatomic \
      --disable-libgomp --disable-libquadmath --disable-libsanitizer \
      --disable-libssp --disable-libvtv --enable-languages=c,c++ \
      > cfg.log 2>&1
    _r16b=$?
    say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r16b)"
    if [ "$_r16b" != 0 ]; then
      R16=FAIL; tail -20 cfg.log 2>/dev/null | sed 's/^/      /'
    elif timeout 10800 make -j"$NP" > b.log 2>&1 \
         && make DESTDIR="$S" install > i.log 2>&1; then
      R16=ok
      # LFS's own final step: cc as a name for gcc, which many builds assume.
      ln -sf gcc "$S/usr/bin/cc" 2>/dev/null || true
      say "    gcc pass 2 installed into $S"

      # PRESENT IS NOT THE SAME AS RUNS, AND THIS RUNG WAS ONLY ASKING THE
      # FIRST QUESTION.
      #
      # This file already records the failure: "rung 4 = ok meant the files
      # existed, not that they ran. It reported ok, and rung 5 after it, while
      # `as` could not be executed at all." The check below was `[ -e ]`, which
      # is that same check again, one chapter higher.
      #
      # It matters here more than it did there. Everything rung 16 installs is
      # DYNAMIC and glibc-linked -- that is the point of pass 2 -- so each of
      # these binaries carries an absolute PT_INTERP, normally
      # /lib/ld-linux-aarch64.so.1. Rungs 15, 17 and 18 then invoke them
      # in PHASE B, where the sysroot is bound as / and the path resolves. On
      # THIS side it cannot: the kernel resolves PT_INTERP against the root
      # the process is running in, which is the box, and the box's /lib holds
      # nothing at all -- the workflow's own count says "shared objects the
      # box needs: 0", both tier-2 binaries being static.
      #
      # An exec of such a binary fails with ENOENT, and busybox sh reports
      # that as "gcc: not found" -- the message for a missing PROGRAM. Rung 15
      # sends its make output to /dev/null, so the first visible symptom would
      # have been busybox failing to configure, three rungs from the cause.
      #
      # So: run them. If they run, this costs four lines of log and asserts
      # something real. If they do not, the run stops HERE, on the rung that
      # built them, with the interpreter named.
      _sysroot_runs=yes
      # DID busybox --install SHADOW binutils? Rung 15 sweeps $S/usr/bin and
      # links every applet it has to itself, and busybox HAS ar, strings and
      # nm. busybox's ar can only READ archives, never create one -- this
      # file already records that about the box's own copy -- so a shadowed
      # ar means every static library in phase B fails, naming libtool or gcc
      # rather than the symlink that caused it.
      #
      # Rung 15 now runs BEFORE this one, which is LFS's order and which makes
      # binutils the later writer. That is the fix; this is the check that it
      # held, because ordering is exactly the kind of thing a later edit
      # silently undoes.
      for b in ar strings nm; do
        if [ -L "$S/usr/bin/$b" ]; then
          say "    $S/usr/bin/$b IS A SYMLINK -> $(readlink "$S/usr/bin/$b")"
          say "    busybox shadowed binutils. Rung 15 must run before rung 16."
          R16=FAIL
        fi
      done
      # PRESENT AND NOT EXECUTABLE IS THE CORRECT OUTCOME HERE, AND AN
      # EARLIER REVISION OF THIS CHECK FAILED THE RUNG FOR IT.
      #
      # I wrote that version when `in_sysroot` was the design and nothing
      # could ever enter the sysroot -- at that point a pass-2 binary that
      # would not run WAS a dead end. Phase B replaced that design and asks
      # the same question at B0, where the sysroot is bound as / and where a
      # negative answer is real. This copy was left behind still setting
      # R16=FAIL, so run #115 built and installed gcc pass 2 correctly and
      # then failed the rung for it.
      #
      # What chapter 6 produces is glibc-linked and cross-built. LFS says so
      # plainly: "installed into their final location, but cannot be used
      # yet ... using the utilities will be possible in the next chapter
      # after entering the chroot environment."
      #
      # So this now MEASURES AND REPORTS rather than gates. Both answers are
      # informative and neither is a failure:
      #   does not execute -> normal, and the interpreter line proves why
      #   executes         -> it was linked statically or against the box's
      #                       musl, which would mean --host did not take
      _ran=0; _didnt=0
      for b in gcc g++ ld as; do
        if [ ! -e "$S/usr/bin/$b" ]; then
          printf '      %-6s MISSING\n' "$b"; _sysroot_runs=no; continue
        fi
        if "$S/usr/bin/$b" --version > /dev/null 2>&1; then
          printf '      %-6s runs here -- %s\n' "$b" \
            "$("$S/usr/bin/$b" --version 2>&1 | head -1)"
          _ran=$((_ran+1))
        else
          printf '      %-6s installed, does not run in the box (expected)\n' "$b"
          _didnt=$((_didnt+1))
        fi
      done
      if [ "$_sysroot_runs" != yes ]; then
        # Only a MISSING file gets here now, and that is a real failure: it
        # means the install did not put the tool where phase B will look.
        R16=FAIL
        say "    A chapter 6 tool is missing from $S/usr/bin, so phase B"
        say "    would start in a sysroot that cannot build anything."
      elif [ "$_didnt" -gt 0 ]; then
        say ""
        say "    --- why they do not run HERE, which is the point ---"
        "$S/tools/bin/$VERON_TOOLCHAIN_TGT-readelf" -l "$S/usr/bin/gcc" 2>/dev/null \
          | grep -A1 -i "interpreter" | head -4 | sed 's/^/      /'
        say "      box /lib holds: $(ls /lib 2>/dev/null | tr '\n' ' ')"
        say ""
        say "    That interpreter lives at $S/usr/lib, and the box's /lib is"
        say "    musl's. These are cross-built chapter 6 tools and they are"
        say "    MEANT to be unrunnable on this side -- LFS: \"installed into"
        say "    their final location, but cannot be used yet\"."
        say "    Phase B binds $S as / and runs them there. B0 is the check"
        say "    that matters; a failure there would be real."
      elif [ "$_ran" -gt 0 ]; then
        say ""
        say "    ALL FOUR RAN IN THE BOX, WHICH IS SUSPICIOUS RATHER THAN GOOD."
        say "    Chapter 6 output should be glibc-dynamic against $S. If it"
        say "    runs here it was linked statically or against the box's musl,"
        say "    which would mean --host=$VERON_TOOLCHAIN_TGT did not take and phase B"
        say "    would be testing the wrong binaries."
      fi
    else
      R16=FAIL; say "    --- gcc pass 2 errors ---"
      grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      whyfail b.log
    fi
  else
    R16=FAIL; say "    --- binutils pass 2 errors ---"
    grep -aE "PATH_MAX" b.log 2>/dev/null | head -3 | sed 's/^/      /'
    grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
    whyfail b.log
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
# PHASE A ENDS HERE, AND THE MARKER IS WHAT PHASE B READS.
#
# Everything above ran with the BOX as /. What exists now is a cross toolchain
# in $S/tools, a glibc sysroot in $S, binutils pass 2 and gcc pass 2 in
# $S/usr, and a cross-built busybox providing $S/usr/bin/sh.
#
# Nothing above has executed a single glibc-linked binary, and that is correct
# rather than a limitation -- LFS chapter 6 says the same of its own output:
# "installed into their final location, but cannot be used yet."
#
# WRITTEN ONLY IF THE SYSROOT CAN ACTUALLY BE ENTERED. Phase B needs a shell,
# a make, a compiler and a linker in $S/usr/bin. If any is missing the marker
# is withheld and the workflow skips phase B rather than starting a second
# sandbox that dies on its first command with "sh: not found".
if [ "$R16" = ok ] && [ "$R15" = ok ]; then
  _pa=yes
  for _n in sh make gcc g++ ld as; do
    [ -e "$S/usr/bin/$_n" ] || { say "  phase A: $S/usr/bin/$_n MISSING"; _pa=no; }
  done
  # AND THAT THE SHELL IS REACHABLE FROM A DIFFERENT ROOT, which is the only
  # thing phase B needs from this directory before it can run at all. `-e`
  # above follows the link and cannot tell; three runs wrote this marker over
  # a sysroot whose /usr/bin/sh pointed at a path that exists only here.
  case "$(readlink "$S/usr/bin/sh" 2>/dev/null || true)" in
    busybox) : ;;
    *) say "  phase A: /usr/bin/sh does not point at busybox relatively --"
       say "  phase B would fail to exec a shell. Marker withheld."
       _pa=no ;;
  esac
  if [ "$_pa" = yes ]; then
    printf 'phase A complete: cross toolchain, glibc %s, gcc %s pass 2, busybox\n' \
      "$GLIBC" "$GCC15" > "$S/.phase-a-complete"
    say ""
    say "  PHASE A COMPLETE -- $S is ready to be entered."
    say "  The workflow now runs phase B with $S bound as /."
  else
    say ""
    say "  PHASE A INCOMPLETE -- $S cannot be entered, so phase B is skipped."
  fi
fi

# ---------------------------------------------------------------------------
head1 "RUNGS -- arm: $ARM"
printf '    %-40s %s\n' "0   compiler runs, libtcc1.a"       "$R0"
printf '    %-40s %s\n' "1   freestanding compile+link"      "$R1"
printf '    %-40s %s\n' "2   musl, no make"                  "$R2"
printf '    %-40s %s\n' "3   hosted program, real libc"      "$R3"
printf '    %-40s %s\n' "3.5 GNU make"                       "$R35"
printf '    %-40s %s\n' "4   binutils"                       "$R4"
printf '    %-40s %s\n' "4.5 make rebuilt with real binutils" "$R45"
printf '    %-40s %s\n' "4.6 libc.a gets libtcc1's helpers"   "$R46"
printf '    %-40s %s\n' "4.7 m4 (gmp's configure needs it)"    "$R47"
printf '    %-40s %s\n' "4.8 flex (git tree lacks gengtype-lex.c)" "$R48"
printf '    %-40s %s\n' "5   gmp / mpfr / mpc"               "$R5"
printf '    %-40s %s\n' "6   gcc 4.7.4 by tcc -- stage 4 stage 1" "$R6"
printf '    %-40s %s\n' "7   gmp/mpfr/mpc rebuilt by that gcc"   "$R7"
printf '    %-40s %s\n' "8   gcc 4.7.4 again -- stage 4 stage 2" "$R8"
printf '    %-40s %s\n' "9   gcc 10.2.0 by g++ 4.7.4"            "$R9"
printf '    %-40s %s\n' "10  LFS 5.2 binutils pass 1"            "$R10"
printf '    %-40s %s\n' "11  LFS 5.3 gcc 15 pass 1"              "$R11"
printf '    %-40s %s\n' "11.5 perl (LFS puts it in ch7)"          "$R115"
printf '    %-40s %s\n' "12  LFS 5.4 linux API headers"          "$R12"
printf '    %-40s %s\n' "11.7 m4/flex/bison/python (after 12)"   "$R117"
printf '    %-40s %s\n' "13  LFS 5.5 glibc"                      "$R13"
printf '    %-40s %s\n' "14  LFS 5.6 libstdc++"                  "$R14"
printf '    %-40s %s\n' "15  busybox, cross by pass 1 (replaced in B)" "$R15"
printf '    %-40s %s\n' "16  ch6 binutils + gcc pass 2"          "$R16"
say ""
if [ "$R20" = ok ]; then
  say "    EVERYTHING BUILT. The kernel and initramfs are in /out and the"
  say "    workflow boots them outside the box."
elif [ "$R14" = ok ]; then
  say "    CHAPTER 5 COMPLETE -- a cross toolchain and a glibc sysroot,"
  say "    from a seed-adjacent tcc. Chapter 6 is next: busybox in place of"
  say "    its seventeen packages, then binutils and gcc pass 2."
elif [ "$R11" = ok ]; then
  say "    REACHED LFS 5.3 -- a cross gcc 15 targeting $VERON_TOOLCHAIN_TGT."
  say "    5.4 linux headers, then 5.5 glibc, are next."
elif [ "$R9" = ok ]; then
  say "    REACHED gcc 10.2.0, built by a g++ descended from tcc."
  say "    gcc 15 is the next rung."
elif [ "$R8" = ok ]; then
  say "    REACHED a self-rebuilt gcc 4.7.4 in a box with busybox and one"
  say "    compiler. This is stage 4's stage 2; gcc 10 is the next rung."
else
  say "    STOPPED. The first rung above that is not 'ok' is the frontier;"
  say "    everything after it was skipped, not failed."
fi

# Machine-readable, so the workflow can diff two arms without parsing prose.
printf '%s %s %s %s %s %s %s %s %s\n' \
  "$ARM" "$R0" "$R1" "$R2" "$R3" "$R35" "$R4" "$R5" "$R6" > /out/rungs.txt

# NOTHING IS UPLOADED, SO NOTHING IS COPIED OUT.
#
# This used to collect logs into /out and, on success, ~60 MB of binutils, gcc,
# make and musl. Both artifact steps are gone from the workflow, so the copy had
# no reader -- and an unread copy of a 77 MB cc1plus is just runner time.
#
# Everything a failure needs is already in this log: each rung prints its own
# configure tail, its own build errors grouped by file, and the relevant
# config.log around the failing test. That was built up over the rounds where
# the artifact was never the thing anyone read.
#
# If a toolchain is wanted later, restore the copy AND the upload together --
# one without the other is what this was.
say ""
say "  artifacts: none. See the rung output above; nothing is copied to /out."
