#!/usr/bin/env python3
# stages/6-release/prune-firmware.py -- the firmware tree reduced to what the
# kernel's modules name (modinfo -F firmware), plus provenance and licenses.
#
#     prune-firmware.py MODULES-DIR FWTREE OUT
#
# modinfo is whichever is on PATH inside the box: the released system's own.
import os, shutil, struct, sys
mods, tree, out = sys.argv[1:4]

def modinfo_firmware(path):
    """The firmware= entries of a module's .modinfo section, read from the
    ELF directly: no modinfo(8) -- busybox's answers only a fixed set of
    fields (not firmware; the runner, 2026-08-27), kmod's is not in the
    released system. A section is a pure function of the file's bytes."""
    d = open(path, "rb").read()
    if d[:4] != b"\x7fELF":
        return []
    is64 = d[4] == 2; le = d[5] == 1; E = "<" if le else ">"
    if is64:
        shoff, = struct.unpack_from(E + "Q", d, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from(E + "HHH", d, 0x3A)
    else:
        shoff, = struct.unpack_from(E + "I", d, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from(E + "HHH", d, 0x2E)
    def sh(i):
        o = shoff + i * shentsize
        if is64:
            name, typ, flags, addr, off, size = struct.unpack_from(E + "IIQQQQ", d, o)
        else:
            name, typ, flags, addr, off, size = struct.unpack_from(E + "IIIIII", d, o)
        return name, off, size
    _, stroff, strsize = sh(shstrndx)
    strtab = d[stroff:stroff + strsize]
    for i in range(shnum):
        name, off, size = sh(i)
        nm = strtab[name:strtab.index(b"\0", name)]
        if nm == b".modinfo":
            entries = d[off:off + size].split(b"\0")
            return [e[9:].decode() for e in entries if e.startswith(b"firmware=")]
    return []

want = set()
nmods = 0
for dp, _, fs in sorted(os.walk(mods)):
    for f in sorted(fs):
        if ".ko" not in f:
            continue
        nmods += 1
        want.update(modinfo_firmware(os.path.join(dp, f)))
if nmods and not want:
    sys.exit(f"prune-firmware: {nmods} modules and none of their .modinfo sections names firmware -- "
             f"that cannot be right for a generic kernel; refusing to prune the tree to nothing")
def place(rel):
    src = os.path.join(tree, rel)
    for cand in (src, src + ".zst"):
        if os.path.lexists(cand):
            dst = os.path.join(out, os.path.relpath(cand, tree))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.islink(cand):
                t = os.readlink(cand)
                if not os.path.lexists(dst):
                    os.symlink(t, dst)
                place(os.path.normpath(os.path.join(os.path.dirname(rel), t)))
            elif not os.path.exists(dst):
                shutil.copy2(cand, dst)
            return True
    return False
os.makedirs(out, exist_ok=True)
hit = sum(1 for rel in sorted(want) if place(rel))
for keep in ("WHENCE", "WHENCE.zst", "regulatory.db", "regulatory.db.p7s", "LICENSE.intel-ucode"):
    p = os.path.join(tree, keep)
    if os.path.exists(p):
        shutil.copy2(p, os.path.join(out, keep))
for e in sorted(os.listdir(tree)):
    if e.startswith(("LICEN", "GPL")) or e == "LICENSES":
        s, d = os.path.join(tree, e), os.path.join(out, e)
        shutil.copytree(s, d, dirs_exist_ok=True) if os.path.isdir(s) else shutil.copy2(s, d)
if os.path.isdir(os.path.join(tree, "intel-ucode")):
    shutil.copytree(os.path.join(tree, "intel-ucode"), os.path.join(out, "intel-ucode"), dirs_exist_ok=True)
total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(out) for f in fs
            if not os.path.islink(os.path.join(dp, f)))
print(f"  firmware pruned to what the modules name: {hit} of {len(want)} referenced names present "
      f"({len(want) - hit} not in the tree -- the kernel would miss them identically), {total // 1048576} MiB kept")
