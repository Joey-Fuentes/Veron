#!/usr/bin/env bash
# Transplant gcc 4.8.5's aarch64 backend into a gcc 4.7.4 tree.
#
#   usage: backport-aarch64.sh <gcc-4.7.4-dir> <gcc-4.8.5-dir>
#
# WHY 4.8.5's BACKEND AND NOT 4.8.0's. gcc-backend-backport-probe measured the
# backend<->middle-end interface delta with a control: the vax backend, which
# nobody was developing, needed 15 files / 76+ / 72- across 4.7.4 -> 4.8.0 --
# and the IDENTICAL delta across 4.7.4 -> 4.8.5. The interface did not move
# within the 4.8 series, so 4.8.5's backend is no further from 4.7 than 4.8.0's
# while carrying ~1800 lines of fixes to a port that was one release old.
#
# The probe also found the backend uses 0 of the 21 target hooks new in 4.8
# (with a positive control proving the search works), and that all 40 symbols
# it references which 4.7 lacks are self-supplied: 30 gen_* emitted by genemit
# from the backend's own .md files, 1 from gengtype, 9 backend-local statics.
#
# EVERY PIECE MOVED IS NAMED BELOW. A backport that quietly drags in extra is
# not a reviewed delta.

set -euo pipefail

G47=${1:?usage: backport-aarch64.sh <4.7.4 dir> <4.8.5 dir>}
G48=${2:?usage: backport-aarch64.sh <4.7.4 dir> <4.8.5 dir>}
say() { printf '%s\n' "$*"; }

say "  before: 4.7.4 has $(grep -c aarch64 "$G47/gcc/config.gcc" || true) aarch64 mentions in config.gcc"

# ---------------------------------------------------------------- directories
# Three, not one. A port lives in gcc/config/<arch> plus gcc/common/config/<arch>
# (the target-independent option handling) plus libgcc/config/<arch> (the
# runtime). Missing either of the last two is the classic way a backport
# "almost" works and then fails late.
for d in "gcc/config/aarch64" "gcc/common/config/aarch64" "libgcc/config/aarch64"; do
    if [ -d "$G48/$d" ]; then
        mkdir -p "$G47/$(dirname "$d")"
        cp -r "$G48/$d" "$G47/$(dirname "$d")/"
        say "    copied $d ($(ls -1 "$G48/$d" | wc -l) files)"
    else
        say "    NOTE: 4.8.5 has no $d"
    fi
done

# ------------------------------------------------------------- data files
# config.sub and config.guess are standalone data files with no gcc coupling;
# replacing them wholesale is what gcc itself does when it syncs from
# config-patches. This is the only reason 4.7 cannot even NAME the target.
for f in config.sub config.guess; do
    cp "$G48/$f" "$G47/$f"
    # cp over an EXISTING file keeps the destination's mode, so a non-executable
    # placeholder would silently stay non-executable and configure would fail
    # with "Permission denied" much later.
    chmod +x "$G47/$f"
    say "    $f <- 4.8.5 ($(grep -c aarch64 "$G47/$f") aarch64 mentions)"
done

# ------------------------------------------------------------- case arms
# Extracted from 4.8.5 rather than hand-written, so what lands is exactly what
# upstream says. A hand-written stanza is a place to introduce a difference
# nobody reviews.
splice() {   # $1 = relative path, $2 = "case ${x} in" anchor
    python3 - "$G48/$1" "$G47/$1" "$2" <<'PY'
import re, sys
srcf, dstf, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
src, dst = open(srcf).read(), open(dstf).read()
# ^-anchored with re.M, NOT r'\n(aarch64...)'. A leading \n gets CONSUMED by
# the previous match -- it is the same newline that terminates the previous
# arm's ";;" -- so consecutive arms are silently missed and only the first is
# found. Caught by testing against a tree with two adjacent aarch64 arms.
arms = re.findall(r'^(aarch64[^\n]*\)\n(?:.*?\n)*?\t;;\n)', src, re.M)
if not arms:
    print(f"    {dstf}: NO aarch64 case arms found in 4.8.5 -- check the pattern")
    sys.exit(0)
i = dst.find(anchor)
if i == -1:
    print(f"    {dstf}: anchor {anchor!r} not found -- not spliced")
    sys.exit(0)
j = i + len(anchor)
open(dstf, 'w').write(dst[:j] + "".join(arms) + dst[j:])
print(f"    {dstf}: spliced {len(arms)} aarch64 case arm(s)")
PY
}
splice gcc/config.gcc     '
case ${target} in
'
splice libgcc/config.host '
case ${host} in
'

say "  after : 4.7.4 has $(grep -c aarch64 "$G47/gcc/config.gcc" || true) aarch64 mentions in config.gcc"
say "  target recognised: $(cd "$G47" && ./config.sub aarch64-unknown-linux-gnu 2>&1)"
