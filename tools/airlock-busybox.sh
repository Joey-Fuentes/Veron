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
name=$(basename "$BB_URL"); tb="dl/$name"
# OUR MIRROR FIRST, UPSTREAM SECOND, THE PIN EITHER WAY. mirror-sources.sh
# keeps every sources/*.toml tarball as a release of its own -- tag
# src/<filename>, asset <sha8>-<filename> -- so this build never waits on
# busybox.net being up (run 89155834277: it was not, and the first version
# of this file reported a file that never arrived as "does not match").
# sources/busybox.toml's own mirror line is a git-tag archive of the same
# commit, not the same bytes, so it cannot satisfy the pin and is not tried.
if ! { [ -s "$tb" ] && [ "$(sha256sum "$tb" | cut -d' ' -f1)" = "$BB_SHA" ]; }; then
  rm -f "$tb"
  # the mirror's asset is the plain filename (tools/mirror-sources.sh);
  # the <sha8>- form is the stage-5 MIRRORS.tsv route -- tried second
  _rel="https://github.com/${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}/releases/download/src/$name"
  for u in "$_rel/$name" "$_rel/$(printf '%.8s' "$BB_SHA")-$name" "$BB_URL"; do
    if curl -fsSL --connect-timeout 20 --retry 3 -o "$tb" "$u" && [ -s "$tb" ]; then
      echo "  fetched $name from $u"; break
    fi
    echo "  no answer from $u"; rm -f "$tb"
  done
fi
[ -s "$tb" ] || { echo "FAIL: could not fetch $name from the mirror or upstream"; exit 1; }
[ "$(sha256sum "$tb" | cut -d' ' -f1)" = "$BB_SHA" ] || { echo "FAIL: $tb does not match sources/busybox.toml (got $(sha256sum "$tb" | cut -c1-16))"; exit 1; }
echo "  $name matches its pin"
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
yes '' 2>/dev/null | make oldconfig >/dev/null 2>&1 || true
for sym in STATIC SPLIT COMM OD STAT TAR TOUCH SHA256SUM; do
  grep -q "^CONFIG_$sym=y" .config || { echo "FAIL: CONFIG_$sym did not survive oldconfig"; exit 1; }
done
make -j"$(nproc)" >b.log 2>&1 || { echo "FAIL: busybox did not build:"; tail -20 b.log; exit 1; }
cd "$ROOT"
cp build/airlock-busybox/busybox box/tools/busybox && chmod 755 box/tools/busybox
sha256sum box/tools/busybox | cut -d' ' -f1 > box/tools/busybox.sha256
echo "  box/tools/busybox: $(wc -c < box/tools/busybox) bytes, $(box/tools/busybox --list | wc -l) applets, sha256 $(cut -c1-16 box/tools/busybox.sha256)"
