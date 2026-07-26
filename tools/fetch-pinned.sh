#!/usr/bin/env bash
# Fetch a pinned upstream tarball with bounded time, a cache, and a hash check.
#
#   usage: fetch-pinned.sh DEST CACHEFILE SHA256|- "URL ..." "GITURL ..." GITREF
#
# WHY THIS EXISTS. The inline fetch it replaces could burn four minutes and then
# fail the job with `exit 128` and a git credential error:
#
#   musl.libc.org      5 retries x 20s   ~100s   unbounded --retry
#   ftp.barfooze.de    404                       dead mirror
#   git.musl-libc.org  135s                      no timeout at all
#   github.com         "could not read Username"  auth prompt on a 404
#   -> the whole || chain failed under `bash -e`
#
# Four separate defects, none of them about tcc:
#
#   1. NO CACHE. Every run re-downloads sources that never change. One transient
#      outage anywhere in the chain kills a 40-minute job.
#   2. UNBOUNDED WAITS. curl retried five times at 20s and git had no timeout,
#      so failure took minutes instead of seconds.
#   3. DEAD MIRRORS. The same bug was fixed for busybox one round earlier and
#      left in place for musl.
#   4. NO HASH. The pin was a version string. Version strings are asserted after
#      the fact; a hash is what makes the fetch itself verifiable, which is the
#      thing sources/ and TRUST-BOUNDARY.md are about.
#
# Pass "-" for SHA256 to skip verification; the script then PRINTS the hash it
# got so it can be pinned on the next commit. That is deliberate: inventing a
# hash would be worse than not having one.

set -uo pipefail

DEST=${1:?dest dir}
CACHE=${2:?cache file}
WANT_SHA=${3:?sha256 or -}
URLS=${4:-}
GITURLS=${5:-}
GITREF=${6:-}

say() { printf '%s\n' "$*"; }

verify() {   # $1 = file
    [ -s "$1" ] || return 1
    got=$(sha256sum "$1" | cut -d' ' -f1)
    if [ "$WANT_SHA" = "-" ]; then
        say "    sha256 (unpinned): $got"
        say "    ^ pin this in the workflow to make the fetch verifiable"
        return 0
    fi
    if [ "$got" = "$WANT_SHA" ]; then
        say "    sha256 ok"
        return 0
    fi
    say "    SHA MISMATCH: got $got"
    say "                  want $WANT_SHA"
    return 1
}

mkdir -p "$(dirname "$CACHE")" "$DEST"

# ------------------------------------------------------------------ cache hit
if [ -s "$CACHE" ] && verify "$CACHE"; then
    say "  cache hit: $CACHE"
    tar xf "$CACHE" -C "$DEST" --strip-components=1 && exit 0
    say "  cached file did not extract -- refetching"
    rm -f "$CACHE"
fi

# ------------------------------------------------------------------- tarballs
for u in $URLS; do
    say "  trying $u"
    # Bounded: 8s to connect, 2 retries, 180s ceiling for the whole transfer.
    # Worst case per URL is seconds, not minutes.
    if curl -fsSL --retry 2 --retry-delay 2 --retry-connrefused \
            --connect-timeout 8 --max-time 180 -o "$CACHE.tmp" "$u"; then
        if verify "$CACHE.tmp"; then
            mv "$CACHE.tmp" "$CACHE"
            tar xf "$CACHE" -C "$DEST" --strip-components=1 && exit 0
        fi
    fi
    rm -f "$CACHE.tmp"
done

# ------------------------------------------------------------------------ git
# GIT_TERMINAL_PROMPT=0 turns a 404-that-looks-private into an immediate error
# instead of "could not read Username". timeout bounds the connect stall.
export GIT_TERMINAL_PROMPT=0
for g in $GITURLS; do
    [ -n "$GITREF" ] || break
    say "  cloning $g at $GITREF"
    rm -rf "$DEST.git"
    if timeout 120 git clone -q --depth 1 --branch "$GITREF" "$g" "$DEST.git"; then
        rm -rf "$DEST"; mv "$DEST.git" "$DEST"
        say "  cloned (no hash check possible on a clone)"
        exit 0
    fi
    rm -rf "$DEST.git"
done

say "  ALL SOURCES FAILED for $DEST"
say "  This is a fetch problem, not a build problem. Re-run the job; if it"
say "  persists, one of the URLs above has moved and the list needs updating."
exit 1
