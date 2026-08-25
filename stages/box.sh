#!/bin/sh
# stages/box.sh -- run a stage script INSIDE the box, and nothing else.
#
#     sh stages/box.sh stages/3-micro-c/build.sh chain
#     sh stages/box.sh stages/3-micro-c/cross-amd64.sh chain
#     sh stages/box.sh stages/2-pico-c/verify.sh
#     sh stages/box.sh stages/1-self-assembly/rebaseline.sh verify
#
# THE DESIGN, IN ONE SENTENCE: the script is the thing that goes in the box.
# Everything a stage does that produces or measures a byte runs as a script
# executed by the box's own sh, with a PATH that resolves to the declared
# budget and nothing else. A script that says `make` fails "not found",
# because there is no make; a script that says `sha256sum --quiet` fails,
# because the box's sha256sum is busybox's. The seal is not something a
# script reaches into for individual steps -- the script never sees the
# host at all. (Measured the other way, 2026-08-25: the stage 1-3 scripts
# ran ON the runner and only wrapped nothing, so patch(1), GNU make, GNU
# tar and coreutils were all "in the budget" by default, and the ledger's
# "tier 2 = one static busybox" was true of a spike and false of the
# official jobs. This file is the correction.)
#
# THE BUDGET. Two tools, and they are declared here, not discovered:
#   busybox               tier 2, the driver: sh and every applet the
#                         scripts use. Ours by pin (sources/busybox.toml).
#   qemu-aarch64-static   tier 2, only when the host is not aarch64:
#                         executes the committed aarch64 seed. Ours by
#                         recipe (packages-amd64/qemu-user).
# Nothing is on the build path (tier 1). What the chain compiles with, it
# built. Both tools are substitutable -- the artifacts are a function of
# the seed, the pinned sources and the scripts, not of which busybox moved
# the bytes -- so the run RECORDS which bytes it used rather than refusing
# a foreign one: a different busybox reproducing the same records is the
# claim, proven.
#
# WHERE THE TOOLS COME FROM, in order, first hit wins, recorded either way:
#   1. $VERON_TOOLS/<tool>            explicit
#   2. $ROOT/veron-tools/<tool>       the stage-5 tools bundle, unpacked
#                                     beside the checkout (CI does this)
#   3. $ROOT/box/tools/<tool>         built in the airlock from the pin
#                                     (tools/airlock-busybox.sh)
#   4. the system's                    /bin/busybox, /usr/bin/qemu-aarch64-static
#                                     -- Veron's own on the image; someone
#                                     else's distro tools elsewhere
#
# THE SEAL. Before running, every executable in the box's bin is listed
# with its sha256 into out/box/BUDGET; anything not in the declared set is a
# hard stop. The script inside sees VERON_BOX=1 and VERON_RUNNER set to the
# in-box qemu (or empty on aarch64), and the stage scripts refuse to call
# anything the box does not hold, because they cannot.
#
# WHAT STAYS OUTSIDE: the airlock (`build.sh in`, `cross-amd64.sh in`):
# fetch pinned sources, verify hashes, regenerate-and-compare the committed
# generated files. It needs the network and git; its only products are
# content-addressed files under in/, bound read-only into the box.
#
# bwrap itself is the one host binary this file uses. It is not in the box
# and touches no byte; it is the wall.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/sources/tcc.toml" ] || { echo "FAIL: no repo root above $HERE"; exit 1; }
cd "$ROOT"

[ $# -ge 1 ] || { echo "usage: box.sh <stage-script> [args...]"; exit 2; }
SCRIPT="$1"; shift
[ -f "$SCRIPT" ] || { echo "FAIL: no such script: $SCRIPT"; exit 2; }
case "$SCRIPT" in /*) SCRIPT="${SCRIPT#$ROOT/}" ;; esac

command -v bwrap >/dev/null 2>&1 || { echo "FAIL: bwrap is not installed -- it is the wall, and the one host binary this needs"; exit 1; }

HOSTARCH=$(uname -m)
BOX="$ROOT/box"
rm -rf "$BOX/bin"; mkdir -p "$BOX/bin" "$ROOT/out/box" "$ROOT/build"

# ---- resolve the budget ----------------------------------------------------
find_tool() {   # name -> "path<TAB>provenance" on stdout, empty when absent
  _n="$1"
  if [ -n "${VERON_TOOLS:-}" ] && [ -x "$VERON_TOOLS/$_n" ]; then printf '%s\t%s\n' "$VERON_TOOLS/$_n" "VERON_TOOLS"
  elif [ -x "$ROOT/veron-tools/$_n" ]; then printf '%s\t%s\n' "$ROOT/veron-tools/$_n" "veron-tools bundle"
  elif [ -x "$ROOT/box/tools/$_n" ]; then printf '%s\t%s\n' "$ROOT/box/tools/$_n" "airlock-built from the pin"
  elif [ -x "/bin/$_n" ]; then printf '%s\t%s\n' "/bin/$_n" "system"
  elif [ -x "/usr/bin/$_n" ]; then printf '%s\t%s\n' "/usr/bin/$_n" "system"
  fi
}

_r=$(find_tool busybox)
[ -n "$_r" ] || { echo "FAIL: no busybox -- set VERON_TOOLS, unpack the tools bundle as veron-tools/, or run tools/airlock-busybox.sh"; exit 1; }
BB=${_r%%	*}; BB_FROM=${_r#*	}
# a static busybox only: a dynamic one would drag the host's libc into the box
if command -v readelf >/dev/null 2>&1 && readelf -d "$BB" 2>/dev/null | grep -q NEEDED; then
  echo "FAIL: $BB is dynamically linked; the box's driver must be static"; exit 1
fi
cp "$BB" "$BOX/bin/busybox"; chmod 755 "$BOX/bin/busybox"

QEMU=""
if [ "$HOSTARCH" != aarch64 ]; then
  _r=$(find_tool qemu-aarch64-static)
  [ -n "$_r" ] || { echo "FAIL: host is $HOSTARCH and no qemu-aarch64-static was found (the seed is aarch64)"; exit 1; }
  QEMU=${_r%%	*}; QEMU_FROM=${_r#*	}
  cp "$QEMU" "$BOX/bin/qemu-aarch64-static"; chmod 755 "$BOX/bin/qemu-aarch64-static"
fi

# every applet as a symlink, so `sh`, `sed`, `tar`, ... resolve to busybox
for a in $("$BOX/bin/busybox" --list); do ln -sf busybox "$BOX/bin/$a"; done

# ---- SEAL: enumerate, hash, refuse the undeclared --------------------------
{
  echo "# stages/box.sh budget -- every executable in the box, by hash"
  echo "# host: $HOSTARCH  script: $SCRIPT $*"
  echo "busybox  $(sha256sum "$BOX/bin/busybox" | cut -d' ' -f1)  $BB_FROM"
  [ -n "$QEMU" ] && echo "qemu-aarch64-static  $(sha256sum "$BOX/bin/qemu-aarch64-static" | cut -d' ' -f1)  $QEMU_FROM"
  echo "applets  $("$BOX/bin/busybox" --list | wc -l)"
} > "$ROOT/out/box/BUDGET"
undeclared=$(find "$BOX/bin" -type f -perm -u+x | while read -r f; do
  case "$(basename "$f")" in busybox|qemu-aarch64-static) ;; *) echo "$f" ;; esac; done)
[ -z "$undeclared" ] || { echo "FAIL: undeclared executables in the box:"; echo "$undeclared"; exit 1; }
sed 's/^/  /' "$ROOT/out/box/BUDGET"

# ---- run ------------------------------------------------------------------
mkdir -p "$ROOT/in" "$ROOT/out" "$ROOT/build"
# read-only: the repo, the airlock's outputs, the box. read-write: build, out.
exec bwrap --unshare-all --die-with-parent --new-session \
  --ro-bind "$ROOT" /repo \
  --bind "$ROOT/build" /repo/build \
  --bind "$ROOT/out" /repo/out \
  --ro-bind "$BOX/bin" /box/bin \
  --proc /proc --dev /dev --tmpfs /tmp \
  --setenv PATH /box/bin \
  --setenv HOME /tmp --setenv LC_ALL C --setenv TZ UTC --setenv SOURCE_DATE_EPOCH 0 \
  --setenv VERON_BOX 1 \
  --setenv VERON_RUNNER "${QEMU:+/box/bin/qemu-aarch64-static}" \
  --chdir /repo \
  /box/bin/sh "/repo/$SCRIPT" "$@"
