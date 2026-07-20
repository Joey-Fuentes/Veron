# Prebuilt CI image for fast Veron spikes.
#
# Bakes qemu-user + all three cross-binutils so spike jobs skip the ~60s apt
# install and start in ~5s. Build and push ONCE, then reference it from the
# workflow by adding to the `spike` job:
#
#     container: ghcr.io/<you>/veron-ci:latest
#
# ...and deleting the "Install toolchain" step.
#
# Build & push (locally or in a one-off workflow):
#     docker build -t ghcr.io/<you>/veron-ci:latest ci/
#     docker push  ghcr.io/<you>/veron-ci:latest

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        qemu-user \
        binutils-x86-64-linux-gnu \
        binutils-aarch64-linux-gnu \
        binutils-riscv64-linux-gnu \
        make \
        findutils \
    && rm -rf /var/lib/apt/lists/*

# sanity: the three emulators are present
RUN qemu-x86_64 --version && qemu-aarch64 --version && qemu-riscv64 --version
