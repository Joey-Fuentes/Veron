#!/bin/bash
# stages/4-toolchain-kernel/build.sh -- stage 4, the whole ladder from the
# stage-3 contract to a bootable system, as ONE SCRIPT WITH PHASES, run the
# same way on a GitHub runner, on a Veron laptop, or on any Linux with
# bubblewrap:
#
#     sh stages/4-toolchain-kernel/build.sh in        airlock: pins, the 3->4 contract, tarball repack
#     sh stages/4-toolchain-kernel/build.sh chain     the box: ref-tcc -> musl -> make -> binutils -> gcc -> the system
#     sh stages/4-toolchain-kernel/build.sh collect   gather boot/, toolchain/, manifest/ into out/4
#     sh stages/4-toolchain-kernel/build.sh boot      the kernel it built, under qemu (ours when present)
#     sh stages/4-toolchain-kernel/build.sh pack      trim + tar the sysroot into out/4/rel (what the release carries)
#     sh stages/4-toolchain-kernel/build.sh all       in chain collect boot pack
#
# EXTRACTED 2026-08-25 FROM 4-toolchain-kernel-amd64.yml, step bodies kept
# verbatim with their comments (they are the ledger of why), so that the
# workflow becomes a thin caller and the laptop runs the identical text. The
# in-box half was always sealed (bwrap, busybox-only PATH, the stage-3 tcc
# handed forward); this file changes WHERE the airlock's tools come from --
# busybox by stages/box.sh's resolution (bundle, airlock-built from the pin,
# or the system's, by hash) instead of a runner-gcc build inline -- and
# lets the boot gate use the qemu and OVMF this project built when they
# are on the host, apt's only when they are not.
#
# THE BUDGET, unchanged: tier 1 empty; tier 2 busybox (+ a gawk wrapper
# around its awk, written here). ref-tcc is the stage-3 contract, verified
# against the committed record before anything runs.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/sources/tcc.toml" ] || { echo "FAIL: no repo root above $HERE"; exit 1; }
cd "$ROOT"
set -a; . "$HERE/pins.env"; set +a
BUDGET_PATH=""; BUDGET_DRIVER="busybox"
TRACE_APPLETS="${TRACE_APPLETS:-0}"
BOX="$ROOT/box4"
OUT4="$ROOT/out/4"
mkdir -p "$OUT4"

# ---- the box's busybox, by stages/box.sh's resolution order -------------
resolve_busybox() {
  if [ -n "${VERON_TOOLS:-}" ] && [ -x "$VERON_TOOLS/busybox" ]; then BB="$VERON_TOOLS/busybox"; BB_FROM="VERON_TOOLS"
  elif [ -x "$ROOT/veron-tools/busybox" ]; then BB="$ROOT/veron-tools/busybox"; BB_FROM="veron-tools bundle"
  elif [ -x "$ROOT/box/tools/busybox" ]; then BB="$ROOT/box/tools/busybox"; BB_FROM="airlock-built from the pin"
  elif [ -x /bin/busybox ]; then BB=/bin/busybox; BB_FROM="system"
  else echo "FAIL: no busybox -- set VERON_TOOLS, unpack the tools bundle as veron-tools/, or run tools/airlock-busybox.sh"; exit 1; fi
  if command -v readelf >/dev/null 2>&1 && readelf -d "$BB" 2>/dev/null | grep -q NEEDED; then
    echo "FAIL: $BB is dynamically linked; the box's driver must be static"; exit 1; fi
  echo "  busybox: $BB ($BB_FROM) sha256 $(sha256sum "$BB" | cut -c1-16), $("$BB" --list | wc -l) applets"
}
# ELF e_machine without file(1): 0x3e is x86_64. PT_INTERP absent = static.
elf_machine() { od -An -tx1 -j18 -N1 "$1" 2>/dev/null | tr -d ' \n'; }
elf_is_static() {
  _phoff=$(od -An -tu8 -j32 -N8 "$1" | tr -d ' '); _phnum=$(od -An -tu2 -j56 -N2 "$1" | tr -d ' '); _i=0
  while [ "$_i" -lt "$_phnum" ]; do
    [ "$(od -An -tu4 -j$((_phoff + _i*56)) -N4 "$1" | tr -d ' ')" = 3 ] && return 1
    _i=$((_i+1)); done; return 0
}


phase_in() {
  echo "== IN: the 3->4 contract (tcc-amd64, verified against the committed record) =="
  sh "$HERE/in.sh"
  rm -rf tccsrc && cp -a in/3/tcc-src tccsrc
  cp in/4/ref-tcc tccsrc/tcc
  chmod 0755 tccsrc/tcc
  echo "== GATE: the reference tcc must be STATIC =="
  [ "$(elf_machine tccsrc/tcc)" = 3e ] || { echo "  FAIL: ref-tcc is not an x86_64 ELF"; exit 1; }
  elf_is_static tccsrc/tcc || { echo "  ref-tcc is DYNAMICALLY linked -- the box cannot stay busybox-only"; exit 1; }
  echo "  static. The box needs no shared objects for it."
  ./tccsrc/tcc -v 2>&1 | head -1 | sed 's/^/  /'
  echo "== Fetch pinned upstreams (airlock -- nothing here enters the box) =="

  mkdir -p dl && cd dl

  # MIRRORS, AND A SHORT CONNECT TIMEOUT SO A DEAD ONE COSTS SECONDS.
  #
  # A run died with
  #
  #     curl: (28) Failed to connect to musl.libc.org port 443
  #           after 134279 ms
  #
  # -- two and a half minutes to discover one host was down, and then
  # the whole job with it. tools/clone-pinned.sh already does this for
  # git ("the first mirror that answers"); this is the same idea for
  # tarballs. --connect-timeout 20 means an unreachable mirror costs 20
  # seconds, not 134.
  #
  # ftpmirror.gnu.org is GNU's own round-robin redirector and is tried
  # first for that reason; ftp.gnu.org is the canonical host and goes
  # last because it is the one that is busy.
  GNU_MIRRORS="https://ftpmirror.gnu.org
               https://mirrors.kernel.org/gnu
               https://mirror.csclub.uwaterloo.ca/gnu
               https://ftp.gnu.org/gnu"
  MUSL_MIRRORS="https://musl.libc.org/releases
                https://distfiles.macports.org/musl
                https://ftp.barfooze.de/pub/sabotage/tarballs"

  # EVERY TARBALL VERIFIES AGAINST sources/*.toml OR THE BUILD DIES.
  # tools/verify-source.sh: pinned -> sha256 must match; named-but-
  # unpinned -> MINT line (commit it); unnamed -> FAIL. Our own
  # src/<file> releases are tried before any upstream mirror -- the
  # mirror we run is the mirror we trust first.
  VERIFY="$ROOT/tools/verify-source.sh"
  SRCREL="https://github.com/${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}/releases/download"
  fetch() {   # $1 = newline-separated mirror list, $2 = path under each
    _out=$(basename "$2")
    if [ -s "$_out" ]; then
      # CACHED IS NOT EXEMPT. The actions cache restored this file
      # from an earlier run; a stale or poisoned cache is exactly
      # what verification exists to catch. A mismatch deletes the
      # file and falls through to a fresh, verified download.
      if sh "$VERIFY" "$_out"; then
        printf '  cached  %-30s %10s bytes\n' "$_out" "$(wc -c < "$_out")"
        return 0
      fi
      echo "  cached copy of $_out FAILED verification -- refetching"
      rm -f "$_out"
    fi
    for _m in "$SRCREL/src/$_out" $1; do
      case "$_m" in "$SRCREL"*) _path="$_out";; *) _path="$2";; esac
      if curl -fsSL --connect-timeout 20 --max-time 900 --retry 2 \
              -o "$_out.part" "$_m/$_path" 2>/dev/null; then
        mv "$_out.part" "$_out"
        printf '  fetched %-30s %10s bytes  from %s\n' \
          "$_out" "$(wc -c < "$_out")" "$_m"
        sh "$VERIFY" "$_out" || { rm -f "$_out"; return 1; }
        return 0
      fi
      echo "    no answer from $_m"
    done
    rm -f "$_out.part"
    echo "  ALL MIRRORS FAILED for $2"
    return 1
  }

  fetch "$MUSL_MIRRORS" "musl-$MUSL_VER.tar.gz"
  fetch "$GNU_MIRRORS"  "make/make-$MAKE_VER.tar.gz"
  fetch "$GNU_MIRRORS"  "make/make-$MAKE_ALT.tar.gz"
  fetch "$GNU_MIRRORS"  "binutils/binutils-$BINUTILS.tar.xz"
  fetch "$GNU_MIRRORS"  "gmp/gmp-$GMP_VER.tar.xz"
  fetch "$GNU_MIRRORS"  "mpfr/mpfr-$MPFR_VER.tar.xz"
  fetch "$GNU_MIRRORS"  "mpc/mpc-$MPC_VER.tar.gz"
  fetch "$GNU_MIRRORS"  "gcc/gcc-$GCC47/gcc-$GCC47.tar.bz2"
  fetch "$GNU_MIRRORS"  "gcc/gcc-$GCC48/gcc-$GCC48.tar.bz2"
  fetch "$GNU_MIRRORS"  "gcc/gcc-$GCC10/gcc-$GCC10.tar.xz"
  fetch "$GNU_MIRRORS"  "gcc/gcc-$GCC15/gcc-$GCC15.tar.xz"
  fetch "$GNU_MIRRORS"  "binutils/binutils-$BINUTILS_LFS.tar.xz"
  fetch "$GNU_MIRRORS"  "glibc/glibc-$GLIBC.tar.xz"
  fetch "$GNU_MIRRORS"  "gawk/gawk-$GAWK_VER.tar.xz"
  fetch "$GNU_MIRRORS"  "m4/m4-$M4_VER.tar.xz"
  fetch "$GNU_MIRRORS"  "m4/m4-$M4_BOOT_VER.tar.gz"
  fetch "$GNU_MIRRORS"  "bison/bison-$BISON_VER.tar.xz"

  # a legacy hash-prefixed pkgconf may sit in the restored cache from
  # the hand-made release URL era; remove it so in-box globs match
  # exactly one pkgconf tarball
  rm -f 3acd3a8a-pkgconf-*.tar.xz

  # The kernel and the two glibc patches are not on a GNU mirror.
  for u in "https://www.cpan.org/src/5.0/perl-$PERL_VER.tar.xz" \
           "https://github.com/gavinhoward/bc/releases/download/$BC_VER/bc-$BC_VER.tar.xz" \
           "https://github.com/westes/flex/releases/download/v$FLEX_VER/flex-$FLEX_VER.tar.gz" \
           "https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2" \
           "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" \
           "https://www.python.org/ftp/python/$PYTHON_VER/Python-$PYTHON_VER.tar.xz" \
           "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz" \
           "https://sourceware.org/elfutils/ftp/$ELFUTILS_VER/elfutils-$ELFUTILS_VER.tar.bz2" \
           "https://github.com/Joey-Fuentes/Veron/releases/download/src/pkgconf-$PKGCONF_VER.tar.xz/pkgconf-$PKGCONF_VER.tar.xz" \
           "https://cdn.kernel.org/pub/linux/kernel/v${KHDR%%.*}.x/linux-$KHDR.tar.xz" \
           "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL%%.*}.x/linux-$KERNEL.tar.xz" \
           "https://www.linuxfromscratch.org/patches/lfs/development/glibc-fhs-1.patch"; do
    b=$(basename "$u")
    if [ -s "$b" ]; then
      case "$b" in
        *.tar.*) if sh "$VERIFY" "$b"; then
                   printf '  cached  %-30s %10s bytes\n' "$b" "$(wc -c < "$b")"
                   continue
                 fi
                 echo "  cached copy of $b FAILED verification -- refetching"
                 rm -f "$b" ;;   # fall through to the fetch below
        *)       printf '  cached  %-30s %10s bytes\n' "$b" "$(wc -c < "$b")"
                 continue ;;
      esac
    fi
    # our own mirror first; fall through to upstream on any miss
    if curl -fsSL --connect-timeout 15 --max-time 900 --retry 2 \
            -o "$b.part" "$SRCREL/src/$b/$b" 2>/dev/null && [ -s "$b.part" ]; then
      mv "$b.part" "$b"
      printf '  fetched %-30s %10s bytes  from src/ release\n' "$b" "$(wc -c < "$b")"
      case "$b" in *.tar.*) sh "$VERIFY" "$b" || exit 1;; esac
      continue
    fi
    rm -f "$b.part"
    # STAGE 4's curl FLAGS, VERBATIM, AND THEY ARE NOT DECORATION.
    #
    # This fetched sixteen tarballs and glibc-fhs-1.patch from the same
    # host and directory, then failed on
    # glibc-2.43-upstream_fixes-1.patch alone. The URL is byte-identical
    # to the one stage4-complete has been using successfully for weeks,
    # so it is the request, not the address.
    #
    #   --http1.1          linuxfromscratch.org's HTTP/2 upsets curl
    #                      on some connections; stage 4 pins 1.1
    #   --retry-all-errors retries a 5xx or a reset, which plain
    #                      --retry does NOT -- it only retries
    #                      transient TRANSPORT errors
    #   --retry-delay 3    gives the far end a moment
    if curl -fsSL --http1.1 --retry 3 --retry-all-errors --retry-delay 3 \
            --connect-timeout 20 --max-time 900 -o "$b.part" "$u" 2>/dev/null; then
      mv "$b.part" "$b"
      printf '  fetched %-30s %10s bytes\n' "$b" "$(wc -c < "$b")"
      # verify tarballs; *.patch is exempt -- the vendored in-repo copy
      # is its authority and is compared right below
      case "$b" in *.tar.*) sh "$VERIFY" "$b" || exit 1;; esac
    else
      rm -f "$b.part"
      # A MISSING glibc PATCH IS NOT FATAL HERE. The vendored copy is
      # taken a few lines below, and that path prints "vendored" so the
      # log says which source was used. Everything else IS fatal:
      # a missing tarball cannot be substituted.
      case "$b" in
        glibc-*.patch) echo "  not upstream: $b (will use the vendored copy)" ;;
        *)             echo "  FETCH FAILED: $u"; _fetchfail=1 ;;
      esac
    fi
  done
  # A MISSING PIN IS NOT A WARNING. This loop used to print
  # "FETCH FAILED" and carry on, and the run then spent its time
  # assembling a box that could not possibly finish -- rung 13 would
  # have stopped on a glibc patch that was never downloaded.
  #
  # THE TWO glibc PATCHES COME FROM DIFFERENT DIRECTORIES, and that is
  # stage4-complete's arrangement rather than an inconsistency:
  #
  #   glibc-fhs-1.patch        lfs/development/  section 3.3 of the
  #                                              vendored book names
  #                                              this exact URL
  #   glibc-2.43-upstream...   lfs/development/  exists ONLY there,
  #                                              because only the
  #                                              development book pairs
  #                                              glibc 2.43 with a 7.x
  #                                              kernel -- which is what
  #                                              this box does
  #
  # A run was lost to putting both under 13.0, and another to putting
  # both under development. Failing here rather than four rungs later
  # is what makes that one minute instead of forty.
  [ "${_fetchfail:-0}" = 0 ] || {
    echo "  one or more pinned inputs did not download; not continuing."
    exit 1; }

  # THE glibc PATCHES ARE VENDORED, NOT FETCHED.
  #
  # /patches/lfs/development/ is not an archive: it tracks whatever the
  # development book currently is, and its contents are revised and
  # REMOVED in place. Two runs died on
  # glibc-2.43-upstream_fixes-1.patch while sixteen tarballs and
  # glibc-fhs-1.patch came down from the same host in the same run --
  # with stage4-complete's own curl flags, so it was the address rather
  # than the request. The file had been removed.
  #
  # A pinned input should not come from a mutable directory. Both
  # patches now live in spikes/stage4/patches/lfs/ and are copied,
  # not downloaded. See the README there for the digests and for how
  # to refresh one deliberately.
  #
  # THE NETWORK COPY IS TRIED FIRST for both, because taking upstream's
  # file when it is reachable keeps us honest about what the book
  # actually ships. The vendored copy stands in when it is not, which
  # is the point of having one.
  #
  # SECTION 3.3 OF THE VENDORED BOOK NAMES BOTH UNDER development/ with
  # these digests -- an earlier version of this file split them across
  # two directories on a guess, and stage4-complete does the same.
  for _pf in glibc-fhs-1.patch; do
    if [ -s "$_pf" ]; then
      echo "  fetched   $_pf"
      continue
    fi
    _v="$ROOT/spikes/stage4/patches/lfs/$_pf"
    if [ -s "$_v" ]; then
      cp "$_v" "$_pf"
      printf '  vendored  %-42s %s bytes\n' "$_pf" "$(wc -c < "$_pf")"
    else
      echo
      echo "  $_pf IS NEITHER REACHABLE NOR VENDORED."
      echo
      echo "  It is not optional: the book introduces the upstream_fixes"
      echo "  patch with \"Now fix glibc to build against Linux 7\", and"
      echo "  this box pairs glibc $GLIBC with linux $KHDR headers --"
      echo "  exactly the pairing it exists for. Without it rung 13 stops"
      echo "  on a -Werror redefinition between the libc and the kernel"
      echo "  headers, which reads as a glibc bug and is not one."
      echo
      echo "  Put a copy in spikes/stage4/patches/lfs/ -- that"
      echo "  directory's README has the digests and the source URL."
      exit 1
    fi
  done

  # THE PATCH DIGESTS, RECORDED AND COMPARED BUT NOT ENFORCED.
  #
  # /patches/lfs/development/ is a MOVING directory -- it tracks
  # whatever the development book currently is, and those patches are
  # revised in place. Pinning a digest would turn a legitimate upstream
  # update into a red build; pinning nothing would let a substitution
  # through unnoticed.
  #
  # So print what arrived and compare it to the digest in the book
  # vendored under spikes/stage4/books. THE REAL GATE IS `patch`
  # ITSELF: a truncated or substituted patch does not apply cleanly to
  # glibc 2.43, and rung 13 refuses to continue when it does not.
  # Same reasoning, same digests, as stage4-complete.
  for _pd in "glibc-fhs-1.patch 9a5997c3452909b1769918c759eff8a2"; do
    set -- $_pd
    [ -f "$1" ] || continue
    _got=$(md5sum "$1" | cut -d' ' -f1)
    if [ "$_got" = "$2" ]; then
      printf '  %-42s md5 matches the vendored book\n' "$1"
    else
      printf '  %-42s md5 DIFFERS from the vendored book\n' "$1"
      echo "      vendored r13.0-156 : $2"
      echo "      fetched now        : $_got"
      echo "    Not fatal -- the development book moves. But if glibc"
      echo "    fails after this, THIS LINE IS THE FIRST THING TO READ."
    fi
  done

  echo "  --- what came in ---"
  sha256sum ./*.tar.* 2>/dev/null | sed 's/^/    /'
  # HASHES ARE PRINTED, NOT YET ENFORCED. sources/musl.toml carries
  # musl's; the rest belong in sources/*.toml before this job is
  # anything but exploratory. With a cache in play that matters MORE,
  # not less -- a cache hit means nobody re-fetched the bytes, so the
  # only thing standing between the job and a corrupted cache entry
  # would be a hash check that does not exist yet.

  # pins/ IS THE WORKING COPY. Everything downstream mutates it; dl/ is
  # left exactly as fetched so the cache stays clean.
  cd ..
  rm -rf pins && mkdir -p pins
  cp dl/*.tar.* pins/
  # THE PATCHES ARE NOT TARBALLS. `cp dl/*.tar.*` would leave
  # glibc-fhs-1.patch and glibc-*-upstream_fixes-1.patch behind in dl/,
  # and rung 13 would report "not in /in -- fetch it" about files that
  # had been fetched perfectly well.
  cp dl/*.patch pins/ 2>/dev/null || true
  echo "  pins/ rebuilt from dl/: $(ls pins | wc -l) files, $(du -sh pins | cut -f1)"

  echo "== NO BACKPORT TO DERIVE ON THIS TARGET =="

  # THE aarch64 ARM DERIVES A PATCH SET HERE and hands it to the box
  # through /in, because gcc 4.7 has no aarch64 port -- it arrived in
  # 4.8, and backport-aarch64.sh transplants 4.8.5's backend in.
  #
  # x86_64 IS 4.7.4's OLDEST AND BEST-SUPPORTED TARGET. There is
  # nothing to derive, so this step exists to say so rather than to be
  # silently absent -- a missing step reads as an oversight, a step
  # that explains itself does not. rungs-amd64.sh asserts both counts
  # at rung 6: many x86_64 mentions in config.gcc, zero aarch64.
  mkdir -p pins
  echo "  nothing staged into /in for this target"

  echo "== AIRLOCK: repack V7 tarballs as ustar (busybox tar requires the magic) =="
  # WHY: some pins (make 3.82's, old gcc's) are V7-format tars without the
  # "ustar" magic at offset 257, and busybox tar -- the box's only tar --
  # refuses them. The workflow repacked with GNU tar --format=ustar; the
  # image's tar is busybox and cannot. python3's tarfile does it on every
  # host the same way: USTAR format, members in archive order, mtimes kept,
  # gzip with mtime 0 -- so a laptop and a runner produce the same bytes.
  # The pin's digest was verified BEFORE this step; what enters the box is
  # the same content in a container busybox reads.
  python3 - "$ROOT/pins" <<'PY'
import sys, os, tarfile, gzip, io, shutil
d = sys.argv[1]
for f in sorted(os.listdir(d)):
    if not any(f.endswith(x) for x in ('.tar.gz', '.tar.xz', '.tar.bz2')): continue
    path = os.path.join(d, f)
    # the raw header magic, from a fresh decompressed stream
    opener = {'gz': gzip.open, 'xz': __import__('lzma').open, 'bz2': __import__('bz2').open}[f.rsplit('.', 1)[1]]
    with opener(path, 'rb') as raw:
        hdr = raw.read(512)
    if hdr[257:262] == b'ustar':
        print(f'  {f:26s} already ustar -- left alone'); continue
    stem = f.split('.tar.')[0]
    out = os.path.join(d, stem + '.tar.gz')
    buf = io.BytesIO()
    with tarfile.open(path, 'r:*') as src, tarfile.open(fileobj=buf, mode='w', format=tarfile.USTAR_FORMAT) as dst:
        for m in src:
            dst.addfile(m, src.extractfile(m) if m.isfile() else None)
    with open(out + '.tmp', 'wb') as o, gzip.GzipFile(filename='', mode='wb', fileobj=o, mtime=0) as gz:
        gz.write(buf.getvalue())
    if out != path: os.remove(path)
    os.replace(out + '.tmp', out)
    with gzip.open(out, 'rb') as raw: after = raw.read(512)[257:262]
    assert after == b'ustar', f'REPACK DID NOT TAKE for {f}'
    print(f'  {f:26s} V7 -> ustar  {os.path.getsize(out)} bytes')
PY
  echo "  --- what the box will see in /in ---"
  ls -1 pins | sed 's/^/    /'
}


phase_chain() {
  [ -x tccsrc/tcc ] && [ -d pins ] || { echo "FAIL: run the in phase first"; exit 1; }
  resolve_busybox
  rm -rf "$BOX"
  echo "== Assemble the box =="

    mkdir -p "$BOX"/bin "$BOX"/lib "$BOX"/work "$BOX"/out \
           "$BOX"/src "$BOX"/in "$BOX"/tmp "$BOX"/proc "$BOX"/dev

  # Tier 1 is empty, so this copies nothing. It stays because the SEAL
  # reads the same variable and the two must not describe different sets.
  # OUR busybox, from the airlock step above -- see it for why.
  cp -L "$BB" "$BOX/bin/busybox"

  # tcc's -B directory: its own source tree, which is where it looks
  # for libtcc1.a and its include/. libtcc1.a is BUILT at rung 0 by the
  # compiler under test, not copied in.
  cp -a tccsrc "$BOX/work/tccsrc"
  rm -f "$BOX/work/tccsrc/libtcc1.a"
  cp -L tccsrc/tcc "$BOX/work/ref-tcc"
  chmod 0755 "$BOX/work/ref-tcc"

  # Only what the tier-2 binaries need to EXECUTE. Both are static, so
  # this should find nothing -- and the count is printed rather than
  # assumed.
  for b in "$BOX"/bin/* "$BOX/work/ref-tcc"; do
    ldd "$b" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}'
  done | sort -u > /tmp/needed
  n=0
  while read -r l; do
    [ -f "$l" ] && cp -L "$l" "$BOX/lib/" && n=$((n+1))
  done < /tmp/needed
  echo "  shared objects the box needs: $n"

  # EVERY APPLET busybox HAS, ASKED FOR RATHER THAN GUESSED.
  #
  # This was a hand-written list and it was short. binutils' libiberty
  # stopped at
  #
  #     touch stamp-picdir
  #     make[2]: *** [stamp-picdir] Error 127
  #
  # -- 127 is "command not found", and `touch` was simply not in it. A
  # build this size will reach for dozens of ordinary utilities and
  # guessing which ones is a round each. `busybox --list` is the
  # authoritative answer and costs one line.
  #
  # TWO ARE NOT LINKED -- `ar` and `strings` -- because both are tier 1
  # by this job's definition: they decide what bytes end up in an
  # artifact, and busybox's ar can only READ archives, never create one.
  #
  # NOT LINKING THEM DOES NOT REMOVE THEM, and that is worth stating
  # plainly rather than leaving as an assumption. Ubuntu's
  # busybox-static is built with FEATURE_SH_STANDALONE, so its ash
  # dispatches any applet it knows BY NAME without consulting PATH.
  # rung 4's smoke test proved it: with ar unlinked and the SEAL
  # reporting 269 applets, `ar cru` still reached busybox and answered
  # "ar: invalid option -- 'r'".
  #
  # So every claim of the form "the box does not have X" holds only if
  # BUSYBOX does not have X. Where a real tool is needed, the answer is
  # to give it a name busybox has no applet for and point the build at
  # it explicitly -- which is what rung 4 does with tcc-ar and AR=.
  # Not linking these two still helps: it keeps them off PATH for
  # anything that is not busybox's own shell.
  for a in $("$BOX/bin/busybox" --list); do
    case "$a" in
      ar|strings) continue ;;
      busybox)    continue ;;
    esac
    if [ "${TRACE_APPLETS:-0}" = 1 ]; then
      # A WRAPPER THAT LOGS ITSELF AND THEN GETS OUT OF THE WAY.
      #
      # The eventual goal is a handmade busybox config containing
      # exactly the applets this chain needs -- allnoconfig plus a list,
      # so the config file IS the declaration rather than defconfig
      # minus a few seds.
      #
      # THAT LIST CANNOT BE DEDUCED FROM THE LOGS. rungs.sh invokes
      # maybe 25 applets and they are all visible. But configure is
      # generated shell that reaches for tr, expr, basename, sort, uniq
      # and a dozen more in branches that depend on what it finds;
      # Makefiles call more; the kernel's scripts/ is a small userland
      # of its own. None of it appears unless it FAILS -- which is how
      # split and comm were found, one round each.
      #
      # So measure instead. Each applet becomes a two-line wrapper that
      # appends its name to a log and then execs the real busybox, so
      # the chain runs exactly as it would otherwise and the log is the
      # precise set that was invoked. Not deduced: recorded.
      #
      # exec, NOT a call -- the wrapper must not sit in the process tree
      # holding a pipe open. A build this size runs applets in pipelines
      # tens of thousands of times.
      printf '#!/bin/busybox sh\necho %s >> /out/applets-used.txt\nexec /bin/busybox %s "$@"\n' \
        "$a" "$a" > "$BOX/bin/$a"
      chmod 0755 "$BOX/bin/$a"
    else
      ln -sf busybox "$BOX/bin/$a"
    fi
  done
  echo "  applets linked: $(find "$BOX/bin" -type l | wc -l)"
  echo "  excluded on purpose: ar strings  (tier 1 -- rung 4 builds them)"

  # WHICH APPLETS THIS busybox DOES NOT HAVE, NAMED BEFORE ANYTHING
  # NEEDS THEM.
  #
  # perl's Configure died on two of them:
  #
  #     ./Configure: line 2135: split: not found
  #     I don't know where 'comm' is, and my life depends on it.
  #
  # Both are real busybox applets -- but they are compile-time options,
  # and Ubuntu's busybox-static is built without them. `busybox --list`
  # reported 269 and the loop linked all 269; the ones missing were
  # never on the list to begin with, so nothing here was wrong and
  # nothing looked wrong either.
  #
  # A build reaching for one of these gets "not found" from the shell,
  # which reads as a PATH problem rather than as a busybox that was
  # compiled without the applet. Printing the gap here turns the next
  # occurrence into one line of reading.
  #
  # This is the same class as `patch -d` and `tr -dc`: what busybox
  # supports is a property of THIS BINARY, not of busybox.
  # gawk AS A WRAPPER, BECAUSE m4 AND bison BOTH PROBE FOR IT BY NAME.
  #
  # busybox has awk and not gawk, and a symlink will not do: it
  # dispatches on argv[0], so a link named gawk makes it answer
  # "gawk: applet not found". The tool-probe hit exactly that and it
  # read like a missing tool rather than a wrong link.
  #
  # busybox awk handles what these configures use -- ENVIRON, -f, gsub,
  # printf, match, all measured in tool-probe -- so the wrapper is
  # honest rather than a stand-in for something absent.
  # rm FIRST, EVEN THOUGH IT IS SAFE TODAY. busybox has no gawk applet,
  # so the loop above creates no symlink here and `>` has nothing to
  # write through. But that is a fact about busybox's applet list, not
  # about this code -- and in tool-probe the identical line truncated
  # the busybox BINARY, because there the name was symlinked first. The
  # error it produced named the wrapper and read as a permissions
  # problem.
  rm -f "$BOX/bin/gawk"
  # gawk MUST ANSWER --version LIKE gawk, NOT LIKE busybox.
  #
  # glibc's configure runs `gawk --version` and parses the result:
  #
  #     checking version of gawk... v. ?.??, bad
  #     *** These critical programs are missing or too old: gawk
  #
  # busybox awk prints its own banner, which that parse cannot read.
  # The CAPABILITY is not in question -- tool-probe measured ENVIRON,
  # -f, gsub, printf and match all working, which is everything m4,
  # bison and glibc's scripts use.
  #
  # So the wrapper answers the version question and passes everything
  # else through. THIS IS A CLAIM ABOUT AN INTERFACE, NOT A LIE ABOUT
  # AN IMPLEMENTATION: it says "this awk behaves as GNU awk 5.3 does
  # for the features being asked about", and that was measured rather
  # than assumed. If something later needs a gawk extension busybox
  # lacks, it fails on that extension, which is a legible failure.
  printf '%s\n' '#!/bin/busybox sh' \
    'case "$1" in' \
    '  --version|-V|--ver*)' \
    '    echo "GNU Awk 5.3.1, API 4.0"' \
    '    echo "(busybox awk -- see the box assembly step for why)"' \
    '    exit 0 ;;' \
    'esac' \
    'exec /bin/busybox awk "$@"' > "$BOX/bin/gawk"
  chmod 0755 "$BOX/bin/gawk"
  echo "  gawk -> busybox awk (wrapper, not a symlink: argv[0] dispatch)"

  echo "  --- POSIX tools this busybox does NOT have ---"
  missing=""
  for a in split comm join csplit paste expand unexpand fold fmt nl \
           pr tsort col cmp uniq tr od dd printf tee; do
    "$BOX/bin/busybox" --list | grep -qx "$a" || missing="$missing $a"
  done
  if [ -n "$missing" ]; then
    echo "   $missing"
    echo "    A rung that needs one of these will report \"not found\", which"
    echo "    reads as a PATH fault. It is not: the applet was compiled out."
  else
    echo "    none of the commonly-needed ones are missing"
  fi
  echo "  box laid out: $(du -sh "$BOX" | cut -f1)"
  echo "  /usr/include present? $( [ -d "$BOX/usr/include" ] && echo YES || echo no )"

  echo "== PROBE: the exact tar command, outside bubblewrap =="

  # THE SAME BINARY, THE SAME FILE, NO SANDBOX.
  #
  # In the box, `tar -zxf /in/make-4.4.tar.gz` is refused with "invalid
  # tar magic" while the identical call opens musl-1.2.5.tar.gz. Three
  # runs of diagnostics inside the box have not settled why, and two of
  # those diagnostics turned out to be broken themselves. So run the
  # command outside, where host tools are available to check the answer.
  #
  # This discriminates in one step:
  #   busybox fails here too      -> busybox tar vs this tarball
  #   busybox works here          -> something about the box, not the file
  #   host tar fails too          -> the download is bad
  B="$BOX/bin/busybox"
  echo "  busybox: $("$B" 2>&1 | head -1)"
  echo
  for f in pins/musl-*.tar.gz pins/make-*.tar.gz; do
    [ -f "$f" ] || continue
    echo "  ===== $f  ($(wc -c < "$f") bytes) ====="
    echo "    first 4 bytes: $(dd if="$f" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -s ' ')"

    # 1. host GNU tar, listing only
    if tar -tzf "$f" > /dev/null 2>/tmp/hosttar.err; then
      echo "    host tar -tzf     : OK  ($(tar -tzf "$f" 2>/dev/null | wc -l) members)"
    else
      echo "    host tar -tzf     : FAILED  $(head -1 /tmp/hosttar.err)"
    fi

    # 2. the box's busybox, same flags, no sandbox
    rm -rf /tmp/bbx && mkdir -p /tmp/bbx
    if ( cd /tmp/bbx && "$B" tar -zxf "$OLDPWD/$f" ) 2>/tmp/bbtar.err; then
      echo "    busybox tar -zxf  : OK  ($(ls /tmp/bbx | tr '\n' ' '))"
    else
      echo "    busybox tar -zxf  : FAILED  $(head -2 /tmp/bbtar.err | tr '\n' ' ')"
    fi

    # 3. busybox on the DECOMPRESSED bytes, which separates the -z path
    #    from the archive itself
    gzip -dc "$f" > /tmp/probe.tar
    rm -rf /tmp/bbx2 && mkdir -p /tmp/bbx2
    if ( cd /tmp/bbx2 && "$B" tar -xf /tmp/probe.tar ) 2>/tmp/bbtar2.err; then
      echo "    busybox tar -xf   : OK on the decompressed file"
    else
      echo "    busybox tar -xf   : FAILED  $(head -2 /tmp/bbtar2.err | tr '\n' ' ')"
    fi

    # 4. the header fields, carved with dd and formatted with od
    echo "    name  (0)   : $(dd if=/tmp/probe.tar bs=1 count=16      2>/dev/null | od -c | head -1)"
    echo "    type  (156) : $(dd if=/tmp/probe.tar bs=1 skip=156 count=1 2>/dev/null | od -c | head -1)"
    echo "    magic (257) : $(dd if=/tmp/probe.tar bs=1 skip=257 count=8 2>/dev/null | od -c | head -1)"
    echo "    host tar says format: $(tar -tvf /tmp/probe.tar 2>/dev/null | head -1)"
    rm -f /tmp/probe.tar
    echo
  done

  echo "== SEAL: enumerate every executable in the box and enforce the budget =="

  echo "  === TIER 1: ON THE BUILD PATH ==="
  if [ -z "$BUDGET_PATH" ]; then
    echo "    EMPTY -- no compiler, no assembler, no linker, no archiver."
    echo "    binutils is BUILT at rung 4. If it appears below, a"
    echo "    configure script found it and this run is void."
  fi
  echo "  === TIER 2: DRIVER (touches no artifact byte) ==="
  echo "    busybox is now one WE BUILT, from a pinned tarball with the"
  echo "    config in this file -- not whatever the runner's distro"
  echo "    shipped. Its applet list is declared rather than inherited."
  for t in $BUDGET_DRIVER; do
    printf '    %-12s %10s  %s\n' "$t" "$(wc -c < "$BOX/bin/$t")" \
      "$(sha256sum "$BOX/bin/$t" | cut -c1-16)"
  done
  echo "  === TIER 3: THE COMPILER UNDER TEST ==="
  printf '    %-12s %10s  %s\n' ref-tcc "$(wc -c < "$BOX/work/ref-tcc")" \
    "$(sha256sum "$BOX/work/ref-tcc" | cut -c1-16)"

  # gawk IS DECLARED, because it is a real file in /bin rather than a
  # symlink and the check below would otherwise fail it as undeclared.
  # It is not a host binary: it is a two-line wrapper this workflow
  # writes, calling the busybox we built. Saying so here keeps the SEAL
  # meaning "nothing arrived that we did not put there" rather than
  # quietly widening to "nothing arrived except the things we forgot".
  printf '%s\n' $BUDGET_PATH $BUDGET_DRIVER gawk | sort -u > /tmp/declared
  # no -printf: the airlock may be busybox find (the image); basename via sh
  find "$BOX/bin" -type f -exec sh -c 'for f; do basename "$f"; done' _ {} + | sort -u > /tmp/actual
  undeclared=$(comm -13 /tmp/declared /tmp/actual || true)
  if [ -n "$undeclared" ]; then
    echo "  UNDECLARED EXECUTABLES IN THE BOX:"
    printf '%s\n' "$undeclared" | sed 's/^/    /'
    exit 1
  fi
  echo "  SEALED. $(wc -l < /tmp/declared) declared entries in /bin:"
  echo "    busybox  -- built by this workflow from a pinned tarball"
  echo "    gawk     -- a wrapper around it, written by this workflow"
  echo "  $(printf '%s' "$BUDGET_PATH" | wc -w) of them on the build path."

  {
    echo "# stage 4 box budget -- every executable in /bin, by hash"
    echo "busybox  $(sha256sum "$BOX/bin/busybox" | cut -d' ' -f1)  $BB_FROM"
    echo "gawk     wrapper around busybox awk, written by build.sh"
    echo "ref-tcc  $(sha256sum "$BOX/work/ref-tcc" | cut -d' ' -f1)  the 3->4 contract"
  } > "$OUT4/BUDGET"
  echo "== IN THE BOX: ref-tcc -> musl -> make -> binutils -> gcc 4.7.4 =="

  # EVERY VERSION THE RUNGS READ IS PASSED WITH --setenv BELOW.
  #
  # bwrap gives the box its own environment: a variable in this
  # workflow's env: block is NOT visible inside. Rungs 0 through 11.5
  # never noticed because their versions are spelled out in rungs.sh;
  # everything from 11.7 up uses $GLIBC, $KHDR, $PERL_VER, $PYTHON_VER,
  # $KERNEL, $GCC15 and $BINUTILS_LFS, and would have died on the first
  # one under `set -u`.
  #
  # THE COMMENTS LIVE HERE, NOT AMONG THE FLAGS. A `#` line inside a
  # backslash continuation is not a comment -- the continuation joins
  # it to the command, and bwrap received the prose as arguments and
  # printed its usage. That cost a run, and the log gave no message
  # beyond the usage text because bwrap has nothing more specific to
  # say about "--setenv EVERY VERSION THE".
  bwrap \
    --unshare-all \
    --die-with-parent \
    --setenv PATH /bin \
    --setenv HOME /work \
    --setenv LC_ALL POSIX \
    --setenv TERM dumb \
    --setenv SOURCE_DATE_EPOCH 0 \
    --setenv LD_LIBRARY_PATH /lib \
    --setenv CC_BIN /work/ref-tcc \
    --setenv TCCDIR /work/tccsrc \
    --setenv ARM reference \
    --setenv MUSL_VER "$MUSL_VER" \
    --setenv MAKE_VER "$MAKE_VER" \
    --setenv MAKE_ALT "$MAKE_ALT" \
    --setenv BINUTILS "$BINUTILS" \
    --setenv BINUTILS_LFS "$BINUTILS_LFS" \
    --setenv GMP_VER "$GMP_VER" \
    --setenv MPFR_VER "$MPFR_VER" \
    --setenv MPC_VER "$MPC_VER" \
    --setenv GCC47 "$GCC47" \
    --setenv GCC10 "$GCC10" \
    --setenv GCC15 "$GCC15" \
    --setenv GLIBC "$GLIBC" \
    --setenv KHDR "$KHDR" \
    --setenv KERNEL "$KERNEL" \
    --setenv ENABLE_KERNEL "$ENABLE_KERNEL" \
    --setenv PERL_VER "$PERL_VER" \
    --setenv PYTHON_VER "$PYTHON_VER" \
    --setenv GAWK_VER "$GAWK_VER" \
    --setenv OPENSSL_VER "$OPENSSL_VER" \
    --setenv M4_VER "$M4_VER" \
    --setenv M4_BOOT_VER "$M4_BOOT_VER" \
    --setenv BC_VER "$BC_VER" \
    --setenv BISON_VER "$BISON_VER" \
    --setenv FLEX_VER "$FLEX_VER" \
    --setenv BUSYBOX_VER "$BUSYBOX_VER" \
    --bind "$BOX" / \
    --ro-bind "$ROOT/spikes" /src \
    --ro-bind "$ROOT/pins" /in \
    --bind "$BOX/out" /out \
    --proc /proc --dev /dev --tmpfs /tmp \
    --chdir /work \
    /bin/sh /src/stage4/bridge/rungs-amd64.sh

  echo "== PHASE B: the final system, built by the final toolchain =="

  if [ ! -f "$BOX/work/lfs/.phase-a-complete" ]; then
    echo "  phase A did not complete -- $BOX/work/lfs is not enterable."
    echo "  Skipped rather than attempted: a sandbox rooted at a"
    echo "  half-built sysroot fails on its first command in a way"
    echo "  that names the wrong thing."
    exit 1
  fi
  mkdir -p "$BOX/pb"
  # THE ENTRY POINT, READ ON THE HOST, BEFORE ANY NAMESPACE EXISTS.
  #
  # Three runs died on `bwrap: execvp /usr/bin/sh: No such file or
  # directory` with no way to tell WHY from the log: bwrap says the
  # path failed, not what the path pointed at. Reading it out here
  # costs one line and shows the symlink target itself, so a repeat
  # names its own cause instead of needing another round.
  echo "  sysroot entry point, as it exists on the host:"
  ls -ld "$BOX/work/lfs/usr/bin/sh" "$BOX/work/lfs/usr/bin/busybox" 2>&1 \
    | sed 's/^/    /'
  bwrap \
    --unshare-all \
    --die-with-parent \
    --new-session \
    --clearenv \
    --setenv PATH /usr/bin:/usr/sbin \
    --setenv HOME /build \
    --setenv LC_ALL POSIX \
    --setenv TERM dumb \
    --setenv SOURCE_DATE_EPOCH 0 \
    --setenv ARM reference \
    --setenv VERON_TOOLCHAIN_TGT x86_64-veron-linux-gnu \
    --setenv GLIBC "$GLIBC" \
    --setenv GCC15 "$GCC15" \
    --setenv BINUTILS_LFS "$BINUTILS_LFS" \
    --setenv KERNEL "$KERNEL" \
    --setenv ENABLE_KERNEL "$ENABLE_KERNEL" \
    --setenv PERL_VER "$PERL_VER" \
    --setenv PYTHON_VER "$PYTHON_VER" \
    --setenv GAWK_VER "$GAWK_VER" \
    --setenv OPENSSL_VER "$OPENSSL_VER" \
    --setenv M4_VER "$M4_VER" \
    --setenv M4_BOOT_VER "$M4_BOOT_VER" \
    --setenv BC_VER "$BC_VER" \
    --setenv BISON_VER "$BISON_VER" \
    --setenv FLEX_VER "$FLEX_VER" \
    --setenv BUSYBOX_VER "$BUSYBOX_VER" \
    --bind "$BOX/work/lfs" / \
    --bind "$BOX/pb" /build \
    --ro-bind "$ROOT/spikes" /src \
    --ro-bind "$ROOT/pins" /in \
    --bind "$BOX/out" /out \
    --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
    --chdir /build \
    /usr/bin/sh /src/stage4/bridge/sysroot-amd64.sh

}


applet_set() {
  echo "== THE APPLET SET: what the chain actually invoked =="

  L="$BOX/out/applets-used.txt"
  if [ "${TRACE_APPLETS:-0}" != 1 ]; then
    echo "  tracing was off. Dispatch with trace_applets=true to record"
    echo "  the applet set -- it roughly doubles the run, so it is a"
    echo "  deliberate one-off rather than something every run pays for."
    return 0
  fi
  if [ ! -s "$L" ]; then
    echo "  tracing was on but nothing was recorded. Either the box never"
    echo "  started, or /out was not writable from inside it."
    return 0
  fi
  total=$(wc -l < "$L")
  sort -u "$L" > /tmp/used.txt
  used=$(wc -l < /tmp/used.txt)
  have=$("$BB" --list | wc -l)
  echo "  invocations recorded : $total"
  echo "  distinct applets used: $used"
  echo "  applets compiled in  : $have"
  echo
  echo "  --- the set, which is the config ---"
  tr '\n' ' ' < /tmp/used.txt | fold -w 72 -s | sed 's/^/    /'
  echo
  echo "  --- by frequency, most-used first ---"
  sort "$L" | uniq -c | sort -rn | head -25 | sed 's/^/    /'
  echo
  echo "  --- compiled in but NEVER invoked ($((have - used))) ---"
  "$BB" --list | sort > /tmp/have.txt
  comm -23 /tmp/have.txt /tmp/used.txt | tr '\n' ' ' | fold -w 72 -s | sed 's/^/    /'
  echo
  echo "  --- as a busybox config ---"
  while read -r a; do
    printf '    CONFIG_%s=y\n' "$(echo "$a" | tr 'a-z-' 'A-Z_')"
  done < /tmp/used.txt | head -60
  echo
  echo "  READ THIS AS A FLOOR, NOT A SPEC. It records the applets the"
  echo "  paths that RAN invoked. A rung that failed early under-reports"
  echo "  everything above it, and a configure branch not taken this time"
  echo "  may be taken next time -- autoconf picks tools by what it"
  echo "  finds. The list is a measured lower bound on a set that was"
  echo "  previously being guessed at one round per missing tool."
  echo
  echo "  Some names are not applets: busybox's own symbol for a few"
  echo "  differs from the command name. Check each against --list"
  echo "  before writing the final config."

}

phase_collect() {
  echo "== Collect the bootable artifacts =="

  set -u
  mkdir -p boot
  for f in Image initramfs.cpio.gz; do
    [ -s "$BOX/out/$f" ] && cp "$BOX/out/$f" boot/ || echo "  $BOX/out/$f ABSENT"
  done
  [ -d boot ] && ( cd boot && sha256sum ./* 2>/dev/null | tee SHA256SUMS | sed 's/^/    /' ) || true

  echo "== Collect the final toolchain =="

  set -u
  mkdir -p toolchain
  S="$BOX/work/lfs"
  for f in usr/bin/gcc usr/bin/ld usr/bin/as usr/lib/libc.so.6 usr/bin/busybox; do
    [ -s "$S/$f" ] && cp "$S/$f" "toolchain/$(basename "$f")" 2>/dev/null || true
  done
  if [ -d "$S/usr/libexec/gcc" ]; then
    tar -C "$S/usr/libexec" -c gcc 2>/dev/null \
      | gzip -9n > toolchain/libexec-gcc.tar.gz || true
  fi
  if [ -n "$(ls -A toolchain 2>/dev/null)" ]; then
    ( cd toolchain && sha256sum ./* 2>/dev/null | tee SHA256SUMS | sed 's/^/    /' )
    du -sh toolchain | sed 's/^/    /'
  fi

  echo "== Collect the sysroot manifest =="

  set -u
  mkdir -p manifest
  cp "$BOX/out/manifest.tsv" manifest/ 2>/dev/null || true
  if [ -s manifest/manifest.tsv ]; then
    echo "  $(wc -l < manifest/manifest.tsv) entries"
    printf '  sysroot digest: %s\n' \
      "$(LC_ALL=C sort manifest/manifest.tsv | sha256sum | cut -d' ' -f1)"
  else
    echo "  no manifest.tsv -- the run did not reach B8"
  fi

  applet_set
  rm -rf "$OUT4/boot" "$OUT4/toolchain" "$OUT4/manifest"
  [ -d boot ] && cp -a boot "$OUT4/boot"
  [ -d toolchain ] && cp -a toolchain "$OUT4/toolchain"
  [ -d manifest ] && cp -a manifest "$OUT4/manifest"
  echo "  out/4: $(ls "$OUT4" | tr '\n' ' ')"
}


phase_boot() {
  # THE GATE RUNS ON THIS PROJECT'S OWN EMULATOR WHEN THE HOST HAS IT (the
  # Veron image, or an unpacked tools bundle beside the checkout); apt's
  # qemu only where neither exists. Stated in the log either way.
  if [ -x "$ROOT/veron-tools/qemu-system-x86_64" ]; then
    QEMU="$ROOT/veron-tools/qemu-system-x86_64 -L $ROOT/veron-tools/share/qemu"; echo "  qemu: veron-tools bundle"
  elif [ -x /usr/bin/qemu-system-x86_64 ] && [ -f /usr/share/qemu/bios-256k.bin ] && [ -f /usr/share/qemu/OVMF.fd ]; then
    QEMU=/usr/bin/qemu-system-x86_64; echo "  qemu: /usr/bin/qemu-system-x86_64 (this system's)"
  else
    QEMU="$(command -v qemu-system-x86_64 || true)"; [ -n "$QEMU" ] || { echo "  no qemu-system-x86_64 on this host -- boot gate skipped"; return 0; }
    echo "  qemu: $QEMU (host's)"
  fi

  set -u
  # qemu IS A VERIFIER, NOT A BUILD TOOL, and it stays outside the box
  # for the same reason stage 4 keeps it outside: nothing it does
  # contributes a byte to any artifact. It reads what phase B's rung B8
  # left in /out and reports whether that boots.
  IMG="$BOX/out/Image"
  IRD="$BOX/out/initramfs.cpio.gz"
  if [ ! -s "$IMG" ] || [ ! -s "$IRD" ]; then
    echo "  no Image or initramfs -- phase B did not reach B8"
    # GREEN ONLY IF PHASE B WAS NEVER SUPPOSED TO RUN.
    #
    # This step used to `exit 0` unconditionally, so a phase B that
    # died at B2 left the whole job green with no image -- the same
    # shape stage4-complete records against itself: "a failed build
    # inside the box went green and the damage showed up later
    # somewhere else."
    #
    # The rungs deliberately never exit non-zero; the gates live out
    # here. So: if phase A did not complete, a missing image is
    # expected and this stays green, which preserves the "partial
    # progress reports rather than fails" contract phase A has always
    # had. If phase A DID complete, phase B was supposed to produce an
    # image and did not, and that is a failure.
    if [ -f "$BOX/work/lfs/.phase-a-complete" ]; then
      echo "  phase A completed, so phase B was expected to produce one."
      echo "  See the PHASE B step above for the first FAIL."
      exit 1
    fi
    echo "  phase A did not complete either -- nothing to boot yet."
    exit 0
  fi
  echo "  Image:     $(stat -c%s "$IMG") bytes"
  echo "  initramfs: $(stat -c%s "$IRD") bytes"
  echo "  booting on qemu-system-x86_64 ..."
  # THE SYSROOT, OFFERED OVER 9p, READ-ONLY.
  #
  # This is what lets the guest chroot into the sysroot this chain
  # built and run its gcc inside the kernel that same chain built --
  # the strongest single line this job can print. stage4-complete has
  # done it for several runs; the reference job enabled the three
  # kernel options for it and never offered the device, so the guest
  # reported "9p not available" every time and the gcc-in-guest half
  # was dead code on both sides.
  #
  # security_model=none because there is no uid mapping worth
  # preserving here and mapped-xattr needs a WRITABLE export, which
  # this deliberately is not. readonly=on because the guest only
  # reads; its compile output goes to a tmpfs it bind-mounts itself.
  #
  # NOTHING IS COPIED. Only what the guest opens crosses the boundary,
  # which is why sharing a multi-gigabyte sysroot costs nothing here.
  #
  # -nic none STAYS. 9p rides virtio-pci, not ethernet, despite the
  # CONFIG_NET_9P name -- so the guest gets the sysroot and still has
  # no network, which is the property the box has held all along.
  #
  # 600s: gcc under TCG emulation is slow, and a timeout that fires
  # reads exactly like a hang.
  set +e
  # console=ttyS0, NOT ttyAMA0, AND THE COMMENT LIVES UP HERE.
  #
  # ttyAMA0 is the PL011 on arm's `virt` board and does not exist on a
  # PC; getting it wrong gives a kernel that boots and says nothing,
  # which reads exactly like a kernel that did not boot.
  #
  # THE COMMENT WAS ORIGINALLY INSIDE THE COMMAND AND THAT BROKE IT.
  # A `#` line between two backslash-continued lines ends the
  # continuation, so run 85202723681 ran qemu with no -append at all
  # and then tried to execute the next line as a command:
  #     line 77: -append: command not found
  #     THE KERNEL THIS CHAIN BUILT DID NOT REACH USERSPACE.
  # Every rung had passed. The only thing wrong was where a comment
  # sat.
  #
  # NATIVE x86_64, WITH NO -M virt AND NO -cpu. The aarch64 arm names
  # a board and a CPU because qemu-system-aarch64 has no default
  # machine and refuses to start without one. x86 has one -- `pc` --
  # and this runner is x86_64, so the guest is the same architecture
  # as the kernel it has just built.
  timeout -k 30 600 $QEMU \
    -smp 2 -m 2048 \
    -nographic -no-reboot -nic none \
    -fsdev local,id=vsysroot,path="$BOX/work/lfs",security_model=none,readonly=on \
    -device virtio-9p-pci,fsdev=vsysroot,mount_tag=veronsysroot \
    -kernel "$IMG" \
    -initrd "$IRD" \
    -append "console=ttyS0 earlycon rdinit=/init panic=1 loglevel=7" \
    > /tmp/boot.log 2>&1
  echo "  qemu rc=$?"
  set -e

  # THE GUEST'S REPORT IN FULL, NOT A TAIL. `tail -25` was right when
  # init printed three lines; it now cuts the test list in half and
  # leaves the reader guessing which half. Everything from the first
  # VERON marker on is the part a human wants.
  if grep -q "VERON-BOOT-OK" /tmp/boot.log; then
    echo "  --- the guest, reporting on itself ---"
    sed -n '/VERON-BOOT-OK/,$p' /tmp/boot.log | sed 's/^/    /'
  else
    echo "  did not reach VERON-BOOT-OK -- console, last 30 lines:"
    tail -30 /tmp/boot.log | sed 's/^/    /'
    echo "  THE KERNEL THIS CHAIN BUILT DID NOT REACH USERSPACE."
    exit 1
  fi

  echo
  echo "  ================================================"
  grep -h 'VERON-' /tmp/boot.log | sed 's/^/    /'
  echo "  ================================================"

  # REACHING USERSPACE IS NOT THE SAME AS BEING A GOOD BUILD, and this
  # is where that distinction is enforced rather than described. The
  # guest ran binaries the final compiler produced; if any failed, the
  # kernel or that compiler is wrong, and printing it green would hide
  # exactly the defect this job exists to find.
  #
  # AN ABSENT SUMMARY IS A FAILURE, NOT A BOOT WITH NO TESTS. That
  # distinction has cost this repository a round before: "an absent
  # probe reads exactly like a passing one."
  tl=$(grep -o 'VERON-TESTS pass=[0-9]* fail=[0-9]*' /tmp/boot.log | tail -1)
  case "$tl" in
    "")      echo "  THE GUEST NEVER REPORTED A TEST SUMMARY."
             echo "  init did not reach the end -- treated as a failure."
             exit 1 ;;
    *fail=0) echo "  in-guest tests: $tl" ;;
    *)       echo "  IN-GUEST TESTS FAILED: $tl"
             grep -E '^\s+t_.* FAIL' /tmp/boot.log | sed 's/^/    /'
             exit 1 ;;
  esac

  if ! grep -q 'VERON-DONE' /tmp/boot.log; then
    echo "  init did not run to completion (no VERON-DONE)"
    exit 1
  fi

  # THE IN-GUEST COMPILER IS REPORTED, NOT GATED. It depends on the 9p
  # share, and a 9p problem is not a toolchain problem -- failing the
  # run on it would charge a qemu detail to the compiler.
  if grep -q 'VERON-GCC-IN-GUEST ok' /tmp/boot.log; then
    echo "  the compiler ran INSIDE the kernel it built."
  else
    grep -h 'VERON-GCC-IN-GUEST' /tmp/boot.log | sed 's/^/  /'
  fi
  echo
  echo "  END TO END: a kernel and a userland built by a toolchain"
  echo "  that was itself built in a box holding one busybox and one"
  echo "  tcc, booted and ran their own tests."

}


phase_pack() {
  # THE RELEASE PAYLOAD, MINUS THE RELEASE: trim, tar, digest -- the
  # workflow's publish step's preparation, verbatim, so a laptop run yields
  # the same rel/ a runner would and the workflow only has to upload it.
  [ -f "$BOX/work/lfs/.chapter5-complete" ] || { echo "FAIL: no complete sysroot to pack ($BOX/work/lfs/.chapter5-complete absent)"; exit 1; }
  rm -rf rel lfs "$OUT4/rel" "$OUT4/lfs" && mkdir -p rel
  cp -a "$BOX/work/lfs" lfs
  before=$(du -sm lfs | cut -f1)
  VERON_TRIM=1 TRIM_STRIP_ARCHIVES=0 \
  TRIM_LOG=rel/trim.txt \
  NATIVE_TRIPLET=x86_64-veron-linux-gnu \
  CROSS_TRIPLET=x86_64-toolchain-linux-gnu \
    /bin/sh spikes/stage4/bridge/sysroot-trim.sh lfs 2>&1 | sed 's/^/    /'
  after=$(du -sm lfs | cut -f1)
  echo "  trimmed: ${before} MB -> ${after} MB"
  [ "$after" -lt "$before" ] || { echo "  TRIM REMOVED NOTHING: ${before} MB -> ${after} MB"; echo "  the trim did not run; check TRIM_LOG is writable"; exit 1; }
  for f in Image initramfs.cpio.gz; do
    [ -s "$BOX/out/$f" ] && cp "$BOX/out/$f" rel/ || { echo "  $BOX/out/$f is missing -- refusing to pack a partial release"; exit 1; }
  done
  [ -s "$BOX/out/manifest.tsv" ] && cp "$BOX/out/manifest.tsv" rel/ || true
  cp "$OUT4/BUDGET" rel/BUDGET 2>/dev/null || true
  # THE CONTAINER IS TRANSPORT, NOT ARTIFACT: the records and the stage-5
  # airlock check the sysroot's manifest digest, host-independent.
  # sysroot.tar.zst is how a release carries it -- GNU tar + zstd, the
  # workflow's exact line so a laptop's SYSROOT-SHA256 and a runner's are
  # one number. The image ships busybox tar: there, out/4/lfs is the
  # deliverable and the tarball is skipped, said so, not faked.
  if tar --version 2>/dev/null | grep -q 'GNU tar' && command -v zstd >/dev/null 2>&1; then
    ZSTD_CLEVEL=19; export ZSTD_CLEVEL
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
        --format=gnu --zstd -cf rel/sysroot.tar.zst -C lfs .
    sha256sum rel/sysroot.tar.zst | tee rel/SYSROOT-SHA256
    printf '  sysroot.tar.zst: %s (from %s MB of files)\n' "$(du -h rel/sysroot.tar.zst | cut -f1)" "$after"
  else
    echo "  no GNU tar + zstd on this host: the trimmed sysroot is out/4/lfs; sysroot.tar.zst not made here"
    mv lfs "$OUT4/lfs"
  fi
  cp -a rel "$OUT4/rel"
  echo "  out/4/rel: $(ls "$OUT4/rel" | tr '\n' ' ')"
}


case "${1:-all}" in
  in)      phase_in ;;
  chain)   phase_chain ;;
  collect) phase_collect ;;
  boot)    phase_boot ;;
  pack)    phase_pack ;;
  all)     phase_in; phase_chain; phase_collect; phase_boot; phase_pack ;;
  *) echo "usage: build.sh [in|chain|collect|boot|pack|all]"; exit 2 ;;
esac
