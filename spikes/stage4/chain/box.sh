#!/bin/sh
# box.sh -- THE sandbox for every rung of the stage-4 chain.
#
# This file is a VERBATIM EXTRACTION of the box that already survives contact
# with ubuntu-24.04-arm in .github/workflows/tcc-builds-gcc-arm64.yml. It was
# moved out of that workflow so that every rung shares ONE definition and the
# four jobs of stage4-complete cannot drift apart from each other or from the
# rung jobs. Nothing here is new. If you change it, you are changing the
# sandbox for every job that sources it, which is the point.
#
#   box.sh --show-mask    print what would be masked, and exit
#   box.sh CMD ...        run CMD inside the box
#
# Required environment:
#   W       the work directory, bound at /work (persistent, host-backed)
#   REPO    the checkout, bound read-only at /repo
# Optional:
#   BOXENV  extra --setenv pairs, e.g. "--setenv CC /work/tccsrc/tcc"
set -eu

# ---------------------------------------------------------------- the mask
# MASK THE RESOLVED REAL BINARY, NOT THE NAME. Run 81871617317 died at
#     bwrap: Can't create file at /usr/bin/c++: No such file or directory
# because almost every driver name on an Ubuntu runner is a symlink, and c++
# leaves /usr/bin on the way to its target:
#     c++ -> /etc/alternatives/c++ -> /usr/bin/g++ -> g++-13
#         -> aarch64-linux-gnu-g++-13
# Fourteen names resolve to just THREE real files. Resolving first and deduping
# means three bind operations, every one of them onto a plain regular file in
# /usr/bin, and no symlink traversal for bwrap to refuse.
mask_list() {
  for c in $(ls /usr/bin 2>/dev/null | grep -E \
             '^(cc|c\+\+|cpp|gcc|g\+\+|clang|clang\+\+)(-[0-9.]+)?$|^[a-z0-9_]+-linux-gnu-(gcc|g\+\+|cpp)(-[0-9.]+)?$'); do
    t=$(readlink -f "/usr/bin/$c" 2>/dev/null) || continue
    if [ -n "$t" ] && [ -f "$t" ]; then echo "$t"; fi
  done | sort -u
}

MASK=""
for t in $(mask_list); do
  MASK="$MASK --ro-bind /dev/null $t"
done
# THE STRUCTURAL HALF OF THE MASK, and note WHICH directory matters: on Ubuntu
# cc1 and cc1plus live in /usr/libexec/gcc, NOT /usr/lib/gcc.
#   /usr/libexec/gcc/aarch64-linux-gnu/13/cc1
#   /usr/lib/gcc/aarch64-linux-gnu/13/     crt*.o, libstdc++.a, specs
# Both are masked, but libexec is the one that makes compiling impossible --
# do not drop it thinking the other covers it. The RUNTIME libgcc_s.so.1 is in
# neither -- it is in /usr/lib/<triplet>/ -- so dynamically linked binaries
# still run.
if [ -d /usr/lib/gcc ];     then MASK="$MASK --tmpfs /usr/lib/gcc";     fi
if [ -d /usr/libexec/gcc ]; then MASK="$MASK --tmpfs /usr/libexec/gcc"; fi

if [ "${1:-}" = "--show-mask" ]; then
  echo "  compiler binaries bind-mounted to /dev/null:"
  mask_list | sed 's/^/    /'
  if [ -d /usr/lib/gcc ];     then echo "    (tmpfs) /usr/lib/gcc       <- crt*.o, libstdc++.a, specs"; fi
  if [ -d /usr/libexec/gcc ]; then echo "    (tmpfs) /usr/libexec/gcc   <- cc1, cc1plus  [load-bearing]"; fi
  echo "  the names that resolve into that set:"
  ls /usr/bin 2>/dev/null | grep -E \
    '^(cc|c\+\+|cpp|gcc|g\+\+|clang|clang\+\+)(-[0-9.]+)?$|^[a-z0-9_]+-linux-gnu-(gcc|g\+\+|cpp)(-[0-9.]+)?$' \
    | tr '\n' ' ' | sed 's/^/    /'
  echo
  exit 0
fi

W=${W:?box.sh: W (work dir) not set}
REPO=${REPO:?box.sh: REPO (checkout) not set}

LIB64=""
# aarch64 has no /lib64; x86_64 does. Emit the symlink only if the host
# actually has one, so this script is portable across both.
if [ -d /lib64 ]; then LIB64="--symlink usr/lib64 /lib64"; fi

# shellcheck disable=SC2086
exec bwrap \
  --unshare-all --die-with-parent --new-session \
  --clearenv \
  --setenv PATH /usr/bin:/bin:/usr/sbin:/sbin \
  --setenv HOME /work \
  --setenv LC_ALL C \
  --setenv TERM dumb \
  --setenv SOURCE_DATE_EPOCH 0 \
  ${BOXENV:-} \
  --ro-bind /usr /usr \
  --ro-bind /etc /etc \
  --ro-bind "$REPO" /repo \
  --symlink usr/bin /bin \
  --symlink usr/sbin /sbin \
  --symlink usr/lib /lib \
  $LIB64 \
  $MASK \
  --proc /proc --dev /dev \
  --tmpfs /tmp --tmpfs /run \
  --bind "$W" /work \
  --chdir /work \
  "$@"
