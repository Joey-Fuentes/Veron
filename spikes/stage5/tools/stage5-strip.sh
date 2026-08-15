#!/bin/sh
# stage5-strip.sh -- strip debug symbols from the merged sysroot.
#
# WHY STAGE 5 NEEDS ITS OWN. stage4/bridge/sysroot-trim.sh strips the sysroot
# it publishes, and stage 5 merges packages INTO that sysroot afterwards --
# so everything stage 5 builds lands unstripped and nothing ever strips it.
# Measured on the amd64 build: git installs 65 distinct executables at 10-18 MB
# each where a stripped git is 3-4 MB, wpewebkit ships a 162 MB library, and
# the 52 stage-5 packages over 1 MB come to 508 MB. That is the largest single
# cut available to this stage and it was simply missing.
#
# IT IS A DECLARED DERIVED STEP, NOT A SILENT SHRINK. Stripping rewrites
# artifact bytes. strip's output is deterministic for a pinned binutils, so
# reproducibility survives -- but the before and after sizes are reported and
# the failures are counted, because the whole point of the four lessons below
# is that a cut which cannot fail loudly is worse than no cut.
#
# FOUR THINGS stage 4 LEARNED THE HARD WAY, KEPT HERE RATHER THAN RELEARNED:
#
#   1. A HOST strip CANNOT READ A FOREIGN ELF, and fails per-file. The first
#      version swallowed that with `|| continue`, every file failed, and the
#      step reported "0 MB removed" with no error while ~1 GB stayed. So the
#      tool is PROBED on a real file from this tree before it is trusted, and
#      a probe that does not shrink the file rejects the candidate.
#
#   2. THE SENTINEL WAS TESTED WITH -x AND THAT SKIPPED THE WHOLE CUT.
#      STRIP=OWN means "the sysroot's own strip, under bwrap" -- a sentinel,
#      not a path -- and `[ -x "$STRIP" ]` is false for it. A run printed
#      "probed OK" and stripped nothing. strip_available() exists for that.
#
#   3. PREFER THE SYSROOT'S OWN strip. It is our binutils, from the chain
#      being recorded. "our binutils stripped this" and "the runner's binutils
#      stripped this" are different provenance claims and only the first is
#      ours to make. It needs bwrap because its PT_INTERP resolves against the
#      runner's root otherwise, loading the wrong glibc.
#
#   4. CHECK ELF MAGIC, NOT THE EXTENSION. A DESTDIR is full of scripts and
#      data; strip on a shell script is an error per file and noise in a log.
#
# --strip-debug, NOT --strip-all. The symbol table stays, so a backtrace still
# names functions; only DWARF goes. --strip-all on a shared library removes
# symbols something may still need to link against, and the extra saving is
# small next to the debug sections.
set -eu

ROOT=${1:?usage: stage5-strip.sh <sysroot>}
LOG=${STRIP_LOG:-/dev/null}

# KILOBYTES, NOT MEGABYTES, AND THE GUARD AT THE FOOT IS WHY. `du -sm` rounds
# to whole megabytes, so a tree that genuinely shrank by a few hundred KB
# reports the same size before and after -- and the "removed nothing" check
# then fails a run that worked. Caught on a 2 MB test tree where both files
# demonstrably shrank and the script reported VERON-STRIP-NOTHING.
sz() { du -sk "$1" 2>/dev/null | cut -f1; }
emit() { echo "$1"; [ "$LOG" = /dev/null ] || echo "$1" >> "$LOG"; }

[ -d "$ROOT" ] || { emit "  no such tree: $ROOT"; exit 1; }

TMPERR=$(mktemp); TMPFAIL=$(mktemp)
trap 'rm -f "$TMPERR" "$TMPFAIL" "$ROOT/.strip-probe"' EXIT

STRIP=""
STRIP_WRAP=""
if command -v bwrap >/dev/null 2>&1 && [ -x "$ROOT/usr/bin/strip" ]; then
    STRIP_WRAP="bwrap --die-with-parent --bind $ROOT / --proc /proc --dev /dev --tmpfs /tmp --setenv PATH /usr/bin:/bin --chdir /"
fi

try_strip() {
    if [ -n "$STRIP_WRAP" ]; then
        $STRIP_WRAP /usr/bin/strip --strip-debug "$1" 2>/dev/null
    else
        return 1
    fi
}

for cand in OWN "$(command -v strip 2>/dev/null || true)"; do
    [ "$cand" = OWN ] || { [ -n "$cand" ] && [ -x "$cand" ]; } || continue
    [ "$cand" = OWN ] && [ -z "$STRIP_WRAP" ] && continue
    # SEVERAL PROBE FILES, NOT THE FIRST ONE, AND THIS IS A FIX RATHER THAN A
    # COPY. stage 4 probes `find ... | head -1` -- so if that one file happens
    # to be ALREADY STRIPPED it does not shrink, the candidate is rejected, and
    # a perfectly working strip is discarded along with the whole cut. Caught
    # here by probing a tree whose first binary was already stripped: the
    # script refused with VERON-STRIP-NONE while the tool was fine.
    #
    # A candidate is only rejected once it has failed to shrink ANY of them.
    shrank=0
    # NO SIZE FILTER ON THE PROBE EITHER. A floor here is the same trap one
    # level down: a tree whose ELFs are all smaller than the threshold offers
    # no probe at all, and the candidate is rejected for the tree's shape
    # rather than the tool's fitness. Caught exactly that way on a test tree
    # of 16 KB binaries.
    for probe in $(find "$ROOT/usr/bin" "$ROOT/usr/lib" -type f ! -type l \
                        2>/dev/null | LC_ALL=C sort | head -12); do
        head -c4 "$probe" 2>/dev/null | od -An -c 2>/dev/null \
            | grep -q 'E   L   F' || continue
        cp "$probe" "$ROOT/.strip-probe" 2>/dev/null || continue
        b=$(wc -c < "$ROOT/.strip-probe")
        if [ "$cand" = OWN ]; then
            try_strip /.strip-probe
        else
            "$cand" --strip-debug "$ROOT/.strip-probe" 2>/dev/null || true
        fi
        [ "$(wc -c < "$ROOT/.strip-probe")" -lt "$b" ] && { shrank=1; break; }
    done
    if [ "$shrank" = 1 ]; then
        rm -f "$ROOT/.strip-probe"
        if [ "$cand" = OWN ]; then
            STRIP=OWN
            emit "  strip: the sysroot's own /usr/bin/strip, under bwrap (probed OK)"
        else
            STRIP="$cand"
            emit "  strip: $cand (probed OK)"
            emit "         NOTE: a HOST tool is rewriting artifact bytes."
        fi
        break
    fi
    rm -f "$ROOT/.strip-probe"
    emit "  strip candidate rejected: $cand (probe did not shrink a test file)"
done

# REFUSE RATHER THAN REPORT A SIZE THAT OMITS THE CUT. This is lesson 1 stated
# as an exit code: a green run that stripped nothing is the failure mode this
# whole script exists to prevent.
if [ -z "$STRIP" ]; then
    emit "  NO WORKING strip FOUND -- refusing to report a size that omits it."
    emit "  On a foreign-arch runner the host strip cannot read these ELFs."
    emit "VERON-STRIP-NONE"
    exit 1
fi

# STRIP TO A NEW FILE AND RENAME. NEVER IN PLACE.
#
# THE SECOND RUN FAILED FOR EXACTLY THIS. The exclusion list kept strip from
# stripping /usr/bin/strip and ld.so, and it still destroyed itself:
#
#     /usr/bin/strip: error while loading shared libraries:
#     /usr/lib/libbfd-2.47.20260726.so: file too short
#
# strip links libbfd, libopcodes and libctf. Stripping libbfd truncated a file
# the running strip had MAPPED, so the next exec of strip could not load. 674
# files failed after that. Extending the exclusion list would only move the
# race -- every library strip depends on, transitively, would have to be
# listed and kept correct forever.
#
# Writing a new file and renaming removes the race instead of enumerating it.
# A running process keeps its open inode; rename only swaps the directory
# entry. So strip can rewrite its own libraries mid-walk and stay alive,
# because it is still mapped to the inode it started with.
#
# THE MODE IS CARRIED OVER EXPLICITLY. strip -o creates a fresh file with
# default permissions, so an executable stripped this way would land 0644 and
# stop being runnable -- which the manifest records as a mode change and the
# boot discovers as a missing program.
do_strip() {
    f=$1
    tmp="${f}.strip.$$"
    if [ "$STRIP" = OWN ]; then
        $STRIP_WRAP /usr/bin/strip --strip-debug -o "${tmp#$ROOT}" "${f#$ROOT}" || {
            rm -f "$tmp"; return 1; }
    else
        "$STRIP" --strip-debug -o "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0755 "$tmp"
    mv -f "$tmp" "$f"
}

strip_available() { [ "$STRIP" = OWN ] || [ -x "$STRIP" ]; }
strip_available || { emit "VERON-STRIP-NONE"; exit 1; }

before=$(sz "$ROOT")
count=0

# EXECUTABLES AND SHARED LIBRARIES BOTH. stage 4 walks bin/sbin/libexec; the
# largest single file in stage 5 is a LIBRARY -- wpewebkit's 162 MB
# libWPEWebKit -- so lib/ is walked here too or the biggest item is missed.
#
# NO SIZE FLOOR. stage 4 uses -size +512k because its tree is compilers; here
# the tail is hundreds of small shared objects whose debug sections are a
# large fraction of each. The ELF check below is what keeps this cheap.
find "$ROOT/usr/bin" "$ROOT/usr/sbin" "$ROOT/usr/libexec" "$ROOT/usr/lib" \
     -type f ! -type l 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    case "$f" in *.py|*.sh|*.pl|*.a) continue ;; esac

    # NEVER STRIP THE TOOLCHAIN THIS SCRIPT IS STANDING ON, AND THE FIRST RUN
    # PROVED WHY. The walk is alphabetical, so it reached /usr/bin/strip and
    # asked it to strip itself ("Text file busy"), then reached
    # /usr/lib/ld-linux-x86-64.so.2 -- the dynamic loader -- and SUCCEEDED.
    # From that point bwrap could not exec anything at all inside the sysroot:
    #
    #     FAILED /usr/sbin/pcscd   bwrap: execvp /usr/bin/strip: I/O error
    #
    # 694 files failed after it, and the booted image reported
    # VERON-STAGE5-TESTS pass=25 fail=151 -- because most dynamically linked
    # binaries could no longer start. Stripping a loader is not a size
    # optimisation, it is a way to destroy an image and report success.
    #
    # ld.so IS EXCLUDED PERMANENTLY, not merely while we are running under it.
    # Its debug sections are small and the downside is unbounded.
    case "${f#$ROOT}" in
        /usr/lib/ld-*.so*|/usr/lib64/ld-*.so*|/lib/ld-*.so*|/lib64/ld-*.so*)
            continue ;;
        /usr/bin/strip|/usr/bin/*-strip|/usr/bin/objcopy|/usr/bin/*-objcopy)
            continue ;;
    esac
    head -c4 "$f" 2>/dev/null | od -An -c 2>/dev/null | grep -q 'E   L   F' || continue
    s1=$(wc -c < "$f")
    chmod u+w "$f" 2>/dev/null || true
    if ! do_strip "$f" 2>"$TMPERR"; then
        printf '    FAILED %-52s %s\n' "${f#$ROOT}" "$(head -1 "$TMPERR")"
        echo failed >> "$TMPFAIL"
        continue
    fi
    s2=$(wc -c < "$f")
    if [ "$s2" -lt "$s1" ]; then
        echo "$((s1 - s2))" >> "$TMPFAIL.saved"
    fi
done

after=$(sz "$ROOT")
nfail=$(wc -l < "$TMPFAIL" 2>/dev/null || echo 0)

emit "  stripped: $((before / 1024)) MB -> $((after / 1024)) MB  ($(( (before - after) / 1024 )) MB / $((before - after)) KB removed)"
[ "$nfail" -eq 0 ] || emit "  $nfail file(s) failed to strip -- see above"

# A CUT THAT REMOVED NOTHING IS A FAILURE, NOT A NO-OP. If a working strip was
# found and probed, and the tree did not shrink, something is wrong with the
# walk rather than with the tool -- and reporting success would repeat exactly
# the bug lesson 2 records.
if [ "$before" -le "$after" ]; then
    emit "VERON-STRIP-NOTHING  a working strip removed no bytes"
    exit 1
fi

# BYTES REMOVED IS NOT THE SAME AS THE RUN HAVING WORKED, and the first run is
# the proof: 133 MB came off before the loader was stripped, 694 files failed
# afterwards, and this script printed VERON-STRIP-OK over the top of a broken
# image. Checking only that the tree shrank is checking the easy half.
#
# A FEW FAILURES ARE TOLERABLE -- a file locked or genuinely unstrippable --
# and a wall of them means the tool stopped working partway through, which is
# a different thing and must fail the build.
if [ "$nfail" -gt 20 ]; then
    emit "VERON-STRIP-BROKEN  $nfail file(s) failed -- the tool stopped working"
    emit "  A large failure count means strip died partway through rather than"
    emit "  meeting a handful of odd files. The tree is now PARTLY stripped,"
    emit "  which is worse than untouched: do not ship this image."
    exit 1
fi
echo "VERON-STRIP-OK  $(( (before - after) / 1024 )) MB"
