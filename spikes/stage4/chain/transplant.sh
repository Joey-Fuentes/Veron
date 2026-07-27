#!/bin/sh
# transplant.sh -- unpack gcc 4.7.4 and 4.8.5 and move 4.8's aarch64 backend
# into 4.7, INSIDE the box.
#
# WHY THIS IS A SEPARATE SCRIPT AND NOT A `run:` BLOCK. It used to be a `run:`
# block on the host, which put the entire transplant -- seven python3 call
# sites, two of them our own source rewriters -- outside the sandbox. The box's
# purpose is that an undeclared dependency fails loudly rather than being
# quietly satisfied, and nothing outside it gets that. The tree the box
# compiles has to be the tree the box produced.
#
# WHAT IS BORROWED HERE, NAMED: python3, tar, and sh, all from the same
# read-only /usr as make and bison. Every C and C++ driver is masked, so
# nothing in this step can compile anything -- it rewrites source and stops.
set -u
. /work/versions.env
cd /work
say() { printf '%s\n' "$*"; }

say "  --- unpacking, inside ---"
[ -d "gcc-$GCC47" ] || tar xf "/work/src/gcc-$GCC47.tar.bz2" || exit 1
[ -d "gcc-$GCC48" ] || tar xf "/work/src/gcc-$GCC48.tar.bz2" || exit 1
say "    gcc-$GCC47  gcc-$GCC48"

say "  --- python available to the transplant ---"
python3 --version 2>&1 | sed 's/^/    /' || { say "    NO python3 IN THE BOX"; exit 1; }

# PROVE THE MASK STILL HOLDS AT THIS POINT. python3 is in the box; a C compiler
# is not, and this step is the one place where that pairing could look
# surprising to a reader. Assert it rather than asking them to trust the
# --show-mask output from three steps earlier.
if command -v gcc > /dev/null 2>&1 && gcc --version > /dev/null 2>&1; then
  say "    A WORKING gcc IS VISIBLE IN THE BOX -- the mask has failed"
  exit 1
fi
say "    no working C compiler in the box (as intended)"

say "  --- transplant ---"
# /repo keeps the repository's real shape because the script finds its own
# tools with dirname($0)/../../..
bash /repo/spikes/stage4/probes/backport-aarch64.sh "gcc-$GCC47" "gcc-$GCC48" \
  > /work/transplant-detail.log 2>&1
rc=$?
tail -8 /work/transplant-detail.log | sed 's/^/    /'
if [ "$rc" -ne 0 ]; then
  say "  TRANSPLANT FAILED rc=$rc"
  grep -nE "error|ERROR|FAIL" /work/transplant-detail.log | head -15 | sed 's/^/    /'
  exit "$rc"
fi

# ASSERT THE TRANSPLANT ACTUALLY LANDED. rc=0 from a script that ends in a
# summary is not evidence that config.gcc now knows the target; check the thing
# the next step depends on.
if ! grep -q aarch64 "gcc-$GCC47/gcc/config.gcc"; then
  say "  transplant returned 0 but config.gcc has no aarch64 -- stopping"
  exit 1
fi
say "  aarch64 present in gcc-$GCC47/gcc/config.gcc"
exit 0
