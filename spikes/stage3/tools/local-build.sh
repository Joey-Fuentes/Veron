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
[ "$n" -ge 25 ] || { echo "  FAIL: expected at least 25, got $n"; exit 1; }

gcc -w -o micro-c \
    m2-planet/cc.c m2-planet/cc_core.c m2-planet/cc_emit.c \
    m2-planet/cc_globals.c m2-planet/cc_macro.c m2-planet/cc_reader.c \
    m2-planet/cc_strings.c m2-planet/cc_types.c \
    "$ROOT/spikes/reference/m2libc/bootstrappable.c"
echo "  micro-c built"

# ---------------------------------------------------------------------------
# 1b. THE SAME COMPILER, ONE PATCH BACK.
#
# EXPERIMENT-zzb widens every integer literal to 64 bits and adds an emission
# path that is UNREACHABLE below 0x7FFFFFFF. The guard for a change of that
# shape is not "does it work" -- difftest answers that -- but "did anything
# ELSE move", and the only thing that can answer it is the compiler as it was
# immediately before. It costs one gcc invocation, which is seconds.
# ---------------------------------------------------------------------------
rm -rf m2-planet-pre
cp -r "$ROOT/spikes/reference/m2-planet" m2-planet-pre
git -C m2-planet-pre init -q
git -C m2-planet-pre config user.email local@veron
git -C m2-planet-pre config user.name local
pre=0
for p in "$ROOT"/spikes/stage3/patches/m2-planet/[0-9]*.patch \
         "$ROOT"/spikes/stage3/patches/micro-c-experiments/EXPERIMENT-*.patch; do
    [ -e "$p" ] || continue
    case "$(basename "$p")" in EXPERIMENT-zzb-*) continue ;; esac
    (cd m2-planet-pre && git apply --ignore-whitespace "$p") \
        || { echo "  FAIL (pre): $(basename "$p")"; exit 1; }
    pre=$((pre + 1))
done
[ "$pre" = "$((n - 1))" ] \
    || { echo "  FAIL: pre-zzb tree has $pre patches, expected $((n - 1))"; exit 1; }
gcc -w -o micro-c-pre \
    m2-planet-pre/cc.c m2-planet-pre/cc_core.c m2-planet-pre/cc_emit.c \
    m2-planet-pre/cc_globals.c m2-planet-pre/cc_macro.c m2-planet-pre/cc_reader.c \
    m2-planet-pre/cc_strings.c m2-planet-pre/cc_types.c \
    "$ROOT/spikes/reference/m2libc/bootstrappable.c"
echo "  micro-c-pre built from $pre patches (the same tree without zzb)"

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
    "$WORK/micro-c-pre" "$WORK/micro-c" | tail -3

echo
echo "== difftest, amd64 (native) =="
sh "$ROOT/spikes/stage3/tools/difftest.sh" \
    "$WORK/micro-c" "$WORK/m2libc" "$WORK/mescc-bin" | tail -4

echo
echo "== difftest, aarch64 (under the committed emulator) =="
sh "$ROOT/spikes/stage3/tools/difftest-qemu.sh" "$WORK" | tail -4

cat <<EOF

== ready ==

  $WORK/micro-c        the compiler
  $WORK/micro-c-pre    the same compiler without EXPERIMENT-zzb, for the
                       byte-identity guard only -- never assemble with it
  $WORK/m2libc         PATCHED -- assemble with this, never spikes/reference
  $WORK/mescc-bin/     M1 and hex2, M1 with the larger string buffer

Next: sh spikes/stage3/tools/local-tcc.sh $WORK
EOF
