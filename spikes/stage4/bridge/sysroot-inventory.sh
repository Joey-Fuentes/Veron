#!/bin/sh
# sysroot-inventory.sh -- WHERE THE 5.6 GB IS. Analysis only; mutates nothing.
#
# Runs inside the box after phase B, against the live sysroot. Answers four
# questions that inference could not:
#
#   1. What is outside /usr and /lib? The manifest walks only those two, so
#      anything else -- leftover source trees, build scratch, /tmp -- is
#      INVISIBLE today and still ships in the 5.6 GB. `hashtree` reported
#      10,657 files in /usr and 0 in /lib; if that does not account for the
#      total, the difference has never been looked at.
#   2. How much is debug info? Four cc1/cc1plus binaries total 1.63 GB and
#      nothing in this tree is ever stripped.
#   3. How much is the duplicate triplet? aarch64-unknown-linux-gnu and
#      aarch64-veron-linux-gnu are both 15.2.0 -- the same compiler installed
#      twice -- and the duplication may run past libexec into /usr/lib/gcc,
#      where libstdc++.a and libgcc.a live.
#   4. What is byte-identical to something else? Same sha256 at two paths is
#      a hardlink or dedup opportunity, and it is free to detect because the
#      manifest already carries the hash.
#
# MEASURE BEFORE CUTTING. This runs first and alone. sysroot-trim.sh is the
# separate step that removes things, and it is default-off, because changing
# two things in one run means a failure cannot be attributed to either.
#
# busybox-compatible: POSIX sh, busybox awk/find/sort/wc. readelf comes from
# the sysroot's own binutils; if it is absent the debug section degrades to a
# heuristic rather than failing.

set -u

ROOT=${1:-/}
OUT=${INVENTORY:-/out/inventory.txt}
TOPN=${TOPN:-40}

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
: > "$OUT"

emit() { printf '%s\n' "$*" | tee -a "$OUT"; }
hr()   { emit ""; emit "  === $* ==="; }

human() {
    # busybox awk has no printf("%'d"), so scale by hand.
    awk -v b="$1" 'BEGIN{
        split("B KB MB GB TB", u, " "); i=1
        while (b >= 1024 && i < 5) { b/=1024; i++ }
        printf "%.1f%s", b, u[i]
    }'
}

emit "VERON SYSROOT INVENTORY"
emit "  root: $ROOT"
emit ""

# ---------------------------------------------------------------- the walk
#
# ONE PASS, recorded to a temp file, because walking a 5.6 GB tree repeatedly
# is the slow part and every section below is a query over the same data.
TMP=${TMPDIR:-/tmp}/inv.$$
find "$ROOT" -xdev \( -path '*/proc/*' -o -path '*/sys/*' -o -path '*/dev/*' \) -prune -o \
     -type f -print 2>/dev/null | LC_ALL=C sort > "$TMP.paths"

: > "$TMP.rows"
while IFS= read -r f; do
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    printf '%s\t%s\n' "$sz" "$f" >> "$TMP.rows"
done < "$TMP.paths"

TOTAL=$(awk -F'\t' '{s+=$1} END{print s+0}' "$TMP.rows")
COUNT=$(wc -l < "$TMP.rows")
emit "  $COUNT files, $(human "$TOTAL") total"

# ---------------------------------------------------------------- top level
hr "BY TOP-LEVEL DIRECTORY"
emit "  the manifest walks /usr and /lib ONLY. Anything else below has never"
emit "  been hashed, recorded, or looked at -- and still ships."
awk -F'\t' -v root="$ROOT" '
{
    p = $2
    sub("^" root, "", p); sub("^/", "", p)
    n = index(p, "/"); d = (n ? substr(p, 1, n-1) : ".")
    sz[d] += $1; ct[d]++
}
END { for (d in sz) printf "%s\t%s\t%s\n", sz[d], ct[d], d }
' "$TMP.rows" | LC_ALL=C sort -rn | while IFS="$(printf '\t')" read -r sz ct d; do
    mark=""
    case "$d" in usr|lib) mark="  [manifested]" ;; *) mark="  [NOT IN MANIFEST]" ;; esac
    printf '    %-14s %10s files  %s%s\n' "$(human "$sz")" "$ct" "/$d" "$mark" | tee -a "$OUT"
done

hr "BY SECOND LEVEL UNDER /usr"
awk -F'\t' -v root="$ROOT" '
{
    p = $2
    sub("^" root, "", p); sub("^/", "", p)
    if (p !~ /^usr\//) next
    rest = substr(p, 5)
    n = index(rest, "/"); d = (n ? substr(rest, 1, n-1) : ".")
    sz[d] += $1; ct[d]++
}
END { for (d in sz) printf "%s\t%s\t%s\n", sz[d], ct[d], d }
' "$TMP.rows" | LC_ALL=C sort -rn | head -20 | while IFS="$(printf '\t')" read -r sz ct d; do
    printf '    %-14s %10s files  /usr/%s\n' "$(human "$sz")" "$ct" "$d" | tee -a "$OUT"
done

# ---------------------------------------------------------------- biggest
hr "THE $TOPN LARGEST FILES"
LC_ALL=C sort -rn "$TMP.rows" | head -"$TOPN" | while IFS="$(printf '\t')" read -r sz f; do
    printf '    %-12s %s\n' "$(human "$sz")" "$f" | tee -a "$OUT"
done

# ---------------------------------------------------------------- triplets
hr "TRIPLET DUPLICATION"
emit "  Two installs of the SAME gcc 15.2.0. The cross triplet is scaffolding:"
emit "  its job is recorded in the ledger, so it does not need to survive. It is"
emit "  also a DETECTION HAZARD -- a triplet-prefixed gcc on the path is how a"
emit "  configure script silently decides it is cross-compiling."
for t in aarch64-unknown-linux-gnu aarch64-veron-linux-gnu; do
    sz=$(awk -F'\t' -v t="$t" '$2 ~ t {s+=$1; c++} END{printf "%s %s", s+0, c+0}' "$TMP.rows")
    b=$(echo "$sz" | cut -d' ' -f1); c=$(echo "$sz" | cut -d' ' -f2)
    printf '    %-32s %-12s %6s files\n' "$t" "$(human "$b")" "$c" | tee -a "$OUT"
done
emit ""
emit "  where each triplet's bytes live:"
awk -F'\t' '$2 ~ /aarch64-(unknown|veron)-linux-gnu/ {
    p=$2
    sub(/\/[^\/]*$/, "", p)
    sz[p]+=$1
} END { for (d in sz) printf "%s\t%s\n", sz[d], d }' "$TMP.rows" \
  | LC_ALL=C sort -rn | head -12 | while IFS="$(printf '\t')" read -r sz d; do
    printf '    %-12s %s\n' "$(human "$sz")" "$d" | tee -a "$OUT"
done

# ---------------------------------------------------------------- debug
hr "DEBUG INFO -- THE STRIPPABLE BYTES"
emit "  Nothing in this tree is ever stripped: there is no strip, install-strip"
emit "  or -s anywhere in rungs-sysroot.sh, and --disable-bootstrap leaves"
emit "  gcc's default -g -O2 in its own binaries."
RE=$(command -v readelf 2>/dev/null || echo /usr/bin/readelf)
if [ -x "$RE" ]; then
    dbg=0; n=0
    # Only files worth asking about; readelf on 10k files is slow.
    LC_ALL=C sort -rn "$TMP.rows" | head -200 | while IFS="$(printf '\t')" read -r sz f; do
        [ "$sz" -gt 1048576 ] || continue
        d=$("$RE" -S "$f" 2>/dev/null | awk '
            /\.debug_/ { getline sizeline; }
            /\.debug_/ { found=1 }
            END { print (found ? 1 : 0) }')
        [ "$d" = 1 ] && printf '%s\t%s\n' "$sz" "$f"
    done > "$TMP.dbg" 2>/dev/null || true
    if [ -s "$TMP.dbg" ]; then
        dsz=$(awk -F'\t' '{s+=$1} END{print s+0}' "$TMP.dbg")
        dct=$(wc -l < "$TMP.dbg")
        emit "    $dct large files carry .debug_* sections, $(human "$dsz") of file size"
        emit "    (file size, not section size -- run `strip` to get the true delta)"
        head -15 "$TMP.dbg" | while IFS="$(printf '\t')" read -r sz f; do
            printf '      %-12s %s\n' "$(human "$sz")" "$f" | tee -a "$OUT"
        done
    else
        emit "    no .debug_* sections found in the largest 200 files"
    fi
else
    emit "    readelf not available; skipped. A cc1 at ~400 MB against a"
    emit "    stripped norm of 30-50 MB is the signature regardless."
fi

# ---------------------------------------------------------------- dupes
hr "BYTE-IDENTICAL FILES"
emit "  Same content at two paths. Free to detect and often free to hardlink."
MAN=${MANIFEST:-/out/manifest.tsv}
if [ -s "$MAN" ]; then
    awk -F'\t' 'NF>=4 && $4 != "" { c[$4]++; s[$4]=$3; if (c[$4]==2) dup[$4]=1 }
                END { t=0; n=0; for (h in dup) { t += s[h]*(c[h]-1); n++ }
                      printf "    %d duplicated hashes, %d wasted bytes\n", n, t }' "$MAN" \
      | tee -a "$OUT"
else
    emit "    no manifest.tsv -- skipped (it carries the hashes already)"
fi

# ---------------------------------------------------------------- statics
hr "STATIC LIBRARIES AND SHARE"
for pat in '*.a' '*.o' '*.la'; do
    sz=$(awk -F'\t' -v p="$pat" 'BEGIN{gsub(/\*/,"",p)} $2 ~ p"$" {s+=$1;c++} END{printf "%s %s", s+0, c+0}' "$TMP.rows")
    b=$(echo "$sz" | cut -d' ' -f1); c=$(echo "$sz" | cut -d' ' -f2)
    printf '    %-8s %-12s %6s files\n' "$pat" "$(human "$b")" "$c" | tee -a "$OUT"
done
emit ""
emit "  .la files are the classic thing that breaks when an old toolchain is"
emit "  removed -- they hardcode paths into it, and they fail late."

rm -f "$TMP.paths" "$TMP.rows" "$TMP.dbg" 2>/dev/null || true
emit ""
emit "VERON-INVENTORY-OK  $OUT"
