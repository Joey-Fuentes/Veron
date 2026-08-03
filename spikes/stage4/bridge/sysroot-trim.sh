#!/bin/sh
# sysroot-trim.sh -- cut the sysroot down to what stage 5 actually needs.
#
# DEFAULT OFF. Nothing here runs unless VERON_TRIM=1. Run the inventory first,
# read it, then enable this. Two changes in one run means a failure cannot be
# attributed to either, which is the lesson six-of-seven bridge runs already
# paid for.
#
# Two independent cuts, each with its own switch, because they fail
# differently:
#
#   VERON_TRIM_CROSS=1   remove the cross-triplet gcc install
#   VERON_TRIM_STRIP=1   strip debug info from the surviving binaries
#
# WHY THIS IS SAFE FOR PROVENANCE. The ledger records that gcc 15.2.0 was
# built by 10.2.0 which was built by 4.7.4, and that the cross install did its
# job. Provenance is RECORDED, not CARRIED -- the artifacts do not have to
# survive for the record to be checkable. Same reason G0's patched source
# leaves the chain immediately and the proof still holds.
#
# WHY IT IS A TEST, NOT A CLEANUP. If nothing invokes the cross triplet, then
# removing it and completing phase B proves it -- measured rather than
# asserted. If something breaks, that is the bug that should not exist, found
# now rather than at package 40 of stage 5 with the cause three layers away.
#
# ORDERING: run AFTER the full sysroot has been manifested and hashed, so the
# record covers what was built and the trim is a declared derived step with
# its own before/after hashes. Not a silent shrink.

set -u

ROOT=${1:-/}
LOG=${TRIM_LOG:-/out/trim.txt}
NATIVE=${NATIVE_TRIPLET:-aarch64-unknown-linux-gnu}
CROSS=${CROSS_TRIPLET:-aarch64-veron-linux-gnu}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG"
emit() { printf '%s\n' "$*" | tee -a "$LOG"; }

treesize() { du -s "$1" 2>/dev/null | awk '{print $1*1024}'; }

BEFORE=$(treesize "$ROOT")
emit "VERON SYSROOT TRIM"
emit "  before: $((BEFORE / 1048576)) MB"

if [ "${VERON_TRIM:-0}" != 1 ]; then
    emit ""
    emit "  VERON_TRIM is not 1 -- MEASURING ONLY, nothing removed."
    emit "  Run sysroot-inventory.sh, read it, then dispatch with trim enabled."
    emit "VERON-TRIM-SKIPPED"
    exit 0
fi

# ------------------------------------------------------------ safety first
#
# THE ONE THING THAT MUST BE CHECKED BEFORE REMOVING THE CROSS INSTALL.
# The compilers are scaffolding; the RUNTIME libraries are not. If
# libgcc_s.so.1 or libstdc++.so.6 in /usr/lib are symlinks into the cross
# tree, removing that tree takes the runtime with it and every dynamically
# linked binary in the sysroot dies -- including the tools needed to diagnose
# it.
emit ""
emit "  --- runtime library ownership ---"
UNSAFE=0
for lib in libgcc_s.so.1 libstdc++.so.6 libstdc++.so.6.0.34 libatomic.so.1 libgomp.so.1; do
    p="$ROOT/usr/lib/$lib"
    # -e FOLLOWS symlinks, so a DANGLING link -- which is precisely the case
    # worth catching, a pointer into a tree that is about to be removed or has
    # already gone -- tests false and gets skipped. -L catches it.
    { [ -e "$p" ] || [ -L "$p" ]; } || continue
    if [ -L "$p" ]; then
        tgt=$(readlink -f "$p" 2>/dev/null || readlink "$p")
        printf '    %-24s -> %s\n' "$lib" "$tgt" | tee -a "$LOG"
        case "$tgt" in
            *"$CROSS"*) emit "      UNSAFE: resolves into the cross tree"; UNSAFE=1 ;;
        esac
    else
        printf '    %-24s regular file (safe)\n' "$lib" | tee -a "$LOG"
    fi
done

# .la files hardcode toolchain paths and fail late and confusingly.
LA=$(find "$ROOT/usr" -name '*.la' 2>/dev/null | wc -l)
emit "    $LA .la files present"
if [ "$LA" -gt 0 ]; then
    n=$(grep -l "$CROSS" $(find "$ROOT/usr" -name '*.la' 2>/dev/null) 2>/dev/null | wc -l)
    emit "    $n of them reference $CROSS"
    [ "$n" -gt 0 ] && { emit "      UNSAFE: .la files point into the cross tree"; UNSAFE=1; }
fi

if [ "$UNSAFE" = 1 ] && [ "${VERON_TRIM_FORCE:-0}" != 1 ]; then
    emit ""
    emit "  REFUSING TO TRIM. Something the sysroot needs at runtime lives in"
    emit "  or points into the cross tree. That is a real finding: fix where"
    emit "  the runtime libs are installed, do not force past this."
    emit "  Override with VERON_TRIM_FORCE=1 only to see what breaks."
    emit "VERON-TRIM-REFUSED"
    exit 0
fi

# ------------------------------------------------------------ cut 1: cross
if [ "${VERON_TRIM_CROSS:-0}" = 1 ]; then
    emit ""
    emit "  --- removing the cross triplet: $CROSS ---"
    for d in "$ROOT/usr/libexec/gcc/$CROSS" "$ROOT/usr/lib/gcc/$CROSS" \
             "$ROOT/usr/$CROSS"; do
        if [ -d "$d" ]; then
            sz=$(treesize "$d")
            emit "    rm $d  ($((sz / 1048576)) MB)"
            rm -rf "$d"
        fi
    done
    # The triplet-prefixed driver binaries are the detection hazard: a
    # configure script that finds one decides it is cross-compiling.
    for f in "$ROOT"/usr/bin/"$CROSS"-*; do
        [ -e "$f" ] || continue
        emit "    rm $f"
        rm -f "$f"
    done
fi

# ------------------------------------------------------------ cut 2: strip
if [ "${VERON_TRIM_STRIP:-0}" = 1 ]; then
    emit ""
    emit "  --- stripping debug info ---"
    emit "  strip output is deterministic for a pinned binutils, so this does"
    emit "  not undermine the reproducibility claim -- but it IS a declared"
    emit "  transformation with its own before/after hashes, not a silent"
    emit "  shrink. The unstripped tree stays in the cache for debugging."
    STRIP=$(command -v strip 2>/dev/null || echo "$ROOT/usr/bin/strip")
    if [ ! -x "$STRIP" ]; then
        emit "    no strip available -- skipped"
    else
        for f in "$ROOT"/usr/libexec/gcc/*/*/cc1 \
                 "$ROOT"/usr/libexec/gcc/*/*/cc1plus \
                 "$ROOT"/usr/libexec/gcc/*/*/lto1 \
                 "$ROOT"/usr/libexec/gcc/*/*/collect2 \
                 "$ROOT"/usr/bin/*; do
            [ -f "$f" ] || continue
            case "$f" in *.sh|*.pl|*.py) continue ;; esac
            b=$(wc -c < "$f" 2>/dev/null || echo 0)
            [ "$b" -gt 1048576 ] || continue
            h1=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
            "$STRIP" --strip-debug "$f" 2>/dev/null || continue
            a=$(wc -c < "$f" 2>/dev/null || echo 0)
            h2=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
            [ "$a" -lt "$b" ] || continue
            printf '    %-52s %6s -> %-6s MB\n' \
                "${f#$ROOT}" "$((b / 1048576))" "$((a / 1048576))" | tee -a "$LOG"
            printf '      was %s\n      now %s\n' "$h1" "$h2" >> "$LOG"
        done
    fi
fi

AFTER=$(treesize "$ROOT")
emit ""
emit "  before: $((BEFORE / 1048576)) MB"
emit "  after:  $((AFTER / 1048576)) MB"
emit "  saved:  $(( (BEFORE - AFTER) / 1048576 )) MB"
emit "VERON-TRIM-OK"
