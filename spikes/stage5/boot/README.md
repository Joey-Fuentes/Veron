# veron-boot -- the missing piece of the boot design

## Why it exists

The design said the kernel's EFI stub is the bootloader. Half of that is true
and was measured: put the kernel at `\EFI\BOOT\BOOTAA64.EFI` and edk2 loads
it and Linux boots.

What is not true is that anything can then **configure** it. The firmware
starts the fallback path with empty `LoadOptions`, fresh media has no NVRAM
boot entry, and the stub reads nothing else:

```
Booting Linux
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

A `.cmdline` PE section was the obvious escape and does not work. That is
systemd-stub's convention -- systemd-stub is a separate EFI application that
reads it and then loads the kernel. **Checked against this exact kernel:** the
strings `.cmdline`, `.initrd` and `.linux` do not appear in the binary at all,
and a section lookup by name needs the name to compare against.

`CONFIG_CMDLINE` would work and is the wrong place: it welds one root device
into the artifact meant to be common to the `.img`, the ISO and Android's AVF.
Three image types, three root filesystems, one kernel -- so the variable part
belongs in the wrapper, and the wrapper is the ESP.

## What it does

Reads `\EFI\veron\cmdline`, loads `\EFI\veron\linux`, serves
`\EFI\veron\initrd` over the LoadFile2 protocol the kernel's stub asks for,
sets `LoadOptions`, and starts the kernel. No menu, no timeout, no second
entry, no chainloading -- there is one kernel and nothing to choose.

No gnu-efi and no EDK2; the UEFI structures are transcribed from the spec.
The same choice `veron-image` makes about GPT and FAT32.

## State: written, compiles, does not yet boot

**Compiles clean with the chain's own compiler.** gcc 15.2.0 from the stage-4
sysroot, running under `qemu-aarch64-static` from the toolbox, zero warnings.
Assembled and linked with the chain's own binutils, and converted to PE with
its `pei-aarch64-little` target -- a 6.7 KB `MZ` executable, built end to end
by Veron's own toolchain.

**The firmware rejects it.** edk2 falls through to the UEFI Shell rather than
running it, so the PE headers are not right yet -- entry point and subsystem
are the likely culprits, since `objcopy` alone does not set everything an EFI
application needs. The same ESP boots the *kernel* from the same path, so the
filesystem and the path are not the problem.

## What that leaves

- the C is the substance and it is done
- the PE conversion needs a proper header pass, not `objcopy` alone
- **the toolchain path is proven**: the chain's gcc and binutils can build EFI
  applications, run under the toolbox's emulator, on any host

One thing found on the way that is worth knowing: the firmware **does** carry
a UEFI Shell, and a `startup.nsh` on the ESP would let it boot the kernel with
arguments today. That is a way to test the rest of the path without this
loader -- and not a design, since it depends on a shell being present.
