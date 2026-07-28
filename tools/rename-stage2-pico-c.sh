#!/bin/sh
# Rename stage 2 from "pico-c" to "pico-c".
#
# WHY A SCRIPT AND NOT AN OVERLAY. A zip cannot move or delete files, and this
# moves a directory, a source file and an archived workflow. Everything else is
# a mechanical substitution across 35 files, which is also better done by a rule
# than by shipping 35 near-identical copies.
#
# WHY THE RENAME. Stage 3 is going to be called micro-c, and stage 2 was
# "pico-c" -- which read backwards, because micro is SMALLER than mini while
# stage 3 is the MORE capable compiler. pico-c -> micro-c ascends properly.
#
# SAFE FOR THE COMMITTED BINARY. spikes/stage0-as/stage0-as.aarch64.s mentions
# stage2-pico-c.s1 exactly once, on line 973, in a COMMENT. The round-trip diff
# strips comments, so no byte of stage0-as moves and no baseline changes. That
# was checked, not assumed -- a rename that moved the seed would need the
# two-commit dance and a LADDER-BASELINE update in the same change.
#
#   usage:  sh tools/rename-stage2-pico-c.sh          (from the repo root)
#
# Idempotent: running it twice is a no-op.
set -eu

[ -d spikes ] || { echo "run this from the repo root"; exit 1; }

if [ ! -d spikes/stage2-pico-c ] && [ -d spikes/stage2-pico-c ]; then
    echo "  already renamed -- nothing to do"
    exit 0
fi

mv_it() {   # mv_it <from> <to>
    [ -e "$1" ] || return 0
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git mv "$1" "$2"
    else
        mv "$1" "$2"
    fi
    echo "    $1 -> $2"
}

echo "  moving paths:"
mv_it spikes/stage2-pico-c spikes/stage2-pico-c
mv_it spikes/stage2-pico-c/stage2-pico-c.s1 spikes/stage2-pico-c/stage2-pico-c.s1
mv_it .github/workflows-archive/stage2-pico-c-demo.yml \
      .github/workflows-archive/stage2-pico-c-demo.yml

echo "  rewriting references:"
# Order matters: the longer, more specific form first, so the general rule
# below cannot half-rewrite a path it has already handled.
#
# --exclude .git and __pycache__: one is not ours to rewrite, the other is
# generated and will be regenerated wrong-then-right on the next import.
files=$(grep -rl -e 'stage2-pico-c' -e 'pico-c' -e 'pico c' . \
        --exclude-dir=.git --exclude-dir=__pycache__ 2>/dev/null || true)

n=0
for f in $files; do
    [ -f "$f" ] || continue
    case "$f" in *.pyc) continue ;; esac
    sed -i \
        -e 's/stage2-pico-c/stage2-pico-c/g' \
        -e 's/stage2_pico_c/stage2_pico_c/g' \
        -e 's/pico-c/pico-c/g' \
        -e 's/pico c/pico c/g' \
        -e 's/Pico-C/Pico-C/g' \
        -e 's/PICO-C/PICO-C/g' \
        "$f"
    n=$((n + 1))
done
echo "    rewrote $n file(s)"

echo "  remaining references (expect none):"
if grep -rn -e 'stage2-pico-c' -e 'pico-c' . \
     --exclude-dir=.git --exclude-dir=__pycache__ 2>/dev/null | grep -v '\.pyc:'; then
    echo "  WARNING: the above still mention pico-c"
    exit 1
fi
echo "    none"

echo
echo "  stage 2 is now pico-c. Stage 3, when it exists, is micro-c:"
echo "    pico < micro, so the ladder reads as ascending capability."
