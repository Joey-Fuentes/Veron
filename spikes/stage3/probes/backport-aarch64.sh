#!/usr/bin/env bash
# Transplant gcc 4.8.5's aarch64 backend into a gcc 4.7.4 tree.
#
#   usage: backport-aarch64.sh <gcc-4.7.4-dir> <gcc-4.8.5-dir>
#
# WHY 4.8.5's BACKEND AND NOT 4.8.0's. gcc-backend-backport-probe measured the
# backend<->middle-end interface delta with a control: the vax backend, which
# nobody was developing, needed 15 files / 76+ / 72- across 4.7.4 -> 4.8.0 --
# and the IDENTICAL delta across 4.7.4 -> 4.8.5. The interface did not move
# within the 4.8 series, so 4.8.5's backend is no further from 4.7 than 4.8.0's
# while carrying ~1800 lines of fixes to a port that was one release old.
#
# The probe also found the backend uses 0 of the 21 target hooks new in 4.8
# (with a positive control proving the search works), and that all 40 symbols
# it references which 4.7 lacks are self-supplied: 30 gen_* emitted by genemit
# from the backend's own .md files, 1 from gengtype, 9 backend-local statics.
#
# EVERY PIECE MOVED IS NAMED BELOW. A backport that quietly drags in extra is
# not a reviewed delta.

set -euo pipefail

G47=${1:?usage: backport-aarch64.sh <4.7.4 dir> <4.8.5 dir>}
G48=${2:?usage: backport-aarch64.sh <4.7.4 dir> <4.8.5 dir>}
say() { printf '%s\n' "$*"; }

say "  before: 4.7.4 has $(grep -c aarch64 "$G47/gcc/config.gcc" || true) aarch64 mentions in config.gcc"

# ---------------------------------------------------------------- directories
# Three, not one. A port lives in gcc/config/<arch> plus gcc/common/config/<arch>
# (the target-independent option handling) plus libgcc/config/<arch> (the
# runtime). Missing either of the last two is the classic way a backport
# "almost" works and then fails late.
for d in "gcc/config/aarch64" "gcc/common/config/aarch64" "libgcc/config/aarch64"; do
    if [ -d "$G48/$d" ]; then
        mkdir -p "$G47/$(dirname "$d")"
        cp -r "$G48/$d" "$G47/$(dirname "$d")/"
        say "    copied $d ($(ls -1 "$G48/$d" | wc -l) files)"
    else
        say "    NOTE: 4.8.5 has no $d"
    fi
done

# ------------------------------------------------------------- data files
# config.sub and config.guess are standalone data files with no gcc coupling;
# replacing them wholesale is what gcc itself does when it syncs from
# config-patches. This is the only reason 4.7 cannot even NAME the target.
for f in config.sub config.guess; do
    cp "$G48/$f" "$G47/$f"
    # cp over an EXISTING file keeps the destination's mode, so a non-executable
    # placeholder would silently stay non-executable and configure would fail
    # with "Permission denied" much later.
    chmod +x "$G47/$f"
    say "    $f <- 4.8.5 ($(grep -c aarch64 "$G47/$f") aarch64 mentions)"
done

# ------------------------------------------------------------- case arms
# config.gcc has SEVERAL `case ${target} in` statements and a port needs arms in
# two of them:
#
#   1. the cpu_type table   -- sets cpu_type=aarch64, extra_objs, target_gtfiles
#   2. the main dispatch    -- sets tm_file, tmake_file, ...
#
# Run 1 spliced into whichever came first and the build died much later with
#     *** Configuration aarch64-unknown-linux-gnu not supported
# which is the main dispatch's catch-all `*)`. Both insertion points are found
# by CONTENT here, not by position:
#   - cpu_type table: the last `case ${target} in` before the first `cpu_type=`
#   - main dispatch : immediately before the `*)` whose body prints
#                     "*** Configuration ... not supported"
splice_config_gcc() {
    python3 - "$G48/gcc/config.gcc" "$G47/gcc/config.gcc" <<'PY'
import re, sys
srcf, dstf = sys.argv[1], sys.argv[2]
src = open(srcf).read()
dst_lines = open(dstf).read().splitlines(keepends=True)

arms = re.findall(r'^(aarch64[^\n]*\)\n(?:.*?\n)*?\t;;\n)', src, re.M)
if not arms:
    sys.exit("    FATAL: no aarch64 case arms found in 4.8.5 config.gcc")
cpu  = [a for a in arms if re.search(r'^\s*cpu_type=', a, re.M)]
main = [a for a in arms if a not in cpu]
print(f"    extracted {len(arms)} arm(s): {len(cpu)} cpu_type, {len(main)} dispatch")

# --- find every `case ${target} in` ... `esac` block --------------------
# THE REAL config.gcc HAS TEN OF THEM and FIVE "*** Configuration ... not
# supported" messages. Runs 3 and 4 used re.search for the FIRST message and
# put the dispatch arms in the cpu_type table (lines 281..334) while the actual
# per-target dispatch is lines 805..2665. Counting arms cannot detect that;
# only the block structure can.
blocks = []
open_at = None
for i, ln in enumerate(dst_lines):
    if ln.rstrip('\n') == 'case ${target} in':
        open_at = i
    elif ln.rstrip('\n') == 'esac' and open_at is not None:
        blocks.append((open_at, i))
        open_at = None
if not blocks:
    sys.exit("    FATAL: no 'case ${target} in' ... 'esac' blocks found")
for st, en in blocks:
    print(f"      block {st+1:>5}..{en+1:<5} {en-st:>5} lines")

# The per-target dispatch is by a wide margin the LARGEST block -- it carries
# an arm for every target gcc supports. That is unambiguous where "the case
# before the first catch-all message" was not.
dispatch = max(blocks, key=lambda b: b[1] - b[0])
print(f"    dispatch block  : lines {dispatch[0]+1}..{dispatch[1]+1} "
      f"({dispatch[1]-dispatch[0]} lines)")

# The cpu_type table is the block that assigns cpu_type.
cpu_block = None
for st, en in blocks:
    if any(re.match(r'\s*cpu_type=', l) for l in dst_lines[st:en]):
        cpu_block = (st, en); break
if cpu_block is None:
    sys.exit("    FATAL: no block assigns cpu_type=")
print(f"    cpu_type block  : lines {cpu_block[0]+1}..{cpu_block[1]+1}")
if cpu_block == dispatch:
    print("    NOTE: same block sets cpu_type and dispatches; inserting all arms once")
    ins = {dispatch[0]: cpu + main}
else:
    ins = {dispatch[0]: main, cpu_block[0]: cpu}

# Insert at each block head, later positions first so indices stay valid.
for at in sorted(ins, reverse=True):
    dst_lines[at+1:at+1] = ins[at]
    print(f"    spliced {len(ins[at])} arm(s) after line {at+1}")

open(dstf, 'w').write("".join(dst_lines))
PY
}

splice_config_host() {
    python3 - "$G48/libgcc/config.host" "$G47/libgcc/config.host" <<'PY'
import re, sys
srcf, dstf = sys.argv[1], sys.argv[2]
src = open(srcf).read()
dst_lines = open(dstf).read().splitlines(keepends=True)
arms = re.findall(r'^(aarch64[^\n]*\)\n(?:.*?\n)*?\t;;\n)', src, re.M)
if not arms:
    print("    libgcc/config.host: no aarch64 arms in 4.8.5"); sys.exit(0)
blocks, open_at = [], None
for i, ln in enumerate(dst_lines):
    if ln.rstrip('\n') == 'case ${host} in':
        open_at = i
    elif ln.rstrip('\n') == 'esac' and open_at is not None:
        blocks.append((open_at, i)); open_at = None
if not blocks:
    print("    libgcc/config.host: no 'case ${host} in' block found"); sys.exit(0)
st, en = max(blocks, key=lambda b: b[1] - b[0])
dst_lines[st+1:st+1] = arms
open(dstf, 'w').write("".join(dst_lines))
print(f"    libgcc/config.host: spliced {len(arms)} arm(s) into the largest block "
      f"(lines {st+1}..{en+1})")
PY
}

splice_config_gcc
splice_config_host

# FAIL HERE, NOT 20 MINUTES LATER. Run 1 spliced into the wrong case statement
# and the only symptom was a configure-gcc failure deep into the build.
n_arms=$(grep -c '^aarch64.*)$' "$G47/gcc/config.gcc" || true)
[ "$n_arms" -ge 2 ] || { say "  FATAL: only $n_arms aarch64 case arms in config.gcc"; exit 1; }
grep -q '^\s*cpu_type=aarch64' "$G47/gcc/config.gcc" || {
    say "  FATAL: cpu_type=aarch64 never set -- the cpu_type table was not patched"; exit 1; }
say "    verified: $n_arms aarch64 arms, cpu_type=aarch64 present"

# ------------------------------------------------------- structure + proof
# TWO RUNS HAVE NOW REPORTED A SUCCESSFUL SPLICE AND STILL HIT
#     *** Configuration aarch64-unknown-linux-gnu not supported
# so the arms are landing somewhere the dispatch does not read. Counting arms
# proves nothing about WHERE they are. Print the map, then prove it by sourcing
# the file the way gcc/configure does.
say ""
say "  === config.gcc structure (line numbers) ==="
say "    case \${target} in    : $(grep -n '^case ${target} in' "$G47/gcc/config.gcc" | cut -d: -f1 | tr '\n' ' ')"
say "    *** Configuration    : $(grep -n '\*\*\* Configuration' "$G47/gcc/config.gcc" | cut -d: -f1 | tr '\n' ' ')"
say "    our aarch64 arms     : $(grep -n '^aarch64.*)$' "$G47/gcc/config.gcc" | cut -d: -f1 | tr '\n' ' ')"
say "    esac                 : $(grep -n '^esac' "$G47/gcc/config.gcc" | cut -d: -f1 | tr '\n' ' ')"

say ""
say "  === PROOF: source config.gcc as gcc/configure does ==="
# config.gcc is a plain shell fragment. Sourcing it with the variables it reads
# is exactly what gcc/configure does: it either sets cpu_type/tm_file or prints
# "not supported" and exits 1. This turns a 40-minute build into an answer now.
#
# THE CHECK MUST HAPPEN IN THE PARENT. `exit 1` inside a SOURCED file
# terminates the shell running it, so any grep written after the `.` never
# executes -- the subshell is already gone. Everything the test learns has to
# be written to a file first and read back out here.
PROOF=$(mktemp)
prc=0
if ! (
    cd "$G47/gcc" || exit 1
    target=aarch64-unknown-linux-gnu
    target_cpu=aarch64 target_vendor=unknown target_os=linux-gnu
    host=aarch64-unknown-linux-gnu build=aarch64-unknown-linux-gnu
    srcdir=. enable_threads= enable_shared=yes enable_multilib=
    gcc_cv_as= gcc_cv_ld= with_cpu= with_arch= with_tune= with_abi=
    cpu_type= tm_file= tm_p_file= xm_file= extra_objs= extra_headers=
    tmake_file= target_gtfiles= extra_options= md_file=
    # shellcheck disable=SC1091
    . ./config.gcc > "$PROOF" 2>&1
    # Only reached if config.gcc did NOT exit.
    { echo "RESULT_cpu_type=${cpu_type:-}"
      echo "RESULT_tm_file=${tm_file:-}"; } >> "$PROOF"
)
# `( ... )` is a compound command: when config.gcc exits 1 the subshell returns
# 1, and under `set -e` that kills the script HERE -- before prc is assigned and
# before a single line of the verdict is printed. Every run so far ended at the
# "=== PROOF ===" header for this reason, so the verdict has never been seen.
# The status must be captured in a context set -e exempts.
then prc=1; fi
head -4 "$PROOF" | sed 's/^/    /'
cpu=$(sed -n 's/^RESULT_cpu_type=//p' "$PROOF")
tmf=$(sed -n 's/^RESULT_tm_file=//p' "$PROOF")

if grep -q 'not supported' "$PROOF"; then
    say "    config.gcc REJECTED the target."
    say "    -> the arms are in the wrong case statement; the map above says which."
    rm -f "$PROOF"
    exit 1
fi
if [ -n "$cpu" ]; then
    say "    SOURCED OK  cpu_type=$cpu  tm_file=${tmf:-<unset>}"
    [ "$cpu" = aarch64 ] || { say "    FATAL: cpu_type is $cpu, not aarch64"; rm -f "$PROOF"; exit 1; }
else
    say "    sourcing ended rc=$prc without saying 'not supported' and without"
    say "    setting cpu_type -- most likely this harness lacks a variable"
    say "    config.gcc wants, rather than a bad splice. Proceeding."
fi
rm -f "$PROOF"

say "  after : 4.7.4 has $(grep -c aarch64 "$G47/gcc/config.gcc" || true) aarch64 mentions in config.gcc"
say "  target recognised: $(cd "$G47" && ./config.sub aarch64-unknown-linux-gnu 2>&1)"
