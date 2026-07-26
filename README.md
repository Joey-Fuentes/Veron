# stage4-complete.yml — One job, tcc to booting Linux

## What this is

A single GitHub Actions workflow that proves the entire ladder works hermetically end to end:

```
tcc (host gcc, declared)
  ↓
gcc 4.7.4 + aarch64 backend  [stages 1-3 from tcc-builds-gcc-arm64]
  ↓
gcc 10.2.0
  ↓
gcc 15.2.0                    [builds the sysroot using gcc 10]
  ↓
linux 7.1.5 kernel + glibc 2.43 userland
  ↓
QEMU BOOT
```

**Inside one bwrap box.** Host compilers masked. No hand-offs. No caching. One narrative.

## Why one job instead of three

- `tcc-builds-gcc-arm64` proves tcc→gcc10 hermetically (stops before kernel)
- `hermetic-gcc15` proves kernel+boot (starts from host cross toolchain)
- **This job proves both, without a seam.**

If the kernel step fails, it fails because of something in the chain, not because of a layer boundary or an undeclared dependency between boxes.

## What it does NOT claim

- `tcc` is reproducible — that's stage 3's rung (seed → tcc is open)
- 3-stage bootstrap — that's deferred like the other rung jobs
- DejaGnu testing — future improvement
- Every step cached — transparency beats speed for a proof statement

## How to use it

```bash
cd ~/Veron
mkdir -p ~/tmp && unzip -o /storage/emulated/0/Download/veron-stage4-complete-s5.zip -d ~/tmp
cp -a ~/tmp/. ~/Veron/ && rm -rf ~/tmp
git add -A && git commit -m "stage4-complete: one job proving tcc to boot" && git push
```

The job will:

1. Build tcc with host gcc (announced in the log)
2. Fetch all sources needed for the entire chain
3. Mask the host compilers
4. Run tcc→4.7→4.7→10→15→kernel→boot, all inside bwrap
5. Report boot success or failure

### Dispatch options

- `boot: yes` (default) — build and boot the kernel
- `boot: no` — build only through gcc 15, skip kernel/boot

## What it proves

Once green:

> Every compiler and binary between tcc and a booting linux kernel descends from tcc. No host /usr, no network, no fallback to the runner's compiler after masking. The method works end to end.

## Expected wall-clock

- ~50–70 minutes on the first run
- Chapter 5–6 rebuilds every run (no caching)
- Kernel build ~10 min, boot ~1 min

## If it fails

The log is linear: find the first red line. It will be:
- `tcc` stage (host gcc issue — not this repo's problem)
- Stage 1/2/3 (gcc chain issue — look at `tcc-builds-gcc-arm64` for context)
- Sysroot chapter (LFS recipe issue — check hermetic-gcc15 for fixes)
- Kernel config (defconfig issue for the kernel version)
- Boot (qemu or initramfs issue — check dmesg)

Each failure is local to the chain, not to a hand-off.

## What to merge it into

- Main branch, under `.github/workflows/`
- Triggers on:
  - Push to the yml file itself
  - Manual dispatch
  - Changes to the transplant tools (`port_gcc47_api.py`, `expand_int_iterators.py`, the backport probe)

This is the stage 4 conclusion job. Run it before a release.
