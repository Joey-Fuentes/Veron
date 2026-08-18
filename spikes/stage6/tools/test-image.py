#!/usr/bin/env python3
# test-image.py -- independent decoders for what veron-mkgpt and
# veron-mkfat emit, written from the UEFI/GPT and Microsoft FAT specs,
# sharing no code with the writers. Then the whole-image assembly is
# checked: partitions where the table says, filesystems inside them
# intact, and the image byte-identical when built twice.
import io, os, struct, subprocess, sys, tempfile, zlib, uuid, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
fail = 0
def check(name, got, want):
    global fail
    ok = got == want
    print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok else f": {got!r} != {want!r}"))
    fail += 0 if ok else 1

# ---------- FAT32 reader (spec-only) ----------
def fat_read(img):
    bps, spc = struct.unpack_from("<HB", img, 11)
    reserved, nfats = struct.unpack_from("<HB", img, 14)
    fatsz = struct.unpack_from("<I", img, 36)[0]
    rootclus = struct.unpack_from("<I", img, 44)[0]
    volid = struct.unpack_from("<I", img, 67)[0]
    data0 = (reserved + nfats * fatsz) * bps
    fat = struct.unpack_from(f"<{fatsz*bps//4}I", img, reserved * bps)
    def chain(c):
        out = []
        while 2 <= c < 0x0FFFFFF8:
            out.append(c); c = fat[c] & 0x0FFFFFFF
        return out
    def clusters(c):
        return b"".join(img[data0 + (x-2)*spc*bps : data0 + (x-1)*spc*bps]
                        for x in chain(c))
    def rdir(c):
        blob = clusters(c); out = {}; lfn = []
        for off in range(0, len(blob), 32):
            e = blob[off:off+32]
            if e[0] == 0: break
            if e[0] == 0xE5: lfn = []; continue
            if e[11] == 0x0F:
                lfn.insert(0, (e[1:11] + e[14:26] + e[28:32]).decode("utf-16-le"))
                continue
            name = "".join(lfn).split("\x00")[0] if lfn else \
                   (e[0:8].decode().strip() +
                    ("." + e[8:11].decode().strip() if e[8:11].strip() else ""))
            lfn = []
            clus = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
            size = struct.unpack_from("<I", e, 28)[0]
            if name in (".", ".."): continue
            out[name] = ("dir", clus) if e[11] & 0x10 else ("file", clus, size)
        return out
    def walk(c):
        out = {}
        for name, t in rdir(c).items():
            out[name] = walk(t[1]) if t[0] == "dir" else clusters(t[1])[:t[2]]
        return out
    return volid, walk(rootclus)

# ---------- GPT reader (spec-only) ----------
def gpt_read(img):
    hdr = img[512:512+92]
    check("GPT signature", hdr[0:8], b"EFI PART")
    hcrc = struct.unpack_from("<I", hdr, 16)[0]
    z = bytearray(hdr); struct.pack_into("<I", z, 16, 0)
    check("GPT header CRC", zlib.crc32(bytes(z)) & 0xFFFFFFFF, hcrc)
    nent, esz, ecrc = struct.unpack_from("<III", hdr, 80)
    entries = img[1024:1024 + nent*esz]
    check("GPT entries CRC", zlib.crc32(entries) & 0xFFFFFFFF, ecrc)
    disk_guid = uuid.UUID(bytes_le=bytes(hdr[56:72]))
    alt = struct.unpack_from("<Q", hdr, 32)[0]
    bh = img[alt*512: alt*512+92]
    check("backup header present", bh[0:8], b"EFI PART")
    parts = []
    for i in range(nent):
        e = entries[i*esz:(i+1)*esz]
        if e[0:16] == b"\x00"*16: continue
        parts.append({
            "type": str(uuid.UUID(bytes_le=e[0:16])),
            "guid": str(uuid.UUID(bytes_le=e[16:32])),
            "first": struct.unpack_from("<Q", e, 32)[0],
            "last": struct.unpack_from("<Q", e, 40)[0],
            "attrs": struct.unpack_from("<Q", e, 48)[0],
            "name": e[56:128].decode("utf-16-le").rstrip("\x00")})
    check("protective MBR 0xEE + sig", (img[446+4], img[510:512]), (0xEE, b"\x55\xaa"))
    return str(disk_guid), parts

# ---------- exercise the FAT writer alone ----------
with tempfile.TemporaryDirectory() as d:
    os.makedirs(f"{d}/esp/EFI/BOOT"); os.makedirs(f"{d}/esp/EFI/veron/A")
    kern = os.urandom(3 * 1048576)
    open(f"{d}/esp/EFI/BOOT/BOOTX64.EFI", "wb").write(kern)
    open(f"{d}/esp/EFI/veron/A/linux.efi", "wb").write(kern)
    subprocess.run([sys.executable, f"{HERE}/veron-mkfat", "--size", str(128*1048576),
                    "--root", f"{d}/esp", "--out", f"{d}/esp.img"],
                   check=True, capture_output=True)
    img = open(f"{d}/esp.img", "rb").read()
    volid, tree = fat_read(img)
    check("FAT volume id fixed", volid, 0x5EB0A501)
    check("fallback path bytes", hashlib.sha256(tree["EFI"]["BOOT"]["BOOTX64.EFI"]).hexdigest(),
          hashlib.sha256(kern).hexdigest())
    check("mixed-case LFN path survives",
          tree["EFI"]["veron"]["A"]["linux.efi"] == kern, True)
    img2 = subprocess.run([sys.executable, f"{HERE}/veron-mkfat", "--size", str(128*1048576),
                           "--root", f"{d}/esp", "--out", "/dev/stdout"],
                          check=True, capture_output=True).stdout
    # (writer prints its status line to stdout too when --out is stdout;
    # compare via a second file instead)
    subprocess.run([sys.executable, f"{HERE}/veron-mkfat", "--size", str(128*1048576),
                    "--root", f"{d}/esp", "--out", f"{d}/esp2.img"],
                   check=True, capture_output=True)
    check("FAT image reproducible",
          hashlib.sha256(img).hexdigest(),
          hashlib.sha256(open(f"{d}/esp2.img","rb").read()).hexdigest())

# ---------- the whole image ----------
with tempfile.TemporaryDirectory() as d:
    os.makedirs(f"{d}/rootfs/usr/bin"); os.makedirs(f"{d}/rootfs/etc")
    open(f"{d}/rootfs/usr/bin/hello", "wb").write(b"#!/bin/sh\necho veron\n")
    open(f"{d}/rootfs/etc/veron-release", "w").write("VERON_COMMIT=test\n")
    open(f"{d}/kernel.efi", "wb").write(os.urandom(2 * 1048576))
    # a modules tarball and a firmware tree, absorbed into slot A
    os.makedirs(f"{d}/m/lib/modules/7.1.5-generic/kernel")
    open(f"{d}/m/lib/modules/7.1.5-generic/kernel/e1000e.ko.zst", "wb").write(b"MOD" * 100)
    open(f"{d}/m/lib/modules/7.1.5-generic/modules.dep", "w").write("")
    subprocess.run(["tar", "-czf", f"{d}/modules.tar.zst", "-C", f"{d}/m", "lib"], check=True)
    os.makedirs(f"{d}/fw/rtw89")
    open(f"{d}/fw/WHENCE.zst", "wb").write(b"WHENCE")
    open(f"{d}/fw/LICENCE.rtw89", "w").write("license text")
    open(f"{d}/fw/rtw89/rtw8852a_fw.bin.zst", "wb").write(b"FW" * 200)
    env = dict(os.environ, VERON_NORMALIZE="/home/claude/veron/Veron/spikes/stage5/tools/normalize-ext4.py", VERON_ESP_MB="128", VERON_ROOT_MB="64", VERON_PERSIST_MB="16",
               SOURCE_DATE_EPOCH="0")
    for out in ("img1", "img2"):
        r = subprocess.run(["sh", f"{HERE}/veron-mkimage", "--rootfs", f"{d}/rootfs",
                            "--kernel", f"{d}/kernel.efi", "--out", f"{d}/{out}",
                            "--modules-tar", f"{d}/modules.tar.zst",
                            "--firmware-dir", f"{d}/fw"],
                           env=env, capture_output=True, text=True)
        if r.returncode:
            print(r.stdout, r.stderr); sys.exit(1)
    h1 = hashlib.sha256(open(f"{d}/img1","rb").read()).hexdigest()
    h2 = hashlib.sha256(open(f"{d}/img2","rb").read()).hexdigest()
    check("WHOLE IMAGE reproducible (built twice, same bytes)", h1, h2)

    img = open(f"{d}/img1", "rb").read()
    disk_guid, parts = gpt_read(img)
    check("4 partitions", len(parts), 4)
    check("names", [p["name"] for p in parts],
          ["veron-esp", "veron-root-a", "veron-root-b", "veron-persist"])
    check("root type GUIDs private and equal",
          (parts[1]["type"] == parts[2]["type"],
           parts[1]["type"] != "4f68bce3-e8cd-4db1-96e7-fbcaf984b709"), (True, True))
    check("roots: no-auto|read-only attrs",
          (parts[1]["attrs"] >> 60) & 0x9, 0x9)
    check("ESP type standard", parts[0]["type"], "c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
    # the ESP inside the disk decodes and carries the kernel at both paths
    esp = img[parts[0]["first"]*512:(parts[0]["last"]+1)*512]
    _, tree = fat_read(esp)
    ksha = hashlib.sha256(open(f"{d}/kernel.efi","rb").read()).hexdigest()
    check("ESP-in-disk: fallback kernel",
          hashlib.sha256(tree["EFI"]["BOOT"]["BOOTX64.EFI"]).hexdigest(), ksha)
    check("ESP-in-disk: slot A kernel",
          hashlib.sha256(tree["EFI"]["veron"]["A"]["linux.efi"]).hexdigest(), ksha)
    # root-A is a real ext4 with the rootfs in it: dumpe2fs sees the fixed UUID
    ra = f"{d}/rootA.img"
    open(ra, "wb").write(img[parts[1]["first"]*512:(parts[1]["last"]+1)*512])
    de = subprocess.run(["dumpe2fs", "-h", ra], capture_output=True, text=True).stdout
    check("root-A ext4, fixed UUID",
          "00000000-0000-4000-8000-0000000000a1" in de, True)
    # the absorbed world is IN the slot: rdump and look
    rd = f"{d}/rd"; os.makedirs(rd)
    subprocess.run(["/sbin/debugfs", "-R", f"rdump /usr/lib {rd}", ra],
                   capture_output=True)
    check("modules absorbed into slot A",
          os.path.exists(f"{rd}/lib/modules/7.1.5-generic/kernel/e1000e.ko.zst"), True)
    check("firmware + its LICENCE absorbed",
          os.path.exists(f"{rd}/lib/firmware/rtw89/rtw8852a_fw.bin.zst")
          and os.path.exists(f"{rd}/lib/firmware/LICENCE.rtw89"), True)
    check("input rootfs never mutated",
          os.path.exists(f"{d}/rootfs/usr/lib/firmware"), False)

print("VERON-IMAGE-OK" if fail == 0 else f"VERON-IMAGE-FAIL {fail}")
sys.exit(1 if fail else 0)
