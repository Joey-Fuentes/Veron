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
CROSS=${CROSS_TRIPLET:-aarch64-toolchain-linux-gnu}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG"
emit() { printf '%s\n' "$*" | tee -a "$LOG"; }
sz()   { du -s "$1" 2>/dev/null | awk '{print $1*1024}'; }
mb()   { awk -v b="$1" 'BEGIN{printf "%.0f", b/1048576}'; }

TMPERR=${TMPDIR:-/tmp}/trim-err.$$
TMPFAIL=${TMPDIR:-/tmp}/trim-fail.$$
: > "$TMPFAIL"

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
TMPSTALE=${TMPDIR:-/tmp}/trim-stale.$$
: > "$TMPFLAG"
: > "$TMPSTALE"

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
        printf '      ok    %-48s (inside a removed tree)\n' "${f#$ROOT}" | tee -a "$LOG"
        continue
    fi
    # THREE OUTCOMES, NOT TWO. Matching the triplet STRING is not the same as
    # referencing a path we are about to remove -- the first version conflated
    # them and reported three files as blockers when they were something else
    # entirely. Classify each referenced path:
    #
    #   BAD    resolves under $ROOT into a tree being removed -- a real blocker
    #   STALE  does not exist in the sysroot at all -- typically a leftover
    #          BUILD-DIRECTORY path (libtool keeps -L entries from the build
    #          tree when a library is not relinked at install). Already broken
    #          before any trim, so it is a separate bug, not a reason to stop.
    bad_here=0; stale_here=0
    for ref in $(grep -o "[^ '\"]*$CROSS[^ '\"]*" "$f" 2>/dev/null | sed 's/^-L//' | sort -u); do
        case "$ref" in /*) ;; *) continue ;; esac
        if [ -e "$ROOT$ref" ] || [ -e "$ref" ]; then
            if is_doomed "$ROOT$ref"; then
                printf '      BAD   %s\n             -> %s (in a removed tree)\n' \
                    "${f#$ROOT}" "$ref" | tee -a "$LOG"
                bad_here=1
            fi
        else
            printf '      STALE %s\n             -> %s (does not exist)\n' \
                "${f#$ROOT}" "$ref" | tee -a "$LOG"
            stale_here=1
        fi
    done
    [ "$bad_here" = 1 ] && echo bad >> "$TMPFLAG"
    [ "$stale_here" = 1 ] && echo stale >> "$TMPSTALE"
done
[ -s "$TMPFLAG" ] && la_bad=1
STALE_N=$( [ -f "$TMPSTALE" ] && wc -l < "$TMPSTALE" || echo 0 )
rm -f "$TMPFLAG" "$TMPSTALE" 2>/dev/null || true
if [ "$STALE_N" -gt 0 ]; then
    emit "      $STALE_N .la reference(s) point at paths that DO NOT EXIST."
    emit "      Not a trim blocker -- they were already dangling. Usually"
    emit "      libtool keeping build-tree -L entries through install."
fi
if [ "$la_bad" = 1 ]; then
    emit "      UNSAFE: .la files OUTSIDE the removed trees point INTO them"
    UNSAFE=1
else
    emit "      no .la file outside a removed tree points into one"
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

# ------------------------------------------------------------ 4b libcc1
if [ "${TRIM_LIBCC1:-1}" = 1 ]; then
    emit ""
    emit '  --- libcc1 (gdb compile-in-context support) ---'
    emit "  libcc1, libcc1plugin and libcp1plugin exist so gdb can compile code"
    emit "  in the debuggee's context. Nothing else links them, and gdb is not"
    emit "  in the package set. Their .la files are ALSO the ones carrying"
    emit "  stale /work/b-gcc2 build paths, so they are broken as well as"
    emit "  unused -- dropping them removes the defect rather than fixing a"
    emit "  path nothing reads."
    b=$(sz "$ROOT")
    for f in "$ROOT"/usr/lib/libcc1.* \
             "$ROOT"/usr/lib/gcc/*/*/plugin/libcc1plugin.* \
             "$ROOT"/usr/lib/gcc/*/*/plugin/libcp1plugin.*; do
        [ -e "$f" ] || continue
        emit "    rm ${f#$ROOT}"
        rm -f "$f"
    done
    report "libcc1" "$b"
fi

# ------------------------------------------------------------ 5 strip
# WHICH strip, AND DOES IT ACTUALLY WORK.
#
# The first version took `command -v strip` and fell back to the sysroot's,
# then swallowed every failure with `|| continue`. On an x86_64 runner that
# meant the host's x86_64 strip could not read an aarch64 ELF, every single
# file failed, and the step reported "0 MB removed" with no error at all --
# the ~1 GB cut silently did nothing. A cut that cannot fail loudly is worse
# than no cut.
#
# PREFER THE SYSROOT'S OWN strip. This runs on a native aarch64 runner, so
# our binutils executes directly. That matters beyond convenience: stripping
# rewrites artifact bytes, so the tool doing it belongs to the chain being
# recorded, not to the host.
STRIP=""
STRIP_WRAP=""
# CANDIDATE 1: the sysroot's OWN strip, run under bwrap with the sysroot as /.
#
# Running it directly does not work and the reason is worth stating: its
# PT_INTERP is /lib/ld-linux-aarch64.so.1, which from outside resolves against
# the RUNNER's root, so it loads the runner's glibc rather than the one it was
# built against. Inside bwrap the path resolves to the sysroot's own loader.
#
# This matters beyond convenience. Stripping REWRITES ARTIFACT BYTES, so the
# tool doing it should belong to the chain being recorded. "our binutils
# stripped this" and "Ubuntu's binutils stripped this" are different
# provenance claims, and only the first one is ours to make.
if command -v bwrap >/dev/null 2>&1 && [ -x "$ROOT/usr/bin/strip" ]; then
    STRIP_WRAP="bwrap --die-with-parent --bind $ROOT / --proc /proc --dev /dev --tmpfs /tmp --setenv PATH /usr/bin:/bin --chdir /"
fi

try_strip() { # $1 = probe file path relative to ROOT
    if [ -n "$STRIP_WRAP" ]; then
        $STRIP_WRAP /usr/bin/strip --strip-debug "$1" 2>/dev/null
    else
        return 1
    fi
}

for cand in OWN "$(command -v strip 2>/dev/null || true)"; do
    [ "$cand" = OWN ] || { [ -n "$cand" ] && [ -x "$cand" ]; } || continue
    [ "$cand" = OWN ] && [ -z "$STRIP_WRAP" ] && continue
    # PROBE IT on a real file from this sysroot rather than trusting that it
    # exists. Wrong architecture, missing loader and wrong binutils version
    # all present as "exists and is executable".
    probe=$(find "$ROOT/usr/bin" -type f -size +512k 2>/dev/null | head -1)
    [ -n "$probe" ] || continue
    cp "$probe" "$ROOT/.strip-probe" 2>/dev/null || continue
    b=$(wc -c < "$ROOT/.strip-probe")
    if [ "$cand" = OWN ]; then
        try_strip /.strip-probe
    else
        "$cand" --strip-debug "$ROOT/.strip-probe" 2>/dev/null
    fi
    if [ "$(wc -c < "$ROOT/.strip-probe")" -lt "$b" ]; then
        rm -f "$ROOT/.strip-probe"
        if [ "$cand" = OWN ]; then
            STRIP=OWN
            emit ""
            emit "  strip: the sysroot's own /usr/bin/strip, under bwrap (probed OK)"
            emit "         our binutils rewrites the bytes, not the host's"
        else
            STRIP="$cand"
            emit ""
            emit "  strip: $cand (probed OK)"
            emit "         NOTE: this is a HOST tool rewriting artifact bytes."
            emit "         The sysroot's own strip is preferred and was not usable."
        fi
        break
    fi
    rm -f "$ROOT/.strip-probe"
    emit "  strip candidate rejected: $cand (probe did not shrink a test file)"
done

do_strip() { # $1 = extra args ... last arg = file
    if [ "$STRIP" = OWN ]; then
        f=$1; shift 2>/dev/null || true
        $STRIP_WRAP /usr/bin/strip "$@" "${f#$ROOT}"
    else
        "$STRIP" "$@"
    fi
}
if [ -z "$STRIP" ] && { [ "$T_STRIP" = 1 ] || [ "$T_ARCHIVES" = 1 ]; }; then
    emit ""
    emit "  NO WORKING strip FOUND, and stripping is the largest single cut"
    emit "  (88-89% of cc1/cc1plus/lto1 measured by readelf). Refusing to"
    emit "  report a size that silently omits ~1 GB of it."
    emit "  On an x86_64 runner the host strip cannot read aarch64 ELF -- this"
    emit "  job belongs on ubuntu-24.04-arm."
    emit "VERON-TRIM-NO-STRIP"
    exit 1
fi
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
        chmod u+w "$f" 2>/dev/null || true
        if ! do_strip "$f" --strip-debug 2>"$TMPERR"; then
            printf '    FAILED %-44s %s\n' "${f#$ROOT}" "$(head -1 "$TMPERR")" | tee -a "$LOG"
            echo failed >> "$TMPFAIL"
            continue
        fi
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
        chmod u+w "$f" 2>/dev/null || true
        if ! do_strip "$f" -D --strip-debug 2>"$TMPERR"; then
            printf '    FAILED %-44s %s\n' "${f#$ROOT}" "$(head -1 "$TMPERR")" | tee -a "$LOG"
            echo failed >> "$TMPFAIL"
            continue
        fi
        s2=$(wc -c < "$f")
        [ "$s2" -lt "$s1" ] || continue
        printf '    %-46s %5s -> %-5s MB\n' "${f#$ROOT}" "$(mb "$s1")" "$(mb "$s2")" | tee -a "$LOG"
    done
    report "strip archives" "$b"
fi

# ------------------------------------------------------------ result
if [ -s "$TMPFAIL" ]; then
    emit ""
    emit "  $(wc -l < "$TMPFAIL") file(s) FAILED to strip -- see FAILED lines above."
fi
rm -f "$TMPERR" "$TMPFAIL" 2>/dev/null || true

AFTER=$(sz "$ROOT")
emit ""
emit "  ============================================================"
emit "  before: $(mb "$BEFORE") MB"
emit "  after:  $(mb "$AFTER") MB"
emit "  saved:  $(mb $(( BEFORE - AFTER ))) MB"
emit "  ============================================================"
emit "VERON-TRIM-OK"
