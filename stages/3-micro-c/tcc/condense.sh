#!/bin/sh
# stages/3-micro-c/tcc/condense.sh -- generate THE one condensed veron patch.
#
#     sh stages/3-micro-c/tcc/condense.sh        (network needed: one clone)
#
# Design D2: tcc is a PINNED RELEASE plus ONE condensed patch, applied
# normally. The delta currently lives as two series the workflows apply in
# order (tcc-arm64-asm [0-9]*.patch, then tcc-microc [0-9]*.patch). This
# script folds them into a single reviewable tcc-veron.patch, generated
# against a verified clean checkout of the pin -- which is why it cannot run
# in a sandbox without network, and why the patch file is ABSENT from the
# tree until this has been run once: never commit an artifact that was never
# verified.
#
# What it does, all loudly checked:
#   1. read the pin + mirrors from sources/tcc.toml (the single source of
#      truth; NOT duplicated here)
#   2. clone_pinned a pristine tree and verify the commit (content-addressed)
#   3. apply the exact series the workflows apply, same glob, same order,
#      same --ignore-whitespace; any failure names the patch and stops
#   4. emit tcc-veron.patch (git diff --cached, so added files are included)
#   5. PROVE it: second pristine copy + ONLY the condensed patch must be
#      byte-identical to the series-patched tree (diff -r)
#   6. print the patch sha256 + patch counts for the commit message
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# Find the repo root by looking for the pin manifest itself, not by counting
# directory levels -- this script sits one level deeper than the stage
# scripts, and the first release counted levels and read sources/tcc.toml
# from the wrong directory.
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do
  ROOT="$(dirname "$ROOT")"
done
[ -f "$ROOT/sources/tcc.toml" ] || {
  echo "FAIL: cannot find repo root (no sources/tcc.toml above $HERE)"; exit 1; }
cd "$ROOT"

SHA=$(sed -n 's/^commit *= *"\([0-9a-f]*\)".*/\1/p' sources/tcc.toml | head -1)
URLS=$(sed -n 's/^mirrors *= *\[\(.*\)\]/\1/p' sources/tcc.toml \
       | tr -d '",' )
[ -n "$SHA" ] || { echo "FAIL: no commit pin in sources/tcc.toml"; exit 1; }
echo "pin: $SHA"
echo "mirrors: $URLS"

. tools/clone-pinned.sh
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
( cd "$W" && clone_pinned tcc-src "$SHA" "$URLS" )

n=0
for p in "$ROOT"/spikes/stage3/patches/tcc-arm64-asm/[0-9]*.patch \
         "$ROOT"/spikes/stage3/patches/tcc-microc/[0-9]*.patch; do
  git -C "$W/tcc-src" apply --ignore-whitespace "$p" \
    || { echo "FAIL: $p does not apply to pristine $SHA"; exit 1; }
  n=$((n+1))
done
echo "applied $n patches (arm64-asm then microc, lexical order)"

git -C "$W/tcc-src" add -A
git -C "$W/tcc-src" diff --cached > "$HERE/tcc-veron.patch"

# 5. the proof: one patch == the whole series
( cd "$W" && clone_pinned tcc-check "$SHA" "$URLS" )
git -C "$W/tcc-check" apply --ignore-whitespace "$HERE/tcc-veron.patch"
if diff -r --exclude=.git "$W/tcc-src" "$W/tcc-check" > /dev/null; then
  echo "VERIFIED: pristine + tcc-veron.patch == pristine + $n series patches"
else
  echo "FAIL: condensed patch does not reproduce the series-patched tree"
  exit 1
fi

echo "tcc-veron.patch: $(wc -l < "$HERE/tcc-veron.patch") lines"
sha256sum "$HERE/tcc-veron.patch"
echo "Commit it: git add stages/3-micro-c/tcc/tcc-veron.patch"
