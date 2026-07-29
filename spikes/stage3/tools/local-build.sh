#!/bin/sh
# BUILD THE LOCAL STAGE-3 ENVIRONMENT FROM THIS REPOSITORY ALONE.
#
# Everything stage-3 work needs, built into one directory, so that micro-c can
# be run, difftest can be run on BOTH architectures, and tcc can be compiled
# and executed without a CI round.
#
#     sh spikes/stage3/tools/local-build.sh [workdir]      default: build/local
#
# Requires: gcc, git, tar. Nothing from the network.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS RATHER THAN A LIST OF COMMANDS IN A README
#
# Doing the obvious thing produces a compiler that segfaults on case 05, and
# the natural conclusion is that micro-c is broken. It is not. There are four
# traps between a clean checkout and a working local setup, every one of them
# silent, and three of them were found the hard way:
#
#   1. `git apply` INSIDE THIS REPOSITORY SKIPS AND EXITS 0.
#      git-apply(1): "When running from a subdirectory in a repository, patched
#      paths outside the directory are ignored." A plain copy of
#      spikes/reference/m2libc placed in the working tree is exactly that, so
#      git computes the prefix, judges the patch paths outside it, skips them
#      and succeeds. Nothing in the m2libc series applied for weeks because of
#      this. Every copy patched below gets `git init` first.
#
#   2. M1's max_string DEFAULTS TO 4096 AND tcc's KEYWORD TABLE IS BIGGER.
#      Without the substitution below, linking tcc dies with "exceeds max
#      string size" and then hex2 fails on a file that does not exist -- two
#      errors, neither naming the cause.
#
#   3. THE .M1 TABLES MUST COME FROM THE PATCHED m2libc.
#      Three aarch64 macros in the vendored table encode x16 as x8. They
#      assemble, link and run, and produce wrong arithmetic. Assembling
#      against the unpatched copy makes case 05 and case 46 segfault against a
#      compiler that passes them. Both CI workflows made this mistake.
#
#   4. CODE MUST PRECEDE STRINGS IN THE JOINED .M1.
#      Concatenating compilation units naively interleaves their string
#      sections, so a function can land on an address that is not a multiple of
#      four and every call to it is SIGBUS on aarch64. See join() in
#      local-tcc.sh.
#
# ---------------------------------------------------------------------------
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=${1:-$ROOT/build/local}
# ABSOLUTE, because these scripts cd into it and a relative path given on the
# command line stops resolving the moment they do.
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

echo "  repository: $ROOT"
echo "  work dir:   $WORK"
mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------------------
# 1. micro-c = M2-Planet at the pin + the patch series
# ---------------------------------------------------------------------------
echo
echo "== micro-c =="
rm -rf m2-planet
cp -r "$ROOT/spikes/reference/m2-planet" m2-planet

# TRAP 1. Give the copy its own repository so `git apply` resolves paths
# against it rather than against Veron. Without this every patch below is
# skipped and reports success.
git -C m2-planet init -q
git -C m2-planet config user.email local@veron
git -C m2-planet config user.name local

n=0
for p in "$ROOT"/spikes/stage3/patches/m2-planet/[0-9]*.patch \
         "$ROOT"/spikes/stage3/patches/micro-c-experiments/EXPERIMENT-*.patch; do
    [ -e "$p" ] || continue
    (cd m2-planet && git apply --ignore-whitespace "$p") \
        || { echo "  FAIL: $(basename "$p")"; exit 1; }
    n=$((n + 1))
done
echo "  $n patches applied"
[ "$n" -ge 30 ] || { echo "  FAIL: expected at least 30, got $n"; exit 1; }

gcc -w -o micro-c \
    m2-planet/cc.c m2-planet/cc_core.c m2-planet/cc_emit.c \
    m2-planet/cc_globals.c m2-planet/cc_macro.c m2-planet/cc_reader.c \
    m2-planet/cc_strings.c m2-planet/cc_types.c \
    "$ROOT/spikes/reference/m2libc/bootstrappable.c"
echo "  micro-c built"

# ---------------------------------------------------------------------------
# 1b. THE COMPILER EITHER SIDE OF EXPERIMENT-zzb, AS A SEQUENCE POINT.
#
# zzb widens every integer literal to 64 bits and adds an emission path that is
# UNREACHABLE below 0x7FFFFFFF. The guard for a change of that shape is not
# "does it work" -- difftest answers that -- but "did anything ELSE move", and
# only the compiler as it was immediately before can answer it.
#
# BOTH SIDES STOP AT zzb, and that is a correction. This used to build "every
# patch except zzb", which worked until zzf edited a line zzb had introduced
# and the pre tree stopped applying. Worse, once zzd..zzf landed the comparison
# was no longer about zzb at all: three later codegen patches were in one side
# and not the other, so the guard would have reported their changes as leaks.
#
# A guard whose meaning drifts as the series grows is worse than no guard,
# because it goes red for the wrong reason and then gets switched off. Pinning
# both sides to the same point in the series fixes the meaning permanently.
# ---------------------------------------------------------------------------
build_upto() {   # $1 = dir, $2 = stop-before basename glob, $3 = output binary
    rm -rf "$1"
    cp -r "$ROOT/spikes/reference/m2-planet" "$1"
    git -C "$1" init -q
    git -C "$1" config user.email local@veron
    git -C "$1" config user.name local
    _c=0
    for _p in "$ROOT"/spikes/stage3/patches/m2-planet/[0-9]*.patch \
              "$ROOT"/spikes/stage3/patches/micro-c-experiments/EXPERIMENT-*.patch; do
        [ -e "$_p" ] || continue
        case "$(basename "$_p")" in $2) break ;; esac
        (cd "$1" && git apply --ignore-whitespace "$_p") \
            || { echo "  FAIL ($1): $(basename "$_p")"; exit 1; }
        _c=$((_c + 1))
    done
    gcc -w -o "$3" "$1"/cc.c "$1"/cc_core.c "$1"/cc_emit.c "$1"/cc_globals.c \
        "$1"/cc_macro.c "$1"/cc_reader.c "$1"/cc_strings.c "$1"/cc_types.c \
        "$ROOT/spikes/reference/m2libc/bootstrappable.c"
    echo "  $3 built from $_c patches"
}
build_upto m2-planet-pre  'EXPERIMENT-zz[b-z]*'  micro-c-pre
build_upto m2-planet-zzb  'EXPERIMENT-zz[c-z]*'  micro-c-zzb

# ---------------------------------------------------------------------------
# 2. M2libc, patched. THE TABLES COME FROM HERE, NOT FROM spikes/reference.
# ---------------------------------------------------------------------------
echo
echo "== m2libc (patched) =="
rm -rf m2libc
cp -r "$ROOT/spikes/reference/m2libc" m2libc
git -C m2libc init -q                        # TRAP 1 again
git -C m2libc config user.email local@veron
git -C m2libc config user.name local

n=0
for p in "$ROOT"/spikes/stage3/patches/m2libc/[0-9]*.patch; do
    [ -e "$p" ] || continue
    (cd m2libc && git apply --ignore-whitespace "$p") \
        || { echo "  FAIL: $(basename "$p")"; exit 1; }
    n=$((n + 1))
done
echo "  $n patches applied"
[ "$n" -ge 5 ] || { echo "  FAIL: expected at least 5, got $n"; exit 1; }

# TRAP 3. Assert the encoding fix is present in the table that will be
# assembled with. "The patch was applied" and "the fix is there" are different
# claims; only the second one matters.
grep -q '^DEFINE add_x0,x16,x0 0002008b' m2libc/aarch64/aarch64_defs.M1 \
    || { echo "  FAIL: the aarch64 table is still wrong"; exit 1; }
grep -q 'define va_copy(ap1, ap2) ap1 = ap2' m2libc/stdarg.h \
    || { echo "  FAIL: va_copy is still reversed"; exit 1; }
python3 "$ROOT/spikes/stage3/tools/verify_defs.py" \
    m2libc/aarch64/aarch64_defs.M1 | sed 's/^/  /'

# TRAP 5. THE 64-BIT IMMEDIATE MACROS CANNOT BE CHECKED BY ANY ASSEMBLER HERE,
# so they are checked by RUNNING them -- see verify-imm64.sh. It needs M1/hex2,
# so it is called at the end of section 3 rather than here.

# ---------------------------------------------------------------------------
# 3. mescc-tools: M1 and hex2
# ---------------------------------------------------------------------------
echo
echo "== M1 and hex2 =="
rm -rf mescc
cp -r "$ROOT/spikes/reference/mescc-tools" mescc
mkdir -p mescc/M2libc
cp "$ROOT/spikes/reference/m2libc/bootstrappable.c" \
   "$ROOT/spikes/reference/m2libc/bootstrappable.h" mescc/M2libc/

# TRAP 2. tcc's keyword table is one string far longer than M1's default
# buffer. Assert the literal is there before substituting, so an upstream
# change reads as a pin failure rather than a truncation that looks like a
# codegen bug.
grep -q 'max_string = 4096,' mescc/M1-macro.c \
    || { echo "  FAIL: M1-macro.c no longer contains 'max_string = 4096,'"
         grep -n 'max_string' mescc/M1-macro.c; exit 1; }
sed -i 's/max_string = 4096,/max_string = 262144,/' mescc/M1-macro.c
grep -q 'max_string = 262144,' mescc/M1-macro.c || { echo "  FAIL: sed"; exit 1; }
echo "  M1 max_string raised to 262144"

gcc -w -o M1   mescc/M1-macro.c mescc/stringify.c mescc/M2libc/bootstrappable.c
gcc -w -o hex2 mescc/hex2_linker.c mescc/hex2_word.c mescc/hex2.c \
               mescc/M2libc/bootstrappable.c
mkdir -p mescc-bin && cp M1 hex2 mescc-bin/
echo "  built"

# ---------------------------------------------------------------------------
# 3b. The 64-bit immediate vocabulary, proven by executing it
# ---------------------------------------------------------------------------
echo
echo "== 64-bit immediate macros =="
sh "$ROOT/spikes/stage3/tools/verify-imm64.sh" "$WORK" | tail -3

# ---------------------------------------------------------------------------
# 4. Prove it, on both architectures
# ---------------------------------------------------------------------------
echo
echo "== the 64-bit widening moved nothing it should not have =="
sh "$ROOT/spikes/stage3/tools/imm-identity.sh" \
    "$WORK/micro-c-pre" "$WORK/micro-c-zzb" | tail -3

echo
echo "== difftest, amd64 (native) =="
sh "$ROOT/spikes/stage3/tools/difftest.sh" \
    "$WORK/micro-c" "$WORK/m2libc" "$WORK/mescc-bin" | tail -4

echo
echo "== difftest, aarch64 (under the committed emulator) =="
sh "$ROOT/spikes/stage3/tools/difftest-qemu.sh" "$WORK" | tail -4

echo
echo "== stage 2's conformance corpus, run through micro-c (aarch64) =="
# 426 SMALL C PROGRAMS WRITTEN FOR A DIFFERENT COMPILER.
#
# tools/cases/ was written FROM bugs already found, so it measures what has
# been fixed. This corpus was written against pico-c, for a different rung, by
# someone not looking for micro-c's bugs -- so every failure in it is a
# construct nobody here chose. Three of them were live codegen bugs that the
# case suite had been green over for rounds, including one on tcc's own data
# structures.
ARCH=aarch64 sh "$ROOT/spikes/stage3/tools/stage2-corpus.sh" \
    "$WORK/micro-c" "$WORK/m2libc" "$WORK/mescc-bin" | tail -3

cat <<EOF

== ready ==

  $WORK/micro-c        the compiler
  $WORK/micro-c-pre    the series stopped just BEFORE zzb
  $WORK/micro-c-zzb    the series stopped just AFTER zzb
                       both exist only for the byte-identity guard -- never
                       assemble anything with either
  $WORK/m2libc         PATCHED -- assemble with this, never spikes/reference
  $WORK/mescc-bin/     M1 and hex2, M1 with the larger string buffer

Next: sh spikes/stage3/tools/local-tcc.sh $WORK
EOF
