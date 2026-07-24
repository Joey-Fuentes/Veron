#!/usr/bin/env bash
# Package the exact sources needed to test the arm64 assembler series OFF-CI.
#
#   usage: fetch-base.sh [output.tar.gz]
#
# WHAT IT PRODUCES, and why each piece is in there:
#
#   tinycc/   the tinycc worktree at the commit the series was written against,
#             found by blob hash rather than by date or ancestry (see
#             apply-series.sh for why ancestry guessing broke tccasm.c:1178).
#             With this, the series can be applied and verified anywhere.
#
#   musl-asm/ every aarch64 .s/.S file in musl 1.2.5, plus the arch headers the
#             .S files include. ~50 KB. This is the actual input that decides
#             the question -- the 20 mnemonics mob's assembler rejects all come
#             from these files.
#
# WHY THIS IS ENOUGH WITHOUT AN arm64 MACHINE. tcc's integrated assembler is
# target code, not host code. `./configure --enable-cross && make` on x86_64
# produces an `arm64-tcc` that assembles arm64 .s files exactly as a native one
# would, so the whole assembler question can be settled on any host. Only
# RUNNING the resulting objects needs aarch64.

set -euo pipefail

OUT=${1:-$HOME/tcc-arm64-asm-base.tar.gz}
KEY_FILE=tccasm.c
KEY_BLOB=523cbab0          # tccasm.c as the series' author had it
MUSL_VER=1.2.5

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
echo "  work dir: $W"

echo "  cloning tinycc ..."
git clone -q git://repo.or.cz/tinycc.git "$W/tinycc" \
  || git clone -q https://repo.or.cz/tinycc.git "$W/tinycc" \
  || git clone -q https://github.com/TinyCC/tinycc.git "$W/tinycc"

echo "  searching history for $KEY_FILE == $KEY_BLOB ..."
BASE=""
while read -r c; do
    got=$(git -C "$W/tinycc" rev-parse "$c:$KEY_FILE" 2>/dev/null) || continue
    case "$got" in "$KEY_BLOB"*) BASE=$c; break;; esac
done < <(git -C "$W/tinycc" log --all --format=%H -- "$KEY_FILE")

if [ -z "$BASE" ]; then
    echo "  NO BLOB MATCH. Falling back to the last commit before the posting date."
    BASE=$(git -C "$W/tinycc" rev-list -1 --before=2026-02-06 HEAD)
fi
echo "  base: $(git -C "$W/tinycc" log -1 --format='%H%n        %ad  %s' --date=short "$BASE")"

mkdir -p "$W/pack"
git -C "$W/tinycc" archive --prefix=tinycc/ "$BASE" | tar x -C "$W/pack"
git -C "$W/tinycc" log -1 --format='%H%n%ad%n%s' --date=iso "$BASE" > "$W/pack/tinycc-BASE.txt"

echo "  fetching musl $MUSL_VER ..."
for u in "https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz" \
         "https://ftp.barfooze.de/pub/sabotage/tarballs/musl-$MUSL_VER.tar.gz"; do
    curl -fsSL --retry 4 --connect-timeout 20 -o "$W/musl.tar.gz" "$u" && break || true
done
mkdir -p "$W/musl"
if [ -s "$W/musl.tar.gz" ]; then
    tar xf "$W/musl.tar.gz" -C "$W/musl" --strip-components=1
else
    git clone -q --depth 1 --branch "v$MUSL_VER" \
        https://git.musl-libc.org/git/musl "$W/musl" \
      || git clone -q --depth 1 --branch "v$MUSL_VER" \
           https://github.com/bminor/musl "$W/musl"
fi

mkdir -p "$W/pack/musl-asm"
( cd "$W/musl" && find . -path '*aarch64*' \( -name '*.s' -o -name '*.S' -o -name '*.h' \) \
    -exec cp --parents {} "$W/pack/musl-asm/" \; )
# crt_arch.h and syscall_arch.h are where adrp and svc actually appear
( cd "$W/musl" && cp --parents arch/aarch64/*.h "$W/pack/musl-asm/" 2>/dev/null || true )

tar czf "$OUT" -C "$W/pack" .
echo
echo "  wrote $OUT"
echo "  size  : $(du -h "$OUT" | cut -f1)"
echo "  sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "  base  : $BASE"
echo
echo "  contents:"
tar tzf "$OUT" | head -5 | sed 's/^/    /'
echo "    ... $(tar tzf "$OUT" | wc -l) entries"
