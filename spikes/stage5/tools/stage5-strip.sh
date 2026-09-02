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
# NO PIPELINE HERE CLOSES ITS INPUT EARLY. `cmd | head -N` is fine on a host
# where SIGPIPE is fatal: the producer dies quietly. The GitHub runner leaves
# SIGPIPE at SIG_IGN and the disposition is inherited through fork AND exec,
# so the producer takes EPIPE, complains on stderr and exits non-zero instead.
# `sed -n '1,Np'` reads to EOF and selects the same N lines without ever
# closing the pipe. Where the cap was only shortening a report it is gone
# entirely; where it selects (try up to twelve candidates) it stays.
#
# --strip-debug, NOT --strip-all. The symbol table stays, so a backtrace still
# names functions; only DWARF goes. --strip-all on a shared library removes
# symbols something may still need to link against, and the extra saving is
# small next to the debug sections.
set -eu

ROOT=${1:?usage: stage5-strip.sh <sysroot>}
# A TRAILING SLASH IS STRIPPED, WHICH IS WHAT MAKES "/" A LEGAL ARGUMENT.
#
# This script is now run INSIDE the box with the sysroot bound at /, so that
# every tool it reaches for -- chmod, mv, find, stat, od -- is the sysroot's
# and not the host's. That means ROOT arrives as "/", and two things depend
# on the form it takes:
#
#   ${f#$ROOT} BUILDS THE PATH THE EXCLUSION LIST MATCHES, and those patterns
#   are absolute (/usr/lib/ld-*.so*, /usr/bin/strip). With ROOT="/" the
#   expansion yields "usr/bin/strip", nothing matches, and the script strips
#   ld.so and the running strip -- the two failures its own comments describe
#   as destroying the tree. With ROOT="" it yields "/usr/bin/strip" and the
#   patterns match exactly as they always did.
#
#   $ROOT/usr/bin/strip still resolves: "" + "/usr/bin/strip".
#
# Binding the tree a second time at /sysroot would also have worked and was
# the wrong answer: bwrap CREATES a missing mount point, and since / is a
# read-write bind of the real directory, that mkdir lands in the sysroot and
# ships. The eleven empty directories already sitting at the root of the
# image -- dest, dl, logs, packages, policy, tools, build, in, out, src --
# are exactly that, left by the main build box.
ROOT=${ROOT%/}
# The existence check needs a path; "" is the root directory.
[ -d "${ROOT:-/}" ] || { echo "  no such tree: ${1}"; exit 1; }
LOG=${STRIP_LOG:-/dev/null}

# KILOBYTES, NOT MEGABYTES, AND THE GUARD AT THE FOOT IS WHY. `du -sm` rounds
# to whole megabytes, so a tree that genuinely shrank by a few hundred KB
# reports the same size before and after -- and the "removed nothing" check
# then fails a run that worked. Caught on a 2 MB test tree where both files
# demonstrably shrank and the script reported VERON-STRIP-NOTHING.
# -x, BECAUSE INSIDE THE BOX $ROOT IS / AND / HAS MOUNTS UNDER IT. Without it
# du walked --proc, --dev and the two --tmpfs mounts and reported the tree at
# 14559 MB on a laptop and 7846 MB on the runner -- neither of which is the
# 1873 MB sysroot, and different from each other, in a log line meant to say
# how much the strip removed. One filesystem, the one the tree is on.
sz() { du -skx "$1" 2>/dev/null | cut -f1; }
emit() { echo "$1"; [ "$LOG" = /dev/null ] || echo "$1" >> "$LOG"; }

# (the tree's existence was checked above, before emit() had a log path)

TMPERR=$(mktemp); TMPFAIL=$(mktemp); TMPINO=$(mktemp)
trap 'rm -f "$TMPERR" "$TMPFAIL" "$TMPINO" "$ROOT/.strip-probe"' EXIT

STRIP=""
# STRIP_WRAP EXISTS TO REACH THE SYSROOT'S STRIP FROM OUTSIDE IT. It bwraps
# $ROOT to / so /usr/bin/strip resolves to the tree's own binutils rather
# than the host's. INSIDE THE BOX THERE IS NOTHING TO REACH: / already is the
# tree and /usr/bin/strip already is its strip.
#
# THIS WAS THE FIVE-ROUND FAILURE, NAMED BY THE sh -x TRACE ON THE FIFTH:
#
#   + command -v bwrap                 <- succeeds: bubblewrap is a stage-5
#                                         package, so the sysroot HAS bwrap
#   + STRIP_WRAP='bwrap ... --bind  / ...'
#                                  ^^ ROOT is empty in the box: --bind "" /
#   + bwrap --die-with-parent --bind / ... /usr/bin/strip --strip-debug ...
#   + rm -f ...                        <- the EXIT trap: try_strip died there
#
# A NESTED bwrap from inside an unprivileged user namespace, with no
# --unshare-all of its own, cannot create mounts on the GitHub runner. It CAN
# on a Veron laptop, which is the entire leg difference: the same code path
# ran on both, and only one kernel let the inner bwrap through. Every bind
# probe passed because none of them nest.
#
# ROOT="" after the trailing-slash normalisation is the honest signal that
# the tree IS / -- there is no outer host to escape, so no wrapper.
STRIP_WRAP=""
if [ -n "$ROOT" ] && command -v bwrap >/dev/null 2>&1 && [ -x "$ROOT/usr/bin/strip" ]; then
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
    # sed -n '1,12p' RATHER THAN head -12, AND THE CAP ITSELF STAYS.
    #
    # Twelve is a selection -- try up to twelve candidates -- not a report
    # being shortened, so it is kept. What changes is that `head` CLOSES THE
    # PIPE while find and sort are still writing thousands of paths, and the
    # GitHub runner leaves SIGPIPE at SIG_IGN (actions/runner #2684; the
    # driver resets it for its own children and documents why). sort then
    # takes EPIPE instead of dying, prints "sort: standard output: Broken
    # pipe" and exits non-zero. `sed -n` reads its input to EOF, so nothing
    # upstream ever sees a closed pipe and the runner's disposition stops
    # mattering.
    for probe in $(find "$ROOT/usr/bin" "$ROOT/usr/lib" -type f ! -type l \
                        2>/dev/null | LC_ALL=C sort | sed -n '1,12p'); do
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
            # INSIDE THE BOX ROOT IS EMPTY AND $cand IS THE TREE'S OWN strip --
            # the note would call it a host tool, which is the opposite of the
            # truth and of why the box exists. Say which it is.
            if [ -z "$ROOT" ]; then
                emit "  strip: $cand -- the tree's own binutils, running inside the box (probed OK)"
            else
                emit "  strip: $cand (probed OK)"
                emit "         NOTE: a HOST tool is rewriting artifact bytes."
            fi
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
    # THE MODE IS READ AND REAPPLIED NUMERICALLY. `chmod --reference` IS GNU
    # ONLY.
    #
    # busybox chmod has no --reference, so on a Veron laptop that call failed
    # and the `|| chmod 0755` fallback ran for EVERY file -- turning 0644
    # objects into 0755 executables. 53 paths in the shipped image: crt1.o,
    # crti.o, crtn.o and the rest of the crt set, usr/lib/gcc's internal
    # objects, libgcc_s.so.1, libnettle, libhogweed and ruby's gems. The
    # runner has GNU coreutils on PATH, so it kept the modes and the two legs
    # disagreed on which of them was right; the stage-4 sysroot says 0644, so
    # the fallback was wrong and had been silently doing all the work.
    #
    # `stat -c%a` exists in busybox and coreutils alike. The 0755 default now
    # applies only if stat itself fails, which is what the original fallback
    # was for and never got to be.
    _m=$(stat -c%a "$f" 2>/dev/null || echo 755)
    chmod "$_m" "$tmp"
    mv -f "$tmp" "$f"
}

strip_available() { [ "$STRIP" = OWN ] || [ -x "$STRIP" ]; }
strip_available || { emit "VERON-STRIP-NONE"; exit 1; }

# ---- delete what a running system never opens -------------------------
#
# EVERYTHING HERE HAPPENS TO THE MERGED TREE, WHICH IS WHY IT IS HERE AND NOT
# IN THE RECIPES. A recipe edit changes recipe-sha, which invalidates that
# package and everything that build-depends on it -- adding one flag to
# pkgconf, python and m4 discarded 117 of 144 packages and cost a full
# rebuild. Trimming after merge costs nothing: the packages are already built,
# the checkpoint still matches, and the decision is reversible by re-running
# without the flag.
#
# stage4/bridge/sysroot-trim.sh does the same thing for the sysroot it
# publishes. This is the stage-5 half, which never existed.
#
# EACH CATEGORY IS MEASURED AND REPORTED SEPARATELY so that a removal that
# turns out to be wrong is attributable, and so the numbers stop being
# estimates.
trim_cat() {   # $1 = label, rest = find predicates
    label=$1; shift
    b=$(sz "${ROOT:-/}")
    find "${ROOT:-/}" "$@" -delete 2>/dev/null || true
    a=$(sz "${ROOT:-/}")
    printf '    %-22s %6d MB\n' "$label" "$(( (b - a) / 1024 ))"
}

if [ "${VERON_TRIM:-1}" = 1 ]; then
    emit ""
    emit "  --- removing what nothing loads at runtime ---"
    # STATIC ARCHIVES, EXCEPT THE FOUR A -static LINK ACTUALLY NEEDS.
    #
    # Measured on the stage-4 sysroot: 115 MB of .a, of which libstdc++.a is
    # 32 and libbfd.a 10.5 -- C++ and binutils' own, neither reachable from a
    # kernel build. But libc.a (22), libm.a (7.5) and libgcc.a (6) are what a
    # `-static` link resolves against, and libc_nonshared.a is linked into
    # EVERY dynamic binary despite rounding to 0 MB, which makes it the one
    # most easily lost to a blanket rule.
    #
    # The kernel build in the stage-4 log shows no -static and no libc.a, so
    # these are probably unnecessary too -- but the log is quiet, that is
    # absence of evidence rather than proof, and 36 MB is not worth gambling
    # the one build capability this image is meant to keep.
    b=$(sz "${ROOT:-/}")
    find "${ROOT:-/}" -type f -name '*.a' \
         ! -name 'libc.a' ! -name 'libm.a' ! -name 'libm-*.a' \
         ! -name 'libgcc.a' ! -name 'libc_nonshared.a' \
         -delete 2>/dev/null || true
    a=$(sz "${ROOT:-/}")
    printf '    %-22s %6d MB\n' "static archives (.a)" "$(( (b - a) / 1024 ))"

    # THE C++ BACK-END AND THE LTO BACK-END.
    #
    # cc1plus is 48 MB and lto1 is 44 MB, and a kernel build invokes neither:
    # the kernel is C, and gcc's LTO back-end runs only for -flto. In the
    # stage-4 log cc1plus appears only where gcc BUILDS ITSELF -- "RUNG 9 --
    # gcc 10.2.0, built by g++ (GCC) 4.7.4" -- which is the seed ladder's job,
    # not the device's.
    #
    # WHAT THIS COSTS, PLAINLY: Veron's own applications are C++ (the FLTK
    # programs, the browser shell), so they can no longer be rebuilt on the
    # device. That is the accepted trade -- kernels are the supported local
    # build, userspace comes from the seed.
    if [ "${VERON_TRIM_CXX:-1}" = 1 ]; then
        trim_cat "cc1plus + lto1" -type f \( -name 'cc1plus' -o -name 'lto1' \)
    fi
    # LIBTOOL .la FILES describe how to link and are read by libtool alone.
    trim_cat "libtool .la"          -type f -name '*.la'
    # HEADERS ARE FOR COMPILING AGAINST AN INSTALLED LIBRARY. A rebuild on
    # this system comes up from the seed and recompiles the libraries too, so
    # it regenerates its own headers rather than reading these.
    # HEADERS ARE NOT ALL THE SAME, AND DELETING THEM ALL BREAKS KERNEL
    # BUILDS ON THE DEVICE.
    #
    # This used to be `-path '*/usr/include/*'`, which removed glibc's and
    # gcc's headers along with everything else. That is fine for a system that
    # only runs -- and fatal for one that must compile its own kernel, because
    # the kernel's host tools (fixdep, objtool, kconfig) are ordinary C
    # programs that #include <stdio.h>.
    #
    # THE DISCRIMINATOR IS DATA, NOT A PATTERN. Every stage-5 package records
    # what it installs in packages/<n>/installs.txt, so the headers that came
    # from a PACKAGE can be named exactly and removed, while everything else
    # under usr/include -- which is the stage-4 sysroot's, glibc's and the
    # kernel's -- is left alone. No guessing about which prefix belongs to
    # whom.
    #
    # Rebuilding Veron's own userspace is deliberately NOT supported on the
    # device: that needs cairo's, glib's and wpewebkit's headers, and those
    # are exactly what this removes. A user who wants that starts from the
    # seed. Kernels are the supported case.
    if [ -n "${PKGDIRS:-}" ]; then
        b=$(sz "${ROOT:-/}")
        for pd in $PKGDIRS; do
            [ -d "$pd" ] || continue
            for il in "$pd"/*/installs.txt; do
                [ -f "$il" ] || continue
                awk '$1=="f" && $4 ~ /^usr\/include\// {print $4}' "$il"
            done
        done | LC_ALL=C sort -u | while IFS= read -r rel; do
            [ -n "$rel" ] && rm -f "$ROOT/$rel" 2>/dev/null
        done
        # EMPTY DIRECTORIES LEFT BEHIND ARE NOISE IN THE MANIFEST, not a size
        # problem -- removed only where nothing remains.
        find "$ROOT/usr/include" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        a=$(sz "${ROOT:-/}")
        printf '    %-22s %6d MB\n' "package headers" "$(( (b - a) / 1024 ))"
    else
        printf '    %-22s %6s\n' "package headers" "skipped (no PKGDIRS)"
    fi
    # MAN AND INFO PAGES. There is no man(1) in this image to read them.
    trim_cat "man pages"            -type f -path '*/share/man/*'
    trim_cat "info pages"           -type f -path '*/share/info/*'
    # DOCS. READMEs and changelogs shipped beside libraries.
    trim_cat "docs"                 -type f -path '*/share/doc/*'
    # LOCALE. gnupg alone ships about 5 MB of translations, and nothing in
    # this image sets LC_MESSAGES to anything but C.
    trim_cat "locale"               -type f -path '*/share/locale/*'
    emit ""
fi

before=$(sz "${ROOT:-/}")
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
    # HARDLINKS MUST SURVIVE STRIPPING, AND THE RENAME BROKE THEM.
    #
    # do_strip writes a new file and renames it over the old path -- which is
    # what stops strip destroying its own libraries mid-walk. But a rename
    # replaces one directory entry, so the OTHER names for that inode keep
    # pointing at the unstripped original, and each in turn gets its own
    # stripped copy. git has 147 names for one builtin: the merge preserved
    # them, and stripping re-expanded them.
    #
    # Measured: the tree GREW during stripping, 1490 MB -> 1832 MB, and the
    # "removed no bytes" guard caught it.
    #
    # So the first link is stripped and the rest are re-linked to the result.
    # The inode is read BEFORE stripping, because the rename changes it.
    ino=$(stat -c '%i %h' "$f" 2>/dev/null) || ino=""
    nlink=${ino#* }
    ino=${ino%% *}
    # THE LOOKUP IS NOT GATED ON nlink, AND GATING IT LEFT ONE FILE BEHIND.
    # Each relink moves a name off the original inode, so its link count falls
    # as the walk proceeds -- by the last name it is 1, which a `nlink > 1`
    # test reads as "not shared" and strips independently. Measured on 13
    # links: twelve relinked, `git-status` came out with its own inode.
    # Recording still checks nlink, because a genuinely unshared file has
    # nothing to record.
    if [ -n "$ino" ]; then
        prev=$(sed -n "s/^$ino //p" "$TMPINO" | sed -n '1p') || prev=""
        if [ -n "$prev" ] && [ -e "$prev" ]; then
            # AN if, NOT `ln ... && continue`. Under `set -e` an AND-list whose
            # last command fails takes the whole script down -- and inside a
            # `find | while read` pipeline it dies without printing anything at
            # all. A failed ln must fall through to a normal strip, not end the
            # run.
            if ln -f "$prev" "$f" 2>/dev/null; then
                continue
            fi
        fi
    fi

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
    # OLD INODE -> THE PATH NOW HOLDING THE STRIPPED CONTENT. Every other name
    # for that old inode is still unstripped and will find this entry.
    #
    # AN if, FOR THE REASON ABOVE, AND THIS IS THE ONE THAT ACTUALLY KILLED A
    # RUN. Written as `[ -n "$ino" ] && [ "$nlink" -gt 1 ] && echo ...`, every
    # file with a single link -- which is nearly all of them -- made the
    # AND-list return non-zero, and `set -e` ended the script mid-walk with no
    # output whatsoever: the step logged the trim, then exit 1, then nothing.
    if [ -n "$ino" ] && [ "${nlink:-1}" -gt 1 ]; then
        echo "$ino $f" >> "$TMPINO"
    fi
done

# THE WALK MUST ANNOUNCE THAT IT FINISHED. A `set -e` fault inside the
# `find | while read` pipeline ends the script with no output at all -- the
# step logged the trim and then exit 1, and there was nothing to read to find
# out why. This marker is the difference between "the walk ended" and "the
# script vanished".
echo "  walk complete"

after=$(sz "${ROOT:-/}")
nfail=$(wc -l < "$TMPFAIL" 2>/dev/null || echo 0)

emit "  stripped: $((before / 1024)) MB -> $((after / 1024)) MB  ($(( (before - after) / 1024 )) MB / $((before - after)) KB removed)"
[ "$nfail" -eq 0 ] || emit "  $nfail file(s) failed to strip -- see above"

# A CUT THAT REMOVED NOTHING IS A FAILURE, NOT A NO-OP. If a working strip was
# found and probed, and the tree did not shrink, something is wrong with the
# walk rather than with the tool -- and reporting success would repeat exactly
# the bug lesson 2 records.
if [ "$after" -gt "$before" ]; then
    emit "VERON-STRIP-GREW  the tree got BIGGER: $(( (after - before) / 1024 )) MB"
    emit "  Stripping cannot add bytes. Something is breaking hardlinks --"
    emit "  every extra name for a shared inode becoming its own copy is the"
    emit "  one way this number goes up."
    exit 1
fi
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
