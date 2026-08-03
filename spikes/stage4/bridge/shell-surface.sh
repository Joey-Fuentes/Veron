#!/bin/sh
# WHAT A REPLACEMENT SHELL WOULD ACTUALLY HAVE TO DO.
#
# `THE APPLET SET` in the workflows answers "which busybox applets did the
# chain invoke". That is half the question. The other half -- and the half that
# decides whether the replacement is written in assembly or in C -- is which
# SHELL CONSTRUCTS the in-box scripts use, and how many of them survive once
# the reporting is moved out of the box.
#
# TRUST-BOUNDARY.md's `.s0` driver entry states the thesis: "almost all of that
# is reporting and verification, not building. Move the checking outside the box
# and what remains is: run a program with args, redirect stdin and stdout, run
# in sequence, abort on a non-zero exit. That is `kaem`'s feature set." This
# measures that claim instead of asserting it.
#
# WHY IT IS STATIC AND NOT A TRACE. A trace tells you what ran on one path
# through one build; a shell has to implement every construct the script CAN
# reach, including the error paths that a green run never takes. For deciding
# what to implement, the static surface is the right upper bound. The applet
# trace remains the right tool for the complementary question -- what to
# compile into busybox while it is still there.
#
# HOW TO READ THE OUTPUT. The BUILD column is what a driver must support to run
# the ladder. The REPORT column is what exists only to describe the run, and is
# the part TRUST-BOUNDARY proposes to lift out of the box entirely. If BUILD is
# small and flat, assembly is viable; if it needs globbing, `case`, arithmetic
# or functions, that is a C-shaped problem.
#
# usage: shell-surface.sh [script...]     (defaults to the in-box scripts)
set -eu

cd "$(dirname "$0")"
FILES="${*:-rungs.sh rungs-sysroot.sh}"

# COMMANDS THAT ONLY DESCRIBE. Splitting these out is the whole point: they are
# the ones that leave with the reporting refactor. `say` and `head1` are the
# scripts' own output helpers; the text tools are almost entirely used to shape
# diagnostics rather than to build anything.
REPORT_CMDS="say head1 echo printf sed grep head tail wc sort uniq comm cut tr fold od cmp diff nl expect rc"
# COMMANDS THAT BUILD. These are the irreducible ones: a driver that cannot run
# these cannot run the ladder.
BUILD_CMDS="make tar mkdir cp mv rm cd ln chmod install ar ranlib strip touch test"

echo "== files =="
for f in $FILES; do printf '   %-22s %s lines\n' "$f" "$(wc -l < "$f")"; done
echo

# COMMENTS OUT FIRST, AND THIS MATTERS MORE THAN IT SOUNDS. These files are
# more comment than code -- 6396 lines, 3049 of them code -- and the comments
# are dense with backtick-quoted identifiers and `*` in prose. Measured raw,
# backticks came out at 177 and collapsed to 9 once comments were stripped.
# A surface measurement that counts prose is not a measurement.
sed 's/#.*//' $FILES | grep -v '^[[:space:]]*$' > /tmp/ss-code.sh
printf '   code lines (comments stripped): %s\n\n' "$(wc -l < /tmp/ss-code.sh)"

# A LINE THAT MENTIONS A REPORTING COMMAND is counted as reporting. This is a
# heuristic and it is generous to the thesis: a line doing both still counts as
# reporting, so REMAINING is a LOWER bound on what a driver must implement.
REPORT_RE='say|head1|echo|printf|sed |grep |head |tail |wc |sort |uniq |cut |tr |fold |expect|whyfail|cmp |diff '

echo "== shell constructs: total, and what survives the reporting refactor =="
probe() {
    _t=$(grep -cE "$2" /tmp/ss-code.sh || true)
    _r=$(grep -E "$2" /tmp/ss-code.sh | grep -cE "$REPORT_RE" || true)
    printf '   %-30s %5s %5s %6s\n' "$1" "$_t" "$_r" "$((_t - _r))"
}
printf '   %-30s %5s %5s %6s\n' "construct" "all" "rept" "REMAIN"
probe "pipelines            |"          '\|[^|]'
probe "command substitution \$( )"      '\$\('
probe "backtick substitution"           '`'
probe "conditionals         if"         '^[[:space:]]*(if|elif)[[:space:]]'
probe "case                 case"       '^[[:space:]]*case[[:space:]]'
probe "loops                for/while"  '^[[:space:]]*(for|while)[[:space:]]'
probe "functions            name()"     '^[a-zA-Z_][a-zA-Z0-9_]*\(\)'
probe "here-documents       <<"         '<<'
probe "redirect out         >"          '[^>0-9]>[^&>]'
probe "redirect append      >>"         '>>'
probe "redirect in          <"          '[^<]<[^<]'
probe "fd redirect          2>&1"       '2>&1'
probe "subshell             ( )"        '^[[:space:]]*\('
probe "logical              && ||"      '&&|\|\|'
probe "arithmetic           \$(( ))"    '\$\(\('
probe "parameter default    \${x:-y}"   '\$\{[A-Za-z_][A-Za-z0-9_]*:-'
probe "parameter edit       \${x%y}"    '\$\{[A-Za-z_][A-Za-z0-9_]*[%#]'
probe "glob                 *"          '[^\$]\*[^)]'
probe "background/&"                    '&[[:space:]]*$'
echo

echo "== external commands, split by purpose =="
# One inventory pass; classify each name against the two lists above.
cat $FILES \
  | sed 's/#.*//' \
  | grep -oE '(^|[;|&(]|\$\()[[:space:]]*[a-z][a-z0-9_.-]*' \
  | sed 's/[^a-z0-9_.-]//g' \
  | grep -vE '^(if|then|else|elif|fi|for|while|do|done|case|esac|return|continue|break|local|set|exit|in|the|and|a|is|it|to|of|not|that|this|with|int|void|long|char|const|static)$' \
  | sort | uniq -c | sort -rn > /tmp/cmds.txt

r_total=0; b_total=0; u_total=0
: > /tmp/report.txt; : > /tmp/build.txt; : > /tmp/other.txt
while read -r n c; do
    [ -n "$c" ] || continue
    case " $REPORT_CMDS " in *" $c "*)
        printf '   %6s  %s\n' "$n" "$c" >> /tmp/report.txt
        r_total=$((r_total + n)); continue ;;
    esac
    case " $BUILD_CMDS " in *" $c "*)
        printf '   %6s  %s\n' "$n" "$c" >> /tmp/build.txt
        b_total=$((b_total + n)); continue ;;
    esac
    printf '   %6s  %s\n' "$n" "$c" >> /tmp/other.txt
    u_total=$((u_total + n))
done < /tmp/cmds.txt

echo "   --- REPORTING: leaves the box with the verification refactor ---"
head -14 /tmp/report.txt
echo "   --- BUILDING: a driver must be able to run these ---"
head -14 /tmp/build.txt
echo "   --- UNCLASSIFIED: read these, they decide the answer ---"
head -18 /tmp/other.txt
echo
printf '   reporting %s   building %s   unclassified %s\n' "$r_total" "$b_total" "$u_total"
echo
echo "== the question this is for =="
echo "   If, once REPORTING leaves, what remains is: run a program with args,"
echo "   redirect stdin/stdout, run in sequence, abort on non-zero -- then the"
echo "   driver is kaem-shaped and assembly is a few hundred instructions."
echo "   If globbing, case, arithmetic or functions survive into BUILDING,"
echo "   that is a C-shaped problem and the .s0 route costs much more."
