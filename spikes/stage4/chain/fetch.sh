#!/bin/sh
# fetch.sh -- the one fetcher for the stage-4 chain.
#
#   fetch.sh <destdir> <url> [<url> ...]
#
# The get() below is an EXTRACTION of the hardened fetch in
# .github/workflows/hermetic-gcc15.yml. Its three defences each have a dead run
# behind them and none of them are decorative:
#
#   -f              a 404 must FAIL. Without it curl exits 0 and writes the
#                   error page into the cache file, and the failure resurfaces
#                   hours later as "tar: unexpected EOF".
#   --http1.1       cdn.kernel.org serves h2 and long transfers on it die with
#                   "curl: (92) HTTP/2 stream 1 was not closed cleanly".
#   --retry-all-errors
#                   plain --retry covers timeouts, 5xx, 408 and 429. Exit 92 is
#                   a transport-layer error and is NOT on that list, so
#                   "--retry 3" alone was decoration.
#
# PINS. Anything named in sources/*.toml is verified against the sha256 there
# before it is allowed into a build; invariant #6, "nothing enters a build
# unnamed". A file with no pin is fetched, hashed, and the hash PRINTED so the
# run produces a candidate pin rather than a shrug. Unpinned inputs are
# reported at the end and are a finding, not a silent pass.
set -eu

DEST=${1:?fetch.sh: destination directory required}
shift
mkdir -p "$DEST"
REPO=${REPO:-$PWD}
UNPINNED=0

pin_for() {   # $1 = basename -> prints the sha256 recorded in sources/, if any
  grep -rl -- "$1" "$REPO/sources/" 2>/dev/null | while read -r f; do
    awk -v want="$1" '
      /url|file/ { if (index($0, want)) hit=1 }
      /sha256/   { if (hit) { gsub(/[^0-9a-f]/, "", $3); print $3; exit } }
    ' "$f"
  done | head -1
}

get() {
  base=$(basename "$1"); printf '  %-34s' "$base"
  if [ -f "$DEST/$base" ]; then echo " cached"; return 0; fi

  case "$1" in
    *.tar.gz) alt=$(printf '%s' "$1" | sed 's/\.tar\.gz$/.tar.xz/') ;;
    *.tar.xz) alt=$(printf '%s' "$1" | sed 's/\.tar\.xz$/.tar.gz/') ;;
    *)        alt="$1" ;;
  esac
  gnu=$(printf '%s' "$1" | sed 's|https://mirrors.kernel.org/gnu|https://ftp.gnu.org/gnu|')
  kern=$(printf '%s' "$1" | sed 's|https://cdn.kernel.org|https://mirrors.edge.kernel.org|')

  n=0
  for u in "$1" "$gnu" "$kern" "$alt"; do
    n=$((n+1))
    # -C - resumes a partial file, which is exactly what a mid-stream protocol
    # error leaves behind. Not on the first attempt: a complete file plus a
    # range request is a 416.
    [ "$n" -eq 1 ] && resume="" || resume="-C -"
    # shellcheck disable=SC2086
    if curl -fsSL --http1.1 --retry 3 --retry-all-errors \
         --retry-delay 3 --connect-timeout 15 --max-time 900 \
         $resume -o "$DEST/$base" "$u" 2> /tmp/curl.err; then
      echo " ok  $(du -h "$DEST/$base" 2>/dev/null | cut -f1)"
      verify "$base"
      return 0
    fi
  done
  echo " FAILED"
  echo "    last curl error: $(tail -1 /tmp/curl.err 2>/dev/null)"
  echo "    tried:"
  printf '      %s\n' "$1" "$gnu" "$kern" "$alt"
  return 1
}

verify() {
  want=$(pin_for "$1" || true)
  got=$(sha256sum "$DEST/$1" | cut -d' ' -f1)
  if [ -z "$want" ]; then
    echo "    UNPINNED  sha256=$got"
    echo "    ^^ add this to sources/ before it is trusted (invariant #6)"
    UNPINNED=$((UNPINNED+1))
    return 0
  fi
  if [ "$want" != "$got" ]; then
    echo "    PIN MISMATCH"
    echo "      sources/ says : $want"
    echo "      downloaded    : $got"
    return 1
  fi
  echo "    pin ok    $got"
}

rc=0
for u in "$@"; do get "$u" || rc=1; done

if [ "$UNPINNED" -gt 0 ]; then
  echo
  echo "  $UNPINNED input(s) entered this build without a pin in sources/."
  echo "  That is invariant #6 and it is recorded here rather than hidden."
  echo "$UNPINNED" > "$DEST/.unpinned.count"
fi
exit "$rc"
