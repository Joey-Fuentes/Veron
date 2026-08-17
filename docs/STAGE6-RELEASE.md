# Stage 6 — Release: the ruled design

This document records the decisions that define stage 6, each with the
reasoning that produced it. STAGE6.md is the argument; this is the verdict.
Where the two disagree, this file wins and STAGE6.md gets amended.

Every decision below was made deliberately. A reader who wants to reopen one
should first read why it was closed.

---

## 1. Topology: one stage 6, many stage 5s

Stages 4 and 5 are per-architecture and stay that way for the foreseeable
future. Stage 6 is **one arch-common workflow**. On any dispatch it reads
EVERY architecture's current `5/latest-*` and `4/kernel-*`, verifies their
digests and attestations, builds consumer images for whichever architectures
have inputs, and **regenerates the entire site every time**.

The site is a function of "all current releases," never of "what just ran."
Updating one architecture republishes a complete, consistent storefront --
a partial storefront is not a state this design can produce.

## 2. Dispatch model: individual is normal, the chain is a proof

Stages are dispatched individually; that is the normal way the project
builds. Every stage publishes its full release ALWAYS -- the releases are
the interface between stages, which is what makes independent dispatch safe:
each stage digest-verifies what it consumes and refuses a mismatch loudly.

A chain workflow may exist as an occasional end-to-end rot detector. It is
not the entry point. The six-hour job ceiling makes a chained clean stage-5
build impossible in one run regardless of preference -- the platform voted.

## 3. Finality: consumer-grade, nothing left over

When stage 6 runs green, what it published is what any consumer gets, at any
time, complete. A person goes to the site, selects their image, downloads
it, and boots it -- like any other distribution. There is no post-deploy
step, no "and then also," no asterisk that is not printed in plain text on
the site itself.

The one printed asterisk in release one: the stage-4 interior of the trace
is a single coarse edge ("substage records pending"). RULED: release one
ships with that honest line. The extraction of stages 1-4 from workflow YAML
into callable scripts -- which unlocks the per-substage records -- is
scheduled work, not a launch gate. The tracer already says exactly what is
and is not recorded, which is the standard this project holds.

## 4. Releases: append-only mirror, latest-only support, immutable tags

- **The mirror is append-only, forever.** Every pinned input any released
  commit ever referenced stays fetchable. Reproducibility of a release is a
  property of records plus inputs, and the inputs are kept. Storage is the
  only cost and it is modest.
- **Support is latest-only.** Fixes and updates target the newest release.
  "Reproducible forever" is promised; "maintained forever" is not.
- **Every release gets an immutable tag** alongside the moving `latest`.
  Moving tags are display pointers; immutable tags are what updates diff
  toward, what the site's history links, and what an attestation can be
  checked against years later. A consumer artifact that `--clobber` can
  vaporize is not consumer-grade.

## 5. Naming: content-derived, no versions, no timestamps

There is no version scheme and no timestamp anywhere in a name.

- **Assets** are named by their own bytes: `veron-<arch>-<sha7>.img`,
  `veron-<arch>-<sha7>.iso` -- the first 7 hex chars of the file's sha256.
  The builds are reproducible (fixed filesystem UUIDs, normalized metadata,
  probed by rebuild), so the same commit yields the same bytes yields the
  same name: the filename is a claim anyone can check with sha256sum.
- **Releases** are identified by commit: immutable tag `release/<commit7>`.
  A release spans several assets with different content hashes; the commit
  is the one identity they share, and it is what /etc/veron-release and the
  About window already carry.
- 7 chars in both places because it is git's own standard short form and
  therefore what every reader's eyes are calibrated to. Full digests appear
  in SHA256SUMS, the site index, and the attestations; the short forms are
  display names over verifiable identities.
- Accepted knowingly: content names carry no chronology. The site is the
  source of "current"; the About window answers "what am I on."

## 6. Images: true A/B, kernel included

The consumer disk image and every installed system use one fixed GPT layout:

```
p1  ESP        FAT32     kernels for both slots, at fixed paths
p2  root-A     ext4      a complete Veron root
p3  root-B     ext4      a complete Veron root (equal size)
p4  persist    ext4      user state; NO update ever touches it
```

Partition type/role identification uses fixed, spec'd PARTUUIDs so every
tool -- installer, updater, health-check -- finds slots by identity rather
than by position. The .img ships with A populated, B empty, persist empty.

**Boot is the kernel's EFI stub; there is no bootloader.** Two UEFI boot
entries (slot A, slot B) name per-slot kernels on the ESP and differ in
`root=PARTUUID=...`. The firmware's fallback copy at \EFI\BOOT\BOOTX64.EFI
belongs to the committed slot.

**Updates are true A/B including the kernel:**

1. `veron-update` fetches the target release (immutable tag), verifies
   digests against the signed site index.
2. Writes the new root image to the INACTIVE slot; writes the new kernel to
   the inactive ESP path. The running system is not modified in any byte.
3. Re-verifies both BY HASH after writing (veron-trace against the mounted
   inactive slot -- the verifier already exists).
4. Sets UEFI `BootNext` to the inactive entry and reboots. BootNext is
   try-once BY FIRMWARE CONSTRUCTION: this is the whole reason for choosing
   it. No rollback code runs on the failure path, because the failure path
   is the firmware falling through to the untouched old default.
5. A health-check service in the new system confirms the boot (reaches its
   target, records boot-ok), then COMMITS: rewrites BootOrder and the
   fallback copy. Until commit, the old system remains the default.

`/persist` is outside both slots and survives every update and every
rollback, which is the property enrollment and wifi state already rely on.

**The efivars writer is a research task before it is code.** Writing UEFI
variables has bricked real machines when done naively; the ruled bar is the
most professional, robust, current approach with no security compromise.
The research covers: efivarfs immutable-flag semantics, the known firmware
quirks and their mitigations, systemd's hardened efivars write path as the
reference implementation to learn from (not to import), and how modern
boot-counting / UKI conventions map onto this BootNext design. Findings get
written up and ruled on before the first line of the writer exists.

## 7. Kernels: the two that exist

The matrix is what stage 4 publishes today: the **minimal** kernel (the
maintainer's laptop-tailored config, doubling as the CI/qemu kernel) and the
**generic** kernel (broad drivers, firmware pinned by digest). Both are
attested; both have reproduced byte-for-byte across independent builds.
The structure must make adding a third config easy; nothing requires one
now. The firmware blobs remain individually pinned and are excluded from
the built-from-source claim explicitly, with their licenses listed on the
site.

## 8. Live ISO: persistence or none, chosen by the user

The hybrid ISO boots live (squashfs + tmpfs overlay) and must support BOTH
modes: pure live (nothing kept) and opt-in persistence. Persistence uses
fscrypt on an ext4 `.dat` volume -- the arrangement that survives Ventoy,
which recreates the ISO's block device via device-mapper and therefore
forbids stacking a second dm device under the persistence volume.

## 9. Secure Boot: disabled for v1, said plainly; signing is the roadmap

The site states it in plain text: **disable Secure Boot to boot Veron.**
No hedging, no burying it in a FAQ.

The recorded roadmap, in order of intent: sign everything (releases already
carry Sigstore attestations; artifact signing extends this), then Secure
Boot support, then TPM / vTPM integration. None of it is v1, all of it is
planned, and the design above (EFI stub, fixed ESP layout, immutable
releases) was chosen to take signing without rework.

## 10. The tracer: veron-trace, as shipped

STAGE6.md specified a small C tracer against libgcrypt so the device can
verify itself without python. The requirement's REASON is met by
`tools/veron-trace` as it exists: busybox sh + awk, on the device, doing
the full walk, --verify, --hash-files, the census, --inventory, --snapshot,
--commands and --kernel -- hardware-proven, python-free.

RULED: the sh tracer is the stage-6 deliverable. It has a property a C
binary cannot offer this project's exact audience -- the person who does
not trust our program can `cat` the verifier and audit the very bytes that
run, with no compiler between the source they read and the tool they trust.
A C port is post-6 work, re-motivated when on-device signature verification
arrives with the signing roadmap. STAGE6.md's §2.1 gets amended to record
this.

## 11. The site

GitHub Pages, regenerated in full on every stage-6 run:

- Per-arch download cards: image, ISO, sha256, size, the release tag, a
  link to the attestation and the Rekor entry.
- A machine-readable index (`index.json`): for each arch, the release
  commit, every asset's name and full sha256, the files.tsv digest, and the
  attestation id. This index is the update endpoint `veron-update` and the
  About window's "Check for updates" consume -- replacing the commits-
  behind counter.
- Verification instructions a stranger can follow: sha256sum -c, gh
  attestation verify, and veron-trace usage on the running system.
- The licenses page: per-package (from the ledger) and per-firmware-blob,
  plus the GPL source-availability statement that shipping binaries
  obligates.
- The Secure Boot statement (§9) and the update model (§6), in plain words.

## 12. Updates, phased

- **v1 (stage 6 launch):** `veron-update` does whole-image A/B as in §6 --
  automated, verified, one action from the About window, rollback by
  firmware. Complete consumer story, no asterisk.
- **v2:** differential updates. files.tsv (path, kind, sha256, size, mode)
  was designed as the update contract -- two manifests diff into exactly
  the files to fetch, replace, re-mode, or delete; per-file blobs are
  published content-addressed (GHCR blobs are sha256-addressed natively).
  v2 rides the same A/B slots and commit machinery as v1; only the transfer
  gets smaller.

## 13. Order of work

1. This spec's constants: PARTUUIDs, ESP paths, entry names, index schema.
2. efivars research write-up; ruling; then the writer.
3. Image build: the A/B GPT .img assembled from 5/latest-* (this absorbs
   the flash script's job -- kernels, modules, firmware move INTO the
   image at build time, becoming recordable and hash-verifiable, which
   removes the census's "pinned at flash" caveat and gives initramfs-fw a
   pre-existing record at last).
4. Hybrid ISO with the two persistence modes.
5. veron-install (adds e2fsprogs to stage 5 -- the one reach-back).
6. Health-check + commit service; veron-update v1; About wiring.
7. The site, the index, the licenses page; 6-release.yml end to end,
   boot-gating every image in qemu before publish; attest everything.
8. First official release: `release/<commit7>`.
