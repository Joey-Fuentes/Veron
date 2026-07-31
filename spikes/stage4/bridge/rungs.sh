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

R0=skip; R1=skip; R2=skip; R3=skip; R35=skip; R4=skip; R5=skip; R6=skip

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
  cd /work/src && tar xzf /in/musl-*.tar.gz && cd musl-*
  for s in src/fenv/aarch64/fenv.s src/ldso/aarch64/tlsdesc.s \
           src/process/aarch64/vfork.s src/setjmp/aarch64/longjmp.s \
           src/signal/aarch64/restore.s src/thread/aarch64/__set_thread_area.s \
           src/thread/aarch64/__unmapself.s src/thread/aarch64/clone.s \
           src/thread/aarch64/syscall_cp.s; do
    rm -f "$s"
  done
  rm -f src/complex/*.c
  say "    declared substitutions applied (9 .s, src/complex)"

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
  : > /work/srclist
  for f in src/*/*.c ldso/*.c; do
    [ -f "$f" ] || continue
    d=$(dirname "$f"); b=$(basename "$f" .c)
    # replaced by an aarch64 version? then skip the generic one
    if [ -f "$d/aarch64/$b.c" ] || [ -f "$d/aarch64/$b.s" ] || [ -f "$d/aarch64/$b.S" ]; then
      continue
    fi
    echo "$f" >> /work/srclist
  done
  for f in src/*/aarch64/*.c crt/*.c crt/aarch64/*.c; do
    [ -f "$f" ] && echo "$f" >> /work/srclist
  done
  say "    file set: $(wc -l < /work/srclist) sources (aarch64, arch files replacing generic)"

  nc=0; nf=0
  : > /work/musl-fail.txt
  for f in $(sort /work/srclist); do
    o="obj/${f%.c}.o"; mkdir -p "$(dirname "$o")"
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

  say "    headers: $(find "$SYS/include" -name '*.h' 2>/dev/null | wc -l) files"
  say "    crt:     $(ls "$SYS/lib"/crt*.o 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
  if [ -s "$SYS/lib/libc.a" ] && [ -f "$SYS/lib/crt1.o" ]; then R2=ok; else R2=FAIL; fi
  cd /work
fi

HOSTED="-I$SYS/include -L$SYS/lib"

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
  # TWO WAYS, AND THE DIFFERENCE BETWEEN THEM IS THE DIAGNOSIS.
  #
  #   plain     what autoconf will do -- `$CC prog.c -o prog`, nothing else.
  #   explicit  crt files named on the command line, -nostdlib, libc by path.
  #
  # If plain fails and explicit works, the libc is fine and the compiler simply
  # cannot FIND it -- which still sinks every rung above, because configure
  # runs hundreds of conftest cycles and will not pass paths for us. If both
  # fail, the libc itself is wrong. Those are different problems and the last
  # two runs could not tell them apart.
  if $CC -static -o r3.bin r3.c 2>r3.err && ./r3.bin >r3.out 2>&1; then
    say "    plain:    $(cat r3.out)"; R3=ok
  else
    say "    plain:    FAILED"
    grep -av '^[A-Z][0-9]*$' r3.err | head -8 | sed 's/^/      /'
    if $CC $HOSTED -nostdlib -static -o r3e.bin \
         "$SYS/lib/crt1.o" "$SYS/lib/crti.o" r3.c -lc "$TCCDIR/libtcc1.a" \
         "$SYS/lib/crtn.o" 2>r3e.err && ./r3e.bin >r3e.out 2>&1; then
      R3=FAIL
      say "    explicit: $(cat r3e.out)"
      say ""
      say "    THE LIBC IS GOOD AND THE COMPILER CANNOT FIND IT. That is a"
      say "    search-path problem, not a codegen one -- but it still stops"
      say "    every rung above, because autoconf will not pass paths."
      say "    Compare the crt install above against -print-search-dirs."
    else
      R3=FAIL
      say "    explicit: ALSO FAILED -- the libc itself is wrong"
      grep -av '^[A-Z][0-9]*$' r3e.err | head -12 | sed 's/^/      /'
    fi
  fi
fi

# ---------------------------------------------------------------------------
head1 "RUNG 3.5 -- GNU make, built by the compiler under test"
# busybox has no make and nothing else is borrowed, so every autoconf rung
# above depends on this one. make ships build.sh precisely for the case where
# no make exists yet.
#
# IT IS ALSO THE CHEAPEST HOSTED SIGNAL. make is small plain C touching little
# beyond stdio, string and the process calls; it fails in minutes and for a
# readable reason. binutils fails after a long configure, usually as a
# consequence of something earlier.
if [ "$R3" = ok ]; then
  cd /work/src && tar xzf /in/make-*.tar.gz && cd make-*
  ./configure --prefix="$PFX" --disable-nls CC="$CC $HOSTED" > cfg.log 2>&1
  say "    configure rc=$?"
  if [ -f build.sh ]; then
    if sh ./build.sh > build.log 2>&1 && [ -x ./make ]; then
      cp ./make "$PFX/bin/make"; R35=ok
      say "    make: $(wc -c < "$PFX/bin/make") bytes"
      "$PFX/bin/make" --version 2>&1 | head -1 | sed 's/^/    /'
    else
      R35=FAIL; say "    --- where it stopped ---"
      grep -nE "error:|undefined reference" build.log 2>/dev/null | head -15 | sed 's/^/      /'
      tail -15 build.log 2>/dev/null | sed 's/^/      /'
    fi
  else
    R35=FAIL
    say "    configure produced no build.sh -- cannot bootstrap make without make"
    tail -12 cfg.log 2>/dev/null | sed 's/^/      /'
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
  cd /work/src && tar xf /in/binutils-*.tar.xz
  mkdir -p b-binutils && cd b-binutils
  ../binutils-*/configure --prefix="$PFX" --disable-nls --disable-werror \
    --disable-gdb --disable-gdbserver --disable-libdecnumber --disable-readline \
    CC="$CC $HOSTED" > cfg.log 2>&1
  say "    configure rc=$?"
  if timeout 3000 make -j"$NP" > build.log 2>&1 && make install > /dev/null 2>&1; then
    R4=ok
    for t in as ld ar ranlib; do
      printf '    %-8s %s\n' "$t" "$( [ -x "$PFX/bin/$t" ] && wc -c < "$PFX/bin/$t" || echo ABSENT )"
    done
  else
    R4=FAIL; say "    --- where it stopped ---"
    grep -nE "error:|Error [0-9]|undefined reference" build.log 2>/dev/null | head -15 | sed 's/^/      /'
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
  cd /work/src
  tar xf /in/gmp-*.tar.xz  && mv gmp-*/  gmp
  tar xf /in/mpfr-*.tar.xz && mv mpfr-*/ mpfr
  tar xf /in/mpc-*.tar.gz  && mv mpc-*/  mpc
  r5=ok
  ( cd gmp && ./configure --disable-shared --disable-assembly --prefix="$PFX" \
      CC="$CC $HOSTED" > cfg.log 2>&1 \
    && timeout 1800 make -j"$NP" > build.log 2>&1 && make install > /dev/null 2>&1 ) \
    || { r5=FAIL; say "    gmp NOT INSTALLED"; tail -12 gmp/build.log 2>/dev/null | sed 's/^/      /'; }
  for p in mpfr mpc; do
    [ "$r5" = ok ] || break
    ( cd "$p" && ./configure --disable-shared --with-gmp="$PFX" --prefix="$PFX" \
        CC="$CC $HOSTED" > cfg.log 2>&1 \
      && timeout 1200 make -j"$NP" > build.log 2>&1 && make install > /dev/null 2>&1 ) \
      || { r5=FAIL; say "    $p NOT INSTALLED"; tail -12 "$p/build.log" 2>/dev/null | sed 's/^/      /'; }
  done
  R5=$r5
  [ "$R5" = ok ] && say "    prefix/lib: $(ls "$PFX/lib" 2>/dev/null | tr '\n' ' ')"
  cd /work
fi

# ---------------------------------------------------------------------------
head1 "RUNG 6 -- gcc 4.7.4.  THE OVERLAP WITH stage4-complete."
# The rung stage 4 already reaches with a host-gcc-built tcc, against host
# glibc and host binutils. Reaching it here -- from this box, with a libc, a
# make and a binutils all built inside it -- is what makes the two jobs one
# ladder.
if [ "$R5" = ok ]; then
  cd /work/src && tar xf /in/gcc-*.tar.bz2
  mkdir -p b-gcc && cd b-gcc
  ../gcc-*/configure --prefix="$PFX" \
    --with-gmp="$PFX" --with-mpfr="$PFX" --with-mpc="$PFX" \
    --enable-languages=c --disable-shared --disable-nls \
    --disable-multilib --disable-bootstrap --disable-libsanitizer \
    --with-sysroot="$SYS" \
    CC="$CC $HOSTED" > cfg.log 2>&1
  say "    configure rc=$?"
  if timeout 5400 make -j"$NP" > build.log 2>&1; then
    R6=ok
    say "    xgcc: $( [ -x gcc/xgcc ] && wc -c < gcc/xgcc || echo ABSENT )"
    say "    cc1:  $( [ -x gcc/cc1 ]  && wc -c < gcc/cc1  || echo ABSENT )"
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
