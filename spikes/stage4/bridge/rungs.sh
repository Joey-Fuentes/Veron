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

R0=skip; R1=skip; R2=skip; R3=skip; R35=skip; R4=skip; R5=skip; R6=skip

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
    ./configure "$@" CC="$CCAUTO" > cfg.log 2>&1
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
        ./configure "$@" CC="$CCAUTO" LD="$CC_BIN" > cfg.log 2>&1
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
            CC="$CCAUTO" > cfg.log 2>&1
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
  # AN ar AND A ranlib BEFORE binutils CAN BUILD ONE. Same move as LD= above,
  # and the same justification as rung 2's archive: tcc IS the archiver in this
  # box until rung 4 produces a real one. `tcc -ar` already built musl's
  # 3.2 MB libc.a from 1277 objects, so this is a proven path rather than a
  # hopeful one.
  #
  # busybox's ar is deliberately NOT linked into the box -- it can only read
  # archives, not create them, and configure finding it would produce a build
  # that fails later and further away.
  #
  # ranlib is `true`. tcc -ar writes the symbol index as it goes, so there is
  # nothing for a separate indexing pass to do; live-bootstrap's own configure
  # logs show `checking for ranlib... :` -- the no-op -- for the same reason.
  mkdir -p "$PFX/bin"
  # THE SHIM TRANSLATES FLAGS; IT DOES NOT JUST FORWARD THEM.
  #
  # The first attempt was `exec tcc -ar "$@"` and bfd stopped at libbfd.la with
  # an archiver usage message printed into the log. binutils' libtool does not
  # call `ar rcs`: it calls `ar cru`, `ar cq`, `ar cr` and similar, and tcc -ar
  # accepts `rcs` and prints usage for anything else. Forwarding the flags
  # verbatim was the bug.
  #
  # Creation modes all collapse to rcs, which is what they mean here -- replace
  # members, create if absent, write an index. Extraction modes (x, t, p) are
  # NOT translated: tcc -ar cannot do them, and silently doing something else
  # would corrupt a build rather than stop it. Those exit non-zero and say so.
  cat > "$PFX/bin/ar" <<'ARSHIM'
#!/bin/sh
# tcc -ar stands in for binutils ar until rung 4 builds a real one.
_flags=$1
case "$_flags" in
  -*) _flags=${_flags#-} ;;
esac
case "$_flags" in
  *x*|*t*|*p*|*d*|*m*)
      echo "ar-shim: tcc -ar cannot do '$_flags' (extract/list/delete)" >&2
      exit 1 ;;
esac
shift
exec CCBIN -ar rcs "$@"
ARSHIM
  sed -i "s|CCBIN|$CC_BIN|" "$PFX/bin/ar"
  printf '#!/bin/sh\nexit 0\n' > "$PFX/bin/ranlib"
  chmod 0755 "$PFX/bin/ar" "$PFX/bin/ranlib"
  PATH="$PFX/bin:$PATH"; export PATH

  # SMOKE-TEST IT BEFORE A 40-MINUTE BUILD DEPENDS ON IT. The last run trusted
  # this shim and found out inside bfd, 1700 lines into a log.
  say "    --- ar shim smoke test ---"
  ( cd /tmp && rm -f as.c as.o as.a
    printf 'int shim_probe(void){return 7;}\n' > as.c
    $CC -c -o as.o as.c 2>/dev/null
    for _f in cru cq cr rcs; do
      rm -f as.a
      if ar "$_f" as.a as.o 2>/tmp/ar.err; then
        printf '      ar %-4s -> ok   (%s bytes)\n' "$_f" "$(wc -c < as.a 2>/dev/null || echo 0)"
      else
        printf '      ar %-4s -> FAIL %s\n' "$_f" "$(head -1 /tmp/ar.err)"
      fi
    done
    rm -f as.c as.o as.a )
  say "    ranlib: no-op (tcc -ar indexes as it writes)"

  _busrc="../$(cd .. && onedir 'binutils-* ./binutils-*')"
  cfg_binutils() {
      say "START JOE: THIS IS THE COMMAND IM ABOUT TO DO: $_busrc/configure $* CC=\"$CCAUTO\""
      "$_busrc/configure" "$@" --prefix="$PFX" --disable-nls --disable-werror \
        --disable-gdb --disable-gdbserver --disable-libdecnumber --disable-readline \
        CC="$CCAUTO" > cfg.log 2>&1
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
  if timeout 3000 make -j"$NP" MAKEINFO=true > build.log 2>&1 \
     && make install MAKEINFO=true > /dev/null 2>&1; then
    R4=ok
    for t in as ld ar ranlib; do
      printf '    %-8s %s\n' "$t" "$( [ -x "$PFX/bin/$t" ] && wc -c < "$PFX/bin/$t" || echo ABSENT )"
    done
  else
    R4=FAIL; say "    --- the failing command ---"
    grep -nE "^(libtool|/bin/sh|ar |.*ar-shim)" build.log 2>/dev/null | tail -6 | sed 's/^/      /'
    say "    --- where it stopped ---"
    grep -nE "error:|Error [0-9]|undefined reference|ar-shim" build.log 2>/dev/null | head -15 | sed 's/^/      /'
    tail -15 build.log 2>/dev/null | sed 's/^/      /'
  fi
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 5 -- gmp, mpfr, mpc.  gcc's arithmetic dependencies."
# Same three, same versions, same configure shape as
# spikes/stage4/chain/rung1.sh. If they build here and there, the overlap is
# real rather than nominal.
if [ "$R4" = ok ]; then
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
  # THE BACKPORT IS NOT OPTIONAL AND IS NOT NEW WORK.
  #
  # gcc 4.7.4 has NO aarch64 backend -- aarch64 arrived in 4.8. stage 4 logs
  # exactly that: "4.7.4 aarch64 mentions in config.gcc (expect 0)". So every
  # gcc 4.7.4 in this repo is 4.7.4 carrying 4.8.5's backend, transplanted by
  # spikes/stage4/probes/backport-aarch64.sh -- a reviewed, named delta that
  # already exists and that stage 4 already depends on. Configuring stock 4.7.4
  # for aarch64 does not build a worse compiler; it does not configure at all.
  #
  # THE SCRIPT IS bash AND THIS BOX HAS busybox ash. It opens with
  # `#!/usr/bin/env bash` and `set -euo pipefail`, and calls `bash -n` on
  # config.host internally. ash accepts pipefail, and the internal `bash -n` is
  # already guarded by a fallback in the script, but this is the first time it
  # has run outside a box with bash in it. If it fails here that is a portability
  # finding about the script, not about the compiler -- so it is reported as its
  # own line rather than folded into gcc's result.
  untar /in/gcc-4.7 || { say "    gcc 4.7 did not extract"; R6=FAIL; }
  untar /in/gcc-4.8 || { say "    gcc 4.8 did not extract"; R6=FAIL; }
  g47=$(onedir 'gcc-4.7* ./gcc-4.7*')
  g48=$(onedir 'gcc-4.8* ./gcc-4.8*')
  say "    donor: $g48   target: $g47"
  say "    aarch64 in stock 4.7.4 config.gcc (expect 0): $(grep -c aarch64 "$g47/gcc/config.gcc" 2>/dev/null || echo '?')"
  if sh /src/stage4/probes/backport-aarch64.sh "$g47" "$g48" > /work/backport.log 2>&1; then
    say "    backport ok -- aarch64 in config.gcc now: $(grep -c aarch64 "$g47/gcc/config.gcc" 2>/dev/null || echo '?')"
  else
    say "    BACKPORT FAILED -- gcc cannot be configured for aarch64 without it"
    tail -15 /work/backport.log 2>/dev/null | sed 's/^/      /'
    R6=FAIL
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
    CC="$CCAUTO" \
    --build=aarch64-unknown-linux-gnu \
    --host=aarch64-unknown-linux-gnu \
    --target=aarch64-unknown-linux-gnu \
    --prefix="$PFX" --enable-languages=c,c++ \
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
  if [ "$R6" != FAIL ] && timeout 5400 make -j"$NP" MAKEINFO=true > build.log 2>&1; then
    R6=ok
    say "    xgcc:    $( [ -x gcc/xgcc ] && wc -c < gcc/xgcc || echo ABSENT )"
    say "    cc1:     $( [ -x gcc/cc1 ]  && wc -c < gcc/cc1  || echo ABSENT )"
    say "    cc1plus: $( [ -x gcc/cc1plus ] && wc -c < gcc/cc1plus || echo ABSENT )"
  else
    R6=FAIL; say "    --- where it stopped ---"
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

mkdir -p /out
cp -a "$PFX" /out/prefix 2>/dev/null || true
cp -a "$SYS/lib" /out/sysroot-lib 2>/dev/null || true
for l in /work/src/*/build.log /work/src/*/cfg.log \
         /work/src/b-*/build.log /work/src/b-*/cfg.log /work/musl-fail.txt; do
  [ -f "$l" ] && cp "$l" "/out/$(echo "$l" | tr / _)" 2>/dev/null || true
done
