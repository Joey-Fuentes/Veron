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

R0=skip; R1=skip; R2=skip; R3=skip; R35=skip; R4=skip; R45=skip; R5=skip; R6=skip

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
    --prefix="$PFX" --enable-languages=c,c++ \
    --disable-nls \
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
  # CAN xgcc LINK AT ALL, EITHER WAY? Asked here rather than discovered inside
  # a target library's configure, and asked BOTH ways so the answer separates
  # "dynamic is broken" from "linking is broken".
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
  fi

  # THE ONE THAT ACTUALLY FAILED LAST TIME. Existing is not enough; libgcc's
  # configure execs it, and it answered "Permission denied".
  if "$PFX/aarch64-unknown-linux-gnu/bin/as" --version >/dev/null 2>&1; then
    printf '      %-52s %s\n' "tooldir as EXECUTES" yes
  else
    printf '      %-52s %s\n' "tooldir as EXECUTES" "NO -- libgcc will fail"
  fi

  if [ "$R6" != FAIL ] && timeout 5400 make -j"$NP" MAKEINFO=true > build.log 2>&1; then
    R6=ok
    say "    xgcc:    $( [ -x gcc/xgcc ] && wc -c < gcc/xgcc || echo ABSENT )"
    say "    cc1:     $( [ -x gcc/cc1 ]  && wc -c < gcc/cc1  || echo ABSENT )"
    say "    cc1plus: $( [ -x gcc/cc1plus ] && wc -c < gcc/cc1plus || echo ABSENT )"
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
printf '    %-40s %s\n' "6   gcc 4.7.4 -- stage 4's rung 1"  "$R6"
say ""
if [ "$R6" = ok ]; then
  say "    REACHED gcc 4.7.4 in a box with busybox and one compiler."
else
  say "    STOPPED. The first rung above that is not 'ok' is the frontier;"
  say "    everything after it was skipped, not failed."
fi

# Machine-readable, so the workflow can diff two arms without parsing prose.
printf '%s %s %s %s %s %s %s %s %s\n' \
  "$ARM" "$R0" "$R1" "$R2" "$R3" "$R35" "$R4" "$R5" "$R6" > /out/rungs.txt

# LOGS ALWAYS. BINARIES ONLY IF THE LADDER ACTUALLY CLOSED.
#
# This used to copy $PFX and $SYS/lib unconditionally -- binutils' as, ld, ar
# and ranlib at ~15 MB each, plus gmp/mpfr/mpc, make and musl's 3.2 MB libc.a.
# Sixty-odd megabytes uploaded on every run, INCLUDING runs that died at rung 2
# and had nothing worth keeping. On a failure the binaries are the least useful
# thing in the box; the logs are the only useful thing, and they are small.
mkdir -p /out/logs
for l in /work/src/*/config.log /work/src/*/cfg.log /work/src/*/build.log \
         /work/src/b-*/config.log /work/src/b-*/cfg.log /work/src/b-*/build.log \
         /work/bld/config.log /work/bld/cfg.log /work/bld/build.log \
         /work/musl-fail.txt /work/musl-cc.err /work/make-cc.err; do
  [ -f "$l" ] && cp "$l" "/out/logs/$(echo "${l#/work/}" | tr / _)" 2>/dev/null || true
done
# gcc's sub-configures each keep their own, and they are where the reason is.
for l in $(find /work/bld -name config.log 2>/dev/null | head -20); do
  cp "$l" "/out/logs/bld_$(echo "${l#/work/bld/}" | tr / _)" 2>/dev/null || true
done
say ""
say "  logs collected: $(ls /out/logs 2>/dev/null | wc -l) files, $(du -sh /out/logs 2>/dev/null | cut -f1)"

if [ "$R6" = ok ]; then
  cp -a "$PFX" /out/prefix 2>/dev/null || true
  cp -a "$SYS/lib" /out/sysroot-lib 2>/dev/null || true
  say "  toolchain kept: rung 6 closed, so the binaries are worth having"
else
  say "  toolchain NOT kept: rung 6 did not close, so $(du -sh "$PFX" 2>/dev/null | cut -f1) of"
  say "  half-built binaries would be uploaded for nothing. Logs only."
fi
