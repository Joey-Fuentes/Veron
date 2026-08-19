set -eu
# THE FLASH SCRIPT'S JOB MOVES INTO THE ARTIFACT: firmware
# fetched through the mirror like every pinned source, prepared
# the way upstream ships it (dedup by its own install; per-file
# zstd the kernel decompresses at load), WHENCE and LICENCE.*
# beside the blobs. Unpinned entries skip OUT LOUD; unknown
# pinned names fail so new sources get deliberate handlers.
python3 - > fw-list.tsv <<'PY'
import tomllib
for src in tomllib.load(open("sources/firmware.toml", "rb"))["source"]:
    if not src.get("sha256"):
        print("SKIP\t%s\tunpinned -- stated, not silent" % src["name"])
        continue
    # Tarball pins carry a url and are named by it. GIT pins have
    # url = "" -- their artifact is the tarball fetch-git.sh
    # generated, named <name>-<version>.tar.gz, and the mirror
    # row recorded at mint time is the route to it. The first
    # version derived the name from the empty url and asked
    # mirror.py to fetch a file called nothing (run of
    # 2026-08-18 02:13Z).
    if src.get("url"):
        fname, url = src["url"].rsplit("/", 1)[-1], src["url"]
    elif src.get("git") and src.get("commit"):
        fname = "%s-%s.tar.gz" % (src["name"], src["version"])
        url = src["git"]
    else:
        raise SystemExit("source %r has neither url nor git+commit" % src["name"])
    print("FETCH\t%s\t%s\t%s\t%s" % (src["name"], src["sha256"], fname, url))
PY
cat fw-list.tsv
mkdir -p fw-dl fwtree
while IFS="$(printf '\t')" read -r verb name a b c; do
  case "$verb" in
    SKIP)  echo "  $name: $a" ;;
    FETCH) echo "::group::fetch $name ($b)"
           date -u +"  start %H:%M:%SZ"
           # HARD CEILING: a route that trickles must fail loudly,
           # not eat the job. 8 minutes moves 619 MB at ~1.3 MB/s;
           # anything slower is a bad route, and mirror.py's next
           # route deserves the chance the ceiling creates.
           timeout 480 python3 tools/mirror.py fetch "$a" "$b" --url "$c" --dest fw-dl \
             || { echo "  fetch of $name timed out or failed."
                  echo "  If the github route 404'd: the mirror lacks firmware --"
                  echo "  run  sh tools/mirror-sources.sh  once (authed) and re-dispatch;"
                  echo "  kernel.org at runner bandwidth cannot beat this ceiling."
                  exit 1; }
           date -u +"  done  %H:%M:%SZ"
           echo "::endgroup::"
           case "$name" in
             linux-firmware|wireless-regdb|intel-ucode) : ;;
             *) echo "  $name is pinned but has no handler here -- add one deliberately"; exit 1 ;;
           esac ;;
  esac
done < fw-list.tsv
echo "::group::prepare the tree"
date -u +"  extract %H:%M:%SZ"
tar -xf fw-dl/linux-firmware-*.tar.xz -C fw-dl
# PLAIN install (dedup + layout, no compression), then compress
# IN PARALLEL ourselves: install-zst runs zstd one file at a
# time -- thousands of files, one core, many silent minutes.
# xargs -P fans out; -T1 per file keeps every output byte
# deterministic regardless of core count, which the built-twice
# cmp downstream depends on.
make -C fw-dl/linux-firmware-*/ install DESTDIR="$PWD/fwstage" FIRMWAREDIR=/ >/dev/null
# copy-firmware.sh INSTALLS ONLY THE BLOBS -- WHENCE and the
# LICENCE/GPL texts live in the source root and never reach
# DESTDIR ("prepared tree lost WHENCE", run of 2026-08-18). They
# are the redistribution terms, so they ship beside what they
# govern, uncompressed and readable on the installed system.
# -a, because upstream ships BOTH loose LICENCE.* files AND a
# LICENSES/ directory (cp without -r refused it, run of
# 2026-08-18 02:00Z). Everything license-shaped comes along.
cp -a fw-dl/linux-firmware-*/WHENCE* fwstage/
cp -a fw-dl/linux-firmware-*/LICEN* fwstage/
cp -a fw-dl/linux-firmware-*/GPL* fwstage/ 2>/dev/null || true
[ "$(find fwstage -maxdepth 2 \( -name 'LICEN*' -o -name 'GPL*' \) | wc -l)" -gt 10 ] \
  || { echo "suspiciously few license files in the tree"; exit 1; }
date -u +"  compress %H:%M:%SZ"
find fwstage -type f ! -name 'WHENCE*' ! -name 'LICEN*' ! -name 'GPL*' ! -name '*.txt' ! -path '*/LICENSES/*' ! -path '*/intel-ucode/*' -print0 \
  | xargs -0 -n64 -P"$(nproc)" zstd -q -19 -T1 --rm
cp -a fwstage/. fwtree/
if ls fw-dl/intel-ucode-*.tar.gz >/dev/null 2>&1; then
  tar -xf fw-dl/intel-ucode-*.tar.gz -C fw-dl
  # the plain family files and the license; NOT with-caveats --
  # Intel gates those behind per-platform conditions this
  # project has no way to honour, so they do not ship
  cp -a fw-dl/intel-ucode-20*/intel-ucode fwtree/
  cp fw-dl/intel-ucode-20*/license fwtree/LICENSE.intel-ucode
fi
if ls fw-dl/wireless-regdb-*.tar.xz >/dev/null 2>&1; then
  tar -xf fw-dl/wireless-regdb-*.tar.xz -C fw-dl
  cp fw-dl/wireless-regdb-*/regulatory.db fw-dl/wireless-regdb-*/regulatory.db.p7s fwtree/
fi
[ -e fwtree/WHENCE ] || [ -e fwtree/WHENCE.zst ] \
  || { echo "prepared tree lost WHENCE"; exit 1; }
date -u +"  done %H:%M:%SZ"
echo "::endgroup::"
echo "firmware tree: $(find fwtree -type f | wc -l) file(s), $(du -sh fwtree | cut -f1)"
