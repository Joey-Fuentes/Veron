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
#   3. apply the exact series the workflows apply -- same glob, same order,
#      and the SAME FALLBACK: `git apply --ignore-whitespace || patch -p1`.
#      The fallback is load-bearing, not belt-and-suspenders: the series has
#      internal context drift (arm64-asm 0006/0007 move tccgen.c lines near
#      tcc-microc 0005's hunks), strict git-apply refuses it, and patch(1)'s
#      fuzz is how CI has always landed it. The condensed diff captures the
#      RESULT, which is deterministic either way. Any .rej is a hard stop.
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

command -v patch >/dev/null 2>&1 \
  || { echo "FAIL: GNU patch is required (Termux: pkg install patch)"; exit 1; }

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
  git -C "$W/tcc-src" apply --ignore-whitespace "$p" 2>/dev/null \
    || patch -p1 -d "$W/tcc-src" -i "$p" >/dev/null \
    || { echo "FAIL: $(basename "$p") does not apply (even with fuzz)"; exit 1; }
  n=$((n+1))
done
echo "applied $n patches (arm64-asm then microc, lexical order)"
# FUZZ HYGIENE: a fuzzy application that half-landed leaves .rej files; that
# is a hard stop, never a shrug. Backup .orig files are noise -- remove them
# so they cannot enter the diff.
if find "$W/tcc-src" -name '*.rej' | grep -q .; then
  echo "FAIL: rejected hunks:"; find "$W/tcc-src" -name '*.rej'; exit 1
fi
find "$W/tcc-src" -name '*.orig' -delete
# THE TREE-STATE ASSERTIONS THE WORKFLOW ITSELF LEARNED TO MAKE: "N patches
# applied" is not "the fix is in the tree".
grep -q '#include <float.h>' "$W/tcc-src/tccgen.c" \
  || { echo "FAIL: arm64-asm 0006 not in tccgen.c"; exit 1; }
grep -q 'VT_VALMASK | VT_LVAL | VT_SYM)) == VT_CONST' "$W/tcc-src/tccgen.c" \
  || { echo "FAIL: arm64-asm 0007 not in tccgen.c"; exit 1; }

git -C "$W/tcc-src" add -A
git -C "$W/tcc-src" diff --cached > "$HERE/tcc-veron.patch"

# 5. the proof: one patch == the whole series
( cd "$W" && clone_pinned tcc-check "$SHA" "$URLS" )
git -C "$W/tcc-check" apply --ignore-whitespace "$HERE/tcc-veron.patch" \
  || { echo "FAIL: condensed patch does not apply to pristine"; exit 1; }
if diff -r --exclude=.git "$W/tcc-src" "$W/tcc-check" > /dev/null; then
  echo "VERIFIED: pristine + tcc-veron.patch == pristine + $n series patches"
else
  echo "FAIL: condensed patch does not reproduce the series-patched tree"
  exit 1
fi

echo "tcc-veron.patch: $(wc -l < "$HERE/tcc-veron.patch") lines"
sha256sum "$HERE/tcc-veron.patch"
echo "Commit it: git add stages/3-micro-c/tcc/tcc-veron.patch"
