#!/bin/sh
# stages/3-micro-c/adopt.sh -- ONE-TIME: turn the pin-true in/3 inputs into
# committed Veron source, per design D2: micro-c and its lineage live
# in-tree in FINAL FORM; upstream and patch notions end at adoption. After
# this commit, build.sh reads only the repo (tcc stays the sole
# pin+one-patch exception) and the in/ phase stops fetching anything.
#
# Run AFTER a pin-true `build.sh in` (it refuses otherwise):
#     sh stages/3-micro-c/build.sh in
#     sh stages/3-micro-c/adopt.sh
#     git add -A && git commit && git push
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do
  ROOT="$(dirname "$ROOT")"; done
cd "$ROOT"
IN="$ROOT/in/3"
[ -f "$IN/PIN-TRUE" ] && [ "$(cat "$IN/PIN-TRUE")" = yes ] || {
  echo "FAIL: in/3 is not a pin-true materialization -- run build.sh in"
  echo "      with network until no PIN-FALLBACK line prints."; exit 1; }

say() { printf '%s\n' "$*"; }
rec() { printf '  %-40s %8s bytes  %s\n' "$1" "$(wc -c < "$2")" \
        "$(sha256sum "$2" | cut -c1-16)"; }

say "== adopt: the unit prologue (ours, final form) =="
cp "$IN/patched_bootstrap.c" "$HERE/bootstrap.c"
rec 'bootstrap.c' "$HERE/bootstrap.c"
# the M2libc dir was removed at micro-c adoption (empty submodule
# mountpoint); recreate it for the one file the flist names there
mkdir -p "$HERE/micro-c/M2libc"
cp "$IN/m2libc-pin/bootstrappable.c" "$HERE/micro-c/M2libc/bootstrappable.c"
rec 'micro-c/M2libc/bootstrappable.c' "$HERE/micro-c/M2libc/bootstrappable.c"

say "== adopt: the linker pair sources (rewritten, final form) =="
rm -rf "$HERE/linker-tools" && mkdir -p "$HERE/linker-tools"
cp "$IN/M1-srcs.txt" "$IN/hex2-srcs.txt" "$HERE/linker-tools/"
( cd "$IN/mescc-s2" && sort -u "$IN/M1-srcs.txt" "$IN/hex2-srcs.txt" \
  | while read -r f; do
      mkdir -p "$HERE/linker-tools/$(dirname "$f")"
      cp "$f" "$HERE/linker-tools/$f"
    done )
say "  $(find "$HERE/linker-tools" -type f | wc -l) files"

say "== adopt: our m2libc (tables + stdio the tcc compile consumes) =="
rm -rf "$HERE/m2libc" && cp -r "$IN/m2libc-veron" "$HERE/m2libc"
rm -rf "$HERE/m2libc/.git"
say "  $(find "$HERE/m2libc" -type f | wc -l) files, $(grep -c '^DEFINE' "$HERE/m2libc/aarch64/aarch64_defs.M1") DEFINEs"

MESCC_FULL=$(git -C "$IN/mescc" rev-parse HEAD 2>/dev/null || echo unknown)
M2LIBC_FULL=68a23cfd05d5a355ba7a30c770d684cbe86fcc4e
cat > "$HERE/ORIGIN-INPUTS.md" << EOD
# ORIGIN — stage 3's remaining adopted inputs (final form, ours)

Adopted per design D2 on $(date -u +%Y-%m-%d): from here on these are Veron
source; upstream and patch notions end at this commit. Recorded so
attribution and license provenance (criterion 7) hold until any rewrite.

| adopted | derived from | how |
|---|---|---|
| \`bootstrap.c\` | M2libc \`$M2LIBC_FULL\` \`aarch64/linux/bootstrap.c\` | \`tools/drop_asm.py\` (6 asm syscall bodies removed; the mini-stdio kept) |
| \`micro-c/M2libc/bootstrappable.c\` | M2libc \`$M2LIBC_FULL\` | verbatim |
| \`linker-tools/\` | mescc-tools \`$MESCC_FULL\` | upstream-makefile-derived source lists; \`max_string\` 4096→262144; \`tools/octal_to_decimal.py\`; \`tools/defines_to_enums.py\` |
| \`m2libc/\` | \`spikes/reference/m2libc\` (M2libc \`ca023d8…\`) + the \`spikes/stage3/patches/m2libc\` series | patches applied, result adopted |

Licenses: M2libc and mescc-tools are GPL-3.0-or-later; these directories
inherit that until rewritten (same rule as \`micro-c/ORIGIN.md\`).
The spike copies and patch series stay live and untouched per §7.0.
EOD
say "== ORIGIN-INPUTS.md written; sha manifest: =="
( cd "$HERE" && find bootstrap.c micro-c/M2libc/bootstrappable.c \
    linker-tools m2libc -type f | sort | xargs sha256sum ) \
  > "$HERE/ADOPTED-SHA256"
say "  $(wc -l < "$HERE/ADOPTED-SHA256") files -> ADOPTED-SHA256"
say ""
say "Now: git add -A && git commit -m 'stage 3: adopt all inputs in final form (D2); upstream ends here' && git push"
