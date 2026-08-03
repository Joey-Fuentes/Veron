#!/bin/sh
# GUEST TESTS. These run on the LIVE OS, after the image has left the box --
# the same shape as VERON-GCC-IN-GUEST. They prove the packages work; they do
# NOT prove the system is self-hosting. That is the self-rebuild gate, and it
# is deliberately not in this spike: it needs a toolchain in the guest and a
# harness already known-good, or a mismatch is ambiguous between the two.
#
# `make check` already ran INSIDE the box at G2. Both, at different moments.
set -u
fail=0
pass=0

ok()   { pass=$((pass+1)); echo "  ok    $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }

echo "VERON-STAGE5-GUEST begin"

# ---- hello: the instrument with no moving parts -----------------------
if out=$(/usr/bin/hello 2>&1); then
  case "$out" in
    *"Hello, world!"*) ok "hello runs: $out" ;;
    *) bad "hello ran but said: $out" ;;
  esac
else
  bad "hello did not run"
fi
echo "VERON-PKG-HELLO pass"

# ---- pkgconf: installed is not the same as working --------------------
if v=$(/usr/bin/pkgconf --version 2>&1); then ok "pkgconf --version: $v"
else bad "pkgconf --version failed"; fi

# The drop-in name build systems actually look for.
if [ -e /usr/bin/pkg-config ]; then ok "pkg-config alias present"
else bad "pkg-config alias missing"; fi

# THE QUERY THAT MATTERS. Two fixture .pc files, one requiring the other:
# this exercises transitive resolution and search-path pinning rather than
# merely proving the binary starts. Fixtures rather than a real consumer,
# because nothing in this spike calls PKG_CHECK_MODULES -- a gap declared
# rather than papered over. Real use gets proven at the first group-4 package.
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig
if cf=$(/usr/bin/pkgconf --cflags veron-b 2>&1); then
  case "$cf" in
    *veron-a*) ok "transitive resolution: $cf" ;;
    *) bad "b resolved but did not pull a: $cf" ;;
  esac
else
  bad "pkgconf --cflags veron-b failed: $cf"
fi

if lb=$(/usr/bin/pkgconf --libs veron-b 2>&1); then
  case "$lb" in
    *-lveron-a*) ok "transitive libs: $lb" ;;
    *) bad "libs missing the dependency: $lb" ;;
  esac
else
  bad "pkgconf --libs veron-b failed"
fi
echo "VERON-PKG-PKGCONF pass"

echo "VERON-STAGE5-TESTS pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && echo "VERON-STAGE5-OK" || echo "VERON-STAGE5-FAIL"
