#!/bin/sh
# DOES THE 64-BIT IMMEDIATE VOCABULARY ACTUALLY WORK? Run it and find out.
#
#     sh spikes/stage3/tools/verify-imm64.sh [workdir]      default: build/local
#
# Run local-build.sh first; this uses its patched m2libc and its M1/hex2.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
#
# patches/m2libc/0005 adds instructions that no assembler on this machine can
# check: there is no aarch64 `as` here. The previous time macros went into that
# table unchecked, three of them encoded x16 as x8 -- they assembled, linked,
# ran, and computed garbage for weeks, and case 05 was red the whole time for a
# reason nobody could see (see 0004-aarch64-defs-x16-in-the-rn-field.patch).
#
# So these are checked by EXECUTION instead. A 64-bit constant is put through
# the literal pool and read back out, and the process exit status carries the
# answer. That is a different question from "do the bytes match `as`" and in
# some ways a better one: byte-identity proves the encoding was TYPED right,
# running it proves the CPU DOES the intended thing.
#
# BOTH HALVES ARE CHECKED SEPARATELY, and that is the whole design of the test.
# A form that loaded only the low 32 bits -- which is exactly the bug being
# fixed -- would pass a low-byte check and fail the high-word one. Testing one
# half would have confirmed the broken behaviour.
#
# aarch64 runs under the committed emulator; amd64 runs natively. Rt is
# exercised below AND above 7, where the encoding's nibble carries.
#
# This does not replace a byte-anchor against real `as` in CI. qemu is an
# emulator, and this project has twice recorded qemu artefacts that did not
# survive native execution. It is the first evidence, not the last.
# ---------------------------------------------------------------------------
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=${1:-$ROOT/build/local}
WORK=$(cd "$WORK" && pwd)

M="$WORK/m2libc"
MESCC="$WORK/mescc-bin"

# NATIVE IF WE CAN, EMULATED IF WE MUST.
#
# On an aarch64 runner these binaries run directly, which answers the one
# caveat the emulator cannot: qemu is a model of the ISA, and this project has
# twice recorded qemu artefacts that did not survive native execution (see
# stage3/README.md, GATE 2 -- an M1 "hang" and a hex2 "crash" that were both
# the emulator). The same script therefore becomes a stronger check in CI than
# it is on the development machine, without being a second script that can
# drift from this one.
HOST=$(uname -m)
if [ "$HOST" = "aarch64" ]; then
    Q=""
    RUNNER="native"
else
    Q="$ROOT/spikes/toolbox/qemu-aarch64-static"
    RUNNER="qemu-aarch64-static"
    [ -x "$Q" ] || { echo "FAIL: no emulator at $Q and this host is not aarch64"; exit 1; }
fi

# AND THE amd64 HALF IS HOST-DEPENDENT IN THE MIRROR IMAGE, which is the thing
# this script got wrong on its first CI run. The aarch64 probes were made
# host-aware and the amd64 ones were left assuming an x86_64 host, so on the
# arm64 runner they tried to execute an amd64 binary and returned 126 --
# "found, not executable" -- which reads like a failed check rather than an
# unrunnable one.
#
# There is no committed x86_64 emulator (spikes/toolbox has qemu-aarch64-static
# and nothing else, because aarch64 is the reference architecture and x86_64 is
# what the development machine already is). So the amd64 probes RUN where they
# can and are SKIPPED, loudly, where they cannot. A skip is reported separately
# from a pass: this file exists because macros went unchecked once already, and
# a skip counted as a pass is how that happens again.
if [ "$HOST" = "x86_64" ]; then
    AMD64_RUNS=yes
else
    AMD64_RUNS=no
fi

[ -d "$M" ] || { echo "FAIL: no $M -- run local-build.sh first"; exit 1; }
[ -x "$MESCC/M1" ] || { echo "FAIL: no $MESCC/M1 -- run local-build.sh first"; exit 1; }

# ASSERT THE MACROS ARE THERE BEFORE TESTING THEM. "the patch applied" and "the
# macro is in the file the assembler will read" are different claims, and this
# repository has been caught by the difference more than once.
grep -q '^DEFINE ldr_x0,8 40000058' "$M/aarch64/aarch64_defs.M1" \
    || { echo "FAIL: ldr_x0,8 missing from the aarch64 table"; exit 1; }
grep -q '^DEFINE b_12 03000014' "$M/aarch64/aarch64_defs.M1" \
    || { echo "FAIL: b_12 missing from the aarch64 table"; exit 1; }
grep -q '^DEFINE movabs_rax, 48B8' "$M/amd64/amd64_defs.M1" \
    || { echo "FAIL: movabs_rax missing from the amd64 table"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 0x123456789ABCDEF0 as two little-endian words: low first.
LO=2596069104      # 0x9ABCDEF0
HI=305419896       # 0x12345678

pass=0
fail=0
skip=0

run_aarch64() {   # $1 = name  $2 = body  $3 = expected exit
    printf ':FUNCTION_main\n%s\nret\n\n:ELF_end\n' "$2" > "$T/t.M1"
    "$MESCC/M1" -f "$M/aarch64/aarch64_defs.M1" -f "$M/aarch64/libc-core.M1" \
        -f "$T/t.M1" --little-endian --architecture aarch64 -o "$T/t.hex2" >/dev/null 2>&1
    "$MESCC/hex2" --architecture aarch64 --little-endian --base-address 0x400000 \
        -f "$M/aarch64/ELF-aarch64.hex2" -f "$T/t.hex2" -o "$T/t.bin" >/dev/null 2>&1
    chmod +x "$T/t.bin"
    set +e
    if [ -n "$Q" ]; then "$Q" "$T/t.bin" >/dev/null 2>&1; else "$T/t.bin" >/dev/null 2>&1; fi
    got=$?
    set -e
    if [ "$got" = "$3" ]; then
        printf '  %-34s ok\n' "$1"; pass=$((pass + 1))
    else
        printf '  %-34s FAIL: exit %s, expected %s\n' "$1" "$got" "$3"; fail=$((fail + 1))
    fi
}

run_amd64() {
    printf ':FUNCTION_main\n%s\nret\n\n:ELF_end\n' "$2" > "$T/t.M1"
    "$MESCC/M1" -f "$M/amd64/amd64_defs.M1" -f "$M/amd64/libc-core.M1" \
        -f "$T/t.M1" --little-endian --architecture amd64 -o "$T/t.hex2" >/dev/null 2>&1
    "$MESCC/hex2" --architecture amd64 --little-endian --base-address 0x600000 \
        -f "$M/amd64/ELF-amd64.hex2" -f "$T/t.hex2" -o "$T/t.bin" >/dev/null 2>&1
    chmod +x "$T/t.bin"
    set +e; "$T/t.bin" >/dev/null 2>&1; got=$?; set -e
    if [ "$got" = "$3" ]; then
        printf '  %-34s ok\n' "$1"; pass=$((pass + 1))
    else
        printf '  %-34s FAIL: exit %s, expected %s\n' "$1" "$got" "$3"; fail=$((fail + 1))
    fi
}

echo "== aarch64, $RUNNER =="

# THE LOW BYTE. Proves the pool is read at all.
run_aarch64 "ldr_x0,8  low byte" \
    "ldr_x0,8
b_12
%$LO
%$HI" 240

# THE HIGH WORD. This is the one that discriminates: a 32-bit load leaves the
# top half zero and this returns 0 instead of 0x78.
run_aarch64 "ldr_x1,8  high word (the 64-bit test)" \
    "ldr_x1,8
b_12
%$LO
%$HI
mov_x0,32
lsr_x0,x1,x0" 120

# Rt below and above 7, where the encoding's nibble carries.
for r in 2 6 13 14 15 16; do
    run_aarch64 "ldr_x$r,8  register field" \
        "ldr_x$r,8
b_12
%240
%0
mov_x0,x$r" 240
done

echo
if [ "$AMD64_RUNS" = yes ]; then
    echo "== amd64, natively =="
    run_amd64 "movabs_rax  low byte" "movabs_rax, %$LO %$HI" 240
    run_amd64 "movabs_rbx  register field" "movabs_rbx, %$LO %$HI
mov_rax,rbx" 240
    run_amd64 "movabs_r14  register field" "movabs_r14, %$LO %$HI
mov_rax,r14" 240
else
    echo "== amd64: SKIPPED, this host is $HOST and cannot execute it =="
    echo "  the movabs macros are checked on the development machine, which is"
    echo "  x86_64; nothing here can run them, and pretending otherwise would"
    echo "  make a skip look like a pass"
    skip=$((skip + 3))
fi

echo
echo "  pass $pass   fail $fail   skipped $skip"
[ "$fail" = 0 ] || exit 1
