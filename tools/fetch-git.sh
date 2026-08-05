#!/bin/sh
# fetch-git.sh -- turn a pinned COMMIT into a tarball we generated ourselves.
#
# WHY THIS EXISTS. Some upstreams publish no release tarball at all. libsfdo
# and dinit only push git tags; what a forge offers as an "archive" is
# synthesised on request by running `git archive` against the tag, using that
# forge's git version, its compression settings and its export-subst handling.
# Those change without notice -- GitHub's generated tarballs shifted for the
# whole ecosystem when their gzip settings changed -- so pinning one means
# pinning an artifact nobody here controls, whose digest can move under a
# recipe that claims to be reproducible.
#
# THE PIN IS THE COMMIT. A git commit name is a Merkle hash over the entire
# tree and its history. It cannot be regenerated differently, it is what
# tools/clone-pinned.sh already verifies with a rev-parse, and it is a
# strictly stronger statement than "some tarball had this sha256".
#
# THE TARBALL IS DERIVED, AND WE MAKE IT. `git archive` with pinned settings
# is deterministic: same commit, same prefix, same output. gzip -n drops the
# timestamp and filename that otherwise make two runs differ. So the digest
# this prints is OUR artifact's, recorded as derived-from-commit rather than
# passed off as upstream's.
#
# Usage:
#   fetch-git.sh <commit> <name-version> <url> <dest-dir>

set -eu

COMMIT="$1"
NAME="$2"
URL="$3"
DEST="$4"

# ABSOLUTE BEFORE ANY cd, AND THIS WAS SILENTLY BROKEN. Everything below runs
# after `cd "$WORK/r"`, so a RELATIVE --dest -- and the spike workflow passes
# `dl` -- resolved inside the temporary clone directory. `mkdir -p "$DEST"`
# then created it there, `git archive` wrote there, the script printed
#
#     wrote   <name>.tar.gz  (N bytes)
#
# and the EXIT trap deleted the whole temp tree on the way out. Exit code 0,
# a digest printed, and nothing on disk.
#
# The same shape as the log collector that printed "collected 32 log files"
# and preserved none of them: a step that reports success and produces
# nothing is worse than one that fails, because the failure is invisible
# until something downstream cannot find a file nobody thinks is missing.
#
# Latent so far only because no recipe uses kind = "git" yet. The three that
# will -- libxkbcommon, dinit, libsfdo -- would each have failed at unpack
# with "no such file", three rungs after the step that claimed to write it.
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)

OUT="$DEST/$NAME.tar.gz"
if [ -f "$OUT" ]; then
    echo "  cached  $NAME.tar.gz"
    # THE CACHED CHECK MUST HASH THE SAME THING THE PIN IS OVER. Hashing the
    # compressed file here would report a digest nothing compares against.
    CACHED_TAR=$(gzip -dc "$OUT" | sha256sum | cut -d' ' -f1)
    echo "          tar $CACHED_TAR"
    if [ "${5:-}" != "" ] && [ "$CACHED_TAR" != "$5" ]; then
        echo "  CACHED ARCHIVE DOES NOT MATCH THE PIN"
        echo "    wanted $5"
        echo "    got    $CACHED_TAR"
        exit 1
    fi
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/veron-git.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "  clone   $URL"
# --no-tags and a bare fetch of the single commit: we want one object graph,
# not a project's whole history. Some servers refuse fetch-by-sha, so this
# falls back to a full clone and then verifies -- the verification is what
# matters, not how the objects arrived.
if ! git -c advice.detachedHead=false init --quiet "$WORK/r" 2>/dev/null; then
    echo "  git init failed"; exit 1
fi
cd "$WORK/r"
git remote add origin "$URL"
if git fetch --quiet --depth 1 origin "$COMMIT" 2>/dev/null; then
    git checkout --quiet FETCH_HEAD
else
    echo "  server refused fetch-by-commit; falling back to a full clone"
    git fetch --quiet --tags origin
    # A NONEXISTENT COMMIT SHOULD SAY SO, not die inside checkout with
    # "reference is not a tree", which reads like a corrupt repository rather
    # than a wrong pin.
    if ! git cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
        echo "  COMMIT NOT IN THIS REPOSITORY: $COMMIT"
        echo "  Either the pin is wrong, or this mirror is stale or truncated."
        exit 1
    fi
    git checkout --quiet "$COMMIT"
fi

# THE VERIFICATION, AND IT IS THE POINT. A clone is the easiest thing here to
# check and the one most often left unchecked: `git clone && checkout $SHA`
# is a correct pin and an unverified one. A mirror serving a tree in which
# that commit does not exist fails loudly, but nothing otherwise asserts that
# what landed IS the pin.
GOT=$(git rev-parse HEAD)
if [ "$GOT" != "$COMMIT" ]; then
    echo "  COMMIT MISMATCH"
    echo "    wanted $COMMIT"
    echo "    got    $GOT"
    exit 1
fi
echo "  verified HEAD is $COMMIT"

# THE PIN IS OVER THE TAR, NOT THE TAR.GZ, AND THAT WAS MEASURED.
#
# The first version hashed the compressed file and the first real run failed:
#
#     wanted a464bff6...  (generated on a phone, gzip from Termux)
#     got    3ad317bc...  (generated on the runner, gzip 1.12)
#     414836 bytes vs 414922
#
# The COMMIT verified both times, so the source tree was identical. Taking the
# phone's tarball, decompressing it and re-compressing with a different gzip
# reproduced the runner's bytes EXACTLY -- same size, same digest. So:
#
#     `git archive --format=tar` IS reproducible across machines.
#     gzip IS NOT -- its output depends on the implementation and version.
#
# Hashing the compressed file made a portable artifact look unportable and
# would have forced a repin every time a runner image changed its gzip. The
# tar digest is the honest pin; the gzip is packaging.
mkdir -p "$DEST"
git archive --format=tar --prefix="$NAME/" "$COMMIT" > "$OUT.tar"
TAR_SHA=$(sha256sum "$OUT.tar" | cut -d' ' -f1)
gzip -n -9 < "$OUT.tar" > "$OUT.tmp"
rm -f "$OUT.tar"
mv "$OUT.tmp" "$OUT"

echo "  wrote   $NAME.tar.gz  ($(wc -c < "$OUT") bytes)"
GOT_SHA="$TAR_SHA"
echo "          tar    $TAR_SHA   <- THE PIN, compressor-independent"
echo "          tar.gz $(sha256sum "$OUT" | cut -d' ' -f1)   <- varies with gzip"
echo "  ^ THIS DIGEST IS OURS, not upstream's. It is derived from the commit"
echo "    above by a documented, deterministic transformation. The commit is"
echo "    the provenance; this is the artifact."

# AND NOW SOMETHING COMPARES IT. Printing a digest and asking a human to
# record it is exactly what llvm-timing.yml did for three runs, after which
# llvm was still the one package in the set with no pin anywhere. `git
# archive` is deterministic for a given git version -- but the git version is
# the RUNNER'S, and gzip's implementation is too, so a change in either moves
# these bytes while the commit stays identical. That is precisely the class of
# drift a recipe's sha256 exists to catch, and it can only be caught here.
if [ "${5:-}" != "" ]; then
    if [ "$GOT_SHA" != "$5" ]; then
        echo "  ARCHIVE TAR DIGEST MISMATCH for $NAME"
        echo "    wanted $5"
        echo "    got    $GOT_SHA"
        echo "  The COMMIT verified, so the source tree is right, and this"
        echo "  digest is of the UNCOMPRESSED tar -- so gzip is not the cause."
        echo "  A different git version writing different tar headers is, or a"
        echo "  change to the flags above. Do not repin without knowing which."
        exit 1
    fi
    echo "  verified the archive digest against the recipe"
else
    echo "  NO ARCHIVE DIGEST PINNED -- add sha256 to the recipe's [source]"
    echo "  so this is checked rather than printed."
fi
