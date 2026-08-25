#!/bin/sh
# tools/airlock-busybox.sh -- build the box's busybox from the pin, in the airlock.
#
#     sh tools/airlock-busybox.sh            -> box/tools/busybox (+ .sha256)
#
# THE BOX'S DRIVER IS OURS BY PIN AND BY CONFIG, on every host that has no
# tools bundle to hand: the arm runner today, any Linux box tomorrow. The
# tarball is sources/busybox.toml's; the config is the list below, written
# here and nowhere else (lifted from the stage-4 airlock, where the probe
# that chose it is recorded: Ubuntu's 272-applet build lacked split, comm
# and tsort, and two rungs failed on "not found" before anyone knew why).
# The host's C compiler builds it; the hash of what it built goes into
# every run's out/box/BUDGET. Substitutable, recorded, non-load-bearing:
# the artifacts do not depend on which busybox moved their bytes.
#
# TODO (ledger): a stage-1-3-built busybox-alike, so tier 2 needs nothing a
# later stage or a host compiler made.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
cd "$ROOT"
BB_URL=$(sed -n 's/^url *= *"\([^"]*\)".*/\1/p' sources/busybox.toml | head -1)
BB_SHA=$(sed -n 's/^sha256 *= *"\([0-9a-f]*\)".*/\1/p' sources/busybox.toml | head -1)
[ -n "$BB_URL" ] && [ -n "$BB_SHA" ] || { echo "FAIL: sources/busybox.toml has no url/sha256"; exit 1; }
mkdir -p box/tools dl
tb="dl/$(basename "$BB_URL")"
if ! { [ -s "$tb" ] && [ "$(sha256sum "$tb" | cut -d' ' -f1)" = "$BB_SHA" ]; }; then
  # the primary URL only: sources/busybox.toml's mirror is a git-tag archive
  # of the same commit, not the same bytes, so it cannot satisfy this pin
  curl -fsSL --connect-timeout 20 --retry 3 -o "$tb" "$BB_URL" || true
fi
[ "$(sha256sum "$tb" | cut -d' ' -f1)" = "$BB_SHA" ] || { echo "FAIL: $tb does not match sources/busybox.toml"; exit 1; }
echo "  $(basename "$tb") matches its pin"
rm -rf build/airlock-busybox && mkdir -p build/airlock-busybox
tar -xf "$tb" -C build/airlock-busybox --strip-components=1
cd build/airlock-busybox
make defconfig >/dev/null 2>&1
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
for sym in SPLIT COMM JOIN PASTE EXPAND UNEXPAND FOLD NL TSORT CMP DIFF PATCH AWK SED GREP SORT UNIQ TR CUT \
           OD STAT FEATURE_STAT_FORMAT TAR FEATURE_TAR_FROM TOUCH FEATURE_TOUCH_SUSV3 SHA256SUM FIND XARGS; do
  sed -i "s/^# CONFIG_$sym is not set/CONFIG_$sym=y/" .config
  grep -q "^CONFIG_$sym=y" .config || echo "CONFIG_$sym=y" >> .config
done
for sym in SSL_CLIENT FEATURE_WGET_OPENSSL TLS TC; do
  sed -i "s/^CONFIG_$sym=y/# CONFIG_$sym is not set/" .config
done
yes '' | make oldconfig >/dev/null 2>&1 || true
for sym in STATIC SPLIT COMM OD STAT TAR TOUCH SHA256SUM; do
  grep -q "^CONFIG_$sym=y" .config || { echo "FAIL: CONFIG_$sym did not survive oldconfig"; exit 1; }
done
make -j"$(nproc)" >b.log 2>&1 || { echo "FAIL: busybox did not build:"; tail -20 b.log; exit 1; }
cd "$ROOT"
cp build/airlock-busybox/busybox box/tools/busybox && chmod 755 box/tools/busybox
sha256sum box/tools/busybox | cut -d' ' -f1 > box/tools/busybox.sha256
echo "  box/tools/busybox: $(wc -c < box/tools/busybox) bytes, $(box/tools/busybox --list | wc -l) applets, sha256 $(cut -c1-16 box/tools/busybox.sha256)"
