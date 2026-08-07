# What stage 5 needs from the kernel

A ledger, not a plan. Every entry is something stage 5 **measured** about the
running kernel and needs changed — recorded here as it is found, and applied to
`spikes/stage4/bridge/rungs-sysroot.sh` in **one pass at the end** rather than
one kernel rebuild per finding.

**Why batch it.** The kernel is the slowest thing in the chain and it sits
under everything: a rebuild invalidates the stage-4 release that stage 5
downloads, and every stage-5 run after it. Reconciling twelve findings once is
one rebuild; reconciling them as they arrive is twelve. Nothing here blocks a
stage-5 recipe from being written or built — these are all runtime
capabilities, and a package that needs one still compiles without it.

**Where the config actually lives:** `spikes/stage4/bridge/rungs-sysroot.sh`,
in the `set_cfg` block around line 1100. Not `stage4-complete.yml` — the
handoff records a session patching that file instead, which did nothing,
because the chain runs `stage0-stage4-complete.yml` and the config is in the
bridge script.

**How to verify afterwards, and why it needs verifying.** `olddefconfig` can
silently demote a symbol, so `set_cfg X y` is a request and not a result. The
check must read the **shipped artifact**, not a build-time file: the kernel
embeds its own config, and it can be extracted from `Image` directly —

```python
d = open("Image","rb").read()
i = d.find(b"IKCFG_ST")                  # marker, then a gzip stream
j = d.find(b"\x1f\x8b\x08", i)
cfg = zlib.decompressobj(16+zlib.MAX_WBITS).decompress(d[j:]).decode()
```

That is how every "currently" value below was measured, against the `Image`
stage 4 actually published. It is also the basis of the gate this file should
become: assert each symbol below is `=y` (or absent) in the published `Image`,
so a demotion fails a run instead of surfacing three packages later.

---

## 1. `CONFIG_MODULES=n` — modules are already fiction

| | |
|---|---|
| currently | `CONFIG_MODULES=y`, **1423 symbols at `=m`** |
| wanted | `CONFIG_MODULES=n` |
| found by | reading the published `Image`'s embedded config while investigating WiFi |

**None of those 1423 modules is installed.** `make modules_install` never runs,
no `/lib/modules` ships, and the image contains **zero `.ko` files** — the
three `.ko` matches in `files.tsv` are ncurses terminfo (`screen.konsole`).
There is no kmod and no modprobe, and `CONFIG_MODPROBE_PATH="/sbin/modprobe"`
names a binary that does not exist.

So `=m` is not "loadable on demand", it is **absent**, and the config currently
says otherwise 1423 times.

**Setting `MODULES=n` changes nothing functionally.** The running kernel
already has none of them. What it changes is that the config stops claiming
capabilities the system does not have, and module loading stops being an
attack surface on a system with no legitimate module to load.

**The cost is honesty about an existing gap, not a regression.** 21 WiFi driver
families are at `=m` today, which means a real user gets none of them. After
this they are `=n` — the same outcome, stated. Whatever hardware Veron intends
to support has to become `=y`, deliberately and as a curated list. That is a
decision to make, not a side effect to absorb.

`CONFIG_MODULE_SIG` is also off. It becomes irrelevant under `MODULES=n`, which
is the cleaner answer than turning it on.

## 2. `CFG80211`, `MAC80211`, `RFKILL` → `=y` — WiFi is currently dead

| | |
|---|---|
| currently | `CONFIG_CFG80211=m`, `CONFIG_MAC80211=m`, `CONFIG_RFKILL=m` |
| wanted | all three `=y` |
| found by | the same config read, prompted by writing the wpa_supplicant recipe |

**This is the DRM finding again, in the one place nobody went back to.** The
`set_cfg` block already carries the argument verbatim — *"a symbol arm64
defconfig leaves at `=m` does not merely fail to load, it does not exist"* —
and fixed `DRM`, `DRM_VIRTIO_GPU`, `INPUT_EVDEV` and `VIRTIO_INPUT` on exactly
that reasoning. Every graphics symbol is now `=y`. Every 802.11 symbol is still
`=m`.

Consequence today: `wpa_supplicant` installs, runs, links libnl correctly, and
finds **no nl80211 to talk to**, because cfg80211 is not in the running kernel.
The package is buildable and the capability is absent — the exact shape wlroots
`-Dbackends=drm` would have had.

This is independent of any hwsim question. Real hardware needs these three
built in regardless.

## 3. WiFi drivers — a decision, not yet a change

21 driver families (`ath*`, `iwl*`, `rtw*`, `mt7*`, …) are at `=m` and
therefore absent. Under `MODULES=n` they must be `=y` to exist at all, and
building all of them is not the answer.

**Open:** which chipsets Veron claims to support. Related and unresolved: the
firmware problem — Veron ships none and provides `/lib/firmware` as a mount
point for a separate image, so "the driver is built in" and "the card works"
remain two different claims. `ath9k` is the interesting case and worth stating
precisely rather than loosely: most ath9k **PCI** parts need no firmware,
while `ath9k_htc` (USB) does.

---

## Already applied, for context

These were found the same way and are in `rungs-sysroot.sh` already. They are
listed so the pattern is visible rather than rediscovered:

`DRM`, `DRM_VIRTIO_GPU`, `DRM_FBDEV_EMULATION`, `INPUT_EVDEV`, `VIRTIO_INPUT`,
`OVERLAY_FS`, `EFI`, `EFI_STUB`, `EFI_PARTITION`, `EFIVAR_FS`, `VIRTIO_NET`,
`PACKET`, `DEVTMPFS`, `DEVTMPFS_MOUNT`, `NET_9P`, `NET_9P_VIRTIO`, `9P_FS`,
`TMPFS_XATTR`, `EXT4_FS`, `VIRTIO_BLK`.

`CONFIG_CMDLINE` was added here and then **removed**, measured: an EFI-stub
boot from the UEFI Shell receives `LoadOptions` fine, and a built-in command
line would weld one root device into the artifact meant to be common to the
`.img`, an ISO and Android's AVF.

## Confirmed present, no change needed

Checked while designing the networking tests, so nobody checks again:

`CONFIG_VIRTIO_NET=y`, `CONFIG_PACKET=y`, `CONFIG_INET=y`, `CONFIG_IP_PNP=y`,
`CONFIG_NETFILTER=y`. The two-VM Ethernet/DHCP test over `-netdev socket`
needs nothing beyond these — it is a plain L2 segment between two QEMU
processes, no TAP, no bridge, no `/dev/net/tun`, no host privileges.

`CONFIG_BRIDGE=m`, i.e. absent. Nothing currently needs it.
