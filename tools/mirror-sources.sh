#!/bin/sh
# tools/mirror-sources.sh -- make the GitHub releases a complete mirror of
# every manifest entry, in the repo's established shape: ONE RELEASE PER
# TARBALL, tag src/<filename> (the convention the stage-5 packages already
# use). Idempotent: existing assets are verified, missing ones fetched from
# upstream (manifest url + mirrors), sha-checked, and uploaded. Unpinned
# entries are fetched, MINTED (hash printed for the manifest), and uploaded.
# Needs: gh (authed), curl, python3.  Run from anywhere in the repo.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}"
WORK="${TMPDIR:-$HOME}/veron-mirror.$$"
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
python3 - << 'PY' > "$WORK/list.tsv"
import tomllib, glob, os
for m in sorted(glob.glob("sources/*.toml")):
    try: d = tomllib.load(open(m, "rb"))
    except Exception: continue
    srcs = d.get("source", [])
    if isinstance(srcs, dict): srcs = [srcs]   # [source] table vs [[source]] array
    for s in srcs:
        if not isinstance(s, dict): continue
        urls = [u for u in [s.get("url","")] + s.get("mirrors",[]) if u]
        if not urls: continue
        if any(u.endswith(".git") for u in urls): continue   # git pins are
        # commit-sha based (tools/clone-pinned.sh territory); curl-ing a repo
        # URL hashes an HTML page -- the tinycc.git lesson of 2026-08-16.
        b = os.path.basename(urls[0])
        print("\t".join([b, s.get("sha256","") or "-", "|".join(urls), m]))
PY
total=0; ok=0; up=0; mint=0
while IFS="$(printf '\t')" read -r b sha urls m; do
  [ "$sha" = "-" ] && sha=""   # sentinel: POSIX read collapses adjacent tabs,
                               # so an empty field must never be emitted
  total=$((total+1))
  # already mirrored?
  if gh release view "src/$b" --repo "$REPO" >/dev/null 2>&1; then
    if [ -z "$sha" ]; then
      # release exists but the manifest has no pin: mint from the RELEASE
      # asset itself, so "mirrored" can never hide an unpinned entry
      gh release download "src/$b" --repo "$REPO" -p "$b" -O "$WORK/$b" --clobber
      got=$(sha256sum "$WORK/$b" | cut -d' ' -f1); rm -f "$WORK/$b"
      echo "  MINT ($(basename "$m")): sha256 = \"$got\"  (from existing release)"
      mint=$((mint+1))
    fi
    echo "mirrored   $b"
    ok=$((ok+1)); continue
  fi
  got=""
  old_ifs=$IFS; IFS='|'
  for u in $urls; do
    if curl -fsSL --connect-timeout 15 --max-time 900 --retry 2 \
         -o "$WORK/$b" "$u" 2>/dev/null && [ -s "$WORK/$b" ]; then
      got=$(sha256sum "$WORK/$b" | cut -d' ' -f1); break
    fi
    rm -f "$WORK/$b"
  done
  IFS=$old_ifs
  [ -n "$got" ] || { echo "FAIL: no mirror produced $b" >&2; exit 1; }
  if [ -n "$sha" ] && [ "$got" != "$sha" ]; then
    echo "FAIL: $b fetched $got != manifest $sha" >&2; exit 1
  fi
  [ -z "$sha" ] && { echo "  MINT ($(basename "$m")): sha256 = \"$got\""; mint=$((mint+1)); }
  gh release create "src/$b" "$WORK/$b" --repo "$REPO" \
    --latest=false --title "$b" \
    --notes "Pinned source mirror: sha256 $got. See sources/ manifests." \
    || gh release upload "src/$b" "$WORK/$b" --repo "$REPO" --clobber
  echo "UPLOADED   $b  $got"
  rm -f "$WORK/$b"; up=$((up+1))
done < "$WORK/list.tsv"
echo "mirror: $total entries -- $ok already mirrored, $up uploaded, $mint hashes to mint into manifests"
