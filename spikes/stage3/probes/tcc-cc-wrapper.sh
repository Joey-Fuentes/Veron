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

n=$#
i=0
while [ "$i" -lt "$n" ]; do
    a=$1; shift; i=$((i + 1))
    case "$a" in
        -Wp,-MD,*)  set -- "$@" -MD -MF "${a#-Wp,-MD,}" ;;
        -Wp,-MMD,*) set -- "$@" -MD -MF "${a#-Wp,-MMD,}" ;;
        # Other -Wp, pass-throughs are preprocessor flags tcc does not take.
        # Dropping them is safe here; anything load-bearing would show up as a
        # compile error rather than silently wrong code.
        -Wp,*)      ;;
        *)          set -- "$@" "$a" ;;
    esac
done

if [ -n "${TCCDIR:-}" ]; then
    exec "$TCC" -B"$TCCDIR" "$@"
else
    exec "$TCC" "$@"
fi
