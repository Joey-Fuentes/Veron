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
head1() { say ""; say "  === $* ==="; }

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

R0=skip; R1=skip; R2=skip; R3=skip; R35=skip; R4=skip; R45=skip; R5=skip; R6=skip; R7=skip; R8=skip; R9=skip; R10=skip; R11=skip; R115=skip; R117=skip; R12=skip; R13=skip; R14=skip; R15=skip; R16=skip; R17=skip; R18=skip; R19=skip; R20=skip

# WHAT IS ACTUALLY IN /in, BEFORE ANYTHING TRIES TO USE IT.
#
# Three runs were spent guessing at an archive nobody had looked at. Printing
# the inventory costs one screen and removes the guessing: name, size, and the
# first four bytes, which say whether a thing is gzip (1f 8b), xz (fd 37),
# bzip2 (42 5a) or something that is not compressed at all.
say ""
say "  === WHAT IS IN /in ==="
for _f in /in/*; do
    [ -f "$_f" ] || continue
    printf '    %-30s %10s  %s\n' "${_f##*/}" "$(wc -c < "$_f")" \
      "$(dd if="$_f" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -s ' ')"
done

say "  arm:      $ARM"
say "  compiler: $CC_BIN  ($(wc -c < "$CC_BIN") bytes)"
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
  objs=""
  for f in lib-arm64.c stdatomic.c atomic.c builtin.c va_list.c alloca.S \
           armeabi.c alloca-arm.S armflush.c; do
    [ -f "$f" ] || continue
    o="/work/lt-$(basename "$f" | tr '.' '_').o"
    # $CC IS TWO WORDS -- the binary and its -B. Quoting it makes the shell
    # look for a command literally named "/work/ref-tcc -B/work/tccsrc", which
    # is what the reference run reported six times as "not found". Every other
    # rung had it unquoted; this one did not.
    if $CC -c -o "$o" "$f" 2>>/work/libtcc1.err; then objs="$objs $o"; fi
  done
  if [ -n "$objs" ] && "$CC_BIN" -ar rcs "$TCCDIR/libtcc1.a" $objs 2>>/work/libtcc1.err; then
    say "    libtcc1.a: $(wc -c < "$TCCDIR/libtcc1.a") bytes"
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
cat > r1.c <<'EOF'
static long sys3(long n, long a, long b, long c)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    __asm__ __volatile__("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
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
  for s in src/fenv/aarch64/fenv.s src/ldso/aarch64/tlsdesc.s \
           src/process/aarch64/vfork.s src/setjmp/aarch64/longjmp.s \
           src/signal/aarch64/restore.s src/thread/aarch64/__set_thread_area.s \
           src/thread/aarch64/__unmapself.s src/thread/aarch64/clone.s \
           src/thread/aarch64/syscall_cp.s; do
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

  # THE TWO GENERATED HEADERS. musl's Makefile builds these with sed before
  # anything compiles. Nothing includes them until they exist and every later
  # compile fails obscurely if they do not, so they are checked, not assumed.
  mkdir -p obj/include/bits
  sed -f tools/mkalltypes.sed arch/aarch64/bits/alltypes.h.in \
      include/alltypes.h.in > obj/include/bits/alltypes.h 2>/dev/null
  cp arch/aarch64/bits/syscall.h.in obj/include/bits/syscall.h 2>/dev/null
  sed -n 's/__NR_/SYS_/p' arch/aarch64/bits/syscall.h.in \
      >> obj/include/bits/syscall.h 2>/dev/null
  for h in alltypes.h syscall.h; do
    [ -s "obj/include/bits/$h" ] || say "    WARN: obj/include/bits/$h is empty"
  done
  say "    generated: $(ls obj/include/bits 2>/dev/null | tr '\n' ' ')"

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
  INC="-Iarch/aarch64 -Iarch/generic -Iobj/src/internal -Isrc/include -Isrc/internal -Iobj/include -Iinclude"
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
  # The last run skipped src/string/memset.c because src/string/aarch64/memset.S
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
    if [ -f "$d/aarch64/$b.c" ] || [ -f "$d/aarch64/$b.s" ] || [ -f "$d/aarch64/$b.S" ]; then
      continue
    fi
    echo "$f" >> /work/srclist
  done
  for f in src/*/aarch64/*.c src/*/aarch64/*.s src/*/aarch64/*.S \
           crt/*.c crt/aarch64/*.c crt/aarch64/*.s crt/aarch64/*.S; do
    [ -f "$f" ] && echo "$f" >> /work/srclist
  done
  say "    file set: $(wc -l < /work/srclist) sources (aarch64, arch files replacing generic)"

  nc=0; nf=0
  : > /work/musl-fail.txt
  for f in $(sort /work/srclist); do
    # .c, .s and .S all land on the same object name, which is how musl's own
    # REPLACED_OBJS rule collapses an arch file onto the generic one it stands
    # in for.
    o="obj/${f%.*}.o"; mkdir -p "$(dirname "$o")"
    # musl's Makefile adds -DCRT for the crt objects; without it crt1.c
    # compiles to something that is not a crt file.
    case "$f" in crt/*) X=-DCRT ;; *) X= ;; esac
    if $CC $MUSLCF $INC $X -c -o "$o" "$f" 2>>/work/musl-cc.err; then
      nc=$((nc + 1))
    else
      nf=$((nf + 1)); echo "$f" >> /work/musl-fail.txt
    fi
  done
  say "    compiled $nc objects, $nf failed"
  if [ "$nf" -gt 0 ]; then
    # src/thread/__unmapself.c IS EXPECTED TO FAIL and is not a compiler
    # defect: sources/musl.toml declares the aarch64 __unmapself.s dropped, so
    # the generic C stands in, and that generic C is inline asm tcc does not
    # parse. It costs the thread-exit unmapping path, which nothing below gcc
    # exercises. Named here so it stops looking like a finding every run.
    say "    --- files that would not compile (first 10 of $nf) ---"
    head -10 /work/musl-fail.txt | sed 's/^/      /'
    # DISTINCT MESSAGES, WITH COUNTS. The first twelve lines of the error log
    # are usually twelve copies of one fault, which reads as twelve problems
    # and sends the next round in twelve directions. 664 failures in the
    # reference run were ONE missing macro.
    say "    --- distinct errors, by count ---"
    grep -a "error:" /work/musl-cc.err 2>/dev/null \
      | sed 's/^.*error:/error:/' | sort | uniq -c | sort -rn | head -10 | sed 's/^/      /'
  fi

  # NO ar IN THIS BOX -- binutils is rung 4. tcc has its own archiver, which is
  # the whole reason `tcc -ar` exists. It is untested on a seed-built tcc, so a
  # failure here is a finding rather than a surprise.
  find obj/src -name '*.o' > /work/objlist.txt
  if "$CC_BIN" -ar rcs "$SYS/lib/libc.a" $(cat /work/objlist.txt) 2>/work/ar.err; then
    say "    libc.a: $(wc -c < "$SYS/lib/libc.a") bytes from $(wc -l < /work/objlist.txt) objects"
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
  # something like /usr/lib/aarch64-linux-gnu, not /usr/lib.
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
    for src in "obj/crt/aarch64/$c.o" "obj/crt/$c.o"; do
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
  cp -a arch/aarch64/bits "$SYS/include/" 2>/dev/null || true
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
#     /work/bld/gcc/as: exec: .../aarch64-unknown-linux-gnu/bin/as:
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
cat > "$PFX/bin/cc-static" <<CCWRAP
#!/bin/sh
exec CCBIN -B TCCDIR -include sys/cdefs.h "\$@" -I/usr/include -L/usr/lib -static
CCWRAP
sed -i -e "s|CCBIN|$CC_BIN|" -e "s|-B TCCDIR|-B$TCCDIR|" "$PFX/bin/cc-static"
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
# aarch64-veron-linux-musl differs from aarch64-unknown-linux-gnu, and it is
# also honest about the libc, which several configure scripts key on.
#
# BOTH ANSWERS ARE TRIED, in this order, and the log says which worked:
#   1. native + -static     the box IS the target, so a static binary really
#                           does run here; letting configure measure beats
#                           letting it guess
#   2. LFS cross triplets   for anything -static does not save
BUILDTRIP=aarch64-unknown-linux-gnu
HOSTTRIP=aarch64-veron-linux-musl

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

  if try_r3 "plain:" $CC -static -o r3.bin r3.c; then
    R3=ok
  elif try_r3 "explicit:" $CC $HOSTED -nostdlib -static -o r3.bin \
         "$SYS/lib/crt1.o" "$SYS/lib/crti.o" r3.c -lc "$TCCDIR/libtcc1.a" \
         "$SYS/lib/crtn.o"; then
    R3=FAIL
    say ""
    say "    THE LIBC IS GOOD AND THE COMPILER CANNOT FIND IT. A search-path"
    say "    problem, not a codegen one -- but it still stops every rung above,"
    say "    because autoconf will not pass paths."
  else
    R3=FAIL
    say "    both routes failed -- read the rc and the ELF line above"
  fi
fi

# ---------------------------------------------------------------------------
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
      say "    make: $(wc -c < "$PFX/bin/make") bytes"
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
    #     -B$PFX/aarch64-unknown-linux-gnu/bin/  -isystem .../include
    #     -B$PFX/aarch64-unknown-linux-gnu/lib/  -isystem .../sys-include
    #
    # and it died with
    #
    #     /work/bld/gcc/as: exec: /work/prefix/aarch64-unknown-linux-gnu/bin/as:
    #                             Permission denied
    #
    # -- so something IS at that path and cannot be executed, while
    # include/ and sys-include/ do not exist at all. binutils here is configured
    # NATIVE, without --target, so whatever it put in the tooldir is incidental;
    # nothing ever arranged it deliberately.
    #
    # THIS IS THE HALF OF LFS I SAID WE COULD SKIP. LFS builds its toolchain
    # with --with-sysroot and a $LFS_TGT directory precisely so the target's
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

    _TD="$PFX/aarch64-unknown-linux-gnu"
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
      mkdir -p "$_p/aarch64-unknown-linux-gnu/bin" "$_p/aarch64-unknown-linux-gnu/lib"
      for _t in as ld ar ranlib nm objcopy objdump strip readelf strings; do
        [ -x "$PFX/bin/$_t" ] || continue
        rm -f "$_p/aarch64-unknown-linux-gnu/bin/$_t"
        ln -s "$PFX/bin/$_t" "$_p/aarch64-unknown-linux-gnu/bin/$_t"
      done
      rm -rf "$_p/aarch64-unknown-linux-gnu/sys-include"
      ln -s /usr/include "$_p/aarch64-unknown-linux-gnu/sys-include"
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
          say "    make: $(wc -c < "$PFX/bin/make") bytes"
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
  if ! untar /in/gcc-4.7.4; then
    say "    gcc 4.7.4 did not extract"; R6=FAIL
  fi
  g47=$(onedir 'gcc-4.7.4 ./gcc-4.7.4')
  if [ -z "$g47" ]; then
    say "    no gcc-4.7.4 directory after extraction"; R6=FAIL
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

    _nf=$(ls /in/gcc47-aarch64-newfiles.tar.gz 2>/dev/null | head -1)
    _pf=$(ls /in/gcc47-aarch64-changed.patch 2>/dev/null | head -1)
    if [ -z "$_nf" ] || [ -z "$_pf" ]; then
      say "    backport inputs missing from /in:"
      ls -1 /in | sed 's/^/      /'
      R6=FAIL
    else
      say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: tar -zxf $_nf  (into $g47)"
      say "    (cwd: $(pwd))"
      tar -zxf "$_nf" -C "$g47" 2>/tmp/bp1.err
      _r1=$?
      say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r1)"
      [ "$_r1" = 0 ] || sed 's/^/      /' /tmp/bp1.err | head -4

      # busybox patch HAS NO -d. That is GNU patch's "change directory first"
      # flag; busybox's usage lists only -p, -i, -R, -N, -E and --dry-run. So
      # cd into the tree and use -i, both of which it does have.
      #
      # Third flag in this job that GNU has and busybox does not, after
      # `tr -dc '[:print:]'` and `od -j`. The pattern is worth naming: a flag
      # working on the runner says nothing about whether it works in the box,
      # and busybox answers an unknown flag by printing usage and exiting 1 --
      # which reads as a failure of the operation rather than of the invocation.
      say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: (cd $g47 && patch -p1 -i $_pf)"
      ( cd "$g47" && patch -p1 -i "$_pf" ) > /tmp/bp2.out 2>&1
      _r2=$?
      say "END JOE: JUST COMPLETED EXECUTING THE COMMAND  (rc=$_r2)"
      tail -6 /tmp/bp2.out 2>/dev/null | sed 's/^/      /'

      _n=$(grep -c aarch64 "$g47/gcc/config.gcc" 2>/dev/null || true)
      [ -n "$_n" ] || _n=0
      say "    after backport: $_n aarch64 mentions in config.gcc"
      say "    aarch64 backend files: $(find "$g47/gcc/config/aarch64" -type f 2>/dev/null | wc -l)"
      # THE CHECK THAT MATTERS. 0 here means the delta did not land, and
      # configure would fail 20 minutes later with a message about the target
      # rather than about the patch.
      if [ "$_r1" != 0 ] || [ "$_r2" != 0 ] || [ "$_n" = 0 ]; then
        say "    BACKPORT DID NOT LAND -- gcc cannot be configured for aarch64"
        R6=FAIL
      fi
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
  "/work/src/$g47/configure" \
    CC="$CCAUTO" LDFLAGS="$LDF" \
    CFLAGS_FOR_TARGET="-static" LDFLAGS_FOR_TARGET="-static" \
    --build=aarch64-unknown-linux-gnu \
    --host=aarch64-unknown-linux-gnu \
    --target=aarch64-unknown-linux-gnu \
    --prefix=/work/out --enable-languages=c,c++ \
    --disable-nls --disable-libmudflap \
    --disable-multilib --disable-bootstrap --disable-werror \
    --disable-libsanitizer --disable-libgomp --disable-libquadmath \
    --disable-libssp --disable-libatomic --disable-shared \
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
  #     -B$PFX/aarch64-unknown-linux-gnu/bin/  -B.../lib/
  #     -isystem .../include  -isystem .../sys-include
  #
  # Those four directories are gcc's idea of "the target's toolchain and
  # headers". binutils here was configured WITHOUT --target, so it is a native
  # binutils and installed to $PFX/bin -- nothing was ever put under
  # $PFX/aarch64-unknown-linux-gnu/. Printing it before the build turns a
  # "cannot compute suffix of object files" forty minutes in into one line
  # here.
  say "    --- what xgcc will be given for the target ---"
  for _d in "$PFX/aarch64-unknown-linux-gnu/bin" "$PFX/aarch64-unknown-linux-gnu/lib" \
            "$PFX/aarch64-unknown-linux-gnu/include" "$PFX/aarch64-unknown-linux-gnu/sys-include"; do
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
  if "$PFX/aarch64-unknown-linux-gnu/bin/as" --version >/dev/null 2>&1; then
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
    for _cl in $(find /work/bld -name config.log -newer /work/bld/Makefile 2>/dev/null); do
      _d=$(dirname "$_cl")
      grep -q "error:" "$_cl" 2>/dev/null || continue
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
      rm -rf "/work/src/$pk-g1" && mkdir -p "/work/src/$pk-g1"
      ( cd "/work/src/$pk-g1" && untar "/in/$pk-" ) || { r7=FAIL; say "      $pk did not extract"; break; }
      _pd=$(cd "/work/src/$pk-g1" && onedir "$pk-* ./$pk-*")
      ( cd "/work/src/$pk-g1/$_pd" \
        && ./configure CC="$GCC1 -static" --disable-shared $EXTRA \
          --prefix=/work/prereq2 > cfg2.log 2>&1 \
        && timeout 1800 make -j"$NP" MAKEINFO=true > build2.log 2>&1 \
        && make install MAKEINFO=true > /dev/null 2>&1 ) \
        || { r7=FAIL
             say "      $pk NOT INSTALLED"
             tail -12 "/work/src/$pk-g1/$_pd/build2.log" 2>/dev/null | sed 's/^/        /'; }
      [ "$r7" = ok ] && say "      $pk INSTALLED"
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
    --build=aarch64-unknown-linux-gnu \
    --host=aarch64-unknown-linux-gnu \
    --target=aarch64-unknown-linux-gnu \
    --prefix=/work/out2 --enable-languages=c,c++ \
    --disable-nls --disable-libmudflap \
    --disable-multilib --disable-bootstrap --disable-werror \
    --disable-libsanitizer --disable-libgomp --disable-libquadmath \
    --disable-libssp --disable-libatomic --disable-shared \
    CFLAGS_FOR_TARGET="-static" LDFLAGS_FOR_TARGET="-static" \
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
          --build=aarch64-unknown-linux-gnu \
          --host=aarch64-unknown-linux-gnu \
          --target=aarch64-unknown-linux-gnu \
          --prefix=/work/out10 --enable-languages=c,c++ \
          --disable-multilib --disable-bootstrap --disable-werror \
          --disable-libsanitizer --disable-libvtv --disable-libgomp \
          --disable-libquadmath --disable-nls --disable-shared \
          CFLAGS_FOR_TARGET="-static" LDFLAGS_FOR_TARGET="-static" \
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
head1 "RUNG 10 -- LFS 5.2: binutils pass 1, cross to \$LFS_TGT"
# FROM HERE THE ORDER IS LFS's AND IT IS NOT NEGOTIABLE.
#
#   5.2 binutils pass 1   5.3 gcc pass 1   5.4 linux headers
#   5.5 glibc             5.6 libstdc++    ch6 binutils/gcc pass 2
#
# headers before glibc, glibc before libstdc++, libstdc++ before pass 2. Stage 4
# runs exactly this with gcc 10 as the host compiler (CHAIN_CC=out10/bin/gcc),
# which is the compiler rung 9 just produced.
#
# LFS_TGT IS DELIBERATELY NOT THE HOST TRIPLE. That is the book's device: a
# toolchain targeting aarch64-veron-linux-gnu cannot silently reach anything
# built for aarch64-unknown-linux-gnu, so a leak from the old sysroot becomes a
# link error instead of a subtly wrong binary. It also settles a question left
# open earlier in this file -- a non-standard vendor travels fine through
# gcc 15, so config.sub was never the obstacle.
#
# THIS IS WHERE musl LEAVES THE CHAIN. Chapter 5 builds glibc into $S, and
# everything above is glibc. musl carried the stretch where nothing else could
# be built, which is what spikes/livebootstrap/ORDER.md argues it is for.
LFS_TGT=aarch64-veron-linux-gnu
S=/work/lfs

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
exec CHAINCCBIN "\$@" -Wl,--no-eh-frame-hdr
CHAINCC
sed -i "s|CHAINCCBIN|/work/out10/bin/gcc|" "$PFX/bin/chain-cc"
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
  say "    LFS_TGT: $LFS_TGT   sysroot: $S"

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
    # $LFS_TGT-ld exists, everything above uses it and this stops mattering.
    # This flag only has to carry the one link that produces that ld.
    "/work/src/$_bu/configure" \
      CC="$PFX/bin/chain-cc -static" CXX="$CHAIN_CXX -static -Wl,--no-eh-frame-hdr" \
      LDFLAGS="-static -Wl,--no-eh-frame-hdr" \
      --prefix="$S/tools" \
      --with-sysroot="$S" \
      --target="$LFS_TGT" \
      --disable-nls --enable-gprofng=no --disable-werror \
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
      if [ -x "$S/tools/bin/$LFS_TGT-ld" ]; then
        R10=ok
        say "    $LFS_TGT-ld, -as, -ar installed:"
        for b in ld as ar ranlib; do
          printf '      %-28s %s\n' "$LFS_TGT-$b" \
            "$( [ -x "$S/tools/bin/$LFS_TGT-$b" ] && echo present || echo missing )"
        done
      else
        R10=FAIL; say "    installed no $LFS_TGT-ld"
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
# THE t-aarch64-linux SED IS OURS, NOT THE BOOK'S. LFS seds
# gcc/config/i386/t-linux64 for x86_64; the aarch64 file doing the same job is
# t-aarch64-linux. Without it glibc lands in /usr/lib and libstdc++ in
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
    _t="/work/src/$g15/gcc/config/aarch64/t-aarch64-linux"
    if [ ! -f "$_t" ]; then
      say "    $_t is missing -- gcc has moved this file"; R11=FAIL
    elif ! grep -q 'mabi\.lp64=' "$_t"; then
      say "    $_t has no mabi.lp64= line. It now reads:"
      sed 's/^/      /' "$_t"; R11=FAIL
    else
      sed -e '/mabi\.lp64=/s|lib64|lib|' -i.orig "$_t"
      say "    64-bit libdir: $(grep 'mabi\.lp64=' "$_t")"
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
    # the tcc-built ld too -- $LFS_TGT-ld exists now but is the CROSS linker
    # and is not what links the compiler itself.
    "/work/src/$g15/configure" \
      CC="$PFX/bin/chain-cc -static" CXX="$CHAIN_CXX -static -Wl,--no-eh-frame-hdr" \
      LDFLAGS="-static -Wl,--no-eh-frame-hdr" \
      --target="$LFS_TGT" \
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
      LIMH=$(dirname "$("$LFS_TGT-gcc" -print-libgcc-file-name 2>/dev/null)")
      for d in include include-fixed; do
        [ -d "$LIMH/$d" ] || continue
        cat "/work/src/$g15/gcc/limitx.h" "/work/src/$g15/gcc/glimits.h" \
            "/work/src/$g15/gcc/limity.h" > "$LIMH/$d/limits.h"
        say "    full limits.h written to $d/ ($(wc -l < "$LIMH/$d/limits.h") lines)"
      done
      if [ -x "$S/tools/bin/$LFS_TGT-gcc" ]; then
        R11=ok
        "$S/tools/bin/$LFS_TGT-gcc" --version 2>&1 | head -1 | sed 's/^/      /'
        "$S/tools/bin/$LFS_TGT-gcc" -dumpmachine 2>&1 | sed 's/^/      targets: /'
      else
        R11=FAIL; say "    no $LFS_TGT-gcc installed"
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
  say "    --- the same program, compiled by tcc rather than gcc 10 ---"
  ( cd /tmp && rm -f fpt.bin
    if "$CC" $HOSTED -static -o fpt.bin fp.c 2>/tmp/fpt.err && ./fpt.bin 2>&1 | head -3; then
      :
    else
      say "      tcc could not build it:"
      head -3 /tmp/fpt.err 2>/dev/null | sed 's/^/        /'
    fi
    rm -f fpt.bin fp.c )

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
  ( cd /tmp && rm -f fp.c fp.bin
    cat > fp.c <<'FPC'
#include <stdio.h>
#include <stdlib.h>
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
    }
    return 0;
}
FPC
    if "$PFX/bin/chain-cc" -static -O0 -o fp.bin fp.c 2>/tmp/fp.err && ./fp.bin; then
      :
    else
      say "      the float probe would not build or run:"
      head -5 /tmp/fp.err 2>/dev/null | sed 's/^/        /'
    fi
    rm -f fp.bin )

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
    _pcfg="-des -Dprefix=$PFX -Dcc=$PFX/bin/chain-cc -Dldflags=-static -Doptimize=-O0 -fno-strict-aliasing -fwrapv"
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
    # not, on this one section, and only until $LFS_TGT-ld takes over.
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
    ./Configure -des -Dprefix="$PFX" -Dcc="$PFX/bin/chain-cc" \
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
      grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      tail -25 b.log 2>/dev/null | sed 's/^/      /'
    fi
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
# THE ORDER IS FORCED. m4 first, because bison and flex both need it. flex
# before bison, because BOTH stop at
#     configure: error: cannot find output from flex; giving up
# -- bison's scanner ships pre-generated so it would BUILD without flex, but
# its configure checks anyway and there is no --without to give it.
#
# Python last, and it is the one genuinely new package: it wants zlib, libffi
# and openssl for modules that matter later, and this box has none of them.
# It will configure without them and quietly build less; the check afterwards
# names which modules are missing rather than letting that pass as success.
if [ "$R115" = ok ]; then
  r117=ok
  for pk in m4 flex bison; do
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
      ( cd "/work/src/py/$_pyd" \
        && ./configure --prefix="$PFX" --without-ensurepip --disable-test-modules \
             CC="$PFX/bin/chain-cc -static" LDFLAGS="-static" > cfg.log 2>&1 \
        && timeout 3600 make -j"$NP" > b.log 2>&1 \
        && make install > /dev/null 2>&1 ) \
        || { r117=FAIL
             say "    python NOT INSTALLED"
             grep -aiE "error|cannot|not found" "/work/src/py/$_pyd/cfg.log" 2>/dev/null \
               | tail -8 | sed 's/^/      /'
             tail -15 "/work/src/py/$_pyd/b.log" 2>/dev/null | sed 's/^/      /'; }
      if [ "$r117" = ok ]; then
        _py=$(ls "$PFX/bin"/python3* 2>/dev/null | head -1)
        say "    python: $("$_py" --version 2>&1 | head -1)"
        # WHAT IT BUILT WITHOUT. glibc only needs the interpreter, so a Python
        # missing zlib is fine HERE -- but saying so now is cheaper than
        # discovering it when something above wants to read a .zip.
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
head1 "RUNG 12 -- LFS 5.4: linux API headers"
# TWO KERNELS, AND THEY ARE NOT THE SAME ONE. KHDR supplies the API headers
# glibc is compiled against; KERNEL is the image that boots. A kernel may
# always be newer than the headers its libc was built against, and stage 4
# keeps them separate precisely so a libc/kernel disagreement can be fixed by
# changing one number rather than rebuilding both.
if [ "$R117" = ok ]; then
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
      cp -r usr/include "$S/usr" )
    _nh=$(find "$S/usr/include" -name '*.h' 2>/dev/null | wc -l)
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
if [ "$R12" = ok ]; then
  cd /work/src
  if ! untar "/in/glibc-$GLIBC"; then
    say "    glibc did not extract"; R13=FAIL
  else
    _gl=$(onedir "glibc-$GLIBC ./glibc-$GLIBC")
    cd "/work/src/$_gl"
    # BOTH PATCHES. fhs is LFS's own; upstream_fixes is stage 4's note "THE
    # PRICE OF LINUX 7" -- a 2.43 glibc meeting a 7.x kernel.
    for _pt in glibc-fhs-1.patch "glibc-$GLIBC-upstream_fixes-1.patch"; do
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
      say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: glibc configure"
      "/work/src/$_gl/configure" \
        --prefix=/usr \
        --host="$LFS_TGT" \
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
          say "    upstream_fixes patch covers exactly this; if it applied and"
          say "    the error is still here, it does not cover this point release."
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
    --host="$LFS_TGT" --build="$(/work/src/$g15/config.guess)" \
    --prefix=/usr --disable-multilib --disable-nls \
    --disable-libstdcxx-pch \
    --with-gxx-include-dir="/tools/$LFS_TGT/include/c++/$GCC15" \
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
# here is different: it goes in the SYSROOT, cross-compiled by $LFS_TGT-gcc,
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
if [ "$R14" = ok ]; then
  cd /work/src
  if ! untar /in/busybox-; then
    say "    busybox did not extract"; R15=FAIL
  else
    _bb=$(onedir 'busybox-* ./busybox-*')
    cd "/work/src/$_bb"
    make ARCH=arm64 CROSS_COMPILE="$LFS_TGT-" defconfig > /dev/null 2>&1
    yes '' | make ARCH=arm64 CROSS_COMPILE="$LFS_TGT-" oldconfig > /dev/null 2>&1
    # CONFIG_SSL_CLIENT is the applet that drags in networking/tls*.c, which
    # reaches for LONG_BIT without the feature macro. A build sysroot has no
    # use for HTTPS; drop the applet rather than patch a feature-test mismatch.
    for _sym in SSL_CLIENT FEATURE_WGET_OPENSSL TLS; do
      sed -i "s/^CONFIG_$_sym=y/# CONFIG_$_sym is not set/" .config
    done
    # VERIFY AFTER, because a sed that matches nothing is silent and
    # oldconfig is what undid the same edit three runs running.
    if grep -qE "^CONFIG_(SSL_CLIENT|TLS)=y" .config; then
      say "    TLS symbols came back after oldconfig:"
      grep -E "^CONFIG_(SSL_CLIENT|TLS|FEATURE_WGET_OPENSSL)" .config | sed 's/^/      /'
      R15=FAIL
    fi
    if [ "$R15" != FAIL ]; then
      # CONFIG_STATIC: the initramfs has no loader and no libc of its own.
      sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
      if timeout 3600 make ARCH=arm64 CROSS_COMPILE="$LFS_TGT-" \
           CFLAGS_EXTRA="-D_GNU_SOURCE" -j"$NP" > b.log 2>&1 && [ -x busybox ]; then
        mkdir -p "$S/usr/bin"
        cp busybox "$S/usr/bin/busybox"
        R15=ok
        say "    busybox: $(wc -c < busybox) bytes"
        say "    applets: $(./busybox --list 2>/dev/null | wc -l)"
        say "    static:  $(grep -aq 'ld-linux\|ld-musl' busybox && echo NO || echo yes)"
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
if [ "$R15" = ok ]; then
  rm -rf /work/b-binutils2 && mkdir -p /work/b-binutils2 && cd /work/b-binutils2
  say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: binutils pass 2 configure"
  "/work/src/$_bu/configure" \
    --prefix=/usr \
    --build="$(/work/src/$_bu/config.guess)" \
    --host="$LFS_TGT" \
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
      --build="$(/work/src/$g15/config.guess)" \
      --host="$LFS_TGT" \
      --target="$LFS_TGT" \
      LDFLAGS_FOR_TARGET="-L$PWD/$LFS_TGT/libgcc" \
      --prefix=/usr \
      --with-build-sysroot="$S" \
      --enable-default-pie --enable-default-ssp \
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
      for b in gcc g++ cc ld as; do
        printf '      %-6s %s\n' "$b" "$( [ -e "$S/usr/bin/$b" ] && echo present || echo missing )"
      done
    else
      R16=FAIL; say "    --- gcc pass 2 errors ---"
      grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
      tail -25 b.log 2>/dev/null | sed 's/^/      /'
    fi
  else
    R16=FAIL; say "    --- binutils pass 2 errors ---"
    grep -aE "PATH_MAX" b.log 2>/dev/null | head -3 | sed 's/^/      /'
    grep -nE "error:|Error [0-9]" b.log 2>/dev/null | head -12 | sed 's/^/      /'
    tail -25 b.log 2>/dev/null | sed 's/^/      /'
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 17 -- the kernel's own prerequisites: m4, bc, bison, flex"
# THE TOOLCHAIN IS NOT ENOUGH TO BUILD A KERNEL, in stage 4's words: kconfig is
# generated by flex and bison, and m4 comes first because both need it.
#
# bc IS NOT OPTIONAL. kernel/time/Makefile generates timeconst.h by piping
# CONFIG_HZ through bc; without one the kernel does not build. Stage 4 notes
# that BusyBox's bc applet had been silently answering to `bc` -- "it may well
# work, but nothing here declared it, which is the failure mode this repository
# is built to avoid". So it is declared and built.
#
# perl came at rung 11.5 because glibc wanted it too.
if [ "$R16" = ok ]; then
  r17=ok
  for pk in m4 bc bison flex; do
    [ "$r17" = ok ] || break
    cd /work/src
    rm -rf "/work/src/$pk-k" && mkdir -p "/work/src/$pk-k"
    ( cd "/work/src/$pk-k" && untar "/in/$pk-" ) || { r17=FAIL; say "    $pk did not extract"; break; }
    _kd=$(cd "/work/src/$pk-k" && onedir "$pk-* ./$pk-*")
    ( cd "/work/src/$pk-k/$_kd" \
      && ./configure --prefix="$PFX" CC="$CHAIN_CC -static" \
           LDFLAGS="-static -Wl,--no-eh-frame-hdr" > cfg.log 2>&1 \
      && timeout 1800 make -j"$NP" MAKEINFO=true > b.log 2>&1 \
      && make install MAKEINFO=true > /dev/null 2>&1 ) \
      || { r17=FAIL
           say "    $pk NOT INSTALLED"
           tail -15 "/work/src/$pk-k/$_kd/b.log" 2>/dev/null | sed 's/^/      /'; }
    [ "$r17" = ok ] && say "    $pk: $( [ -x "$PFX/bin/$pk" ] && echo installed || echo 'built, no binary' )"
  done
  R17=$r17
  [ "$R17" = ok ] && say "    m4 $(m4 --version 2>&1 | head -1 | grep -o '[0-9.]*$')  bison $(bison --version 2>&1 | head -1 | grep -oE '[0-9.]+$')"
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 18 -- the kernel"
# A FRESH TREE, NOT THE ONE RUNG 12 USED. That one was mrproper'd and had
# `make headers` run in it; stage 4's rule is that nothing built inside the box
# should start from a tree another compiler has already been in.
#
# THE CONFIG EDITS, AND WHY EACH ONE:
#   WERROR n            a 2026 gcc warns about 2026 kernel code; -Werror turns
#                       every one into a build failure
#   DEVTMPFS + _MOUNT   bwrap is unprivileged so the initramfs cannot mknod
#                       /dev/console. The kernel mounts devtmpfs before running
#                       init, so /dev/console exists by the time it opens it.
#   9P + 9P_VIRTIO      lets qemu hand the sysroot to the guest read-only, so
#                       the booted kernel can run the compiler that built it.
#                       Verified softly: a kernel that boots is a good result
#                       whether or not 9p is available.
#
# VERIFY AFTER olddefconfig, which is what undid the same edit three runs
# running in stage 4. A sed that matches nothing is silent.
if [ "$R17" = ok ]; then
  cd /work/src
  rm -rf /work/src/klinux && mkdir -p /work/src/klinux
  ( cd /work/src/klinux && untar "/in/linux-$KERNEL" ) || { say "    kernel did not extract"; R18=FAIL; }
  _kx=$(cd /work/src/klinux && onedir "linux-$KERNEL ./linux-$KERNEL")
  if [ "$R18" != FAIL ] && [ -n "$_kx" ]; then
    cd "/work/src/klinux/$_kx"
    make ARCH=arm64 CROSS_COMPILE="$LFS_TGT-" defconfig > /dev/null 2>&1
    set_cfg() {
      if [ "$2" = n ]; then
        sed -i "s/^CONFIG_$1=y/# CONFIG_$1 is not set/" .config
      else
        sed -i "s/^# CONFIG_$1 is not set/CONFIG_$1=y/" .config
        grep -q "^CONFIG_$1=y" .config || echo "CONFIG_$1=y" >> .config
      fi
    }
    set_cfg WERROR n
    set_cfg DEVTMPFS y
    set_cfg DEVTMPFS_MOUNT y
    set_cfg NET_9P y
    set_cfg NET_9P_VIRTIO y
    set_cfg 9P_FS y
    make ARCH=arm64 CROSS_COMPILE="$LFS_TGT-" olddefconfig > /dev/null 2>&1
    _bad=0
    grep -q "^CONFIG_WERROR=y" .config && { say "    WERROR came back on after olddefconfig"; _bad=1; }
    grep -q "^CONFIG_DEVTMPFS=y" .config || { say "    DEVTMPFS did not take"; _bad=1; }
    grep -q "^CONFIG_DEVTMPFS_MOUNT=y" .config || { say "    DEVTMPFS_MOUNT did not take"; _bad=1; }
    if [ "$_bad" != 0 ]; then
      grep -E "^(# )?CONFIG_(WERROR|DEVTMPFS)" .config | sed 's/^/      /'
      R18=FAIL
    else
      say "    config ready: defconfig, WERROR off, devtmpfs automounted"
      if timeout 7200 make ARCH=arm64 CROSS_COMPILE="$LFS_TGT-" -j"$NP" Image > b.log 2>&1 \
         && [ -f arch/arm64/boot/Image ]; then
        cp arch/arm64/boot/Image /work/Image
        R18=ok
        say "    Image: $(wc -c < /work/Image) bytes"
      else
        R18=FAIL; say "    --- errors ---"
        grep -nE "error:|Error [0-9]|No rule to make" b.log 2>/dev/null | head -15 | sed 's/^/      /'
        tail -25 b.log 2>/dev/null | sed 's/^/      /'
      fi
    fi
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 19 -- initramfs"
# The busybox from rung 15 plus an init script. cpio newc, gzipped, which is
# what the kernel unpacks.
if [ "$R18" = ok ]; then
  rm -rf /work/ir && mkdir -p /work/ir/bin /work/ir/dev /work/ir/proc /work/ir/sys /work/ir/sysroot
  cp "$S/usr/bin/busybox" /work/ir/bin/busybox
  ( cd /work/ir && ./bin/busybox --list > /tmp/applets.txt 2>/dev/null
    _n=$(wc -l < /tmp/applets.txt)
    if [ "$_n" -lt 100 ]; then
      echo "  too few applets -- --list did not run"
    fi
    while read -r a; do ln -sf busybox "bin/$a" 2>/dev/null; done < /tmp/applets.txt )
  # bwrap is unprivileged so mknod is unavailable; CONFIG_DEVTMPFS_MOUNT is
  # what carries /dev/console. Try anyway and say which one is doing it.
  if ( cd /work/ir && mknod dev/console c 5 1 2>/dev/null ); then
    say "    /dev/console created in the image"
  else
    say "    no mknod in the box -- /dev/console comes from CONFIG_DEVTMPFS_MOUNT"
  fi
  cat > /work/ir/init <<'INIT'
#!/bin/sh
mount -t proc  none /proc  2>/dev/null
mount -t sysfs none /sys   2>/dev/null
echo
echo "================================================"
echo "  VERON-BRIDGE: the guest, reporting on itself"
echo "================================================"
echo "  uname: $(uname -a)"
echo "  init : busybox $(busybox 2>&1 | head -1 | cut -c1-40)"
# The sysroot over 9p, if the kernel has it: chroot in and run the compiler
# this chain built, inside the kernel it built.
if mount -t 9p -o trans=virtio,version=9p2000.L veronsysroot /sysroot 2>/dev/null; then
  echo "  9p   : sysroot mounted"
  if [ -x /sysroot/usr/bin/gcc ]; then
    echo "  === VERON-GCC-IN-GUEST ==="
    chroot /sysroot /usr/bin/gcc --version 2>&1 | head -1
  fi
else
  echo "  9p   : not available (not a gate)"
fi
echo "  VERON-BOOT-OK"
echo
poweroff -f 2>/dev/null || { sync; echo o > /proc/sysrq-trigger; }
INIT
  chmod 0755 /work/ir/init
  ( cd /work/ir && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /work/initramfs.cpio.gz )
  if [ -s /work/initramfs.cpio.gz ]; then
    R19=ok
    say "    initramfs: $(wc -c < /work/initramfs.cpio.gz) bytes"
  else
    R19=FAIL; say "    cpio produced nothing"
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 20 -- hand the Image and initramfs out for the boot"
# THE BOOT ITSELF CANNOT HAPPEN IN HERE. qemu-system-aarch64 is not in this box
# and should not be: it is a VERIFIER, not a build tool, exactly as stage 4
# treats it. The workflow runs it outside, on what this rung leaves behind.
if [ "$R19" = ok ]; then
  mkdir -p /out
  cp /work/Image /out/Image 2>/dev/null
  cp /work/initramfs.cpio.gz /out/initramfs.cpio.gz 2>/dev/null
  if [ -s /out/Image ] && [ -s /out/initramfs.cpio.gz ]; then
    R20=ok
    say "    /out/Image             $(wc -c < /out/Image) bytes"
    say "    /out/initramfs.cpio.gz $(wc -c < /out/initramfs.cpio.gz) bytes"
    say "    the workflow boots these outside the box"
  else
    R20=FAIL; say "    nothing landed in /out"
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
printf '    %-40s %s\n' "5   gmp / mpfr / mpc"               "$R5"
printf '    %-40s %s\n' "6   gcc 4.7.4 by tcc -- stage 4 stage 1" "$R6"
printf '    %-40s %s\n' "7   gmp/mpfr/mpc rebuilt by that gcc"   "$R7"
printf '    %-40s %s\n' "8   gcc 4.7.4 again -- stage 4 stage 2" "$R8"
printf '    %-40s %s\n' "9   gcc 10.2.0 by g++ 4.7.4"            "$R9"
printf '    %-40s %s\n' "10  LFS 5.2 binutils pass 1"            "$R10"
printf '    %-40s %s\n' "11  LFS 5.3 gcc 15 pass 1"              "$R11"
printf '    %-40s %s\n' "11.5 perl (LFS puts it in ch7)"          "$R115"
printf '    %-40s %s\n' "11.7 m4 / flex / bison / python"         "$R117"
printf '    %-40s %s\n' "12  LFS 5.4 linux API headers"          "$R12"
printf '    %-40s %s\n' "13  LFS 5.5 glibc"                      "$R13"
printf '    %-40s %s\n' "14  LFS 5.6 libstdc++"                  "$R14"
printf '    %-40s %s\n' "15  ch6 busybox (for 17 packages)"      "$R15"
printf '    %-40s %s\n' "16  ch6 binutils + gcc pass 2"          "$R16"
printf '    %-40s %s\n' "17  m4 / bc / bison / flex"             "$R17"
printf '    %-40s %s\n' "18  linux $KERNEL"                      "$R18"
printf '    %-40s %s\n' "19  initramfs"                          "$R19"
printf '    %-40s %s\n' "20  Image handed out for boot"          "$R20"
say ""
if [ "$R20" = ok ]; then
  say "    EVERYTHING BUILT. The kernel and initramfs are in /out and the"
  say "    workflow boots them outside the box."
elif [ "$R14" = ok ]; then
  say "    CHAPTER 5 COMPLETE -- a cross toolchain and a glibc sysroot,"
  say "    from a seed-adjacent tcc. Chapter 6 is next: busybox in place of"
  say "    its seventeen packages, then binutils and gcc pass 2."
elif [ "$R11" = ok ]; then
  say "    REACHED LFS 5.3 -- a cross gcc 15 targeting $LFS_TGT."
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
