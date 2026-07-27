mkdir -p .github/workflows-archive
git mv \
  .github/workflows/aarch64-reference.yml \
  .github/workflows/armhf-probe.yml \
  .github/workflows/bench-codegen.yml \
  .github/workflows/borrow-m2-demo.yml \
  .github/workflows/borrow-tcc-demo.yml \
  .github/workflows/borrow-tcc-native.yml \
  .github/workflows/elf-demo.yml \
  .github/workflows/elf-proto.yml \
  .github/workflows/gcc-backend-backport-probe.yml \
  .github/workflows/gcc-chain-probe.yml \
  .github/workflows/gcc-entrypoint-probe.yml \
  .github/workflows/hermetic-enumerate-host.yml \
  .github/workflows/hex2-bisect.yml \
  .github/workflows/livebootstrap-pass1.yml \
  .github/workflows/livebootstrap-pins-probe.yml \
  .github/workflows/m1-loop.yml \
  .github/workflows/m2-tcc-gap-probe.yml \
  .github/workflows/m2libc-113-bisect.yml \
  .github/workflows/mes-rung-recon.yml \
  .github/workflows/mescc-tools-full.yml \
  .github/workflows/no-host-chain.yml \
  .github/workflows/qemu-mmap-probe.yml \
  .github/workflows/qemu-probe.yml \
  .github/workflows/reference-first.yml \
  .github/workflows/reference-m2p-fault.yml \
  .github/workflows/seedas-demo.yml \
  .github/workflows/selfhost-demo.yml \
  .github/workflows/stage0-as-adrnum-demo.yml \
  .github/workflows/stage0-as-brnum-demo.yml \
  .github/workflows/stage0-as-demo.yml \
  .github/workflows/stage0-as-ext-demo.yml \
  .github/workflows/stage0-as-ldrx-demo.yml \
  .github/workflows/stage0-as-mul-demo.yml \
  .github/workflows/stage0-roundtrip.yml \
  .github/workflows/stage1-as-demo.yml \
  .github/workflows/stage2-mini-c-demo.yml \
  .github/workflows/stage3-m2-demo.yml \
  .github/workflows/struct-reverse-probe.yml \
  .github/workflows/tcc-aarch64-probe.yml \
  .github/workflows/tcc-arm64-asm-gap.yml \
  .github/workflows-archive/

# 40 archived, 15 still running (stage3-hermetic-arm64.yml, stage0-selfhost.yml, spike.yml + 12 upper-rung)
