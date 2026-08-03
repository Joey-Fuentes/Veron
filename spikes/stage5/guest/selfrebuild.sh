#!/bin/sh
# selfrebuild.sh -- the tier-1 claim, made literal.
#
# STAGE5.md: "A system that rebuilds itself, on itself, from source, closes
# the loop this project is about." Until now that was true of the runner, not
# of the system. This runs INSIDE the booted image: it rebuilds every package
# from the pinned sources using only the toolchain that shipped in the image,
# and compares the result byte for byte against what the runner produced.
#
# IT IS TWO PROOFS AT ONCE, and the second is the one that is easy to miss:
#
#   1. SELF-HOSTING -- the system built these packages using only itself.
#   2. REPRODUCIBILITY ACROSS GENUINELY DIFFERENT ENVIRONMENTS. Two runs on
#      one runner is a weak diversity check. A runner build and an in-guest
#      build agreeing is a strong one: different kernel, different filesystem,
#      different PID 1, emulated CPU -- same bytes.
#
# PATHS ARE DELIBERATELY IDENTICAL TO THE RUNNER'S. gcc records the build
# directory in DWARF (DW_AT_comp_dir), so building in /tmp/build here and
# /build there would differ for a reason that has nothing to do with the
# question being asked. /build and /dest are tmpfs mounts at the same paths
# the runner used.
#
# A DIFFERENCE HERE IS A FINDING, NOT A FAILURE OF THE IDEA. At n=2 packages
# it is debuggable; at n=150 it would not be, which is the argument for doing
# this now.

set -u

VERON=/veron
EXPECT="$VERON/expected/files.tsv"

echo "VERON-SELFREBUILD begin"

[ -d "$VERON" ] || { echo "VERON-SELFREBUILD-SKIP  no /veron payload"; exit 0; }
[ -s "$EXPECT" ] || { echo "VERON-SELFREBUILD-SKIP  no expected manifest"; exit 0; }

# CHECK, DO NOT WORK AROUND. Every tool below is confirmed present in the
# published sysroot; if one goes missing the honest response is to say which,
# not to substitute something and produce a result that means less.
for t in gcc make tar cmp diff sed wc head mount; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "VERON-SELFREBUILD-FAIL  the image has no $t"; exit 1; }
done

PY=
for c in /usr/bin/python3 /usr/bin/python3.14 /usr/bin/python3.13; do
    [ -x "$c" ] && { PY=$c; break; }
done
[ -n "$PY" ] || { echo "VERON-SELFREBUILD-FAIL  no python3 in the image"; exit 1; }
echo "  python: $PY"
echo "  gcc:    $(/usr/bin/gcc --version 2>/dev/null | head -1)"

# Writable scratch at the SAME paths the runner used.
for d in /build /dest /out; do
    mkdir -p "$d" 2>/dev/null
    mount -t tmpfs -o size=768m none "$d" 2>/dev/null \
        || { echo "VERON-SELFREBUILD-FAIL  could not mount tmpfs on $d"; exit 1; }
done

cd "$VERON" || exit 1
echo "  --- rebuilding, using only what shipped in this image ---"
if ! "$PY" tools/veron --dl "$VERON/dl" --build-dir /build --dest /dest \
        --logs /out --out /out build; then
    echo "VERON-SELFREBUILD-FAIL  the build did not complete in the guest"
    exit 1
fi

if ! "$PY" tools/veron --dest /dest --out /out manifest; then
    echo "VERON-SELFREBUILD-FAIL  could not manifest the rebuilt tree"
    exit 1
fi

echo "  --- comparing against the runner's manifest ---"
# Per-file, so a mismatch names the file rather than just failing a hash.
if cmp -s "$EXPECT" /out/files.tsv; then
    N=$(cut -f2 /out/files.tsv | sort -u | wc -l)
    # THE COUNT IS IN THE MARKER. "the system rebuilt itself" overstates what
    # two small packages prove; "2/2 packages" is honest at every value of n
    # and needs no rewording when the set is 60. The toolchain itself came
    # from stage 4 and is a declared input, not something this rebuilds.
    echo "  $(wc -l < /out/files.tsv) files identical across $N package(s)"
    echo "VERON-SELFREBUILD-OK  $N/$N packages rebuilt in the image, byte-identical"
    exit 0
fi

echo "  DIFFERENCES:"
# Both files are "path<TAB>pkg<TAB>kind<TAB>value", sorted.
diff "$EXPECT" /out/files.tsv 2>/dev/null | head -40 | sed 's/^/    /'
echo ""
echo "  Read this narrowly. A difference does NOT mean the system cannot"
echo "  rebuild itself -- it means some byte depends on the environment, and"
echo "  the environment differs on purpose. Likely candidates, in order:"
echo "    - a path or hostname captured at build time"
echo "    - a timestamp the recipe does not pin"
echo "    - locale or CPU feature detection"
echo "  Each one is either fixed or declared in policy/expected-differences.toml."
echo "VERON-SELFREBUILD-DIFF"
exit 1
