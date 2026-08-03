#!/bin/sh
# sysroot-trim.sh -- cut the published sysroot to what stage 5 needs.
#
# DEFAULT OFF. Nothing runs unless VERON_TRIM=1. Run sysroot-inventory.sh
# first, read it, then enable. Every cut has its own switch because they fail
# differently and a failure has to be attributable to one of them.
#
# WHAT THIS OPERATES ON. Point it at a RESTORED COPY of the sysroot, not at
# the live tree inside the box. Every cut below is about what gets PUBLISHED,
# not about what the build needs while it runs -- those are different
# questions and conflating them is how /tools got mistaken for leftovers.
#
# WHY EACH CUT IS SAFE, stated once:
#
#   /tools, prefix     phase A's cross toolchain. LOAD-BEARING DURING THE
#                      BUILD -- phase B deliberately runs with PATH lacking
#                      /tools/bin, which is what makes "built by the final
#                      compiler" enforced by the sandbox rather than asserted.
#                      That also means phase B has ALREADY PROVEN it needs
#                      nothing from there: every green run is the experiment.
#                      It has no role after the build, so it should not be in
#                      the artifact stage 5 consumes -- if it were, stage 5
#                      would have access to a toolchain phase B was denied.
#   cross triplet      a SECOND, genuinely separate build of gcc 15.2.0, not
#                      a copy: cc1 is 378.7 MB against 379.3, none of the
#                      pairs byte-identical. Independent, so removing one
#                      touches nothing the other needs. Also a detection
#                      hazard: a triplet-prefixed gcc on PATH is how configure
#                      silently decides it is cross-compiling.
#   lto-dump           an LTO *debugging* tool. Nothing builds with it.
#   debug info         measured at 88-89% of cc1/cc1plus/lto1 by readelf.
#   libpython*.a       static embedding of the interpreter. Python itself is
#                      load-bearing for stage 5 and STAYS; this is only the
#                      library for linking CPython INTO another binary, which
#                      nothing in the package set does.
#
# NOT DONE HERE, DELIBERATELY: the lfs -> sysroot rename. It touches a 267 KB
# script, a 67 KB script, the workflow and a cache key, and bundling a wide
# mechanical rename with a behaviour change means a failure cannot be
# attributed to either. Separate commit, no behaviour change, provable diff.

set -u

ROOT=${1:-/}
LOG=${TRIM_LOG:-/out/trim.txt}
NATIVE=${NATIVE_TRIPLET:-aarch64-unknown-linux-gnu}
CROSS=${CROSS_TRIPLET:-aarch64-veron-linux-gnu}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG"
emit() { printf '%s\n' "$*" | tee -a "$LOG"; }
sz()   { du -s "$1" 2>/dev/null | awk '{print $1*1024}'; }
mb()   { awk -v b="$1" 'BEGIN{printf "%.0f", b/1048576}'; }

BEFORE=$(sz "$ROOT")
emit "VERON SYSROOT TRIM"
emit "  root:   $ROOT"
emit "  before: $(mb "$BEFORE") MB"

if [ "${VERON_TRIM:-0}" != 1 ]; then
    emit ""
    emit "  VERON_TRIM is not 1 -- MEASURING ONLY, nothing removed."
    emit "VERON-TRIM-SKIPPED"
    exit 0
fi

# Sub-switches. All default ON once VERON_TRIM=1; set any to 0 to isolate.
T_BUILD=${TRIM_BUILD_TREES:-1}
T_CROSS=${TRIM_CROSS:-1}
T_LTODUMP=${TRIM_LTO_DUMP:-1}
T_STRIP=${TRIM_STRIP:-1}
T_ARCHIVES=${TRIM_STRIP_ARCHIVES:-1}
T_PYSTATIC=${TRIM_PYTHON_STATIC:-1}

report() { # $1 label, $2 bytes-before-this-cut
    now=$(sz "$ROOT")
    emit "    -> $(mb $(( $2 - now ))) MB removed by $1  (now $(mb "$now") MB)"
}

# ------------------------------------------------------------ safety gates
emit ""
emit "  --- safety gates ---"
UNSAFE=0

# Runtime libraries are NOT scaffolding. If one resolves into the cross tree,
# removing that tree kills every dynamically linked binary in the sysroot,
# including the tools needed to work out why.
for lib in libgcc_s.so.1 libstdc++.so.6 libatomic.so.1 libgomp.so.1; do
    p="$ROOT/usr/lib/$lib"
    # -e follows symlinks, so a DANGLING link -- exactly the case worth
    # catching -- tests false. -L catches it.
    { [ -e "$p" ] || [ -L "$p" ]; } || continue
    if [ -L "$p" ]; then
        tgt=$(readlink "$p")
        printf '    %-22s -> %s\n' "$lib" "$tgt" | tee -a "$LOG"
        case "$tgt" in *"$CROSS"*) emit "      UNSAFE: into the cross tree"; UNSAFE=1 ;; esac
    else
        printf '    %-22s regular file (safe)\n' "$lib" | tee -a "$LOG"
    fi
done

# THE LTO PLUGIN. We are KEEPING lto1, so this matters: ld finds
# liblto_plugin.so by a path containing the triplet. If it resolves through
# the cross tree, removing that tree breaks -flto links in a way that reads
# as a linker bug rather than a missing file.
for d in "$ROOT/usr/lib/gcc/$NATIVE/"*/liblto_plugin.so; do
    [ -e "$d" ] && { emit "    liblto_plugin.so present under $NATIVE (safe)"; break; }
done
for d in "$ROOT/usr/lib/bfd-plugins/"*; do
    [ -e "$d" ] || continue
    tgt=$(readlink "$d" 2>/dev/null || echo "$d")
    case "$tgt" in
        *"$CROSS"*) emit "    UNSAFE: bfd-plugins entry into the cross tree: $d"; UNSAFE=1 ;;
    esac
done

# .la FILES: libtool archives hardcode toolchain paths, and they fail late
# and confusingly. But the check has to distinguish two cases that the first
# version of it did not:
#
#   INSIDE a tree that is being removed  -- harmless. The .la goes with it.
#   OUTSIDE, pointing IN                 -- the real hazard.
#
# Counting all of them and refusing was a false-positive generator: /tools is
# entirely the cross toolchain, so every .la in it naturally names the cross
# triplet. Naming the files matters as much as counting them -- "5 reference
# the cross tree" is not actionable, and a gate nobody can act on gets forced
# past, which is worse than no gate.
LA_ALL=$(find "$ROOT" -name '*.la' 2>/dev/null | wc -l)
emit "    $LA_ALL .la files present"

# The loop below runs in a subshell (it is fed by a pipe), so a variable set
# inside it does not survive. A flag file is the portable way to get one bit
# back out.
TMPFLAG=${TMPDIR:-/tmp}/trim-la.$$
: > "$TMPFLAG"

# Which trees are actually going away this run?
DOOMED=""
[ "$T_BUILD" = 1 ] && DOOMED="$DOOMED $ROOT/tools $ROOT/prefix"
[ "$T_CROSS" = 1 ] && DOOMED="$DOOMED $ROOT/usr/libexec/gcc/$CROSS $ROOT/usr/lib/gcc/$CROSS $ROOT/usr/$CROSS"

is_doomed() {
    for d in $DOOMED; do
        case "$1" in "$d"/*|"$d") return 0 ;; esac
    done
    return 1
}

la_bad=0
find "$ROOT" -name '*.la' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    grep -q "$CROSS" "$f" 2>/dev/null || continue
    if is_doomed "$f"; then
        printf '      ok   %-50s (inside a removed tree)\n' "${f#$ROOT}" | tee -a "$LOG"
    else
        printf '      BAD  %s\n' "${f#$ROOT}" | tee -a "$LOG"
        # Show WHAT it points at -- the actionable part.
        grep -o "[^ '\"]*$CROSS[^ '\"]*" "$f" 2>/dev/null | sort -u | head -4 \
          | sed 's/^/             -> /' | tee -a "$LOG"
        echo bad >> "$TMPFLAG"
    fi
done
[ -s "$TMPFLAG" ] && la_bad=1
rm -f "$TMPFLAG" 2>/dev/null || true
if [ "$la_bad" = 1 ]; then
    emit "      UNSAFE: .la files OUTSIDE the removed trees point INTO them"
    UNSAFE=1
else
    emit "      no .la file outside a removed tree references $CROSS"
fi

if [ "$UNSAFE" = 1 ] && [ "${VERON_TRIM_FORCE:-0}" != 1 ]; then
    emit ""
    emit "  REFUSING. Something the sysroot needs points into a tree about to"
    emit "  be removed. That is a finding -- fix where it is installed rather"
    emit "  than forcing past it. VERON_TRIM_FORCE=1 to see what breaks."
    emit "VERON-TRIM-REFUSED"
    exit 0
fi

# ------------------------------------------------------------ 1 build trees
if [ "$T_BUILD" = 1 ]; then
    emit ""
    emit "  --- build-time trees (published artifact only) ---"
    b=$(sz "$ROOT")
    for d in "$ROOT/tools" "$ROOT/prefix"; do
        [ -d "$d" ] || continue
        emit "    rm $d  ($(mb "$(sz "$d")") MB)"
        rm -rf "$d"
    done
    report "build trees" "$b"
fi

# ------------------------------------------------------------ 2 cross triplet
if [ "$T_CROSS" = 1 ]; then
    emit ""
    emit "  --- cross triplet: $CROSS ---"
    b=$(sz "$ROOT")
    for d in "$ROOT/usr/libexec/gcc/$CROSS" "$ROOT/usr/lib/gcc/$CROSS" \
             "$ROOT/usr/$CROSS"; do
        [ -d "$d" ] && { emit "    rm $d ($(mb "$(sz "$d")") MB)"; rm -rf "$d"; }
    done
    # The triplet-prefixed drivers in /usr/bin are the detection hazard.
    for f in "$ROOT"/usr/bin/"$CROSS"-*; do
        [ -e "$f" ] && { emit "    rm ${f#$ROOT}"; rm -f "$f"; }
    done
    report "cross triplet" "$b"
fi

# ------------------------------------------------------------ 3 lto-dump
if [ "$T_LTODUMP" = 1 ]; then
    emit ""
    emit "  --- lto-dump (LTO debugging tool; lto1 itself is KEPT) ---"
    b=$(sz "$ROOT")
    for f in "$ROOT"/usr/bin/lto-dump "$ROOT"/usr/bin/*-lto-dump; do
        [ -e "$f" ] && { emit "    rm ${f#$ROOT} ($(mb "$(wc -c < "$f")") MB)"; rm -f "$f"; }
    done
    report "lto-dump" "$b"
fi

# ------------------------------------------------------------ 4 python static
if [ "$T_PYSTATIC" = 1 ]; then
    emit ""
    emit "  --- static libpython (the interpreter and stdlib STAY) ---"
    b=$(sz "$ROOT")
    find "$ROOT/usr/lib" -name 'libpython*.a' 2>/dev/null | while IFS= read -r f; do
        emit "    rm ${f#$ROOT} ($(mb "$(wc -c < "$f")") MB)"
        rm -f "$f"
    done
    report "static libpython" "$b"
    emit "    NOTE: the two copies were NOT hardlinked, which upstream intends."
    emit "    Dropping them makes this instance moot but not the cause -- ld"
    emit "    and ld.bfd appear four times in /tools with the same shape."
fi

# ------------------------------------------------------------ 5 strip
STRIP=$(command -v strip 2>/dev/null || echo "$ROOT/usr/bin/strip")
if [ "$T_STRIP" = 1 ] && [ -x "$STRIP" ]; then
    emit ""
    emit "  --- strip executables (--strip-debug, keeps the symbol table) ---"
    emit "  strip output is deterministic for a pinned binutils, so this does"
    emit "  not undermine reproducibility -- but it IS a declared derived step"
    emit "  with before/after hashes, not a silent shrink. The unstripped tree"
    emit "  stays in the cache for debugging."
    b=$(sz "$ROOT")
    find "$ROOT/usr/bin" "$ROOT/usr/sbin" "$ROOT/usr/libexec" -type f -size +512k 2>/dev/null \
      | LC_ALL=C sort | while IFS= read -r f; do
        case "$f" in *.py|*.sh|*.pl) continue ;; esac
        head -c4 "$f" 2>/dev/null | od -An -c 2>/dev/null | grep -q 'E   L   F' || continue
        s1=$(wc -c < "$f"); h1=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
        "$STRIP" --strip-debug "$f" 2>/dev/null || continue
        s2=$(wc -c < "$f"); h2=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
        [ "$s2" -lt "$s1" ] || continue
        printf '    %-46s %5s -> %-5s MB\n' "${f#$ROOT}" "$(mb "$s1")" "$(mb "$s2")" | tee -a "$LOG"
        printf '      was %s\n      now %s\n' "$h1" "$h2" >> "$LOG"
    done
    report "strip executables" "$b"
fi

# ------------------------------------------------------------ 6 archives
if [ "$T_ARCHIVES" = 1 ] && [ -x "$STRIP" ]; then
    emit ""
    emit "  --- strip static archives (.a) ---"
    emit "  --strip-debug ONLY, never --strip-all: the linker needs the symbol"
    emit "  table and --strip-all would remove it, breaking every -static link"
    emit "  in a way that surfaces much later than this step. -D keeps archive"
    emit "  members deterministic (zeroed member timestamps/uids)."
    emit "  Separable: TRIM_STRIP_ARCHIVES=0 if anything downstream objects."
    b=$(sz "$ROOT")
    find "$ROOT/usr/lib" -name '*.a' -size +512k 2>/dev/null | LC_ALL=C sort \
      | while IFS= read -r f; do
        s1=$(wc -c < "$f")
        "$STRIP" -D --strip-debug "$f" 2>/dev/null || continue
        s2=$(wc -c < "$f")
        [ "$s2" -lt "$s1" ] || continue
        printf '    %-46s %5s -> %-5s MB\n' "${f#$ROOT}" "$(mb "$s1")" "$(mb "$s2")" | tee -a "$LOG"
    done
    report "strip archives" "$b"
fi

# ------------------------------------------------------------ result
AFTER=$(sz "$ROOT")
emit ""
emit "  ============================================================"
emit "  before: $(mb "$BEFORE") MB"
emit "  after:  $(mb "$AFTER") MB"
emit "  saved:  $(mb $(( BEFORE - AFTER ))) MB"
emit "  ============================================================"
emit "VERON-TRIM-OK"
