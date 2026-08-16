#!/bin/sh
# tools/verify-source.sh <tarball-path> -- enforce the sources/*.toml pin for
# one fetched tarball. THE MANIFESTS ARE THE LAW: a file whose basename has a
# sha256 in any manifest must match it or the build dies. A file that appears
# in a manifest WITHOUT a sha256 follows the minting doctrine the manifests
# themselves state ("it goes in when a run prints its hash, not before"):
# print the MINT line and succeed. A file in NO manifest is an error -- 
# nothing enters a build unnamed (sources/README.md).
set -eu
f="$1"; b=$(basename "$f")
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
got=$(sha256sum "$f" | cut -d' ' -f1)
want=$(python3 - "$b" "$ROOT" << 'PY'
import sys, tomllib, glob, os
b, root = sys.argv[1], sys.argv[2]
for m in glob.glob(os.path.join(root, "sources", "*.toml")):
    try: d = tomllib.load(open(m, "rb"))
    except Exception: continue
    srcs = d.get("source", [])
    if isinstance(srcs, dict): srcs = [srcs]   # [source] table vs [[source]] array
    for s in srcs:
        if not isinstance(s, dict): continue
        urls = [s.get("url", "")] + s.get("mirrors", [])
        names = [os.path.basename(u) for u in urls if u]
        if b in names or s.get("file") == b:
            print(s.get("sha256", "") or "UNPINNED"); print(m); sys.exit(0)
print("ABSENT")
PY
)
case "$want" in
  ABSENT)
    echo "FAIL: $b is in no sources/*.toml manifest -- nothing enters unnamed" >&2
    exit 1 ;;
  UNPINNED*)
    m=$(echo "$want" | sed -n 2p)
    echo "  MINT: $b unpinned in $(basename "$m") -- add:  sha256 = \"$got\""
    ;;
  *)
    w=$(echo "$want" | sed -n 1p)
    if [ "$got" = "$w" ]; then
      echo "  PIN OK  $b  $got"
    else
      echo "FAIL: $b sha256 mismatch" >&2
      echo "  manifest: $w" >&2
      echo "  fetched:  $got" >&2
      exit 1
    fi ;;
esac
