#!/bin/sh
# stages/2-pico-c/verify.sh -- rebuild stage 2 through the committed Stage 1
# pair and require the recorded output hashes. One script, both homes:
# native aarch64, or any host via the toolbox qemu. python3 only.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"
SA=stages/1-self-assembly/self-assembler-arm64
EW=stages/1-self-assembly/elf-wrapper-arm64
if [ "$(uname -m)" = aarch64 ]; then RUN=""
elif [ -x spikes/toolbox/qemu-aarch64-static ]; then RUN="$ROOT/spikes/toolbox/qemu-aarch64-static"
else echo "FAIL: need aarch64 or the toolbox qemu"; exit 1; fi
run() { ${RUN:+"$RUN"} "$@"; }
mkdir -p out/2/aarch64
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

want() { python3 -c "
import tomllib
d=tomllib.load(open('stages/2-pico-c/substages.toml','rb'))
for s in d['substage']:
    if s['id']=='$1': print(s['output'][0]['sha256'], s['output'][0]['bytes'])"; }

echo "== 2/1 pico-c-assembler =="
run "$SA" < stages/2-pico-c/pico-c-assembler-arm64.s > "$W/pca.bin"
run "$EW" out/2/aarch64/pico-c-assembler < "$W/pca.bin"
set -- $(want 2/1/pico-c-assembler)
got=$(sha256sum out/2/aarch64/pico-c-assembler | cut -d' ' -f1)
[ "$got" = "$1" ] && [ "$(wc -c < out/2/aarch64/pico-c-assembler)" = "$2" ] \
  && echo "  MATCHES recorded $1" | cut -c1-40 || { echo "  STALE: got $got"; exit 1; }

echo "== 2/2 pico-c =="
run out/2/aarch64/pico-c-assembler < stages/2-pico-c/pico-c-arm64.s > "$W/pc.s0txt"
run "$SA" < "$W/pc.s0txt" > "$W/pc.bin"
run "$EW" out/2/aarch64/pico-c < "$W/pc.bin"
set -- $(want 2/2/pico-c)
got=$(sha256sum out/2/aarch64/pico-c | cut -d' ' -f1)
[ "$got" = "$1" ] && [ "$(wc -c < out/2/aarch64/pico-c)" = "$2" ] \
  && echo "  MATCHES recorded $1" | cut -c1-40 || { echo "  STALE: got $got"; exit 1; }

echo "== canon canary (the compiler-shaped fixpoint) =="
run out/2/aarch64/pico-c < stages/2-pico-c/selfhost/canon.c > "$W/canon.s1"
run out/2/aarch64/pico-c-assembler < "$W/canon.s1" > "$W/canon.s0txt"
run "$SA" < "$W/canon.s0txt" > "$W/canon.bin"
run "$EW" "$W/canon" < "$W/canon.bin"
printf 'int  main( ) {return 42 ; }\n' > "$W/m.c"
run "$W/canon" < "$W/m.c" > "$W/c1" && run "$W/canon" < "$W/c1" > "$W/c2"
cmp -s "$W/c1" "$W/c2" || { echo "  FAIL: canon not a fixpoint"; exit 1; }
echo "  PASS: canon(canon(x)) == canon(x)  ($(wc -c < "$W/canon") B, $(sha256sum "$W/canon" | cut -c1-16))"

echo "== renamed error prefixes =="
printf 'b nowhere\n' | run out/2/aarch64/pico-c-assembler >/dev/null 2>"$W/e1" || true
head -c 36 "$W/e1" | grep -q "^pico-c-assembler: unresolved label: " || { echo FAIL; exit 1; }
printf 'int main(){break;}\n' | run out/2/aarch64/pico-c >/dev/null 2>"$W/e2" || true
head -c 8 "$W/e2" | grep -q "^pico-c: " || { echo FAIL; exit 1; }
echo "  PASS: both prefixes exact"
echo "STAGE 2 VERIFY: green"
