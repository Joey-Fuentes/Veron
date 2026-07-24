#!/bin/sh
# CC shim for building kbuild-style projects (busybox, and later Linux) with tcc.
#
# THE ONE THING IT FIXES, and why a shim rather than a patch to busybox:
#
# kbuild emits gcc's preprocessor pass-through for dependency generation:
#
#     -Wp,-MD,applets/.applets.o.d
#
# gcc reads that as "-MD, whose argument is this file". tcc's option table has
#
#     { "Wp,", TCC_OPTION_Wp,  HAS_ARG | NOSEP }
#     { "MD",  TCC_OPTION_MD,  HAS_ARG | NOSEP }
#
# and TCC_OPTION_Wp calls insert_args(..., ',') -- it SPLITS on commas and
# re-parses each piece as its own argv entry. So tcc sees `-MD` (which it
# accepts, taking no separate operand) and then `applets/.applets.o.d` as a
# second INPUT FILE, and refuses:
#
#     tcc: error: cannot specify output file with -c many files
#
# tcc spells the same request `-MD -MF <file>`, so this translates rather than
# discards, and dependency files still get written. Nothing in busybox is
# modified, which matters: a patched busybox would be a substitution to declare
# in the ledger, while a CC shim is just how the compiler is invoked.
#
# Env: TCC (path to tcc) and TCCDIR (its -B directory), both already exported
# into GITHUB_ENV by the build step.

: "${TCC:?tcc-cc-wrapper: TCC not set}"

# How many times to re-scan a --start-group archive list. 3 was the measured
# minimum for a 3-deep chain; 5 gives headroom without meaningful cost, since
# an archive whose members are already linked contributes nothing on a re-pass.
GROUP_PASSES=${GROUP_PASSES:-5}
in_group=0
group_objs=""
group_archives=""

# Is this a link or just a compile? Decides whether crt objects and -lc are
# added below. Set before the rewrite loop consumes "$@".
linking=1
for a in "$@"; do
    case "$a" in -c|-E|-S) linking=0 ;; esac
done

n=$#
i=0
while [ "$i" -lt "$n" ]; do
    a=$1; shift; i=$((i + 1))
    case "$a" in
        -Wp,-MD,*)  set -- "$@" -MD -MF "${a#-Wp,-MD,}" ;;
        -Wp,-MMD,*) set -- "$@" -MD -MF "${a#-Wp,-MMD,}" ;;

        # GROUP MARKERS. busybox's scripts/trylink wraps its 28 archives in
        #   -Wl,--start-group ... -Wl,--end-group
        # so the linker re-scans them until symbols stop resolving. tcc has no
        # --start-group and does NOT re-scan, so an archive listed before the
        # object that needs it is simply missed.
        #
        # A FIRST ATTEMPT USED --whole-archive, which tcc does support. That was
        # wrong. It force-loads EVERY member of every archive, including objects
        # for applets the config excluded, which produced ~20 undefined symbols
        # that are genuinely absent (sun_write_table, delete_eth_table,
        # run_nofork_applet) plus 4020 "Unknown relocation type for got" from
        # object files that had never been linked before. Loading more than the
        # link needs is not harmless.
        #
        # What is faithful: OBJECTS FIRST, THEN ARCHIVES REPEATED. Objects are
        # linked unconditionally so moving them earlier changes nothing, and
        # archives are demand-loaded so a repeated pass resolves one more level
        # of cross-archive reference. Measured on a 3-deep chain in reverse
        # order: 1 pass fails on the first symbol, 2 on the second, 3 links.
        # GROUP_PASSES is set above 3 for headroom.
        -Wl,--start-group) in_group=1 ;;
        -Wl,--end-group)
            in_group=0
            set -- "$@" $group_objs
            gp=0
            while [ "$gp" -lt "$GROUP_PASSES" ]; do
                set -- "$@" $group_archives
                gp=$((gp + 1))
            done
            group_objs=""; group_archives="" ;;
        # Other -Wp, pass-throughs are preprocessor flags tcc does not take.
        # Dropping them is safe here; anything load-bearing would show up as a
        # compile error rather than silently wrong code.
        -Wp,*)      ;;
        *.a)
            if [ "$in_group" = 1 ]; then group_archives="$group_archives $a"
            else set -- "$@" "$a"; fi ;;
        *)
            if [ "$in_group" = 1 ]; then group_objs="$group_objs $a"
            else set -- "$@" "$a"; fi ;;
    esac
done

# ---------------------------------------------------------------- musl driver
# WHY THIS EXISTS. busybox builds its own link line and it contains no -L and
# no -nostdlib:
#
#   ... -I<muslroot>/include -static -o busybox_unstripped -Wl,--start-group
#       applets/built-in.o ... -Wl,--end-group -Wl,--start-group -lm -lresolv ...
#
# musl supplies the HEADERS and the system supplies the LIBRARIES, so -lm,
# -lresolv and the implicit -lc resolve against /usr/lib/<triple> -- glibc's
# gcc-built static libc.a. That produced every symbol in the failing link:
# __aarch64_cas4_acq and friends are gcc's outline LSE atomics from libgcc.a,
# _Unwind_Resume / __gcc_personality_v0 are glibc's cancellation path needing
# libgcc_eh, __unordtf2 is libgcc soft-float, __ehdr_start is glibc csu -- plus
# thousands of "Unknown relocation type for got" from TLS relocations tcc never
# emits and its arm64 linker does not enumerate.
#
# This is exactly the job musl-gcc does. musl only generates that wrapper when
# it detects a gcc-like CC, so building musl with tcc leaves us without one;
# this section is it. Set MUSLROOT to enable.
pre=""
post=""
if [ -n "${MUSLROOT:-}" ]; then
    # Compiling and linking both need musl's headers and NOTHING from /usr.
    pre="-nostdinc -I$MUSLROOT/include"
    if [ "$linking" = 1 ]; then
        LIBTCC1=""
        for c in "${TCCDIR:-}/libtcc1.a" "${TCCDIR:-}/arm64-libtcc1.a"; do
            [ -f "$c" ] && LIBTCC1="$c" && break
        done
        pre="$pre -nostdlib $MUSLROOT/lib/crt1.o $MUSLROOT/lib/crti.o"
        post="-L$MUSLROOT/lib -lc $LIBTCC1 $MUSLROOT/lib/crtn.o"
    fi
fi

if [ -n "${TCC_SHIM_DEBUG:-}" ]; then
    printf 'shim: %s -B%s %s %s %s\n' "$TCC" "${TCCDIR:-}" "$pre" "$*" "$post" >&2
fi

if [ -n "${TCCDIR:-}" ]; then
    exec "$TCC" -B"$TCCDIR" $pre "$@" $post
else
    exec "$TCC" $pre "$@" $post
fi
