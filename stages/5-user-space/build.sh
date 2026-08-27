#!/bin/bash
# stages/5-user-space/build.sh -- stage 5, the user-space system, as ONE
# SCRIPT WITH PHASES, the same text on a GitHub runner, a Veron laptop, or
# any Linux with bubblewrap:
#
#     sh stages/5-user-space/build.sh in      selftest, plan, the stage-4 sysroot + kernel (out/4 first, else the releases, attested), sources, checkpoint (optional)
#     sh stages/5-user-space/build.sh chain   VERON-SEAL + every package, in the sysroot box; the installs/linked/manifest/ledger/trace gates
#     sh stages/5-user-space/build.sh merge   the DESTDIRs merged into the system; VERON-STAGE5-OK
#     sh stages/5-user-space/build.sh image   the image, its reproducibility probe, the initramfs
#     sh stages/5-user-space/build.sh boot    the system's own tests under qemu; with BOOT_SYSTEM=1 the generic-kernel boot and the desktop; with NET_TEST=1 DHCP
#     sh stages/5-user-space/build.sh strip   size, strip, rebuild the image, re-verify it boots
#     sh stages/5-user-space/build.sh pack    out/5: rootfs.img (+ .tar.zst where GNU tar exists), IMAGE-SHA256, initramfs, files.tsv, Image
#     sh stages/5-user-space/build.sh all
#
# EXTRACTED 2026-08-26 FROM 5-user-space-amd64.yml (job "spike"), step
# bodies verbatim with their comments. The build itself was always sealed:
# tools/veron runs INSIDE bwrap rooted at the stage-4 sysroot, driven by the
# sysroot's own python. This file changes where the inputs come from (a
# local stage-4 run's out/4 first), replaces the runner's apt/sudo/GitHub
# plumbing with stated equivalents, and keeps every gate.
#
# KNOBS (the workflow's dispatch inputs, as environment variables):
#   STOP_AFTER=<pkg>  USE_CHECKPOINT=1  ADOPT_CHECKPOINT=1  SEED_INSTALLS=1
#   SELFREBUILD=1  BOOT_SYSTEM=1  NET_TEST=1  SKIP_BOOT=1  RELAY=<name>
# Checkpoints need gh (restore/publish are GitHub releases); without gh the
# build is cold, which is what a first laptop run wants anyway.
# `sh build.sh` is how every stage is invoked in this repo, and the image's sh
# is busybox: re-exec under bash, which these step bodies were written for.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/sources/tcc.toml" ] && [ "$ROOT" != / ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/sources/tcc.toml" ] || { echo "FAIL: no repo root above $HERE"; exit 1; }
cd "$ROOT"
REPO="${GITHUB_REPOSITORY:-Joey-Fuentes/Veron}"
RUN_ID="${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}"
COMMIT="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
PARTIAL="${STOP_AFTER:+yes}"; PARTIAL="${PARTIAL:-no}"
B5="$ROOT/box5"; mkdir -p "$B5/bin"
OUT5="$ROOT/out/5"; mkdir -p "$OUT5"
# state that crosses phases (the workflow used $GITHUB_ENV / $GITHUB_OUTPUT)
ENVF="$B5/env.sh"; touch "$ENVF"; . "$ENVF"
setenv() { printf '%s=%q\n' "$1" "$2" >> "$ENVF"; eval "$1=\$2"; export "$1"; }
# THE QEMU THE GATES USE IS THE ONE THIS BUILD MADE: a shim that runs the
# merged system's qemu inside a bwrap of that system (the workflow put the
# same shim in /usr/local/bin). It exists only once the system exists; on a
# host with its own qemu (a Veron laptop) the gates still use the built one,
# because that is what they gate.
qemu_shim() {
  mkdir -p "$B5/qemu-tmp"
  { echo '#!/bin/sh'
    echo "exec bwrap --die-with-parent --setenv TMPDIR $B5/qemu-tmp --bind $ROOT/spikes/stage5/sysroot / --dev-bind /dev /dev --proc /proc --bind $HOME $HOME --bind /tmp /tmp --bind $B5 $B5 /usr/bin/qemu-system-x86_64 \"\$@\""
  } > "$B5/bin/qemu-system-x86_64"
  chmod +x "$B5/bin/qemu-system-x86_64"
}
export PATH="$B5/bin:$PATH"
# TLS FOR THE AIRLOCK'S PYTHON. The image's OpenSSL has openssldir=/etc/ssl
# and so looks for /etc/ssl/cert.pem; ca-certificates installs the bundle
# as /etc/ssl/certs/ca-certificates.crt and nothing links the two, so
# python's default context verified nothing (laptop, 2026-08-26). curl was
# built with --with-ca-bundle= pointing at the bundle and never noticed.
# Name the bundle for OpenSSL here; the image-level fix is a cert.pem link.
if [ -z "${SSL_CERT_FILE:-}" ]; then
  for _ca in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    [ -s "$_ca" ] && { export SSL_CERT_FILE="$_ca"; break; }
  done
fi


phase_in() {

# ---- KVM -- hardware virtualization when the runner has it; the CPU model stays qemu64 either way ----
cd "$ROOT"
# KVM is speed, not a different machine: every qemu below keeps -cpu
# qemu64 (the baseline the image is certified against) and adds
# -enable-kvm when /dev/kvm is present. The maintenance gate ran this
# way and boots took seconds instead of minutes. CPUID stays masked
# to qemu64, so a -march=native artifact still faults here as it would
# on the baseline -- which is the point. TCG is the fallback.
if [ -e /dev/kvm ]; then
  [ -w /dev/kvm ] || echo "  /dev/kvm is not writable by this user; the image puts users in the kvm group"
  setenv VERON_ACCEL "-enable-kvm"
  echo "kvm: on (-enable-kvm -cpu qemu64)"
else
  setenv VERON_ACCEL ""
  echo "kvm: absent -- TCG (-cpu qemu64)"
fi

# ---- VERON-SELFTEST-OK -- the tools honour what callers depend on ----
cd "$ROOT"
# --overlay ON EVERY CALL THAT LOADS RECIPES, AND THE FLAG IS
# WHAT MAKES THAT AUDITABLE. An environment variable would have
# worked and was rejected: a job-level env reaches every step
# including ones nobody thought about, and this project's whole
# position on the build environment is that nothing arrives by
# accident. A flag appears in the log of the step that used it.
#
# THE SELFTEST GAINS A CHECK HERE THAT THE aarch64 ARM DOES NOT RUN:
# with an overlay in use it refuses to let the two copies of a
# recipe disagree about version, url or sha256. That is what makes
# duplicating seven recipes safe rather than a second place for a
# pin to rot.
cd spikes/stage5 && python3 tools/veron --overlay packages-amd64 selftest
cd ../.. && python3 tools/mirror.py selftest

# ---- VERON-PLAN-OK -- regenerate and diff ----
cd "$ROOT"
cd spikes/stage5
# ITS OWN PLAN FILE. The overlay changes seven argv lines and seven
# recipe-shas, so the regenerated plan cannot equal PLAN.txt and
# checking it against PLAN.txt would fail every run for the one
# reason that is not a fault. PLAN-amd64.txt is committed beside it
# and diffs against it in 28 lines -- which is also the cheapest
# review of what this architecture actually changes.
python3 tools/veron --overlay packages-amd64 --plan PLAN-amd64.txt plan --check

# ---- the stage-4 sysroot AND KERNEL: a local run's out/4 first, else the release ----
cd "$ROOT"
rm -rf spikes/stage5/sysroot; mkdir -p spikes/stage5/sysroot boot dl-sysroot
if [ -d out/4/lfs ] && [ -s out/4/boot/Image ]; then
  cp -a out/4/lfs/. spikes/stage5/sysroot/
  cp out/4/boot/Image boot/Image
  got=$(cd out/4/lfs && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
  echo "$got  sysroot (out/4/lfs, content digest)" > dl-sysroot/SYSROOT-SHA256
  printf 'kernel   %s\n' "$(sha256sum boot/Image | cut -d' ' -f1)" > dl-sysroot/PROVENANCE
  echo "    sysroot: out/4/lfs (local stage-4 run); kernel: out/4/boot/Image"
  echo "VERON-ENTRY-OK  $got"
  setenv SYSROOT_SHA "$got"
else
  command -v gh >/dev/null 2>&1 || { echo "FAIL: no local out/4 and no gh to fetch 4/latest-x86_64"; exit 1; }

# ONE RELEASE, BOTH THINGS, AND THAT IS A DIFFERENCE FROM THE
# aarch64 ARM WORTH STATING.
#
# There, the sysroot comes from the stage4/latest RELEASE and the
# kernel comes from an ARTIFACT belonging to whichever
# stage0-stage4-complete run happened to be the latest success --
# `gh run list --workflow=... --limit=1`. That indirection is the
# exact shape this workflow's own history argues against: an
# artifact expires after 30 days, a workflow that has not run in a
# while has no artifact at all, and the failure arrives as "no
# kernel artifact" long after the build has been paid for.
#
# stage4-arch-spike-amd64 publishes Image and initramfs.cpio.gz into
# 4/latest-x86_64 ALONGSIDE the sysroot, and its PROVENANCE
# records the sha256 of all three. So this arm takes the kernel from
# the same object it takes the userland from, and the two are known
# to be from one run rather than assumed to be.
#
# THE aarch64 ARM IS NOT CHANGED TO MATCH. It works, its release
# carries the same files, and moving it is a separate change with
# its own run to prove it.
gh release download 4/latest-x86_64 \
  --pattern 'sysroot.tar.zst' --pattern 'SYSROOT-SHA256' \
  --pattern 'PROVENANCE' --pattern 'Image' \
  --dir dl-sysroot || {
  echo "No 4/latest-x86_64 release. stage4-arch-spike-amd64"
  echo "publishes it on every green run; if none has run since this"
  echo "step landed, dispatch that workflow once."
  exit 1
}
# THE DIGEST IS CHECKED BEFORE THE TARBALL IS OPENED, exactly as the
# aarch64 arm checks its own. A release is a friendlier delivery
# mechanism and not a more trusted one.
want=$(awk '{print $1}' dl-sysroot/SYSROOT-SHA256)
got=$(sha256sum dl-sysroot/sysroot.tar.zst | cut -d' ' -f1)
[ "$want" = "$got" ] || { echo "SYSROOT HASH MISMATCH"; exit 1; }
sed 's/^/    /' dl-sysroot/PROVENANCE 2>/dev/null || true

# AND THE KERNEL AGAINST PROVENANCE, WHICH THE aarch64 ARM CANNOT
# DO. Its kernel arrives as a bare artifact with nothing to check it
# against. Here PROVENANCE carries `kernel <sha256>`, written by the
# job that built it, so the file can be verified rather than merely
# downloaded. If the line is absent the download still proceeds and
# says so -- an older release predating the line is a real case, and
# refusing it would be a gate firing on correct history.
[ -s dl-sysroot/Image ] || {
  echo "the release carries no Image -- stage4-arch-spike-amd64"
  echo "refuses to publish a partial release, so this means the tag"
  echo "predates the kernel being published. Dispatch it once."
  exit 1
}
kwant=$(awk '/^kernel/{print $2}' dl-sysroot/PROVENANCE 2>/dev/null || true)
kgot=$(sha256sum dl-sysroot/Image | cut -d' ' -f1)
if [ -n "$kwant" ]; then
  [ "$kwant" = "$kgot" ] || { echo "KERNEL HASH MISMATCH"; exit 1; }
  echo "    kernel verified against PROVENANCE  $kgot"
else
  echo "    PROVENANCE names no kernel digest -- not verified"
fi
# boot/Image, THE PATH EVERY BOOT STEP BELOW ALREADY USES. The
# aarch64 arm's download-artifact writes into boot/ and its qemu
# invocations read boot/Image from the repository root. Landing the
# file at the same path means the boot steps are copied unchanged
# and diff against their source.
#
# IT IS A bzImage AND IT IS CALLED Image. That is the publisher's
# name, kept rather than renamed: stage4-arch-spike-amd64 copies
# arch/x86/boot/bzImage to box/out/Image so that a consumer's
# download path is the same shape for every architecture. Renaming
# it here would make this file disagree with the release it reads.
cp dl-sysroot/Image boot/Image

gh attestation verify dl-sysroot/sysroot.tar.zst -R "$REPO" >/dev/null && echo "    attestation: verified" || { echo "FAIL: sysroot attestation did not verify"; exit 1; }
zstd -dc dl-sysroot/sysroot.tar.zst | tar -xf - -C spikes/stage5/sysroot
du -sh spikes/stage5/sysroot | sed 's/^/    /'
echo "VERON-ENTRY-OK  $got"
# THE CHECKPOINT BASE. Verified against the published digest above,
# so it is the strongest identity this run has for the image
# everything is built on top of.
setenv SYSROOT_SHA "$got"
fi

# ---- What the entry toolchain calls itself ----
cd "$ROOT"
cd spikes/stage5/sysroot
echo "  loader:"
ls lib64/ld-linux-x86-64.so.2 lib/ld-linux-x86-64.so.2 2>/dev/null \
  | sed 's/^/    /' || echo "    no x86-64 loader at either path"
echo "  gcc drivers:"
ls usr/bin/ 2>/dev/null | grep -E '(gcc|g\+\+)$' | sed 's/^/    /' \
  || echo "    none found"
echo "  gcc libdir:"
ls -d usr/lib/gcc/*/ 2>/dev/null | sed 's/^/    /' \
  || echo "    no /usr/lib/gcc/<triple>"
echo "  an amd64 recipe must name whichever triple appears above;"
echo "  gmp currently names aarch64-veron-linux-gnu -- AMD64.md."

# ---- Can the sysroot gcc emit 32-bit x86 (SeaBIOS question) ----
cd "$ROOT"
cd spikes/stage5
printf 'int main(void){return 0;}\n' > /tmp/m32-probe.c
if bwrap --unshare-all --die-with-parent \
    --bind sysroot / \
    --ro-bind /tmp/m32-probe.c /tmp/m32-probe.c \
    --proc /proc --dev /dev --tmpfs /build \
    --setenv PATH /usr/bin:/usr/sbin:/bin \
    /usr/bin/gcc -m32 -ffreestanding -c /tmp/m32-probe.c \
      -o /build/m32-probe.o 2> /tmp/m32-probe.err; then
  echo "VERON-M32-YES  the sysroot gcc can emit 32-bit x86"
else
  echo "VERON-M32-NO  the sysroot gcc cannot emit 32-bit x86:"
  sed 's/^/    /' /tmp/m32-probe.err | head -5
fi

# ---- Fetch pinned sources through the mirror ----
cd "$ROOT"
cd spikes/stage5
mkdir -p dl
# ITERATE, NEVER HARDCODE. The first version of this step carried
# pkgconf's sha256 as a literal and special-cased hello -- so the
# moment hello's pin stopped being PENDING, the check passed and
# nothing fetched it. `veron sources` emits every pin, so adding a
# package changes one recipe and nothing else.
fail=0
python3 tools/veron --overlay packages-amd64 sources | while IFS="$(printf '\t')" read -r sha name url; do
  python3 ../../tools/mirror.py fetch "$sha" "$name" --url "$url" --dest dl \
    || { echo "  FAILED $name"; exit 1; }
done || fail=1
[ "$fail" = 0 ] || { echo "VERON-FETCH-INCOMPLETE"; exit 1; }

# ---- Fetch git-pinned sources ----
cd "$ROOT"
cd spikes/stage5
# FOUR FIELDS, NOT THREE, AND READING THREE BROKE THE RUN.
#
# `veron git-sources` gained a fourth column -- the pinned digest of
# the tar -- and this reader was left at three. Shell `read -r a b c`
# puts THE REST OF THE LINE into the last variable, so $url became
#     https://github.com/davmac314/dinit.git<TAB>d33a44bb...
# and git reported "URL rejected: Malformed input to a URL
# function", which names the symptom and not the cause.
#
# Two of the three consumers were updated when the column was added
# and this one was not -- the same miss as `cmd_tarball_names` after
# `cmd_fetch` was fixed. A producer gaining a field is a change to
# every reader, and shell `read` fails at it silently by design.
python3 tools/veron --overlay packages-amd64 git-sources \
  | while IFS="$(printf '\t')" read -r commit name url want; do
  [ -n "$commit" ] || continue
  sh ../../tools/fetch-git.sh "$commit" "$name" "$url" dl ${want:+"$want"}
done

# ---- VERON-FETCH-OK -- sha256 against the manifest ----
cd "$ROOT"
cd spikes/stage5 && python3 tools/veron --overlay packages-amd64 fetch

# ---- Restore a build checkpoint (gh only; cold build without it) ----
cd "$ROOT"
if command -v gh >/dev/null 2>&1 && [ -n "${USE_CHECKPOINT:-}${ADOPT_CHECKPOINT:-}" ]; then
cd spikes/stage5
mkdir -p dest
# ONE TAG, AND THE MARKER DECIDES WHAT IS USABLE.
#
# This used to walk `veron keys` backwards looking for a release
# named after a prefix hash. That made a checkpoint all-or-nothing:
# adding seven packages moved 53 of 62 keys, no tag matched, and a
# 55-package checkpoint was discarded whole -- "no usable
# checkpoint -- building everything".
#
# The keys are per package now, so the artifact is just "the last
# one published" and `veron build --resume` keeps the subset whose
# keys still match, deleting the rest. Nothing here needs to know
# which packages those are.
# 5/ckpt-x86_64. A SEPARATE TAG, AND NOT A NAMING PREFERENCE.
# The publish step below clobbers whatever it uploads to; pointing
# both architectures at ckpt/latest would mean this arm's first run
# replaced the aarch64 checkpoint with a tree built against another
# libc. The guard in this step would then correctly discard it on
# the next aarch64 run -- after that run had already downloaded
# several gigabytes and thrown them away.
if gh release download 5/ckpt-x86_64 --pattern 'dest.tar.zst' \
     --dir . 2>/dev/null; then
  tar --zstd -xf dest.tar.zst && rm -f dest.tar.zst
  python3 -c 'import json;m=json.load(open("dest/.veron-checkpoint"));print("  downloaded a checkpoint holding",len(m["keys"]),"package(s)")'
  # A CHECKPOINT FROM A DIFFERENT SYSROOT IS DISCARDED HERE RATHER
  # THAN REFUSED LATER. veron build --resume die()s when the marker's
  # base does not match --base, which is correct as a guard and
  # wrong as an outcome: a new sysroot means every package is stale,
  # and the useful answer is to rebuild them, not to stop.
  #
  # THIS COST A FULL RUN. stage 4 republished the sysroot with
  # libatomic, stage 5 downloaded the checkpoint built against the
  # OLD one, and the build refused before compiling anything:
  #
  #     veron: checkpoint was built against a different sysroot.
  #       marker  fa1c677e...   this run  813ff8a8...
  #     Refusing to build on top of it.
  #
  # The guard stays where it is -- it is the last line of defence
  # against reusing artifacts compiled against another libc. This
  # simply stops handing it something it must reject.
  _want="$SYSROOT_SHA"
  _m=$(python3 -c 'import json;print(json.load(open("dest/.veron-checkpoint")).get("base",""))' 2>/dev/null || echo "")
  if [ "$_m" != "$_want" ]; then
    echo "  checkpoint base $(echo "$_m" | cut -c1-12) != sysroot $(echo "$_want" | cut -c1-12)"
    if [ '${ADOPT_CHECKPOINT:-}' = 'true' ]; then
      # ADOPTING A CHECKPOINT ACROSS A SYSROOT CHANGE, DELIBERATELY,
      # AND THIS IS THE WEAKEST THING IN THIS FILE.
      #
      # The guard exists because a package compiled against one libc
      # is not valid against another, and the comment above records
      # what it already caught once. Re-keying the checkpoint tells
      # that guard the packages belong to this sysroot when nobody
      # has checked that they do.
      #
      # THE ONLY CASE IT IS DEFENSIBLE IN is one where the operator
      # knows what changed between the two sysroots and knows it
      # cannot reach the packages. The case it was written for: stage
      # 4 republished after a KERNEL CONFIG change -- COMMON_CLK and
      # the i2c symbols, so a laptop touchpad would work -- which
      # alters arch/x86/boot/bzImage and nothing a userspace package
      # links against. glibc, gcc and binutils were the same versions
      # built the same way; the digest moved because stage 4 makes no
      # byte-reproducibility claim across runs, not because anything
      # a package can see was different.
      #
      # THAT REASONING IS NOT CHECKED HERE AND CANNOT BE. The old
      # sysroot is already gone -- 4/latest-x86_64 is a mutable
      # tag with one asset -- so there is nothing left to diff
      # against. This flag is the operator asserting the comparison
      # they can no longer make, which is why it is off by default,
      # named in the run log, and recorded in the image's provenance
      # below rather than silently applied.
      #
      # THE MARKER IS RE-KEYED, NOT EDITED, AND THE FIRST VERSION OF
      # THIS GOT THAT WRONG. It rewrote the marker's `base` field
      # with python and left the per-package keys alone, which
      # passed this check and then failed the next one:
      #
      #     checkpoint: 0 package(s) reusable, 121 stale and discarded
      #
      # because the base is an INPUT to every package key --
      # `package_keys(recipes, policy, base)` in tools/veron -- not
      # merely a header beside them. Changing the base changes all
      # 121 keys, so a marker with the new base and the old keys
      # describes nothing.
      #
      # `veron checkpoint --base <new>` recomputes every key for what
      # dest/ currently holds, which is exactly the operation wanted
      # and one the tool already performs. Editing JSON by hand to
      # imitate a command that exists is how the first attempt cost a
      # run.
      echo "  VERON-CHECKPOINT-ADOPTED  re-keying by operator request"
      echo "    was  $_m"
      echo "    now  $_want"
      echo "    the packages in this checkpoint were compiled against"
      echo "    the FORMER sysroot. Nothing here has verified they are"
      echo "    valid against this one."
      # THE OLD BASE IS RECORDED BEFORE IT IS OVERWRITTEN, in a file
      # rather than the marker, because `veron checkpoint` writes the
      # marker from scratch and would drop any field added to it.
      echo "$_m" > .adopted-from
      python3 tools/veron --overlay packages-amd64 --dest dest \
        checkpoint --base "$_want"
    else
      echo "  discarding it: every package is stale on a new sysroot"
      echo "  (adopt_checkpoint=true reuses it anyway -- read that"
      echo "   step's comment first; it weakens a real guard)"
      rm -rf dest && mkdir -p dest
    fi
  fi
else
  echo "  no checkpoint published yet -- building everything"
fi
setenv RESTORED_N "$(ls dest 2>/dev/null | wc -l)"
else
  echo "  no checkpoint restore (gh absent or USE_CHECKPOINT/ADOPT_CHECKPOINT unset): cold build"
  setenv RESTORED_N 0
fi
}

phase_chain() {

# ---- VERON-SEAL + build both packages ----
cd "$ROOT"
cd spikes/stage5
mkdir -p build dest out logs
# THE SANDBOX HAS TO RUN TEST SUITES, NOT JUST COMPILERS.
#
# m4's vendored gnulib suite hung for 66 minutes and then failed two
# process-spawning tests. None of the obvious namespace theories were
# right -- bwrap already brings loopback up inside --unshare-net, and
# it already runs its own PID 1 to reap zombies, so neither was ever
# the problem. What the environment inherits is.
#
# SIGPIPE. The GitHub Actions runner ignores SIGPIPE (actions/runner
# #2684: a shell pipeline "gets stuck" because of it), and SIG_IGN is
# inherited across fork AND exec. gnulib's test-execute expects a
# child to DIE of SIGPIPE; with it ignored the child survives, exits
# 71, and the pipeline never tears down -- which is both the failure
# and the hang. Resetting it is one line and fixes the cause rather
# than deleting the test.
#
# RLIMIT_NOFILE. Modern hosts hand out a hard limit near 2^30. Code
# that closes every fd before exec then makes a billion syscalls per
# spawn. /proc is mounted so glibc should use close_range and stay
# fast, but 1024 costs nothing and removes the question.
#
# MAKEFLAGS. GNU make's jobserver passes fds 3 and 4 to children, and
# gnulib's test-execute-child asserts that no unexpected descriptors
# are inherited. Clearing it for the build keeps the suite honest.
trap - PIPE || true
ulimit -n 1024
unset MAKEFLAGS MFLAGS MAKELEVEL
echo "  SIGPIPE: $(python3 -c 'import signal;print(signal.getsignal(signal.SIGPIPE))')"
echo "  fd limit: $(ulimit -n)"

bwrap --unshare-all --die-with-parent \
  --new-session \
  --bind sysroot / \
  --bind "$PWD/build" /build --bind "$PWD/dest" /dest \
  --bind "$PWD/dl" /dl --bind "$PWD/logs" /logs --bind "$PWD/out" /out \
  --ro-bind "$PWD/packages" /packages \
  --ro-bind "$PWD/packages-amd64" /packages-amd64 \
  --ro-bind "$PWD/policy" /policy --ro-bind "$PWD/tools" /tools \
  --proc /proc --dev /dev --tmpfs /tmp \
  --setenv PATH /usr/bin:/usr/sbin:/bin \
  --setenv HOME /build --setenv SHELL /bin/sh \
  --setenv LC_ALL C --setenv TZ UTC --setenv SOURCE_DATE_EPOCH 0 \
  --chdir / \
  /usr/bin/python3 /tools/veron \
    --overlay /packages-amd64 \
    --dl /dl --build-dir /build --dest /dest --logs /logs --out /out \
    --sysroot / \
    build --clean ${USE_CHECKPOINT:+--resume --base $SYSROOT_SHA} ${STOP_AFTER:+--upto $STOP_AFTER}

# ---- The install listings exist before anything can fail on them ----
cd "$ROOT"
cd spikes/stage5
[ -d dest ] || { echo "  no dest/ -- the build produced nothing to list"; exit 0; }
n=$(ls out/installs 2>/dev/null | wc -l)
echo "  $n listing(s) written during the build; collect backfills the rest"

# ---- VERON-INSTALLS -- declared prefixes ----
cd "$ROOT"
cd spikes/stage5
# --mode warn ON THIS ARM, AND IT IS NOT A LOWERED STANDARD.
#
# [installs].digest is a per-file sha256 listing -- `f <sha256>
# <size> <path>` for every file a package stages. Every one of those
# digests was measured on aarch64. An x86_64 build of the same source
# at the same pin produces different machine code in every binary, so
# EVERY package would report INSTALL-SET-CHANGED, and the gate would
# fail 122 times for the one reason that is not a fault.
#
# A GATE THAT FIRES ON CORRECT CODE GETS SWITCHED OFF. That is this
# project's own recorded lesson about this very check: it stayed at
# warn until all 62 recipes had been seeded, because failing a run
# over recipes that had never been through a seeding run was noise.
# The same argument applies to an architecture that has never been
# through a run at all.
#
# WHAT IS STILL CHECKED, AND IT IS THE HALF THAT TRANSFERS. The
# PREFIX check is architecture-independent: a package installing
# into a directory its recipe does not declare is a fault on x86_64
# exactly as on aarch64, and undeclared-prefix lines still appear
# here. So does the count of unchecked packages. Only the content
# digest cannot mean anything yet.
#
# WHAT WOULD MAKE IT fail HERE. A per-architecture digest -- either a
# second set of [installs] blocks or a per-arch listing file. That is
# a change to the recipe format and to the aarch64 arm, so it is a
# decision rather than a copy, and it is recorded as open in
# spikes/stage5/AMD64.md rather than invented here.
#
# READ THE FILE-SET DIFFS ANYWAY. install-set-changed prints which
# paths appeared and disappeared. Contents differing is expected;
# a package installing a DIFFERENT SET OF PATHS on x86_64 is a real
# finding about the recipe, and this is where it shows up.
python3 tools/veron --overlay packages-amd64 --dest dest installs --mode warn

# ---- VERON-LINKED -- DT_NEEDED against deps.link ----
cd "$ROOT"
cd spikes/stage5
python3 tools/veron --overlay packages-amd64 --dest dest linked --mode warn

cd "$ROOT"
if [ -n "${SEED_INSTALLS:-}" ]; then
cd spikes/stage5
python3 tools/veron --overlay packages-amd64 --dest dest installs --propose --write \
  | tee out/installs-propose.txt
# PLAN.txt CARRIES recipe-sha PER PACKAGE, so writing a block into
# every recipe moves all of them. Regenerating here means the
# artifact is a drop-in rather than something that fails plan-check
# the moment it lands.
python3 tools/veron --overlay packages-amd64 --plan PLAN-amd64.txt plan --write
python3 tools/veron --overlay packages-amd64 selftest
# COUNT BOTH TREES. `ls packages-amd64/*/installs.txt` reported 13
# and passed, which is a guard that cannot tell a full seed from a
# near-empty one.
n=$(ls packages/*/installs.txt packages-amd64/*/installs.txt 2>/dev/null | wc -l)
echo "VERON-INSTALLS-SEEDED  $n listing(s) written"
[ "$n" -gt 0 ] || { echo "seed_installs wrote nothing"; exit 1; }
fi

# ---- VERON-MANIFEST-OK ----
cd "$ROOT"
cd spikes/stage5 && python3 tools/veron --overlay packages-amd64 manifest

# ---- VERON-LEDGER-OK -- records carry what this run proved ----
cd "$ROOT"
cd spikes/stage5
python3 tools/veron --overlay packages-amd64 ledger
python3 tools/veron --overlay packages-amd64 status
echo "  attestations:"
grep -h '"attestations"' ledger/*.json | sed 's/^/    /'

# ---- VERON-TRACE-OK -- every recorded edge back to stage 1 agrees ----
cd "$ROOT"
cd spikes/stage5
# THE BUILD-ONLY LIST COMES FROM THE DRIVER, NOT FROM A SECOND
# PARSER. build_only lives in recipe.toml under overlay resolution
# the driver already implements; re-reading recipes in the records
# tool would be a second implementation waiting to drift. A staged
# bootstrap (freetype-bootstrap under harfbuzz) records the same
# paths as the package that overwrites it, and run 86917062743
# failed the gate on exactly that -- a correct build read as a
# conflict. Tagged staged-not-shipped, the duplicate check judges
# only what the image actually carries.
# --plan-commands ships the PLAN's literal argv into the records:
# "how was this file compiled" then answers OFFLINE, on the
# machine asking, in the exact words that ran -- kept true by the
# plan --check gate above.
python3 ../../tools/veron-trace-records \
  --repo ../.. --ledger ledger \
  --stage4-dir ../../dl-sysroot \
  --build-only "$(python3 tools/veron --overlay packages-amd64 build-only-names)" \
  --plan-commands PLAN-amd64.txt \
  --out out/trace-records
sh ../../tools/veron-trace --records out/trace-records --verify
}

phase_merge() {
[ "$PARTIAL" != yes ] || { echo "  partial build (STOP_AFTER): no system to merge"; return 0; }

# ---- Merge the DESTDIRs into the system ----
cd "$ROOT"
cd spikes/stage5
# THE DRIVER MERGES, BECAUSE THE DRIVER ALREADY KNOWS HOW.
#
# This was `cp -a "$d". sysroot/` in a loop here, and run 55 died on
# it three packages in:
#
#     merging bash
#     cp: cannot create regular file 'sysroot/./usr/bin/bashbug':
#         Permission denied
#
# stage_into() had already copied bash into the build root during the
# build, so the merge was writing over existing files -- and `cp`
# opens the destination rather than replacing it, which fails on any
# mode that is not user-writable.
#
# stage_into() has unlinked first ever since staging bzip2 wrote
# through /usr/bin's busybox symlinks and destroyed the binary that
# `tar` resolved to. THIS LOOP WAS A SECOND IMPLEMENTATION OF STAGING
# WITHOUT THAT LESSON -- the same defect as the find-list that used to
# duplicate BUILD_LOGS. One implementation now, in the driver, and
# `build_only` is honoured there too rather than by a name check here.
# GLOBAL OPTIONS COME BEFORE THE SUBCOMMAND. --dest and --sysroot
# are registered on the top-level parser, so `veron merge --dest X`
# is an error -- which is exactly how run 56 died, three steps after
# a clean 45-package build:
#     veron: error: unrecognized arguments: --dest dest --sysroot sysroot
# Every other call in this file already had the order right; this one
# was written from memory rather than copied.
python3 tools/veron --overlay packages-amd64 --dest dest --sysroot sysroot merge
# Two .pc fixtures, one requiring the other, so pkgconf's transitive
# resolution and search-path pinning are EXERCISED rather than the
# binary merely being installed.
install -D -m644 guest/fixtures/veron-a.pc sysroot/usr/lib/pkgconfig/veron-a.pc
install -D -m644 guest/fixtures/veron-b.pc sysroot/usr/lib/pkgconfig/veron-b.pc
# GENERATED FROM THE RECIPES. guest/test.sh hardcoded both packages;
# at 150 that is a file nobody maintains. Adding a package now adds
# its test, in the same file as its pin and its flags.
python3 tools/veron --overlay packages-amd64 guest-tests --out sysroot/usr/bin/veron-stage5-test


# /etc/veron-release -- WHICH COMMIT BUILT THIS MACHINE.
#
# Nothing in a running Veron could answer that. Establishing whether
# a fix was in a booted image took, on one evening, three photographs
# and finally `eu-nm -D -u` against the deployed module to see
# whether it referenced a symbol the fix had introduced. The release
# page cannot help: assets are replaced with `--clobber`, which never
# moves the tag, so it permanently reports the commit its release
# object was created at rather than the one whose artifacts it holds.
#
# WRITTEN HERE AND NOT IN A RECIPE, because a package build is sealed
# and has no business knowing about git. The merged tree is the first
# point where the image exists and the workflow's own environment is
# still in reach.
#
# IT DOES NOT BREAK REPRODUCIBILITY. VERON-IMAGE-REPRO-OK builds the
# image twice within one run, and every value here is constant across
# those two builds. Two runs of the SAME commit also agree, because
# GITHUB_SHA is the input. Two runs of DIFFERENT commits producing
# different images is the point.
#
# SOURCEABLE, IN THE SHAPE os-release USES, so a script can read it
# with `. /etc/veron-release` and veron-about can parse it with
# nothing more than fgets.
{
  echo "VERON_COMMIT=${COMMIT}"
  # VERON_BUILD_DATE and VERON_RUN_ID were REMOVED from the image:
  # both vary every run (wall clock, run id), so baking them into
  # /etc/veron-release made two runs of the SAME commit produce
  # DIFFERENT images (23199513... vs 3d966930... at commit cf7153fe) --
  # the release non-reproducibility root cause. The version is
  # identified by VERON_COMMIT above, which is deterministic and, since
  # the build is now reproducible, maps to exactly these image bytes.
  # The build date and run id remain available in the PROVENANCE file
  # shipped BESIDE the image (as `built` and `run`), so nothing is
  # lost -- they just no longer corrupt the image's sha. veron-about
  # skips the two now-absent rows via its release_value guards.
  echo "VERON_ARCH=x86_64"
  echo "VERON_REPO=${REPO}"
  # THE RELEASE, NAMED RATHER THAN HUNTED FOR. About used to point
  # at /releases and leave the person to guess which tag; the tag
  # is a constant of this workflow, so it belongs here. %2F because
  # a slash-in-tag release page is reached through the encoded form.
  echo "VERON_RELEASE_TAG=5/latest-x86_64"
  echo "VERON_RELEASE_URL=https://github.com/${REPO}/releases/tag/5%2Flatest-x86_64"
  # THE ATTESTATION INDEX, NOT A SINGLE ATTESTATION'S URL, and the
  # reason is the same self-reference IMAGE-SHA256 has: the
  # attestation is minted over the finished image, so its id cannot
  # exist yet while this file -- which is INSIDE that image -- is
  # being written. The index lists them all; the per-asset check is
  #   gh attestation verify <asset> --repo ${REPO}
  echo "VERON_ATTESTATIONS=https://github.com/${REPO}/attestations"
} > sysroot/etc/veron-release
echo "  wrote /etc/veron-release:"
sed 's/^/    /' sysroot/etc/veron-release

# THE TRACER AND ITS RECORDS SHIP IN THE IMAGE, SO THE FLASHED
# MACHINE TRACES ITSELF OFFLINE: veron-trace /usr/bin/gpg walks
# from the file's recorded hash down to the stage-1 self-assembler
# with no network and no Python. Installed HERE, the same seam as
# /etc/veron-release and for the same reason: the records name
# this run's ledger and the consumed stage-4 digests, which a
# sealed package build has no business knowing. WHAT IS ABSENT IS
# ABSENT ON PURPOSE: the stage-5 image digest cannot ride inside
# the image it digests (the IMAGE-SHA256 self-reference), so
# verifying the partition against the published digest stays an
# outside job -- the tracer says so rather than pretending.
# REPRODUCIBILITY HOLDS: both image builds in this run copy the
# same records written once by the trace step above.
mkdir -p sysroot/usr/share/veron/trace
cp out/trace-records/* sysroot/usr/share/veron/trace/
install -m 0755 ../../tools/veron-trace sysroot/usr/bin/veron-trace
echo "  installed veron-trace + $(ls out/trace-records | wc -l) record file(s)"

# THE SELF-REBUILD PAYLOAD IS NOT PART OF THE OPERATING SYSTEM.
#
# This used to `cp -a dl packages policy tools sysroot/veron/`, which
# put the pinned source tarballs, all 62 recipes, the policy and the
# DRIVER ITSELF inside the shipped image -- 970 MiB, 21% of it, that
# nothing in the running system reads. `guest/init` touches it for
# exactly one thing: `veron.selfrebuild=1`, which is off by default.
#
# It is a TEST FIXTURE. Shipping it made the published artifact
# change whenever the driver changed, with nothing in files.tsv able
# to explain why -- two runs with byte-identical package contents
# (manifest-sha256 8504bee5 both) produced different images, and the
# cause was `tools/veron` having grown four kilobytes between them.
# Reproduced locally: same merged tree, one differing file under
# veron/, different image.
#
# It also meant the artifact carried its own verifier. A payload
# that ships the tool that checks it, plus the manifest of the tree
# it sits in, vouches for itself.
#
# So it is built BESIDE the image and attached at boot time. The
# test is stronger for it: selfrebuild now exercises a system it is
# not part of.
mkdir -p out/selfrebuild/expected
cp -a dl out/selfrebuild/dl
cp -a packages policy tools out/selfrebuild/
cp out/files.tsv out/selfrebuild/expected/files.tsv
install -D -m755 guest/selfrebuild.sh out/selfrebuild/selfrebuild.sh
printf '    payload %s (attached at boot, NOT in the image)\n' \
  "$(du -sh out/selfrebuild | cut -f1)"
du -sh sysroot | sed 's/^/    image  /'

# ---- VERON-STAGE5-OK -- hello and pkgconf in the system they belong to ----
cd "$ROOT"
cd spikes/stage5
bwrap --unshare-all --die-with-parent \
  --bind sysroot / --proc /proc --dev /dev --tmpfs /tmp \
  --setenv PATH /usr/bin:/usr/sbin --setenv LC_ALL C --setenv TZ UTC \
  --chdir / /usr/bin/veron-stage5-test
}

phase_image() {
[ "$PARTIAL" != yes ] || { echo "  partial build: no image"; return 0; }

# ---- Build the image and probe reproducibility ----
cd "$ROOT"
cd spikes/stage5/out
# SOURCE_DATE_EPOCH DOES NOT WORK HERE. That was the first guess and
# it was wrong -- reproduced locally against mke2fs 1.47.0 with the
# variable set, and the same three superblock timestamps still
# differed. The image is normalised afterwards instead; see
# tools/normalize-ext4.py for the byte offsets and the reasoning.
SZ=$(du -sm ../sysroot | cut -f1); SZ=$((SZ + 200))
build_img() {
  rm -f "$1"
  # REMOVE THE FONTCONFIG CACHE BEFORE IMAGING. The VERON-STAGE5-OK
  # smoke test and the desktop boots run with sysroot bound WRITABLE
  # (bwrap --bind sysroot /), and fontconfig builds
  # /var/cache/fontconfig/*.cache-N with per-run absolute paths and
  # MTIMES baked in. Those 4 bytes (two cache files' mtime) were the
  # entire remaining cross-run image difference at a fixed commit --
  # the cache-9 files under /var/cache/fontconfig, found via
  # debugfs icheck/ncheck on the differing blocks. The cache is
  # DESIGNED to be built at runtime in the tmpfs overlay (see the
  # dejavu-fonts recipe), not shipped in the image, so clearing it
  # here restores reproducibility and ships exactly what was intended.
  rm -rf ../sysroot/var/cache/fontconfig
  /sbin/mke2fs -q -t ext4 -d ../sysroot \
    -U 00000000-0000-4000-8000-000000000001 \
    -E hash_seed=00000000-0000-4000-8000-000000000002 \
    -O ^has_journal,^resize_inode,^dir_index,^metadata_csum \
    -m 0 -b 4096 "$1" "${SZ}M"
  # DECLARED TRANSFORMATION, not a silent fixup: rewrites the three
  # superblock timestamps and every inode's times, with debugfs so
  # the checksums are recomputed rather than left wrong.
  python3 ../tools/normalize-ext4.py "$1"
}
build_img rootfs.img
sha256sum rootfs.img | tee IMAGE-SHA256
cp rootfs.img /tmp/img1
build_img rootfs.img
if cmp -s /tmp/img1 rootfs.img; then
  echo "VERON-IMAGE-REPRO-OK  two builds, identical bytes"
else
  echo "VERON-IMAGE-REPRO-DIFF  the CONTAINER did not reproduce."
  echo "  The packages may still be byte-identical; a filesystem is"
  echo "  full of exactly the metadata that varies. Record the cause"
  echo "  in policy/expected-differences.toml or fix the knob."
  # THE WHOLE DIFF IS WRITTEN, NOT THE FIRST 20 BYTES OF IT.
  #
  # `cmp -l | head -20` was the only copy of this comparison, so
  # twenty differing bytes were kept and every other one was thrown
  # away -- for the one failure where knowing WHICH bytes moved is
  # the entire diagnosis. A pattern in the offsets is what tells a
  # timestamp from a UUID from a build path, and twenty samples
  # cannot show a pattern.
  #
  # It goes to a file because this is the one output here that can
  # genuinely be enormous: a 4.5 GB image with a shifted layout
  # differs in most of its bytes. That is a fault to diagnose and
  # not a reason to discard it -- `veron collect` picks the file up,
  # and the console gets a count and a sample rather than a silent
  # sample presented as the answer.
  cmp -l /tmp/img1 rootfs.img > image-diff.txt 2>&1 || true
  printf '  %s differing byte(s); full list in the diag bundle as repro/image-diff.txt\n' \
    "$(wc -l < image-diff.txt)"
  head -20 image-diff.txt | sed 's/^/    /'
fi

# PUBLISH THE IMAGE, FOR THE SAME REASON THE SYSROOT AND THE TOOLBOX
# ARE PUBLISHED. rootfs.img is what this entire pipeline exists to
# produce -- built, hashed, proven byte-identical across two builds,
# booted under a kernel this chain compiled -- and it was being
# destroyed with the runner. The one artifact a person would actually
# want was the one nothing kept.
#
# Compressed, because the tree is several gigabytes and a GitHub
# release asset is capped at 2 GB. The stage-4 sysroot went from
# 619 MB to 122 MB the same way; an ext4 image full of the same
# binaries compresses similarly.
# A SMALL BUNDLE OF EXACTLY WHAT LOGIN NEEDS, BESIDE THE FULL IMAGE.
#
# rootfs.img.tar.zst is 1.7 GB -- fine for a release, useless for
# anyone iterating on the boot path who has to move it first. The
# boot question is only about dinit, busybox, a shell and /etc, and
# those are a few megabytes. Testing `console` against this bundle
# answers the same question as testing against the full image, and
# answers it in a minute instead of a download.
#
# Built from the merged sysroot rather than from the recipes, so it
# is the real thing rather than a reconstruction.
# THE SYSROOT IS ONE LEVEL UP, NOT HERE. This looked in ./sysroot
# from spikes/stage5/out, found nothing, and produced a 4 KB
# "loginkit" containing an empty directory -- which reported success
# because every miss was `|| true`.
# THE KIT MUST CARRY ITS OWN LOAD CLOSURE, AND IT DID NOT.
#
# This copied seven names and no libraries. Four of the five that
# landed -- dinit, dinitctl, dinit-check, bash -- are dynamically
# linked, so exactly one binary in the "loginkit" could run: the
# static busybox. Booted locally against the real kernel with that
# kit as the root:
#
#   VERON-SWITCHROOT-EXEC  /usr/bin/dinit
#   switch_root: can't execute '/usr/bin/dinit': No such file or
#   directory
#   Kernel panic - not syncing: Attempted to kill init!
#
# The ENOENT is the LOADER. dinit was present and executable.
#
# `veron loginkit` resolves PT_INTERP and the transitive DT_NEEDED
# closure out of the sysroot, follows each soname to the versioned
# file behind it, REPRODUCES THE SYSROOT'S LAYOUT rather than just
# its contents, and REFUSES to write a kit whose programs cannot be
# loaded from it. A hand-written file list cannot do that and cannot
# be made to.
#
# THE LAYOUT HALF WAS LEARNED THE SAME WAY. The sysroot is
# merged-usr -- /lib is a SYMLINK to usr/lib -- and the first
# version materialised it as a real directory, so the libraries
# landed at lib/ while ld.so searched usr/lib. It reported
# VERON-LOGINKIT-OK and the guest still could not load dinit.
python3 ../tools/veron --overlay ../packages-amd64 --sysroot ../sysroot loginkit --kit loginkit
# WRITTEN WHERE THE UPLOAD LOOKS, WHICH IS NOT WHERE THIS STEP
# STANDS. The artifact declares spikes/stage5/loginkit.tar.gz and
# this step runs in spikes/stage5/out, so the first version wrote it
# one directory too deep and the upload reported "No files were
# found with the provided path". Third path bug of the same shape in
# this one step.
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -czf ../loginkit.tar.gz loginkit
ls -la ../loginkit.tar.gz | sed 's/^/    /'
printf '  loginkit.tar.gz: %s (every program plus the libraries it loads)\n' \
  "$(du -h ../loginkit.tar.gz | cut -f1)"

# ---- Build stage 5 initramfs ----
cd "$ROOT"
cd spikes/stage5
python3 guest/mkinitramfs.py sysroot out/initramfs.cpio.gz
}

phase_boot() {
[ "$PARTIAL" != yes ] || { echo "  partial build: nothing to boot"; return 0; }
[ -z "${SKIP_BOOT:-}" ] || { echo "  SKIP_BOOT set"; return 0; }
qemu_shim

# ---- Boot the stage-5 system and run its own tests ----
cd "$ROOT"
[ -s boot/Image ] || { echo "VERON-BOOT-SKIP  no kernel artifact"; exit 0; }
O=spikes/stage5/out

# The in-guest rebuild is opt-in and off by default: twelve minutes
# for two packages under TCG, answering a question G3 already
# answers natively in seconds. Passed on the KERNEL CMDLINE so the
# image contents -- and therefore its hash -- do not depend on it.
SR=""; HARNESS_TIMEOUT=900; PAYLOAD=""
if [ "${SELFREBUILD:-}" = "true" ]; then
  SR=" veron.selfrebuild=1"; HARNESS_TIMEOUT=2400
  # THE PAYLOAD IS ATTACHED, NOT EMBEDDED. It used to be copied into
  # the image; it is a test fixture, so it now rides on a second 9p
  # share and the image ships without it. If the directory is not
  # there the guest says so and skips rather than pretending.
  if [ -d "$O/selfrebuild" ]; then
    PAYLOAD="-fsdev local,id=pl,path=$PWD/$O/selfrebuild,security_model=none,readonly=on -device virtio-9p-pci,fsdev=pl,mount_tag=veronpayload"
  else
    echo "  selfrebuild requested but $O/selfrebuild does not exist"
  fi
fi

# BOOT A COPY. The gate remounts the root read-write to get scratch
# space, so booting the published image directly would mutate the
# artifact whose hash was just recorded -- and the reproducibility
# claim with it.
cp "$O/rootfs.img" "$O/rootfs-boot.img"

# ================= BOOT 1: THE TEST HARNESS =================
#
# THIS BOOT IS WHAT PROVES THE PACKAGES. guest/init runs
# veron-stage5-test under the kernel this chain built and prints one
# line per package. It runs on every green build and its OUTPUT IS
# REPORTED UNCONDITIONALLY -- see the three faults below.
#
# FAULT 1: THE REPORTING SAT AFTER AN `exit 0`. boot_system=true ran
# this boot and then took a branch ending in `exit 0`, so the DRM
# probe, the per-package dump, VERON-STAGE5-BOOT-OK and the selfhost
# gate were all unreachable. The previous fix made the harness boot
# RUN again; it did not make it REPORT. A run showed
# VERON-STAGE5-LOGIN-OK, three dinit services, and not one word
# about the 62 packages -- which is the same silence the fix was
# written to end.
#
# FAULT 2: `cp boot-system.log boot.log` DESTROYED THE EVIDENCE. The
# harness log was overwritten by the second boot's before anything
# read it, so even the artifact could not show what the tests said.
# The two boots now write two files and neither touches the other.
#
# FAULT 3: THE SECOND BOOT'S TIMEOUT WAS APPLIED TO THE FIRST.
# QEMU_TIMEOUT=180 was set for dinit-that-never-exits and then used
# on the qemu invocation BELOW -- the harness, which runs 65 tests
# under TCG. The second boot has its own literal `timeout 180`, so
# the variable never reached the boot it was written for. It cut the
# harness window from 900s to 180s and bought nothing. The harness
# keeps its own timeout under its own name.
set +e
# qemu-system-x86_64, WITH NO -M AND NO -cpu, AND THAT IS
# DELIBERATE RATHER THAN AN OMISSION. qemu-system-aarch64 has no
# default machine and refuses to start without one, which is why the
# aarch64 arm names `virt` and `cortex-a57`. x86 has a default
# machine (`pc`) and a default cpu, and this runner is x86_64, so the
# guest is the same architecture as the kernel it is booting. Stage
# 4's amd64 arm makes exactly this call for exactly this reason.
#
# NO -enable-kvm, NOT YET. Some hosted x86 runners expose /dev/kvm
# and it would make every boot here minutes faster. It is left off
# because this arm has never produced a green run, and the first
# thing a first run must not do is vary two things at once: qemu is
# a VERIFIER and contributes no artifact byte, so KVM cannot change
# what is built -- but it can change what a hang looks like. Turn it
# on once there is a baseline to compare against.
# -cpu qemu64, NAMED RATHER THAN INHERITED, AND NOT RAISED.
#
# An earlier version of this file passed no -cpu at all and said so
# deliberately: x86 has a default where qemu-system-aarch64 has
# none. The default is `qemu64`, a conservative model, and run
# 85313812045 showed what inheriting it silently costs -- libffi,
# built with -march=native on a recent Xeon runner, hit an invalid
# opcode the moment ctypes loaded it.
#
# THE ANSWER TO THAT IS NOT -cpu max. Raising the emulated CPU until
# the image runs would make the test pass and leave an image that
# only boots on hardware as new as whatever built it -- a green
# marker over a real defect in the artifact, which is the one thing
# this project treats as worse than a red one. libffi is pinned to
# the baseline instead; see packages-amd64/libffi.
#
# So the model is NAMED at the value it already had. It is now
# visible in the log, it is what the image is actually certified
# against, and raising it becomes a decision somebody has to write
# down rather than a default nobody chose.
timeout "$HARNESS_TIMEOUT" qemu-system-x86_64 \
  $VERON_ACCEL -cpu qemu64 -smp 4 -m 4096 \
  -nographic -no-reboot -nic none \
  -drive file=$O/rootfs-boot.img,format=raw,if=virtio \
  -fsdev local,id=vs,path="$PWD/spikes/stage5/sysroot",security_model=none,readonly=on \
  -device virtio-9p-pci,fsdev=vs,mount_tag=veronsysroot \
  -device virtio-gpu-pci -device virtio-keyboard-pci \
  $PAYLOAD \
  -kernel boot/Image -initrd "$O/initramfs.cpio.gz" \
  -append "console=ttyS0 earlycon rdinit=/init panic=1 loglevel=7${SR}" \
  > "$O/boot-harness.log" 2>&1
harness_rc=$?
set -e
echo "=== boot 1: the test harness ==="
echo "  qemu rc=$harness_rc (0 expected: the harness powers off)"

# THE PROBE'S ANSWER, LIFTED OUT OF THE BOOT LOG.
#
# It is reported and never enforced: nothing in the set needs DRM or
# evdev yet, and failing a green run over a capability no package
# uses would be a gate that fires on correct code. What it buys is
# knowing the answer before wlroots, mesa and labwc are written
# against it.
grep -aE "VERON-(DRM|EVDEV)-(OK|ABSENT)" "$O/boot-harness.log" \
  | sed 's/^ */  /' \
  || echo "  VERON-GRAPHICS-PROBE-ABSENT  the probe did not run"

harness_fail=0
if grep -aq VERON-STAGE5-INIT "$O/boot-harness.log"; then
  sed -n '/VERON-STAGE5-INIT/,$p' "$O/boot-harness.log" | sed 's/^/    /'
else
  # THE WHOLE LOG, NOT THE LAST 40 LINES. This is the branch where
  # the guest never reached userspace, so the interesting part is
  # the kernel coming up -- which is at the TOP. `tail -40` kept the
  # panic and threw away the boot that led to it.
  sed 's/^/    /' "$O/boot-harness.log"
  echo "VERON-STAGE5-BOOT-FAIL  the stage-5 init never reached userspace"
  harness_fail=1
fi
if [ "$harness_fail" = 0 ]; then
  if grep -aq "VERON-STAGE5-OK" "$O/boot-harness.log"; then
    echo "VERON-STAGE5-BOOT-OK  the packages ran under the kernel"
  else
    echo "VERON-STAGE5-BOOT-FAIL  init ran, tests did not pass"
    harness_fail=1
  fi
fi
# THE RETURN CODE IS CHECKED, NOT MERELY ECHOED. It was captured
# into `rc`, printed, and never read again -- so a harness that
# timed out or panicked after printing its markers passed. A qemu
# that did not exit cleanly is a finding even when the console
# looked right.
if [ "$harness_rc" != 0 ] && [ "$harness_fail" = 0 ]; then
  echo "VERON-STAGE5-BOOT-FAIL  markers present but qemu exited $harness_rc"
  harness_fail=1
fi

# THE TIER-1 CLAIM. Reported separately from the boot, because they
# are different claims: the boot says the packages work, the gate
# says the system can rebuild them. A DIFF here is a finding worth
# having, not a broken system -- so it is surfaced loudly and does
# not fail the run while the spike is still learning what varies.
if grep -aq "VERON-SELFREBUILD-OK" "$O/boot-harness.log"; then
  echo "VERON-SELFHOST-OK  rebuilt inside the image, byte-identical"
elif grep -aq "VERON-SELFREBUILD-DIFF" "$O/boot-harness.log"; then
  echo "VERON-SELFHOST-DIFF  it rebuilt, and some bytes differ."
  echo "  That is a reproducibility finding across two genuinely"
  echo "  different environments -- see the diff above and record"
  echo "  each cause in policy/expected-differences.toml."
elif grep -aq "VERON-SELFREBUILD-SKIP" "$O/boot-harness.log"; then
  echo "VERON-SELFHOST-SKIPPED  in-guest rebuild is off by default."
  echo "  Reproducibility is answered by G3 above, natively and in"
  echo "  seconds. Re-run with selfrebuild=true for the in-guest"
  echo "  confirmation -- about 12 minutes for two packages."
else
  echo "VERON-SELFHOST-ABSENT  the gate did not run and did not skip"
fi

# ================= BOOT 2: THE SYSTEM =================
#
# A SECOND BOOT, ADDING A PROOF RATHER THAN TRADING ONE. Same image,
# same kernel, veron.boot=system -- guest/init switch_roots into
# dinit instead of running the harness. They answer different
# questions and both are wanted: the harness proves the packages
# work under this kernel, this proves the machine comes up.
system_fail=0
if [ "${BOOT_SYSTEM:-}" = "true" ]; then
  echo ""
  echo "=== boot 2: switch_root into dinit ==="
  # 180 SECONDS WAS BEING SPENT IN FULL, EVERY RUN, DOING NOTHING.
  #
  # dinit as PID 1 does not exit, so `timeout 180` was the normal
  # ending -- which meant the step always paid the whole 180s
  # whatever happened. Measured on the last green run:
  #
  #   harness boot   34.0s   (exits by itself, powers off)
  #   system boot   180.0s   <- the timeout, to the hundredth
  #
  # Three services come up in seconds; the remaining ~165s was the
  # step watching an idle getty. That is the whole reason the boot
  # went from seconds to minutes.
  #
  # So: WAIT FOR THE MARKER, NOT THE CLOCK. `boot` is
  # `type = internal` with `waits-for.d = boot.d`, so dinit reports
  # it only once every service in boot.d is up -- it is the last
  # line the gate below reads, and there is nothing after it worth
  # waiting for. The timeout stays as the FAILURE ending: if the
  # marker never comes, this still gives up at 180s and the log
  # says which service is missing.
  #
  # < /dev/null because qemu -nographic takes the console, and this
  # invocation is now backgrounded rather than run in the foreground.
  set +e
  qemu-system-x86_64 \
    $VERON_ACCEL -cpu qemu64 -smp 4 -m 4096 \
    -nographic -no-reboot -nic none \
    -drive file=$O/rootfs-boot.img,format=raw,if=virtio \
    -device virtio-gpu-pci -device virtio-keyboard-pci \
    -kernel boot/Image -initrd "$O/initramfs.cpio.gz" \
    -append "console=ttyS0 earlycon rdinit=/init panic=1 loglevel=7 veron.boot=system" \
    > "$O/boot-system.log" 2>&1 < /dev/null &
  qpid=$!
  waited=0
  while [ "$waited" -lt 180 ]; do
    if grep -aq "\[  OK  \] boot" "$O/boot-system.log" 2>/dev/null; then
      echo "  dinit reached its root service after ${waited}s -- not waiting out the timeout"
      break
    fi
    kill -0 "$qpid" 2>/dev/null || { echo "  qemu exited on its own after ${waited}s"; break; }
    sleep 1
    waited=$((waited + 1))
  done
  [ "$waited" -lt 180 ] || echo "  no root service after 180s -- giving up"
  # TERM, THEN KILL. A qemu that ignores TERM would otherwise hold
  # the runner open for the rest of the job -- the step would have
  # finished and the process would not have.
  kill "$qpid" 2>/dev/null
  for _ in 1 2 3 4 5; do
    kill -0 "$qpid" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$qpid" 2>/dev/null
  wait "$qpid" 2>/dev/null
  set -e
  # EVERY MARKER LINE, NOT THE FIRST 20. dinit prints one per
  # service; capping at 20 means the system that fails is the one
  # whose output gets cut. The full console is in the diag bundle
  # either way, and this grep is already selecting the lines worth
  # reading.
  sed 's/^/    /' "$O/boot-system.log" \
    | grep -aE "VERON-|OK  \]|FAILED\]"
  # rc=124 IS THE EXPECTED ENDING HERE, not a fault. What decides
  # the result is whether dinit started what it was asked to.
  for svc in early-filesystems console boot; do
    if grep -aq "\[  OK  \] $svc" "$O/boot-system.log"; then
      echo "  VERON-DINIT-OK      $svc"
    else
      echo "  VERON-DINIT-FAIL    $svc did not start"
      grep -a "$svc" "$O/boot-system.log" | sed 's/^/      /'
      system_fail=1
    fi
  done
  if [ "$system_fail" = 0 ]; then
    echo "VERON-STAGE5-LOGIN-OK  dinit brought up every service"
  else
    echo "VERON-STAGE5-LOGIN-FAIL"
  fi
fi

# ONE VERDICT, AT THE END, OVER BOTH BOOTS. Neither branch exits
# early any more: an early `exit 0` is what made the harness silent,
# and an early `exit 1` would have made the system boot's failure
# hide the harness result the same way in reverse.
echo ""
echo "  harness  $([ "$harness_fail" = 0 ] && echo OK || echo FAIL)"
if [ "${BOOT_SYSTEM:-}" = "true" ]; then
  echo "  system   $([ "$system_fail" = 0 ] && echo OK || echo FAIL)"
else
  echo "  system   not requested (boot_system=false)"
fi
if [ "$harness_fail" != 0 ] || [ "$system_fail" != 0 ]; then
  exit 1
fi

cd "$ROOT"
if [ -n "${BOOT_SYSTEM:-}" ]; then

# ---- Boot the image under the GENERIC kernel ----
cd "$ROOT"
# THE SECOND KERNEL MEETS THE USER SPACE. 4/kernel-x86_64 is the
# generic kernel (owned config, same seed-true toolchain); the image
# must run under it before it may publish, because that pairing --
# this image, that kernel -- is what stage 6 puts on the ISO and
# what bare metal boots. Same image, same initramfs, same harness;
# only -kernel changes. The mdev/hotplug work in veron-system is
# exercised HERE, where CONFIG_UEVENT_HELPER exists, not under the
# minimal kernel, where it does not.
O=spikes/stage5/out
[ -s "$O/initramfs.cpio.gz" ] || { echo "VERON-GENERIC-BOOT-SKIP  no initramfs"; exit 0; }
mkdir -p boot-generic
gh release download 4/kernel-x86_64 -D boot-generic --clobber \
  || { echo "VERON-GENERIC-BOOT-SKIP  no 4/kernel-x86_64 release yet"; exit 0; }
( cd boot-generic && grep vmlinuz-generic KERNEL-GENERIC-SHA256 | sha256sum -c - )
set +e
timeout 900 qemu-system-x86_64 \
  $VERON_ACCEL -cpu qemu64 -smp 4 -m 4096 \
  -nographic -no-reboot -nic none \
  -drive file=$O/rootfs-boot.img,format=raw,if=virtio \
  -fsdev local,id=vs,path="$PWD/spikes/stage5/sysroot",security_model=none,readonly=on \
  -device virtio-9p-pci,fsdev=vs,mount_tag=veronsysroot \
  -device virtio-gpu-pci -device virtio-keyboard-pci \
  -kernel boot-generic/vmlinuz-generic -initrd "$O/initramfs.cpio.gz" \
  -append "console=ttyS0 earlycon rdinit=/init panic=1 loglevel=7" \
  > "$O/boot-generic.log" 2>&1
rc=$?
set -e
echo "=== boot: the SAME image under the GENERIC kernel ==="
echo "  qemu rc=$rc (0 expected: the harness powers off)"
# AGENTS.md invariant 9: the whole log, always
sed 's/^/    /' "$O/boot-generic.log"
fail=0
grep -aq "VERON-STAGE5-INIT" "$O/boot-generic.log" \
  || { echo "VERON-STAGE5-GENERIC-BOOT-FAIL  init never reached userspace"; fail=1; }
tl=$(grep -a "VERON-STAGE5-TESTS" "$O/boot-generic.log" | tail -1 || true)
echo "  $tl"
case "$tl" in *"fail=0"*) : ;; *) echo "VERON-STAGE5-GENERIC-TESTS-FAIL"; fail=1 ;; esac
# UNDER set -e, AN UNGUARDED `grep && x` DIES WHEN GREP FINDS
# NOTHING -- i.e. on the HEALTHY boot. Found in audit before this
# step's first-ever execution; it would have failed a passing
# image at the last gate of a ten-hour climb.
if grep -aq "VERON-STAGE5-FAIL" "$O/boot-generic.log"; then fail=1; fi
[ "$fail" = 0 ] || exit 1
echo "VERON-STAGE5-GENERIC-BOOT-OK  the image runs under the generic kernel"

# ---- Screenshot the desktop ----
cd "$ROOT"
# RUN FROM THE REPO ROOT, LIKE THE BOOT STEP ABOVE, AND FOR THE SAME
# REASON: the kernel artifact is at boot/Image relative to the root,
# not to spikes/stage5. The first version did `cd spikes/stage5` and
# qemu answered
#
#     qemu-system-x86_64: could not load kernel 'boot/Image'
#
# which the step then reported as "no frame captured" -- a true
# statement about the wrong thing. Every path here is now anchored
# the same way the working boot step anchors its own.
[ -s boot/Image ] || { echo "VERON-SHOT-SKIP  no kernel artifact"; exit 0; }
O=spikes/stage5/out
S=spikes/stage5
rm -f "$O/mon.sock" "$O/desktop.ppm" "$O/desktop.png" "$O/console.in" \
      "$O/shot.ppm" "$O/desktop-minibrowser.png"
mkfifo "$O/console.in"

# HOLD THE FIFO OPEN. A `>` redirect that finishes closes the write
# end, the reader sees EOF, and the guest's shell exits -- taking
# the session with it. This background writer keeps it open for the
# life of the step.
( sleep 45
  # RUN seatd IN THE FOREGROUND FIRST, PURELY TO SEE ITS ERROR.
  # Under dinit its stderr goes nowhere, so two runs reported only
  #
  #     dinit: Service seatd process terminated with exit code 1
  #
  # which says that it failed and nothing about why. The first guess
  # -- that `-g video` named a group /etc/group did not have -- was
  # wrong: the group was added and seatd still exits 1. Guessing
  # again is worse than spending three seconds on the answer.
  # DO NOT START seatd HERE. An earlier version ran
  # `timeout 3 /usr/bin/seatd -g video` to see its output, and seatd
  # opens with
  #
  #     [seatd/seatd.c:167] Removing leftover socket at /run/seatd.sock
  #
  # -- it DELETED the socket belonging to the dinit-managed seatd,
  # ran for three seconds, and was killed. labwc then found nothing
  # to connect to and libseat reported "No backend was able to open
  # a seat". The probe caused the failure it was meant to explain,
  # and cost a run.
  #
  # What that run did establish, and worth keeping: seatd itself is
  # fine -- it logs "Created VT-bound seat seat0", "seatd started",
  # and exits 0 -- and /dev/dri/card0, /dev/dri/renderD128 and two
  # /dev/input/event nodes all exist in the running system.
  # labwc's OWN LOG, FIRST. The service writes /run/labwc.log; if it
  # died on boot the reason is in there and nowhere else, and this
  # has to be read before the test restarts it and overwrites it.
  printf 'echo ---LABWC-LOG---\n'
  printf 'cat /run/labwc.log 2>&1 | tail -20\n'
  printf 'echo ---CONSOLE-LOGS---\n'
  # THE SILENT EXIT. console and console-auth die with code 1 at
  # boot in this harness and never say why on the serial console:
  # no getty error, no login prompt, no verifier breadcrumb --
  # the dying process speaks only into its dinit logfile, which
  # this step never printed, so the evidence rode the tmpfs into
  # oblivion every run. Print it. One line here is the difference
  # between a mystery and a diagnosis, which is this tree's most
  # repeated lesson.
  printf 'cat /run/console.log /run/console-auth.log /run/hotplug.log 2>&1 | tail -30\n'
  printf 'echo ---SEAT-STATE---\n'
  printf 'ls -l /run/seatd.sock /dev/dri /dev/input 2>&1 | head -20\n'
  printf 'dinitctl status seatd 2>&1 | head -6\n'
  sleep 4
  # BACK TO THE SERVICE, NOW THAT IT SURVIVES. The foreground probe
  # did its job -- it found the /dev/shm segfault -- and then became
  # the wrong tool: labwc in the foreground BLOCKS THE SHELL, so
  # every later line sat unread in the FIFO. The tty still echoed
  # them, so VERON-SHOT-READY appeared in the log and the wait loop
  # matched on text that had been TYPED rather than RUN. The capture
  # then happened while labwc was still painting its first frame
  # under kms_swrast, and caught the top-left 192x24 of a 1280x800
  # wallpaper.
  #
  # dinitctl start returns immediately, so the shell stays live and
  # the settle below is real time rather than an echo race.
  # WHAT A PERSON DOES, AND NOTHING ELSE.
  #
  # Wait for the desktop, press Super+Return, type the command, look
  # at the screen. Every line has a counterpart in someone sitting
  # at the machine.
  #
  # ONE CONNECTION FOR THE WHOLE LINE, NOT ONE PER CHARACTER. The
  # first version of this called qemu-monitor.py once per keystroke,
  # and that script slept 0.5s on connect and 2.0s after the
  # command -- so typing a 40-character line cost forty processes,
  # forty socket connections and about a hundred seconds of
  # sleeping, for keystrokes that produce no output to wait for. The
  # monitor echoed it back one character at a time while it
  # happened. All the keys now go down a single connection.
  #
  # THE WAITS ARE FOR SOMETHING, NOT FOR A DURATION. `sleep 45` for
  # the desktop and `sleep 20` for the terminal were guesses that
  # cost their full length on every run whether or not the thing had
  # already happened. The compositor announces itself by creating
  # its socket and the terminal by taking focus, so both are polled
  # -- fast when they are ready, and with a ceiling so a genuine
  # failure still ends the step.
  #
  # THE PAGE IS NAMED, OR THE BROWSER GOES TO ITS HOME PAGE. The
  # first run of this test opened correctly and loaded
  # duckduckgo.com, because that is veron-browser's default with no
  # argument -- and this VM has `-nic none`, so it showed a name
  # resolution error. A local file, never the network: a test that
  # reaches the internet fails on a runner with no route and passes
  # for the wrong reason on one behind a captive portal.

  # THE COMPOSITOR IS UP WHEN ITS SOCKET EXISTS. Asked over the
  # serial line, which is already connected and costs nothing.
  printf 'for i in $(seq 1 60); do [ -S /run/user/1000/wayland-0 ] && break; sleep 1; done; echo VERON-WAYLAND-READY\n'
  for _ in $(seq 1 70); do
    grep -aq VERON-WAYLAND-READY "$O/desktop-console.log" && break
    sleep 1
  done

  # Super+Return, THE BINDING labwc ALREADY HAS. qemu spells the
  # left Super key `meta_l`.
  python3 "$S/tools/qemu-monitor.py" "$O/mon.sock" \
    "sendkey meta_l-ret" >> "$O/desktop-console.log" 2>&1 || true

  # THE TERMINAL IS UP WHEN foot IS RUNNING. Same channel, same
  # reason -- and this is the thing the keystrokes are about to be
  # typed into, so it is worth confirming rather than assuming.
  printf 'for i in $(seq 1 30); do pidof foot > /dev/null && break; sleep 1; done; echo VERON-FOOT-READY\n'
  for _ in $(seq 1 40); do
    grep -aq VERON-FOOT-READY "$O/desktop-console.log" && break
    sleep 1
  done

  # EVERY KEY IN ONE ARGUMENT, ON ONE CONNECTION.
  #
  # The run before this typed one character per process, at roughly
  # 2.5 seconds each, and the screenshot caught the command
  # half-written:
  #
  #     $ veron-browser /usr/share/veron/t
  #
  # -- no Return, no browser, nineteen minutes. The obvious fix,
  # building `sendkey v sendkey e ...` and passing it unquoted,
  # word-splits so that `sendkey` and `v` arrive as separate
  # commands and qemu rejects both. The key names go inside a single
  # --keys= argument instead, which takes the shell out of it.
  _keys=""
  _s="veron-browser /usr/share/veron/test.html"
  while [ -n "$_s" ]; do
    _c=${_s%"${_s#?}"}
    _s=${_s#?}
    case "$_c" in
      -) _k=minus ;;
      .) _k=dot ;;
      /) _k=slash ;;
      " ") _k=spc ;;
      *) _k=$_c ;;
    esac
    _keys="$_keys,$_k"
  done
  python3 "$S/tools/qemu-monitor.py" "$O/mon.sock" \
    "--keys=${_keys#,},ret" >> "$O/desktop-console.log" 2>&1 || true

  # THE PAGE IS LOADED WHEN THE COLOUR IS ON SCREEN. This is the one
  # wait that cannot be asked over the serial line -- the answer is
  # in the framebuffer -- so the frame is grabbed and counted until
  # the marker appears. A page that renders in four seconds costs
  # four, not forty.
  for _ in $(seq 1 45); do
    python3 "$S/tools/qemu-monitor.py" "$O/mon.sock" --wait=0.5 \
      "screendump $PWD/$O/probe.ppm" >/dev/null 2>&1 || true
    [ -s "$O/probe.ppm" ] || { sleep 1; continue; }
    _n=$(python3 "$S/tools/ppm2png.py" "$O/probe.ppm" \
           "$O/probe.png" 1e6f50 2>/dev/null \
         | sed -n 's/^ *\([0-9]*\) pixel(s) of #1e6f50/\1/p')
    [ "${_n:-0}" -ge 20000 ] && break
    sleep 1
  done

  printf 'echo VERON-SHOT-READY\n'
  sleep 600 ) > "$O/console.in" &
feeder=$!

set +e
qemu-system-x86_64 \
  $VERON_ACCEL -cpu qemu64 -smp 4 -m 4096 \
  -display none -no-reboot -nic none \
  -drive file=$O/rootfs-boot.img,format=raw,if=virtio \
  -vga none -device virtio-gpu-pci -device virtio-keyboard-pci \
  -serial stdio \
  -monitor unix:"$O/mon.sock",server,nowait \
  -kernel boot/Image -initrd "$O/initramfs.cpio.gz" \
  -append "console=ttyS0 rdinit=/init panic=1 loglevel=4 veron.boot=system" \
  < "$O/console.in" > "$O/desktop-console.log" 2>&1 &
qpid=$!

# WAIT FOR THE SOCKET, NOT A FIXED SLEEP. qemu creates it during
# startup and a laptop and a runner do not agree on how long that is.
for _ in $(seq 1 30); do
  [ -S "$O/mon.sock" ] && break
  sleep 1
done

# ONE CAPTURE PATH. It was written when this step launched three
# browsers and needed a frame for each; only veron-browser is
# launched now, so it is called once for the frame that matters.
# The function stays because writing a screendump by hand is how
# copies drift, and because a second capture will be wanted again
# the moment anything else needs looking at.
# Arguments: the marker to wait for, and the png to write.
veron_capture() {
  _marker=$1
  _png=$2
  _waited=0
  while [ "$_waited" -lt 420 ]; do
    grep -aq "$_marker" "$O/desktop-console.log" 2>/dev/null && break
    if ! kill -0 "$qpid" 2>/dev/null; then
      echo "  qemu exited after ${_waited}s -- it did not stay up"
      return 1
    fi
    sleep 2
    _waited=$((_waited + 2))
  done
  echo "  $_marker after ${_waited}s"
  rm -f "$O/shot.ppm"
  python3 "$S/tools/qemu-monitor.py" "$O/mon.sock" \
    "screendump $PWD/$O/shot.ppm" | sed 's/^/    /'
  sleep 3
  [ -s "$O/shot.ppm" ] || { echo "  no frame for $_marker"; return 1; }
  python3 "$S/tools/ppm2png.py" "$O/shot.ppm" "$_png"
  rm -f "$O/shot.ppm"
  return 0
}

# FRAME 1: MiniBrowser under LD_PRELOAD, chrome height 0.
veron_capture VERON-SHOT-1-READY "$O/desktop-minibrowser.png" \
  || echo "  (no MiniBrowser frame -- see the console log)"

# THE CAP WAS 140 AND THE FEEDER NEEDED 159, SO THIS LOOP HAD NEVER
# ONCE MATCHED ITS MARKER. Run 31684964493 printed `guest ready after
# 140s` -- the timeout, not the marker -- and screendump fired 19
# seconds before the feeder had even typed VERON-SHOT-READY. Every
# frame this step captured before that fix was taken on a timeout
# that happened to land somewhere useful. The cap is now well clear
# of the feeder; if it ever reports the full wait again, that is a
# real hang and not arithmetic.
waited=0
while [ "$waited" -lt 420 ]; do
  grep -aq "VERON-SHOT-READY" "$O/desktop-console.log" 2>/dev/null && break
  if ! kill -0 "$qpid" 2>/dev/null; then
    echo "  qemu exited after ${waited}s -- it did not stay up"
    break
  fi
  sleep 2
  waited=$((waited + 2))
done
echo "  guest ready after ${waited}s"

python3 "$S/tools/qemu-monitor.py" "$O/mon.sock" "screendump $PWD/$O/desktop.ppm" \
  | sed 's/^/    /'
sleep 3
kill "$feeder" "$qpid" 2>/dev/null
sleep 2
kill -9 "$feeder" "$qpid" 2>/dev/null
wait "$qpid" 2>/dev/null
set -e

echo "  --- what the session said ---"
grep -aE "labwc|seatd|swaybg|yambar|foot|OK  \]|FAILED\]" \
  "$O/desktop-console.log" 2>/dev/null | tail -25 | sed 's/^/    /' || true

# THE BROWSER SECTIONS, IN THE STEP LOG. desktop-console.log is
# uploaded as an artifact and the crash was sitting in it the whole
# time; nobody downloads an artifact to find out why a green run was
# green. Everything between the markers the feeder typed goes here.
echo "  --- browser: MiniBrowser on the veron backend ---"
sed -n '/---MODULE-DIR---/,/---BROWSER-VERON-BROWSER---/p' \
  "$O/desktop-console.log" 2>/dev/null | head -70 | sed 's/^/    /' \
  || echo "    (no browser section -- the feeder never got that far)"
echo "  --- the residency comparison, in two lines ---"
grep -aE "MINI-VERON-(ALIVE|DEAD)|MINI-PRELOAD-(ALIVE|DEAD)|VERON-BROWSER-(ALIVE|DEAD)" \
  "$O/desktop-console.log" 2>/dev/null | sed 's/^/    /' || true
echo "  --- browser: veron-browser ---"
sed -n '/---BROWSER-VERON-BROWSER---/,/---BROWSER-STOCK---/p' \
  "$O/desktop-console.log" 2>/dev/null | head -50 | sed 's/^/    /' \
  || echo "    (not reached)"
echo "  --- browser: the stock wayland backend ---"
sed -n '/---BROWSER-STOCK---/,/---BACKTRACE---/p' \
  "$O/desktop-console.log" 2>/dev/null | head -40 | sed 's/^/    /' \
  || echo "    (not reached)"
echo "  --- cores: stacks and module maps ---"
sed -n '/---BACKTRACE---/,/VERON-SHOT-READY/p' \
  "$O/desktop-console.log" 2>/dev/null | head -300 | sed 's/^/    /' \
  || echo "    (no core dumped)"

if [ ! -s "$O/desktop.ppm" ]; then
  # THE FIRST FAILURE PRINTED NOTHING USEFUL. It said "no frame
  # captured" and exited, and the qemu log -- which is the only
  # thing that knows why -- was never shown. `guest ready after 2s`
  # meant the wait loop had broken on `kill -0`, i.e. qemu was
  # already dead, and nothing said so.
  echo "  --- qemu / console output ---"
  tail -40 "$O/desktop-console.log" 2>/dev/null | sed 's/^/    /' \
    || echo "    (no log at all -- qemu never started)"
  echo "  --- monitor socket ---"
  ls -l "$O/mon.sock" 2>/dev/null | sed 's/^/    /' \
    || echo "    (no socket)"
  echo "VERON-SHOT-FAIL  no frame captured"
  exit 1
fi
# THE MARKER COLOUR IS COUNTED IN THE FRAME. test.html paints a large
# flat field of #1e6f50, a value that appears nowhere else on this
# desktop. Its presence is the proof that the browser rendered.
python3 "$S/tools/ppm2png.py" "$O/desktop.ppm" "$O/desktop.png" 1e6f50 \
  | tee "$O/frame-colours.txt"
rm -f "$O/desktop.ppm" "$O/mon.sock" "$O/console.in"
echo "VERON-SHOT-OK  $O/desktop.png"

# -vga none IS WHY THIS NOW SEES THE DESKTOP. x86_64 qemu adds a
# default VGA device unless told not to, so the guest had TWO
# displays: the std VGA that SeaBIOS and the kernel decompressor draw
# on, and virtio-gpu-pci that labwc opens through /dev/dri/card0.
# screendump takes the first, so every desktop.png ever captured was
# the boot text -- byte for byte the same frame across runs, which is
# what gave it away. STAGE5.md describes the same split from the
# other side: with -display gtk you flip between the console and the
# desktop through the View menu, because they are two outputs.
#
# A FRAME OF BOOT TEXT IS NOT A DESKTOP, so the size is checked. The
# VGA text console is 720x400; the compositor is whatever virtio-gpu
# came up at, and not that.
dims=$(python3 "$S/tools/png-size.py" "$O/desktop.png" 2>/dev/null || echo unknown)
echo "  frame: $dims"
case "$dims" in
  720x400|640x480|unknown)
    echo "  that is a VGA text console, not the compositor"
    bad=1 ;;
esac

# A SCREENSHOT IS NOT A PASS. Until this block existed the step
# captured a frame and exited 0 no matter what the session had done,
# so run 85938164747 shipped a green tick while labwc had died on
# boot and the WPE module had been rejected for a missing symbol.
# Both were in the log the whole time and nothing read it.
bad=0

# labwc DYING IS A FAILURE even though the test restarts it by hand
# further up -- the restart is there to get a frame, not to excuse
# the exit. dinit reports it in one line.
if grep -aq "Service labwc process terminated" "$O/desktop-console.log"; then
  echo "  labwc terminated on boot:"
  grep -aE "Service labwc|labwc" "$O/desktop-console.log" | head -6 | sed 's/^/    /'
  echo "  --- labwc's own log ---"
  sed -n '/---LABWC-LOG---/,/---SEAT-STATE---/p' "$O/desktop-console.log" \
    | head -22 | sed 's/^/    /' || echo "    (not captured)"
  bad=1
fi

# THE PLATFORM MODULE MUST LOAD. When GIO rejects it WPE silently
# falls through to the stock wayland backend, so the browser still
# draws -- without our chrome, and with no error anywhere but this
# line.
if grep -aqE "Failed to load module|g_io_module_load" "$O/desktop-console.log"; then
  echo "  the wpe-platform-veron module did not load:"
  grep -aE "Failed to load module|undefined symbol" "$O/desktop-console.log" \
    | head -4 | sed 's/^/    /'
  bad=1
fi

# ANY SERVICE EXITING NONZERO. chrony is excluded: it has no network
# in this harness and restarting too quickly is expected here.
if grep -aE "process terminated with exit code" "$O/desktop-console.log" \
     | grep -av chrony | grep -aq .; then
  echo "  services exited nonzero:"
  grep -aE "process terminated with exit code" "$O/desktop-console.log" \
    | grep -av chrony | head -6 | sed 's/^/    /'
  bad=1
fi

# THE BROWSER MUST HAVE SURVIVED, AND THIS DID NOT USED TO CHECK.
#
# Run 86191621985 printed, for every single launch:
#
#     Failed to connect to display of type wpe-display-veron:
#     veron: no Wayland display
#
# and the step still passed, because the health check only asked
# whether labwc stayed up and no service exited nonzero -- both true.
# The whole point of this step is the browser, and the browser was
# the one thing it did not look at. The image published.
#
# THE VERDICT COMES FROM THE SCREEN.
#
# Everything before this asked a serial shell whether a process
# existed. That was answering a question nobody has: a person does
# not check pidof, they look at the display. And the markers it
# relied on were typed into a shell that was not the one running the
# browser, so they failed for reasons the browser had nothing to do
# with -- while the same image ran correctly on real hardware.
#
# #1e6f50 IN QUANTITY MEANS WebKit PAINTED. test.html fills its body
# with that colour precisely so this check can exist; it is in
# neither the wallpaper gradient, nor foot's 242424, nor the bar's
# 1a1a1b. Pixels of it on screen mean layout, paint, buffer
# handover and compositing all worked.
#
# THE THRESHOLD IS DELIBERATELY LOW. A browser window that opened
# small, or is partly behind the terminal, still proves the path
# works; requiring most of the screen would fail on a window
# placement change. 20000 pixels is about 2% of 1280x800 -- far more
# than antialiasing could produce by accident, far less than a
# maximised window.
_green=$(sed -n 's/^ *\([0-9]*\) pixel(s) of #1e6f50/\1/p' \
         "$O/frame-colours.txt" | head -1)
_green=${_green:-0}
echo "  #1e6f50 in the frame: $_green pixel(s)"
if [ "$_green" -lt 20000 ]; then
  echo "  THE BROWSER DID NOT RENDER. The desktop came up -- the"
  echo "    frame was captured -- but the test page's colour is not"
  echo "    on screen, so no browser window is showing it."
  bad=1
fi

if [ "$bad" != 0 ]; then
  echo "VERON-DESKTOP-FAIL  the frame was captured but the session was not healthy"
  exit 1
fi
echo "VERON-DESKTOP-OK  labwc stayed up, the module loaded, the browser ran"
fi
cd "$ROOT"
if [ -n "${NET_TEST:-}" ]; then

# ---- VERON-DHCP -- two instances, one L2 segment ----
cd "$ROOT"
O=spikes/stage5/out
[ -s boot/Image ] || { echo "VERON-NET-SKIP  no kernel artifact"; exit 0; }
[ -s "$O/rootfs.img" ] || { echo "VERON-NET-SKIP  no image"; exit 0; }

# A COPY EACH. Both guests remount nothing, but they share a file if
# given one, and the published artifact must not be touched by a
# test at all -- the same reason the boot step copies it.
# NO COPIES. The step used to cp the multi-GB image twice so two VMs
# could each hold a write lock. (An earlier version of this comment
# blamed a dying disk and D-state for run 88569211258's hang; that
# was WRONG -- the hang was a comment amputating the qemu command,
# see above. The cps were merely waste.) snapshot=on gives each VM a private throwaway COW while
# the shared base is opened READ-ONLY: no copies, no lock conflict,
# and the net test's writes were disposable by design anyway.

PORT=11242
# romfile= (EMPTY) ON BOTH NICs IS EXPLICIT SUPPRESSION, NOT ABSENCE
# (run 88564664022): virtio-net-pci loads efi-virtio.rom by default,
# the prebuilt iPXE NETBOOT blob apt's qemu ships and ours does not;
# nothing here PXE-boots. AND THIS COMMENT LIVES ABOVE THE COMMAND
# FOR BLOOD-BOUGHT REASONS (run 88569211258): a prior edit placed it
# INSIDE the backslash continuation, where the joined line's # ended
# the command -- severing -device, -kernel, the log redirect and the
# trailing &. The server ran FOREGROUND and kernel-less, SeaBIOS
# reported "No bootable device" and idled under -no-reboot, and the
# step hung unkillably for 26 minutes. A comment inside a continued
# command is not a comment; it is an amputation.
echo "=== VM-A: the DHCP server ==="
set +e
qemu-system-x86_64 \
  $VERON_ACCEL -cpu qemu64 -smp 2 -m 2048 \
  -nographic -no-reboot \
  -drive file=$O/rootfs.img,format=raw,if=virtio,snapshot=on \
  -netdev socket,id=n0,listen=127.0.0.1:$PORT \
  -device virtio-net-pci,netdev=n0,romfile= \
  -kernel boot/Image -initrd "$O/initramfs.cpio.gz" \
  -append "console=ttyS0 rdinit=/init panic=1 loglevel=3 veron.net=server" \
  > "$O/net-server.log" 2>&1 < /dev/null &
SRV=$!
set -e

# WAIT FOR THE MARKER, NOT A FIXED SLEEP, AND THIS COST A ROUND.
# The first local run slept a few seconds and then started the
# client; the server had already finished its work and powered off,
# so the client sent five DISCOVERs into a dead socket and reported
# "no lease, failing" -- which looks exactly like a broken L2 link
# and was a timing bug. The server now blocks serving until killed,
# and this waits for it to say so.
ready=0
for i in $(seq 1 120); do
  if grep -aq "VERON-NET-SERVER-UP" "$O/net-server.log" 2>/dev/null; then
    ready=$i; break
  fi
  if ! kill -0 "$SRV" 2>/dev/null; then
    echo "VERON-NET-FAIL  the server VM exited before it was ready"
    sed 's/^/    /' "$O/net-server.log" | tail -30
    exit 1
  fi
  sleep 1
done
if [ "$ready" = 0 ]; then
  echo "VERON-NET-FAIL  server never reported VERON-NET-SERVER-UP in 120s"
  sed 's/^/    /' "$O/net-server.log" | tail -30
  kill "$SRV" 2>/dev/null; exit 1
fi
grep -a "VERON-NET-SERVER-UP" "$O/net-server.log" | sed 's/^/  /'
echo "  server ready after ${ready}s"

echo ""
echo "=== VM-B: the DHCP client ==="
set +e
timeout 300 qemu-system-x86_64 \
  $VERON_ACCEL -cpu qemu64 -smp 2 -m 2048 \
  -nographic -no-reboot \
  -drive file=$O/rootfs.img,format=raw,if=virtio,snapshot=on \
  -netdev socket,id=n0,connect=127.0.0.1:$PORT \
  -device virtio-net-pci,netdev=n0,romfile= \
  -kernel boot/Image -initrd "$O/initramfs.cpio.gz" \
  -append "console=ttyS0 rdinit=/init panic=1 loglevel=3 veron.net=client" \
  > "$O/net-client.log" 2>&1 < /dev/null
crc=$?
set -e
echo "  client qemu rc=$crc"

# THE SERVER IS A FIXTURE AND IS TORN DOWN HERE. TERM then KILL, for
# the same reason the system boot does it: a qemu that ignores TERM
# would hold the runner open after the step had finished.
kill "$SRV" 2>/dev/null || true
for _ in 1 2 3 4 5; do kill -0 "$SRV" 2>/dev/null || break; sleep 1; done
kill -9 "$SRV" 2>/dev/null || true
wait "$SRV" 2>/dev/null || true

sed -n '/VERON-NET/,$p' "$O/net-client.log" | sed 's/^/    /'

# THE VERDICT READS THE CLIENT'S OWN MEASUREMENT. guest/init emits
# VERON-DHCP-OK only from an address it observed on the interface,
# not from dhcpcd's exit status -- "it exited 0" and "the interface
# has an address" are different claims, and the local run proved it:
# busybox udhcpc obtained a lease and configured nothing, and the
# check correctly refused to call that success.
fail=0
if grep -aq "VERON-DHCP-OK" "$O/net-client.log"; then
  echo "VERON-DHCP-OK  the client leased an address from the server VM"
else
  echo "VERON-DHCP-FAIL  no lease applied to the interface"
  fail=1
fi
if grep -aq "VERON-NET-PING-OK" "$O/net-client.log"; then
  echo "VERON-NET-PING-OK  and the two machines exchanged packets"
else
  echo "VERON-NET-PING-FAIL  no round trip to 10.42.0.1"
  fail=1
fi
[ "$fail" = 0 ]
fi
}

phase_strip() {
[ "$PARTIAL" != yes ] || { echo "  partial build: nothing to strip"; return 0; }
qemu_shim

# ---- Size the system, and name what nothing reaches ----
cd "$ROOT"
cd spikes/stage5
echo "  === merged system, before stripping ==="
du -sh sysroot | sed 's/^/    total   /'
echo "    largest directories:"
du -sh sysroot/usr/* 2>/dev/null | sort -rh | head -12 | sed 's/^/      /'
echo "    apparent vs on-disk (the gap is hardlinks):"
printf '      on-disk  %s\n' "$(du -sh sysroot | cut -f1)"
printf '      apparent %s\n' "$(du -sh --apparent-size sysroot | cut -f1)"

# AND WHAT IS IN THERE THAT NOTHING RUNS. Declared edges alone were
# too weak to trust -- they cannot see a shebang or a dlopen -- so
# this reads the built tree: DT_NEEDED out of real ELFs, interpreters
# out of real shebangs, and paths out of the bytes themselves.
#
# warn, NOT fail. It over-reports by design (a path in a help string
# counts as a reference), and a package it cannot reach is a
# candidate for build_only rather than proof of anything.
echo "  === what nothing running reaches ==="
# ONE LINE, NOT A CONTINUATION. The selftest tokenises every veron
# invocation in these workflows and a backslash-wrapped one does not
# parse -- it reported `malformed invocation`, which is the gate
# doing its job rather than a false positive.
python3 tools/veron --overlay packages-amd64 reachable --sysroot sysroot --mode warn > out/reachable.txt 2>&1 || true
tail -40 out/reachable.txt | sed 's/^/    /'

# ---- Strip, rebuild the image, and re-verify it still boots ----
cd "$ROOT"
cd spikes/stage5

# THE TEST BINARY IS GENERATED INTO THE SYSROOT AND MUST SURVIVE.
# veron-stage5-test is a shell script, so strip skips it by
# extension -- but the packages it exercises are what is being
# stripped, which is the point of running it again below.
STRIP_LOG=out/strip.txt sh tools/stage5-strip.sh sysroot

# THE TRACE RECORDS LEARN WHAT THE STRIP JUST DID. packages.tsv
# was written from pre-strip DESTDIRs and installed into this
# sysroot; the strip above then rewrote the ELF bytes, so on the
# flashed machine every stripped binary read DOES NOT MATCH
# (measured: /usr/bin/foot, first flash with the tracer aboard).
# stripped.tsv records the post-strip hashes of every path the
# strip changed, BEFORE the stripped image is built from this
# tree -- so the image carries the record that describes its own
# bytes. No self-reference: stripped.tsv is in no package record,
# and writing it changes no other file. The full image was built
# before this line and matches packages.tsv directly.
if [ -s sysroot/usr/share/veron/trace/packages.tsv ]; then
  python3 ../../tools/veron-trace-records \
    --strip-overlay sysroot \
    --records sysroot/usr/share/veron/trace
  # AND THE OTHER LIST: every path in this tree that no package
  # installed -- veron-release, the tracer, these records --
  # written down so the on-device strays walk (--strays) can tell
  # "the build added this" from "someone added this". Computed
  # from the tree, not remembered, and AFTER the strip overlay so
  # stripped.tsv is itself on the list.
  python3 ../../tools/veron-trace-records \
    --extras sysroot \
    --records sysroot/usr/share/veron/trace
  # THE BOOT ARTIFACTS' PINS, INTO THE IMAGE THAT BOOTS FROM THEM.
  # boot-generic/ was downloaded and digest-verified by the
  # generic-boot gate; the initramfs was built above. Folding
  # their digests into CHAIN here means the flashed machine can
  # verify /vmlinuz-generic, /Image and /initramfs.cpio.gz by
  # hash, offline (veron-trace --kernel, or trace the path). The
  # tool states omissions: a run without the generic release
  # writes what it has and says what it lacks.
  python3 ../../tools/veron-trace-records \
    --boot-chain \
    --records sysroot/usr/share/veron/trace \
    --generic-dir ../../boot-generic \
    --initramfs out/initramfs.cpio.gz
else
  echo "  no trace records in the tree -- overlay skipped"
fi

echo "  === merged system, after stripping ==="
du -sh sysroot | sed 's/^/    total   /'

cd out
SZ=$(du -sm ../sysroot | cut -f1); SZ=$((SZ + 200))
build_img() {
  rm -f "$1"
  # REMOVE THE FONTCONFIG CACHE BEFORE IMAGING. The VERON-STAGE5-OK
  # smoke test and the desktop boots run with sysroot bound WRITABLE
  # (bwrap --bind sysroot /), and fontconfig builds
  # /var/cache/fontconfig/*.cache-N with per-run absolute paths and
  # MTIMES baked in. Those 4 bytes (two cache files' mtime) were the
  # entire remaining cross-run image difference at a fixed commit --
  # the cache-9 files under /var/cache/fontconfig, found via
  # debugfs icheck/ncheck on the differing blocks. The cache is
  # DESIGNED to be built at runtime in the tmpfs overlay (see the
  # dejavu-fonts recipe), not shipped in the image, so clearing it
  # here restores reproducibility and ships exactly what was intended.
  rm -rf ../sysroot/var/cache/fontconfig
  /sbin/mke2fs -q -t ext4 -d ../sysroot \
    -U 00000000-0000-4000-8000-000000000001 \
    -E hash_seed=00000000-0000-4000-8000-000000000002 \
    -O ^has_journal,^resize_inode,^dir_index,^metadata_csum \
    -m 0 -b 4096 "$1" "${SZ}M"
  python3 ../tools/normalize-ext4.py "$1"
}
# KEEP THE FULL IMAGE. Everything above -- the guest tests, the
# desktop screenshot, the two-instance DHCP run -- was measured
# against the UNSTRIPPED tree, and that is the artifact those results
# describe. Rebuilding over the top of it would publish a stripped
# image carrying a full image's test evidence, and leave no way to
# debug the shipped system with symbols in hand.
#
# So both are published: rootfs-full.img is what was tested, and
# rootfs.img is what the strip produced and the boot below re-tests.
cp rootfs.img rootfs-full.img
sha256sum rootfs-full.img | tee IMAGE-SHA256-FULL

# THE STRIPPED IMAGE'S OWN DIGEST. IMAGE-SHA256 was written for the
# unstripped build; leaving it would publish a checksum that does not
# match the artifact beside it.
build_img rootfs.img
sha256sum rootfs.img | tee IMAGE-SHA256
cp rootfs.img /tmp/img-stripped
build_img rootfs.img
if cmp -s /tmp/img-stripped rootfs.img; then
  echo "VERON-IMAGE-REPRO-OK  two builds of the stripped tree, identical bytes"
else
  echo "VERON-IMAGE-REPRO-DIFF  the stripped container did not reproduce"
  cmp -l /tmp/img-stripped rootfs.img > image-diff-stripped.txt 2>&1 || true
  printf '  %s differing byte(s)\n' "$(wc -l < image-diff-stripped.txt)"
fi

cd "$ROOT"
if [ -z "${SKIP_BOOT:-}" ]; then

# ---- Boot the STRIPPED image and re-run its package tests ----
cd "$ROOT"
O=spikes/stage5/out
cp "$O/rootfs.img" "$O/rootfs-stripped-boot.img"
set +e
timeout 900 qemu-system-x86_64 \
  $VERON_ACCEL -cpu qemu64 -smp 4 -m 4096 \
  -nographic -no-reboot -nic none \
  -drive file=$O/rootfs-stripped-boot.img,format=raw,if=virtio \
  -fsdev local,id=vs,path="$PWD/spikes/stage5/sysroot",security_model=none,readonly=on \
  -device virtio-9p-pci,fsdev=vs,mount_tag=veronsysroot \
  -kernel boot/Image -initrd "$O/initramfs.cpio.gz" \
  -append "console=ttyS0 earlycon rdinit=/init panic=1 loglevel=7" \
  > "$O/boot-stripped.log" 2>&1
rc=$?
set -e
echo "  qemu rc=$rc"

# VERON-STAGE5-TESTS IS THE MARKER, NOT VERON-BOOT-OK, AND CHECKING
# THE WRONG ONE FAILED A RUN THAT WORKED. VERON-BOOT-OK belongs to
# the `veron.boot=system` path; this is the harness boot, which runs
# veron-stage5-test and powers off. A run that booted cleanly and
# reported pass=177 fail=0 was rejected because the marker it never
# prints was absent.
#
# -a BECAUSE THE LOG CONTAINS BINARY. A console log carries control
# sequences, and grep treats a file with a NUL as binary and reports
# nothing -- the same reason every other grep against these logs in
# this file passes -a.
if ! grep -aq "VERON-STAGE5-TESTS" "$O/boot-stripped.log"; then
  echo "VERON-STRIPPED-BOOT-FAIL  the stripped image never reached its tests"
  tail -40 "$O/boot-stripped.log" | sed 's/^/    /'
  exit 1
fi
grep -aE "VERON-STAGE5-TESTS" "$O/boot-stripped.log" | tail -2 | sed 's/^/    /'
if grep -aq "VERON-STAGE5-FAIL" "$O/boot-stripped.log"; then
  echo "VERON-STRIPPED-TESTS-FAIL  stripping broke something that worked"
  grep -aE "^\s+FAIL|bad " "$O/boot-stripped.log" | head -25 | sed 's/^/    /'
  exit 1
fi
echo "VERON-STRIPPED-OK  boots and passes its own tests after stripping"
fi
}

phase_pack() {
cd "$ROOT"
cd spikes/stage5/out
# TWO GUARDS, AND THE SECOND IS NOT REDUNDANT. `[ -e rootfs.img ]`
# already stops a partial run here, because the image step is gated
# off when stop_after is set and there is nothing to find. The
# explicit check says WHY rather than leaving it to a missing file,
# and it keeps working if the image step is ever un-gated: this is
# the step that writes to a release under names that claim to be the
# x86_64 stage-5 system, and it must never do that for 81 packages
# of 122.
if [ "${PARTIAL:-no}" = "yes" ]; then
  echo "VERON-STAGE5-UNPUBLISHED  partial build (stop_after) --"
  echo "  a run that stopped early has not built a system and"
  echo "  cannot publish one. The checkpoint above is its output."
  exit 0
fi
[ -e rootfs.img ] || { echo "  no image was built"; exit 0; }
R=../../..
missing=""
for f in "$R/boot/Image" files.tsv initramfs.cpio.gz; do
  [ -e "$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  echo "  not publishing -- missing:$missing"
  echo "VERON-STAGE5-UNPUBLISHED  inputs absent, nothing compressed"
  exit 0
fi
# ZSTD_CLEVEL=10, NOT 19. Level 19 was chosen for the stage-4
# sysroot -- 619 MB, written once per chain -- and reused here on an
# image seven times larger without rethinking it, which cost about
# thirty minutes a run for a few percent of size.
# DETERMINISTIC TAR, matching stage 4's sysroot.tar.zst and this
# workflow's own loginkit.tar.gz. The inner rootfs.img is already
# byte-reproducible; a bare `tar --zstd` still embedded the file's
# per-run mtime in the tar header, so the .tar.zst differed run-to-run
# (1c90fb5a vs 16ef70c1 at a fixed commit) even though IMAGE-SHA256
# matched. --mtime=@0 pins it; the rest match stage 4 exactly.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  ZSTD_CLEVEL=10 tar --sort=name --mtime=@0 --owner=0 --group=0 \
    --numeric-owner --format=gnu --zstd -cf rootfs.img.tar.zst rootfs.img
else
  # transport only: rootfs.img is the artifact and IMAGE-SHA256 names it;
  # without GNU tar the image stays uncompressed in out/5
  echo "  no GNU tar here: rootfs.img left as is (IMAGE-SHA256 covers it)"
fi
printf '  rootfs.img.tar.zst (stripped): %s\n' "$(du -h rootfs.img.tar.zst | cut -f1)"
# THE FULL IMAGE TOO, WHEN THE STRIP RAN. A run where stripping was
# skipped or failed has no rootfs-full.img, and publishing a missing
# file would fail the step for a reason unrelated to the image.
if [ -e rootfs-full.img ] && tar --version 2>/dev/null | grep -q 'GNU tar'; then
  ZSTD_CLEVEL=10 tar --sort=name --mtime=@0 --owner=0 --group=0 \
    --numeric-owner --format=gnu --zstd -cf rootfs-full.img.tar.zst rootfs-full.img
  printf '  rootfs-full.img.tar.zst (unstripped): %s\n' \
    "$(du -h rootfs-full.img.tar.zst | cut -f1)"
  printf '  the stripped image is what a device runs; the full one\n'
  printf '  carries symbols and is what the tests above measured.\n'
fi

cd "$ROOT"
rm -rf "$OUT5"; mkdir -p "$OUT5"
for f in rootfs.img rootfs.img.tar.zst rootfs-full.img.tar.zst IMAGE-SHA256 files.tsv initramfs.cpio.gz .adopted-from; do
  [ -e "spikes/stage5/out/$f" ] && cp "spikes/stage5/out/$f" "$OUT5/"
done
cp boot/Image "$OUT5/Image"
echo "  out/5: $(ls -A "$OUT5" | tr '\n' ' ')"
}


case "${1:-all}" in
  in)    phase_in ;;
  chain) phase_chain ;;
  merge) phase_merge ;;
  image) phase_image ;;
  boot)  phase_boot ;;
  strip) phase_strip ;;
  pack)  phase_pack ;;
  all)   phase_in; phase_chain; phase_merge; phase_image; phase_boot; phase_strip; phase_pack ;;
  *) echo "usage: build.sh [in|chain|merge|image|boot|strip|pack|all]"; exit 2 ;;
esac
