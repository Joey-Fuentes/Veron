#!/bin/sh
# BUILD tcc WITH micro-c AND RUN IT. Locally, in about a minute.
#
#     sh spikes/stage3/tools/local-tcc.sh [workdir]
#     sh spikes/stage3/tools/local-tcc.sh [workdir] FILE FUNC[,FUNC...]
#
# With no extra arguments it builds a plain tcc and runs it on a trivial
# program. With a file and function list it instruments those functions first,
# so the last marker names the statement execution reached -- which is the loop
# every stage-3 fault has been found with:
#
#     sh .../local-tcc.sh build/local tccpp.c macro_subst,macro_subst_tok
#
# Run local-build.sh first.
#
# ---------------------------------------------------------------------------
# THE TWO THINGS THAT ARE NOT OBVIOUS
#
# CODE BEFORE STRINGS. Concatenating compilation units naively interleaves
# their string sections, so a function can land on an address that is not a
# multiple of four and every call to it is SIGBUS on aarch64. join() below
# splits each unit at its "# Program strings" line and emits all the code
# first. This is not an optimisation; without it nothing runs.
#
# THE TABLES COME FROM THE PATCHED m2libc. Three aarch64 macros in the vendored
# copy encode x16 as x8, which assembles and links and computes garbage. $M
# below is the patched tree local-build.sh produced, never spikes/reference.
#
# WHAT instrument.py CANNOT DO. It will not place markers inside a switch body
# -- the result is "ERROR in process_switch / MISSING }" -- so next_nomacro and
# tok_str_add2 have to be probed by hand. And a fault OUTSIDE the instrumented
# set appears as the last marker INSIDE it, which looks identical to a fault at
# that line. Check the frequency column: a "last statement" that ran 980 times
# is a loop body, not a crash site.
# ---------------------------------------------------------------------------
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=${1:-$ROOT/build/local}
# ABSOLUTE, because these scripts cd into it and a relative path given on the
# command line stops resolving the moment they do.
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
INST_FILE=${2:-}
INST_FUNCS=${3:-}

MC="$WORK/micro-c"
M="$WORK/m2libc"
L="$ROOT/spikes/stage3/micro-c-libc"
D="$M/aarch64"
Q="$ROOT/spikes/toolbox/qemu-aarch64-static"

[ -x "$MC" ] || { echo "FAIL: run local-build.sh first"; exit 1; }
grep -q '^DEFINE add_x0,x16,x0 0002008b' "$D/aarch64_defs.M1" \
    || { echo "FAIL: $M is the UNPATCHED m2libc"; exit 1; }

cd "$WORK"

# --- tcc source, already configured -----------------------------------------
if [ ! -d tcc-src ]; then
    echo "== unpacking tcc =="
    tar -xzf "$ROOT/spikes/toolbox/tcc-5ec0e6f8-arm64-configured.tar.gz"
    [ -f tcc-src/config.h ] || { echo "FAIL: no config.h in the tarball"; exit 1; }
    echo "  tcc-src ready (config.h and tccdefs_.h are pre-generated)"
fi

rm -rf tcc-work && cp -r tcc-src tcc-work

# --- optional instrumentation -----------------------------------------------
if [ -n "$INST_FILE" ] && [ -n "$INST_FUNCS" ]; then
    echo "== instrumenting $INST_FILE: $INST_FUNCS =="
    python3 "$ROOT/spikes/stage3/tools/instrument.py" --map --prefix P \
        "tcc-work/$INST_FILE" "$INST_FUNCS" > marker-map.txt \
        || { echo "FAIL: could not instrument"; exit 1; }
    python3 "$ROOT/spikes/stage3/tools/instrument.py" --prefix P \
        "tcc-work/$INST_FILE" "$INST_FUNCS" > /tmp/inst.$$ 2>/dev/null
    mv /tmp/inst.$$ "tcc-work/$INST_FILE"
    echo "  $(wc -l < marker-map.txt) statements mapped -> $WORK/marker-map.txt"
fi

# --- compile ----------------------------------------------------------------
# NO -D TCC_TARGET_ARM64 -- config.h defines it, and CONFIG_TRIPLET with it.
# config.h guards those behind
#     #if !(TCC_TARGET_I386 || ... || TCC_TARGET_ARM64 || ...)
# so a command-line target WINS and the whole block is skipped. Passing the
# -D therefore left CONFIG_TRIPLET undefined, tcc.h fell to
#     # define USE_TRIPLET(s) s
# and the crt prefix came out as a bare /usr/lib -- no crt1.o there, so every
# link failed. configure's --triplet cannot help: the text lands inside the
# block that never runs.
echo "== micro-c compiles libtcc.c (about 30 s, silent) =="
( cd tcc-work && "$MC" --architecture aarch64 --expand-includes --max-string 65536 \
    -D ONE_SOURCE=1 -D TCC_TARGET_LINUX=1 \
    -D CONFIG_TCC_STATIC=1 -I . -I "$L" -I "$M" \
    -f libtcc.c -o ../libtcc.M1 )
echo "  libtcc.M1: $(wc -l < libtcc.M1) lines, $(grep -c '^:FUNCTION_' libtcc.M1) functions"

echo "== the runtime under it =="
H="-f $M/stdarg.h -f $M/sys/types.h -f $M/stddef.h -f $M/signal.h -f $M/sys/utsname.h"
# shellcheck disable=SC2086
"$MC" --architecture aarch64 --max-string 65536 \
    -f "$M/ctype.c" $H \
    -f "$M/aarch64/linux/unistd.c" -f "$M/aarch64/linux/fcntl.c" \
    -f "$M/fcntl.c" -f "$M/stdlib.c" -f "$M/string.c" \
    -f "$M/stdio.h" -f "$M/stdio.c" -f "$M/bootstrappable.c" -o m2libc.M1
"$MC" --architecture aarch64 --max-string 65536 -I "$L" -f "$L/impl/runtime.c" -o runtime.M1
"$MC" --architecture aarch64 --max-string 65536 -f "$L/impl/setjmp-aarch64.c" -o setjmp.M1
"$MC" --architecture aarch64 --max-string 65536 -f "$L/impl/main-tcc.c" -o maintcc.M1
echo "  m2libc $(grep -c '^:FUNCTION_' m2libc.M1), runtime $(grep -c '^:FUNCTION_' runtime.M1)"

# --- link -------------------------------------------------------------------
# CODE BEFORE STRINGS. See the header.
join() {
    out="$1"; shift
    : > "$out.code"; : > "$out.strs"
    for f in "$@"; do
        sed '/^# Program strings$/,$d'   "$f" >> "$out.code"
        sed -n '/^# Program strings$/,$p' "$f" >> "$out.strs"
    done
    cat "$out.code" "$out.strs" > "$out"; rm -f "$out.code" "$out.strs"
}

echo "== assemble and link =="
join all.M1 libtcc.M1 m2libc.M1 runtime.M1 setjmp.M1 maintcc.M1
"$WORK/mescc-bin/M1" -f "$D/aarch64_defs.M1" -f "$D/libc-full.M1" -f all.M1 \
    --little-endian --architecture aarch64 -o all.hex2
"$WORK/mescc-bin/hex2" --architecture aarch64 --little-endian \
    --base-address 0x400000 -f "$D/ELF-aarch64.hex2" -f all.hex2 -o mc-tcc
chmod +x mc-tcc
echo "  mc-tcc: $(stat -c%s mc-tcc) bytes"

# --- run --------------------------------------------------------------------
echo "== run =="
printf 'int main(void) { return 7; }\n' > seven.c
set +e
timeout 120 "$Q" ./mc-tcc seven.c -o seven.out 2> marks.txt
rc=$?
set -e
echo "  exit: $rc"
[ "$rc" -gt 128 ] && echo "  SIGNAL $((rc - 128))"

echo "  stderr:"
grep -av '^[A-Z][0-9]*$' marks.txt | head -5 | sed 's/^/    /'

if [ -f marker-map.txt ]; then
    last=$(grep -aoE '^P[0-9]+' marks.txt | tail -1)
    echo "  markers printed: $(grep -acE '^P[0-9]+' marks.txt)"
    echo "  LAST STATEMENT THAT COMPLETED: $last"
    grep "^$last " marker-map.txt | sed 's/^/    /'
    echo "  frequency (a count > 1 is a loop body, not a crash site):"
    grep -aoE '^P[0-9]+' marks.txt | sort | uniq -c | sort -rn | head -5 \
        | awk '{printf "    %-6s x%s\n", $2, $1}'
fi

echo
echo "  everything is in $WORK -- mc-tcc, marks.txt, marker-map.txt"
