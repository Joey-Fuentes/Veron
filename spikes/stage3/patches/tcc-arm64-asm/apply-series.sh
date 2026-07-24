#!/usr/bin/env bash
# Apply the Feb-2026 tinycc arm64 assembler series to a tinycc clone.
#
#   usage: apply-series.sh <tinycc-dir> [<patch-dir>]
#
# WHY THIS IS NOT JUST `git apply`. The series was posted on 2026-02-05 against
# whatever mob was that day. Applying it to today's mob fails twice over: mob
# now has its OWN arm64 assembler (so 0003 would be creating an arm64-tok.h that
# already exists), and unrelated files have drifted.
#
# A first attempt rewound to `FIRST^`, the commit before mob's assembler landed.
# That is the wrong tree -- mob's assembler landed MONTHS after February, so
# tccasm.c had already moved, and 0003's two-line hunk at tccasm.c:1178 failed:
#
#     +#elif defined(TCC_TARGET_ARM64)
#     +        *str == 'x' || *str == 'w' || *str == 's' || *str == 'd' ||
#
# The fix is not to search harder for a plausible commit. Every hunk header in
# a git-formatted patch carries `index <pre>..<post>`, and <pre> is the blob
# hash of the file the author had. A tree whose blobs equal those pre-images IS
# the author's tree, exactly, with no date arithmetic involved.
#
# Note that a file touched by more than one patch in a series has a DIFFERENT
# pre-image in each: 0003's tccasm.c pre-image is 0002's OUTPUT and so exists
# nowhere in tinycc's history. Only the FIRST appearance of each file is a real
# repository blob, which is what this script keys on.

set -euo pipefail

T=${1:?usage: apply-series.sh <tinycc-dir> [<patch-dir>]}
P=${2:-$(cd "$(dirname "$0")" && pwd)}

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- pre-images
# "<path> <blob>" for the first patch in the series that touches each path.
declare -A PRE
for p in "$P"/000*.patch; do
    while read -r f blob; do
        [ -z "${f:-}" ] && continue
        [ "${blob:0:7}" = "0000000" ] && continue      # newly created file
        [ -n "${PRE[$f]:-}" ] && continue              # first appearance wins
        PRE[$f]=$blob
    done < <(awk '
        /^diff --git /   { f=$3; sub(/^a\//,"",f) }
        # NB: awk treats a multi-character separator as a REGEX, so ".."
        # matches any two characters and yields an empty first field. The
        # separator has to be escaped.
        /^index /        { split($2, a, /\.\./); if (f != "") print f, a[1] }
    ' "$p")
done

say "  series pre-image blobs (${#PRE[@]} files):"
for f in $(printf '%s\n' "${!PRE[@]}" | sort); do
    printf '    %-16s %s\n' "$f" "${PRE[$f]}"
done

# ------------------------------------------------------------------ the base
# Key off tccasm.c: it is touched early, changes often enough to be
# discriminating, and it is the file that actually failed.
KEY=tccasm.c
WANT=${PRE[$KEY]:-}
BASE=""

if [ -n "$WANT" ]; then
    say ""
    say "  searching history for a commit whose $KEY is $WANT ..."
    while read -r c; do
        got=$(git -C "$T" rev-parse "$c:$KEY" 2>/dev/null) || continue
        case "$got" in "$WANT"*) BASE=$c; break;; esac
    done < <(git -C "$T" log --all --format=%H -- "$KEY")
fi

if [ -z "$BASE" ]; then
    say "  no blob match -- falling back to the last commit before the posting date"
    BASE=$(git -C "$T" rev-list -1 --before=2026-02-06 HEAD 2>/dev/null || true)
fi
[ -n "$BASE" ] || { say "  could not determine a base commit"; exit 1; }

say "  base: $(git -C "$T" log -1 --format='%h %ad %s' --date=short "$BASE")"

# How good is this base? Score every file, so a partial match is visible up
# front rather than as a mystery conflict three patches in.
ok=0; bad=0
for f in $(printf '%s\n' "${!PRE[@]}" | sort); do
    got=$(git -C "$T" rev-parse "$BASE:$f" 2>/dev/null || echo "<absent>")
    case "$got" in
        "${PRE[$f]}"*) printf '    %-16s match\n'  "$f"; ok=$((ok+1)) ;;
        *)             printf '    %-16s DRIFT (%s)\n' "$f" "${got:0:8}"; bad=$((bad+1)) ;;
    esac
done
say "  blobs matching: $ok   drifted: $bad"
[ "$bad" -eq 0 ] || say "  NOTE: a drifted file may still apply; --3way is given the real base."

git -C "$T" checkout -q "$BASE"

# ----------------------------------------------------------------- apply
for p in "$P"/000*.patch; do
    say "  applying $(basename "$p")"
    # Capture rather than pipe: `git apply | sed` would report sed's status.
    if out=$(git -C "$T" apply --3way "$p" 2>&1); then
        printf '%s\n' "$out" | sed 's/^/      /'
    elif out2=$(git -C "$T" apply "$p" 2>&1); then
        printf '%s\n' "$out2" | sed 's/^/      /'
    else
        printf '%s\n' "$out"  | sed 's/^/      /'
        say "  FAILED on $(basename "$p")"
        say "  --- the tree where the patch expected something else ---"
        git -C "$T" apply --check -v "$p" 2>&1 | tail -20 | sed 's/^/      /' || true
        exit 1
    fi
done

say "  applied cleanly on top of ${BASE:0:8}"
[ -f "$T/arm64-tok.h" ] || { say "  arm64-tok.h missing after apply"; exit 1; }
