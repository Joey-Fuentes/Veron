#!/bin/sh
# rung2.sh -- gcc 10 -> a sysroot -> gcc 15.2.0, inside the box.
#
# PORTED FROM .github/workflows/hermetic-gcc15.yml, which is authoritative and
# carries the scar tissue (the -Werror=attributes fix, the _GNU_SOURCE flag that
# has to arrive as a CONFIG STRING, the header/libc pairing rationale). If a
# step here fails, read that job before re-deriving anything.
#
# THE ORDER IS THE POINT. The previous revision ran
#     binutils -> linux headers -> glibc -> gcc 15
# and configured glibc --host=$LFS_TGT before anything had built an
# $LFS_TGT-gcc for it to use. LFS builds the CROSS COMPILER FIRST -- binutils
# pass 1, gcc pass 1, headers, glibc, libstdc++, then pass 2 -- because glibc
# cannot be cross-compiled by a compiler that does not exist.
set -u
cd /work
NP=$(nproc)
S=/work/sysroot
say() { printf '%s\n' "$*"; }
die() { say "  $*"; exit 1; }
run() { "$@" > /work/last.log 2>&1 || { say "    FAILED: $*"; tail -25 /work/last.log | sed 's/^/      /'; exit 1; }; }

export PATH=/work/out10/bin:$PATH
export LD_LIBRARY_PATH=/work/out10/lib64:/work/out10/lib
[ -x /work/out10/bin/gcc ] || die "no gcc 10 -- rung 1's tree did not arrive"
say "  builder: $(gcc --version | head -1)"

mkdir -p "$S/tools" "$S/work"
export LFS_TGT=${LFS_TGT:-aarch64-veron-linux-gnu}

for t in binutils-$BINUTILS gcc-$GCC15 glibc-$GLIBC linux-$LINUX_HEADERS; do
  case "$t" in *) tar xf "/work/src/$t.tar.xz" ;; esac
done
cd gcc-$GCC15
tar xf /work/src/gmp-$GMP_VER.tar.xz  && mv gmp-$GMP_VER  gmp
tar xf /work/src/mpfr-$MPFR_VER.tar.xz && mv mpfr-$MPFR_VER mpfr
tar xf /work/src/mpc-$MPC_VER.tar.gz  && mv mpc-$MPC_VER  mpc
cd /work

# ------------------------------------------------------------ 5.2 binutils p1
say ""
say "  === 5.2 binutils pass 1 ==="
rm -rf b-bi1 && mkdir b-bi1 && cd b-bi1
run ../binutils-$BINUTILS/configure --prefix="$S/tools" --with-sysroot="$S" \
      --target=$LFS_TGT --disable-nls --enable-gprofng=no --disable-werror
run make -j"$NP"
run make install
say "  ok"
cd /work

# ------------------------------------------------------------ 5.3 gcc pass 1
# THE STEP THE PREVIOUS REVISION SKIPPED ENTIRELY. Without it there is no
# $LFS_TGT-gcc, and glibc's configure --host=$LFS_TGT has nothing to run.
say ""
say "  === 5.3 gcc pass 1 (the cross compiler) ==="
rm -rf b-gc1 && mkdir b-gc1 && cd b-gc1
run ../gcc-$GCC15/configure --target=$LFS_TGT --prefix="$S/tools" \
      --with-glibc-version=$GLIBC --with-sysroot="$S" --with-newlib \
      --without-headers --enable-default-pie --enable-default-ssp \
      --disable-nls --disable-shared --disable-multilib --disable-threads \
      --disable-libatomic --disable-libgomp --disable-libquadmath \
      --disable-libssp --disable-libvtv --disable-libstdcxx \
      --enable-languages=c,c++
run make -j"$NP"
run make install
# gcc pass 1 needs its internal header assembled from limits.h fragments.
cd ../gcc-$GCC15
cat gcc/limitx.h gcc/glimits.h gcc/limity.h \
  > "$("$S/tools/bin/$LFS_TGT-gcc" -print-libgcc-file-name | sed 's/libgcc.a/include\/limits.h/')"
say "  ok: $($S/tools/bin/$LFS_TGT-gcc --version | head -1)"
cd /work

# ------------------------------------------------------------ 5.4 linux headers
say ""
say "  === 5.4 linux API headers ==="
cd linux-$LINUX_HEADERS
run make mrproper
run make ARCH=arm64 headers
mkdir -p "$S/usr/include"
cp -r usr/include/* "$S/usr/include/"
find "$S/usr/include" -type f ! -name '*.h' -delete
say "  ok"
cd /work

# ------------------------------------------------------------ 5.5 glibc
say ""
say "  === 5.5 glibc (cross-compiled INTO the sysroot) ==="
# --prefix=/usr WITH DESTDIR, not both pointing at the sysroot. The previous
# revision passed --prefix=/work/sysroot AND DESTDIR=/work/sysroot, which
# installs into /work/sysroot/work/sysroot.
rm -rf b-gl && mkdir b-gl && cd b-gl
echo "rootsbindir=/usr/sbin" > configparms
run ../glibc-$GLIBC/configure --prefix=/usr --host=$LFS_TGT \
      --build="$(../glibc-$GLIBC/scripts/config.guess)" \
      --enable-kernel=5.4 --with-headers="$S/usr/include" \
      --disable-nscd libc_cv_slibdir=/usr/lib
run make -j"$NP"
run make DESTDIR="$S" install
# LFS's own sanity check. A cross compiler that installs a glibc it cannot then
# link against is the failure worth catching here, not three steps later.
say "  --- can the cross compiler link against it? ---"
printf 'int main(void){return 0;}\n' > /tmp/gl.c
"$S/tools/bin/$LFS_TGT-gcc" /tmp/gl.c -o /tmp/gl 2> /tmp/gl.err \
  || { say "  CANNOT LINK"; head -15 /tmp/gl.err | sed 's/^/    /'
       "$S/tools/bin/$LFS_TGT-gcc" -v 2>&1 | tail -5 | sed 's/^/    /'; exit 1; }
readelf -l /tmp/gl | grep -q 'ld-linux-aarch64' \
  && say "  ok: interpreter is the sysroot's" \
  || say "  note: unexpected interpreter -- $(readelf -l /tmp/gl | grep interpreter)"
cd /work

# ------------------------------------------------------------ 5.6 libstdc++
say ""
say "  === 5.6 libstdc++ pass 1 ==="
rm -rf b-cxx && mkdir b-cxx && cd b-cxx
run ../gcc-$GCC15/libstdc++-v3/configure --host=$LFS_TGT --build="$(../gcc-$GCC15/config.guess)" \
      --prefix=/usr --disable-multilib --disable-nls --disable-libstdcxx-pch \
      --with-gxx-include-dir="/tools/$LFS_TGT/include/c++/$GCC15"
run make -j"$NP"
run make DESTDIR="$S" install
say "  ok"
cd /work

# ------------------------------------------------------------ 6.x gcc pass 2
say ""
say "  === 6.x gcc pass 2 (a compiler that RUNS in the sysroot) ==="
rm -rf b-gc2 && mkdir b-gc2 && cd b-gc2
run ../gcc-$GCC15/configure --build="$(../gcc-$GCC15/config.guess)" --host=$LFS_TGT \
      --target=$LFS_TGT LDFLAGS_FOR_TARGET="-L$PWD/$LFS_TGT/libgcc" \
      --prefix=/usr --with-build-sysroot="$S" --enable-default-pie \
      --enable-default-ssp --disable-nls --disable-multilib \
      --disable-libatomic --disable-libgomp --disable-libquadmath \
      --disable-libsanitizer --disable-libssp --disable-libvtv \
      --enable-languages=c,c++
run make -j"$NP"
run make DESTDIR="$S" install
ln -sf gcc "$S/usr/bin/cc" 2>/dev/null || true
say "  ok"

say ""
say "  rung 2 complete: gcc 10 -> sysroot -> gcc 15.2.0"
exit 0
