#!/bin/sh
# stages/4-toolchain-kernel/in.sh -- STAGE 4's INPUT PHASE: receive the 3->4
# contract. Per the boundary decision, that contract is ONE COMPILER
# (tcc-amd64 for this leg) plus the tcc source recipe -- nothing else.
# Stage 4's first rung is that compiler building its own musl.
#
# INPUT RESOLUTION (design 3.4): out/3/x86_64/ first (a local chain run),
# then the 3/latest-x86_64 release. EITHER WAY the artifact must match the
# committed record stages/3-micro-c/substages-amd64.toml -- consumers verify
# contracts, they do not trust paths or tags.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do
  ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/sources/tcc.toml" ] || { echo "FAIL: no repo root above $HERE"; exit 1; }
cd "$ROOT"
IN="$ROOT/in/4"
REPO="${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}"
mkdir -p "$IN"

want=$(python3 -c "
import tomllib
d = tomllib.load(open('stages/3-micro-c/substages-amd64.toml','rb'))
for s in d['substage']:
    if s['id'] == '3/6/tcc-amd64': print(s['output'][0]['sha256'])")
[ -n "$want" ] || { echo "FAIL: no committed record for 3/6/tcc-amd64"; exit 1; }

got=""
if [ -x "$ROOT/out/3/x86_64/tcc-amd64" ]; then
  got=$(sha256sum "$ROOT/out/3/x86_64/tcc-amd64" | cut -d' ' -f1)
fi
if [ "$got" = "$want" ]; then
  cp "$ROOT/out/3/x86_64/tcc-amd64" "$IN/ref-tcc"
  SRC="out/3/x86_64 (local chain run)"
else
  echo "  fetching the contract from the 3/latest-x86_64 release"
  for f in tcc-amd64 ARTIFACT-SHA256 substages.toml; do
    curl -fsSL --connect-timeout 15 --retry 2 \
      -o "$IN/rel-$f" \
      "https://github.com/$REPO/releases/download/3/latest-x86_64/$f" \
      || { echo "FAIL: could not fetch $f from the release"; exit 1; }
  done
  ( cd "$IN" && sed 's/  / rel-/' rel-ARTIFACT-SHA256 | grep rel-tcc-amd64 \
      | sha256sum -c ) || { echo "FAIL: release digest check"; exit 1; }
  cmp -s "$IN/rel-substages.toml" stages/3-micro-c/substages-amd64.toml \
    || { echo "FAIL: the release's records differ from the committed record"; exit 1; }
  cp "$IN/rel-tcc-amd64" "$IN/ref-tcc"
  SRC="3/latest-x86_64 release (digests + records verified)"
fi
chmod 0755 "$IN/ref-tcc"
got=$(sha256sum "$IN/ref-tcc" | cut -d' ' -f1)
[ "$got" = "$want" ] || { echo "FAIL: ref-tcc $got != recorded $want"; exit 1; }
case "$(file -b "$IN/ref-tcc")" in
  *"dynamically linked"*) echo "FAIL: ref-tcc must be static"; exit 1 ;;
esac

# the box also receives the patched tcc SOURCE tree (it rebuilds libtcc1
# in-box); materialize it the repo-hermetic way -- the committed toolbox
# tarball + the one condensed patch, exactly what built tcc-amd64 itself
[ -d "$ROOT/in/3/tcc-src" ] || sh stages/3-micro-c/build.sh in
[ -f "$ROOT/in/3/tcc-src/tcc.c" ] || { echo "FAIL: no tcc source tree"; exit 1; }

{
  echo "ref-tcc     $got"
  echo "source      $SRC"
  echo "record      stages/3-micro-c/substages-amd64.toml (3/6/tcc-amd64)"
  echo "built-by    self-assembler -> pico-c -> micro-c -> tcc-arm64 -> tcc-arm64-to-amd64 -> tcc-amd64"
} > "$IN/PROVENANCE"
sed 's/^/  /' "$IN/PROVENANCE"
echo "  ref-tcc ready: the 3->4 contract, verified against the frozen record"
