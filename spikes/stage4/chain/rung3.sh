#!/bin/sh
# rung3.sh -- gcc 15 -> linux 7.1.5 + userland -> an initramfs that COMPILES.
#
# PORTED FROM .github/workflows/hermetic-gcc15.yml's kernel and boot chapters.
#
# WHAT THIS PRODUCES AND WHY. A boot marker proves the kernel reached userspace.
# It proves nothing about the toolchain that built it, and "every compiler
# descends from tcc" is a claim about the toolchain. So the initramfs carries
# the compiler and the init script uses it: VERON-GCC-IN-GUEST is the gate,
# VERON-BOOT-OK is only the precondition.
set -u
# THE VERSION SET CROSSES THE BOUNDARY AS A FILE, NOT AS INHERITED ENV.
# box.sh uses --clearenv on purpose: the box's environment is part of what this
# job DECLARES, not whatever the runner happened to export. Run 81907665505
# died here -- "GMP_VER: parameter not set" -- because this script was written
# as though the workflow's env: block reached inside. It does not, and it should
# not. /work/versions.env is written by the job before entry, so the set is
# explicit, is one definition for all rungs, and lands in the log as an answer
# to "which versions was this".
. /work/versions.env
cd /work
NP=$(nproc)
S=/work/sysroot
say() { printf '%s\n' "$*"; }
die() { say "  $*"; exit 1; }

export LFS_TGT=${LFS_TGT:-aarch64-veron-linux-gnu}
export PATH="$S/tools/bin:$PATH"
CROSS="$LFS_TGT-"
[ -x "$S/tools/bin/${CROSS}gcc" ] || die "no ${CROSS}gcc -- rung 2's sysroot did not arrive"
say "  builder: $(${CROSS}gcc --version | head -1)"

mkdir -p /work/img

# ------------------------------------------------------------ the kernel
say ""
say "  === linux $KERNEL ==="
tar xf /work/src/linux-$KERNEL.tar.xz
cd linux-$KERNEL
make ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig > /dev/null 2>&1 || die "defconfig failed"

# CONFIG EDITS GO THROUGH olddefconfig. Hand-editing .config and building
# immediately is how the previous revision's DEVTMPFS lines got silently
# dropped: Kconfig rewrites the file on the next read. And CONFIG_WERROR=n is
# not valid syntax -- the negative form is "# CONFIG_WERROR is not set".
cat >> .config <<'EOF'
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
# CONFIG_WERROR is not set
EOF
make ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig > /dev/null 2>&1
for opt in CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT CONFIG_BLK_DEV_INITRD; do
  grep -q "^$opt=y" .config || die "$opt did not survive olddefconfig"
done
say "  config ok"

# HOSTCC. The kernel builds scripts/basic/fixdep and friends for the BUILD
# machine, and every C compiler on the runner is masked in this box. The
# compiler we just built is the only one here, so it is HOSTCC too -- which is
# also the honest answer: nothing in this image was built by the runner.
make -j"$NP" ARCH=arm64 CROSS_COMPILE="$CROSS" \
     HOSTCC="$S/tools/bin/${CROSS}gcc" Image > /work/kbuild.log 2>&1 || {
  say "  kernel build FAILED"
  grep -nE "error:|Error [0-9]" /work/kbuild.log | head -20 | sed 's/^/    /'
  tail -25 /work/kbuild.log | sed 's/^/    /'; exit 1; }
[ -f arch/arm64/boot/Image ] || die "make returned 0 but no Image exists"
cp arch/arm64/boot/Image /work/Image
cp arch/arm64/boot/Image /work/img/Image
cp .config /work/img/kernel.config
say "  ok: $(du -h /work/Image | cut -f1)"
cd /work

# ------------------------------------------------------------ busybox
say ""
say "  === busybox (static, by the same compiler) ==="
tar xf /work/src/busybox-1.36.1.tar.bz2
cd busybox-1.36.1
make CROSS_COMPILE="$CROSS" defconfig > /dev/null 2>&1
# CONFIG_STATIC via the config system, not sed on a line that may not exist.
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/;s/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' .config
grep -q '^CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config
# TLS pulls in headers this toolchain has no reason to carry, and a static
# busybox does not need it.
sed -i 's/^CONFIG_TLS=y/# CONFIG_TLS is not set/' .config
make CROSS_COMPILE="$CROSS" oldconfig < /dev/null > /dev/null 2>&1
make -j"$NP" CROSS_COMPILE="$CROSS" > /work/bbuild.log 2>&1 || {
  say "  busybox FAILED"; tail -25 /work/bbuild.log | sed 's/^/    /'; exit 1; }
file busybox | sed 's/^/  /'
cd /work

# ------------------------------------------------------------ initramfs
say ""
say "  === initramfs, carrying the compiler ==="
I=/work/initramfs
rm -rf "$I"; mkdir -p "$I"/bin "$I"/sbin "$I"/etc "$I"/proc "$I"/sys "$I"/dev "$I"/tmp "$I"/usr
install -m755 busybox-1.36.1/busybox "$I/bin/busybox"
for a in sh ls cat echo mkdir mount umount uname id sleep cut head tail grep; do
  ln -sf busybox "$I/bin/$a"
done

# The toolchain and the pre-built test programs the gate staged.
if [ -d "$S/work/guest" ]; then
  cp -a "$S/work/guest/." "$I/usr/" 2>/dev/null || true
  [ -f "$S/work/guest/t_fib" ]   && install -m755 "$S/work/guest/t_fib"   "$I/bin/t_fib"
  [ -f "$S/work/guest/t_hello" ] && install -m755 "$S/work/guest/t_hello" "$I/bin/t_hello"
fi

cat > "$I/init" <<'INIT'
#!/bin/sh
mount -t proc  proc /proc
mount -t sysfs sys  /sys
mount -t devtmpfs dev /dev 2>/dev/null

echo "VERON-BOOT-OK   $(uname -s) $(uname -r) $(uname -m)"
echo "VERON-INVENTORY $(uname -a | cut -c1-100)"

# THE SAME BINARIES, RUN AGAIN. They were compiled in the box and executed
# there; running them here proves the guest can execute what the toolchain
# produced, not merely that the toolchain produced something.
if [ -x /bin/t_hello ]; then /bin/t_hello; fi
if [ -x /bin/t_fib ]; then
  /bin/t_fib; echo "VERON-FIB       exit=$? (expect 55)"
fi

# THE ACTUAL GATE. Compile a new program, inside the kernel this toolchain
# built, with the compiler this toolchain produced, and run the result.
CC=""
for c in /usr/bin/*-gcc /usr/bin/gcc /usr/bin/cc; do
  [ -x "$c" ] && { CC="$c"; break; }
done
if [ -n "$CC" ]; then
  echo "VERON-GUEST-CC  $CC"
  cat > /tmp/g.c <<'EOF'
int main(void){ return 42; }
EOF
  "$CC" -O2 -static /tmp/g.c -o /tmp/g 2> /tmp/g.err
  if [ -x /tmp/g ]; then
    /tmp/g
    echo "VERON-GCC-IN-GUEST exit=$? (expect 42)"
  else
    echo "VERON-GCC-IN-GUEST FAILED"
    head -10 /tmp/g.err
  fi
else
  echo "VERON-GCC-IN-GUEST NO COMPILER IN GUEST"
fi

echo "VERON-DONE"
# A boot that ends in a shell never exits and the run dies on the timeout, which
# is indistinguishable from a hang. Power off instead, so the log ends cleanly.
poweroff -f 2>/dev/null || exec /bin/sh
INIT
chmod +x "$I/init"

cd "$I"
find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > /work/initramfs.cpio.gz
cp /work/initramfs.cpio.gz /work/img/
say "  ok: $(du -h /work/initramfs.cpio.gz | cut -f1)"

say ""
say "  rung 3 complete: kernel + userland built, initramfs carries the compiler"
exit 0
