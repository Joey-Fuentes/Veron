#!/bin/sh
# WHERE DO TWO BUILDS OF THE SAME THING DIFFER?
#
# The reproducibility check says two artifacts differ. This says WHERE, which
# is usually enough to name the cause without a second round.
#
# THE SHORTCUT THIS EXPLOITS. When two builds have the SAME SIZE, nothing about
# the content's shape changed -- no reordering, no different code, no different
# inputs. Something wrote different values into the same slots. That is a small
# and enumerable set of causes, and the byte offsets distinguish them:
#
#   a handful of bytes, one contiguous run     a timestamp, a build-id, a UUID
#   ~20 bytes in .note.gnu.build-id            the build-id, and CONTENT
#                                              differed first -- keep looking
#   scattered through .rodata / .strtab        symbol names: -frandom-seed
#   scattered through .text                    code generation ordering
#   only in the archive/section headers        `ar` member mtimes -- use `ar D`
#
# Different sizes mean something structural changed and this tool is the wrong
# one; reach for diffoscope, which recurses into archives and compressed data.
#
# usage: repro-diff.sh <a> <b>
set -eu

A="${1:-}"; B="${2:-}"
[ -n "$A" ] && [ -n "$B" ] || { echo "usage: $0 <a> <b>"; exit 2; }
[ -f "$A" ] && [ -f "$B" ] || { echo "FAIL: both paths must exist"; exit 2; }

SA=$(wc -c < "$A"); SB=$(wc -c < "$B")
printf '  A  %-52s %12s bytes  %s\n' "$A" "$SA" "$(sha256sum "$A" | cut -c1-16)…"
printf '  B  %-52s %12s bytes  %s\n' "$B" "$SB" "$(sha256sum "$B" | cut -c1-16)…"
echo

if [ "$SA" = "$SB" ] && cmp -s "$A" "$B"; then
    echo "  IDENTICAL."
    exit 0
fi

if [ "$SA" != "$SB" ]; then
    echo "  SIZES DIFFER by $((SB - SA)) bytes."
    echo "  Something structural changed -- ordering, content, or compression."
    echo "  This tool localises same-size differences; use diffoscope here."
    exit 1
fi

# Same size: localise.
cmp -l "$A" "$B" > /tmp/rd-bytes.txt 2>/dev/null || true
N=$(wc -l < /tmp/rd-bytes.txt)
printf '  SAME SIZE, %s differing bytes (%s%% of the file)\n' \
    "$N" "$(( N * 100 / SA ))"
echo

# Contiguous runs, because "12 bytes at one offset" and "12 bytes scattered
# over 4MB" have completely different causes.
awk '{ off=$1+0
       if (off != prev+1) { if (start) printf "    %-12s %-12s %s\n", start, prev, prev-start+1; start=off }
       prev=off }
     END { if (start) printf "    %-12s %-12s %s\n", start, prev, prev-start+1 }' \
    /tmp/rd-bytes.txt > /tmp/rd-runs.txt
R=$(wc -l < /tmp/rd-runs.txt)
printf '  in %s contiguous run(s)\n' "$R"
printf '    %-12s %-12s %s\n' "first" "last" "length"
head -20 /tmp/rd-runs.txt
[ "$R" -gt 20 ] && echo "    … $((R - 20)) more"
echo

# THE ACTUAL BYTES, FOR SHORT RUNS. An offset says where; the bytes usually say
# what. Twenty contiguous bytes of high-entropy binary is a SHA-1; sixteen is an
# MD5; four that read as a plausible epoch is a timestamp; anything printable is
# a string and names itself. This was learned the slow way -- the compiler's
# sixteen bytes were identified only after downloading a 400 MB artifact and
# running `dd` by hand, and that whole round is avoided by printing them here.
#
# Short runs only: a diff scattered over megabytes is not read byte by byte, and
# dumping it would bury the summary that follows.
echo "  --- the differing bytes ---"
_shown=0
while read -r first last len; do
    [ "$len" -le 64 ] || continue
    [ "$_shown" -lt 8 ] || { echo "    …"; break; }
    off=$((first - 1))
    printf '    @%-10s len %-4s A: %s\n' "$off" "$len" \
        "$(dd if="$A" bs=1 skip="$off" count="$len" 2>/dev/null | od -An -tx1 | tr -s ' ' | tr -d '\n')"
    printf '    %-12s %-8s B: %s\n' "" "" \
        "$(dd if="$B" bs=1 skip="$off" count="$len" 2>/dev/null | od -An -tx1 | tr -s ' ' | tr -d '\n')"

    # THE SURROUNDING TEXT, WHICH IS USUALLY WHAT NAMES IT. Differing bytes
    # answer "what shape"; the string they sit inside answers "what thing".
    # Four ASCII hex characters could be anything; the same four inside
    # `...-g31EF` or `srcversion=...` identify themselves immediately, and the
    # alternative is a round of guessing at kernel internals.
    _ctx=$(( off > 56 ? off - 56 : 0 ))
    printf '    %-12s %-8s …: %s\n' "" "" \
        "$(dd if="$A" bs=1 skip="$_ctx" count=160 2>/dev/null \
           | tr -c '[:print:]' '.' | tr -s '.')"
    _shown=$((_shown + 1))
done < /tmp/rd-runs.txt
echo "    20 bytes of entropy is a SHA-1; 16 is an MD5; 4 that decode as an"
echo "    epoch is a timestamp; printable bytes name themselves."
echo

# Map each run onto an ELF section, which is what turns an offset into a cause.
if readelf -S "$A" >/dev/null 2>&1; then
    echo "  --- which ELF section each run falls in ---"
    # NO strtonum -- it is a gawk extension and the box has busybox awk.
    # Hex is converted with shell `printf`, which is POSIX.
    : > /tmp/rd-secs.txt
    readelf -S -W "$A" 2>/dev/null \
      | sed -n 's/^  \[[ 0-9]*\] *\([^ ]*\) *[^ ]* *[0-9a-f]* *\([0-9a-f]*\) *\([0-9a-f]*\).*/\1 \2 \3/p' \
      | while read -r _n _o _s; do
            case "$_o$_s" in *[!0-9a-fA-F]*|"") continue ;; esac
            printf '%s %d %d\n' "$_n" "$((0x$_o))" "$((0x$_s))" >> /tmp/rd-secs.txt
        done
    while read -r first last len; do
        off=$((first - 1))
        sec=$(awk -v o="$off" '$2 <= o && o < $2 + $3 { print $1; exit }' /tmp/rd-secs.txt)
        printf '    offset %-12s len %-8s %s\n' "$off" "$len" "${sec:-<no section>}"
    done < /tmp/rd-runs.txt | head -20
    echo
    # WHICH SECTIONS HOLD THE DIFFERENCES, BY VOLUME. On a gcc built with -g
    # this matters more than the offset list: .debug_info alone is 225 MB of a
    # 397 MB cc1 and .text is 25 MB, so a difference is ~9x more likely to land
    # in debug metadata than in code by chance alone. "Differs in .debug_info"
    # and "differs in .text" are a metadata bug and a codegen bug respectively,
    # and they get completely different attention.
    echo "  --- differing bytes per section ---"
    while read -r first last len; do
        off=$((first - 1))
        sec=$(awk -v o="$off" '$2 <= o && o < $2 + $3 { print $1; exit }' /tmp/rd-secs.txt)
        printf '%s %s\n' "${sec:-<none>}" "$len"
    done < /tmp/rd-runs.txt \
      | awk '{ n[$1]+=$2; c[$1]++ } END { for (s in n) printf "    %-24s %10d bytes in %d run(s)\n", s, n[s], c[s] }' \
      | sort -k2 -rn
    echo
    echo "  READ IT THIS WAY:"
    echo "    .debug_*            METADATA, not code. The compiler still works;"
    echo "                        the recorded line tables or DWARF strings vary."
    echo "                        Check -fdebug-prefix-map, and note that -g0 or"
    echo "                        a strip removes the whole surface."
    echo "    .text               CODE. A different compiler, not just a"
    echo "                        differently-described one. This is the"
    echo "                        serious case."
    echo "    .rodata .strtab     symbol names -- try -frandom-seed=<fixed>"
    echo "    .note.gnu.build-id  derived FROM content -- content differed"
    echo "                        first, this is a symptom"
    echo "    .comment            toolchain version strings"
    echo "    one short run only  a timestamp; find what embeds it"
else
    # NOT AN ELF -- say so, rather than silently printing nothing. A raw arm64
    # `Image` has no section table, and the first version of this tool skipped
    # the whole block without a word, which reads as "no sections differed".
    echo "  --- no ELF section table ---"
    echo "    $A is not an ELF (a raw arm64 Image, an archive, a disk image…),"
    echo "    so offsets cannot be mapped to sections. Read the bytes above."
fi

exit 1
