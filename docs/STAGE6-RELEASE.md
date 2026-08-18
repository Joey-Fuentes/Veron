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
  DISPLAY NAMES ONLY -- 28 bits is neither collision- nor preimage-
  resistant, so nothing ever verifies against the short form, exactly as
  git shows short hashes but trusts full ones.
- Release assets must each stay under GitHub's 2 GiB per-file ceiling; the
  Pages site itself stays under 1 GB by carrying no images at all -- it
  links to release assets.
- Accepted knowingly: content names carry no chronology. The site is the
  source of "current"; the About window answers "what am I on."

## 6. Images: true A/B, kernel included

The consumer disk image and every installed system use one fixed GPT
layout. SLOT SIZE, RULED (2026-08-18): exactly the staged world's need
plus 100 MB, derived at build time -- no speculative growth budget.
Recorded consequence: installed disks freeze their windows, so a release
that outgrows an installed window is a reinstall event for those
machines UNTIL the queued design item lands: a strategy for safely
growing or shrinking the fixed container on installed disks (open;
nothing in v1 depends on it). The updater refuses-before-writing
anything larger than the installed window and zero-pads anything
smaller, keeping partition bytes release-determined. ESP 128 MiB at 1 KiB FAT clusters, RULED 2026-08-18 (FAT32's 65,525-
cluster floor scales with cluster size; 4 KiB clusters forced ~257 MiB
minimum for ~100 MB of kernels; 128 carries 4x headroom over the four-
kernel update peak); persist ships at 256 MiB and grows to fill the disk
at first boot
(deliberately the last partition). RULED 2026-08-18: the raw image fits a standard DVD-5 (4482 MiB) --
enforced as a named build guard -- which in turn ruled the firmware
question: the image ships the firmware its kernel's modules actually
reference (modinfo-keyed prune, per arch; WHENCE and every license kept
whole; regdb and intel-ucode always), because the complete tree cannot
fit two slots under the DVD. Projected ~4.0 GiB raw, and
the publish gate enforces GitHub's 2 GiB asset ceiling on the
compressed download.

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

**The A/B authority is ON DISK; BootNext is only the trigger.** The
research verdict (docs/STAGE6-EFIVARS-RESEARCH, ruled): real firmware may
ignore, volatilize, or reset NVRAM boot variables, so NVRAM must never be
the sole record of slot health. Per-slot state -- priority, tries left,
successful -- lives in GPT partition attribute bits on the slot partitions
(the ChromeOS model), written atomically. The boot flow refines to:

1. update writes the inactive slot (root partition + ESP kernel), verifies
   both BY HASH after writing;
2. sets that slot's tries=N, successful=0 in its GPT attributes;
3. sets BootNext to the slot's fixed Boot#### entry; reboots. BootNext is
   deleted by firmware before control transfer (UEFI 2.11 §3) -- try-once
   by construction, no rollback code on the failure path;
4. early in boot, a dinit service decrements tries for the running slot
   (identified via BootCurrent, cross-checked against root=PARTUUID);
5. the health target -- rootfs verified, critical services up -- gates
   veron-bless, which sets successful=1, rewrites BootOrder, and copies
   the new kernel over the fallback \EFI\BOOT\BOOTX64.EFI. Until bless,
   the old slot remains the default; if NVRAM is wiped entirely, the
   fallback still boots the committed slot.

**Partition constants, ruled from the research:** root-A and root-B use a
PRIVATE Veron partition type GUID, NOT the Discoverable Partitions
Specification x86-64 root type -- two identically-DPS-typed roots make
auto-discovery ambiguous on any rescue system running systemd-gpt-auto,
and Veron selects by root=PARTUUID explicitly. The no-auto (bit 63) and
read-only (bit 60) GPT flags are set on both roots; Veron's own tries/
successful bits use the vendor-free attribute range the way ChromeOS does.
Boot entry numbers are fixed constants (one per slot, reused forever) to
minimize NVRAM churn.

**The boot artifact per slot is a single PE binary** -- the EFI-stub
kernel with the initramfs baked in (CONFIG_INITRAMFS_SOURCE), cmdline
inside the image. One file per slot is the whole boot chain, which is
exactly the signing-friendly shape the §9 roadmap needs: sign one PE,
everything in it is covered.

**The efivars writer is ruled and specified** (was: a research task). Writing UEFI
variables has bricked real machines when done naively; the ruled bar is the
most professional, robust, current approach with no security compromise.
From the research (systemd's efi_set_variable studied as reference and
REIMPLEMENTED -- it is LGPL, not copied; rhboot/efivar's raw-ioctl pattern
for the flag): clear FS_IMMUTABLE_FL via FS_IOC_GETFLAGS/SETFLAGS before
writing and restore it after (the flag exists because rm -rf bricked real
laptops -- kernel commit ed8b0de5a33d); write the 4-byte little-endian
attributes word (NV|BS|RT = 0x7) and the payload in ONE EINTR-retrying
write; read-first and skip if already correct (NVRAM wear); delete is
unlink(), never a zero-length write; retry EINTR/EBUSY with ~50ms backoff;
NEVER set efi_no_storage_paranoia -- the kernel's QueryVariableInfo free-
space margin is the guard against the documented Samsung/Lenovo store-
exhaustion bricks and stays on. The writer lives at
stages/6-verification-distribution (source: spikes/stage6/efiboot/ until
the move), pure C, no dependencies, and is testable off-target: the
variable ENCODING (EFI_LOAD_OPTION, HD()+File() device paths, mixed-endian
GUIDs) is pure bytes with golden tests; only the final efivarfs write
needs the laptop.

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
modes: pure live (nothing kept) and opt-in persistence. Persistence, refined by the research: the v1 default is a PLAIN ext4
`.dat` overlay -- no device-mapper layer at all, which is what survives
Ventoy (it recreates the ISO's block device via dm, so nothing may stack
another dm device under the persistence volume, ruling out dm-crypt
there). Encrypted persistence is a later opt-in via fscrypt v2 -- three
ioctls plus a passphrase KDF, feasible as a minimal from-source C tool,
so the Go fscrypt userspace never ships. Stated plainly beside it: fscrypt
does not hide filesystem metadata; a user needing full-disk secrecy
installs to disk rather than carrying an encrypted live stick.

**Compatibility contract, ruled: UEFI x86_64 only -- a posture, not a
roadmap item.** No legacy BIOS path, ever: no syslinux, no El Torito BIOS
image, no MBR boot code -- machines without UEFI predate this project's
interest and the site says the requirement in one line. What "boots on
many machines" actually means here: the generic kernel's broad driver set
with pinned firmware; the removable-media fallback path
\EFI\BOOT\BOOTX64.EFI, which every UEFI firmware must try with no NVRAM
setup; and one hybrid artifact serving optical, dd'd-USB and Ventoy
identically. The one UEFI-diversity risk stays tested rather than
assumed: some firmware balks at hybrid GPT and wants the MBR-table
variant (documented by Syslinux), so the ISO boot gate runs the OVMF
matrix -- optical shape, dd'd-disk shape, Ventoy shape -- before anything
publishes.

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
  **THE DIFF BASE IS THE RUNNING SLOT, NEVER THE TARGET SLOT'S RESIDUE**
  (clarified 2026-08-18, prompted by the question "why not ship B
  pre-populated so the first update can be differential"). The updater
  assembles the target INTO the inactive slot from a three-tier source
  ladder, cheapest first (refined 2026-08-18): (1) the file already
  sitting in the inactive slot, KEPT IN PLACE if its hash equals the
  target's -- residue is never trusted, but hash-verification promotes it
  to proven content per file, so a regularly-updated machine moves almost
  no bytes; (2) the verified running slot, copied locally; (3) the
  network, for genuinely new blobs only -- so differential works on the very first update of a fresh
  install, empty B and all. The inactive slot's prior contents are never
  an input: residue would have to be proven before patching, while the
  running slot is proven by construction. And shipping B pre-populated
  would double the compressed download for zero gain -- the duplicate
  sits ~2.9 GiB away in the stream, past zstd's 2 GiB long-range window,
  so the compressor cannot fold it and the 2 GiB asset ceiling breaks.
  Zeros in B are load-bearing: they are what keeps the download at
  rootfs-price.

## 13. Order of work (progress noted in place)

1. This spec's constants: PARTUUIDs, ESP paths, entry names, index schema.
   [DONE -- constants live in tools/veron-mkimage and veron-efiboot]
2. efivars research write-up; ruling; then the writer.
   [DONE -- veron-efiboot: immutable-flag-safe, idempotent, read-back
   verified, independently decoded]
3. Image build: the A/B GPT .img assembled from 5/latest-* (this absorbs
   the flash script's job -- kernels, modules, firmware move INTO the
   image at build time, becoming recordable and hash-verifiable, which
   removes the census's "pinned at flash" caveat and gives initramfs-fw a
   pre-existing record at last).
   [TOOLING DONE -- veron-mkgpt + veron-mkfat + veron-mkimage: pure
   python/sh, no sfdisk/dosfstools/mtools, whole image byte-reproducible,
   independently decoded. REMAINING: EFI-stub kernel with baked initramfs
   from stage 4, then the OVMF boot gate proves it boots.]
4. Hybrid ISO with the two persistence modes.
5. veron-install (adds e2fsprogs to stage 5 -- the one reach-back).
6. Health-check + commit service; veron-update v1; About wiring.
7. The site, the index, the licenses page; 6-release.yml end to end,
   [SITE GENERATOR DONE -- veron-site: whole-storefront regeneration,
   index.json update endpoint, SHA256SUMS, zero external assets.
   REMAINING: licenses page from the ledger + firmware list.]
   boot-gating every image in qemu before publish; attest everything.
8. First official release: `release/<commit7>`.
