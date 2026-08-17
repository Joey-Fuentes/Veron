#!/usr/bin/env python3
# test-encoding.py -- an INDEPENDENT decoder for what veron-efiboot emits.
#
# The C tool encodes; this decodes from the UEFI 2.11 spec text alone,
# sharing no code with the encoder -- the same two-implementations
# discipline the repo uses everywhere a format matters. If both read the
# spec the same wrong way this won't catch it; the third check is
# firmware itself, on the laptop, which is why the tool read-back
# verifies every write.
import struct, subprocess, sys, uuid, os, tempfile

TOOL = "./veron-efiboot"
ARGS = ["--desc", "Veron slot A",
        "--part-guid", "d5a1f0e2-3c4b-4a6d-8e7f-102938475650",
        "--part-num", "2",
        "--part-start", "1050624",
        "--part-size", "8388608",
        "--file", r"\EFI\veron\A\linux.efi",
        "--cmdline", "root=PARTUUID=d5a1f0e2-3c4b-4a6d-8e7f-102938475650 ro"]

raw = subprocess.run([TOOL, "print-entry"] + ARGS,
                     check=True, capture_output=True).stdout

fail = 0
def check(name, got, want):
    global fail
    ok = got == want
    print(("  ok    " if ok else "  FAIL  ") + f"{name}: {got!r}" + ("" if ok else f" != {want!r}"))
    fail += 0 if ok else 1

# EFI_LOAD_OPTION: UINT32 Attributes; UINT16 FilePathListLength;
# CHAR16 Description[] NUL-terminated; FilePathList; OptionalData.
attrs, fpl_len = struct.unpack_from("<IH", raw, 0)
check("Attributes = LOAD_OPTION_ACTIVE", attrs, 0x00000001)
off = 6
end = raw.index(b"\x00\x00", off)
end += (end - off) % 2  # CHAR16 alignment of the terminator
desc = raw[off:end].decode("utf-16-le")
check("Description", desc, "Veron slot A")
off = end + 2

dp = raw[off:off + fpl_len]
opt = raw[off + fpl_len:]

# node 1: HD() -- Type 4 SubType 1 Length 42
t, st, ln = struct.unpack_from("<BBH", dp, 0)
check("HD node type/subtype/len", (t, st, ln), (4, 1, 42))
pnum, pstart, psize = struct.unpack_from("<IQQ", dp, 4)
check("PartitionNumber", pnum, 2)
check("PartitionStart", pstart, 1050624)
check("PartitionSize", psize, 8388608)
sig = dp[24:40]
# GPT GUIDs are mixed-endian; Python's bytes_le is exactly that layout.
check("Signature GUID", str(uuid.UUID(bytes_le=bytes(sig))),
      "d5a1f0e2-3c4b-4a6d-8e7f-102938475650")
mbrtype, sigtype = dp[40], dp[41]
check("MBRType=GPT, SignatureType=GUID", (mbrtype, sigtype), (2, 2))

# node 2: File() -- Type 4 SubType 4
t, st, ln = struct.unpack_from("<BBH", dp, 42)
check("File node type/subtype", (t, st), (4, 4))
fpath = dp[46:42 + ln - 2].decode("utf-16-le")
check("File path", fpath, r"\EFI\veron\A\linux.efi")

# node 3: End -- 0x7f 0xff len 4, and it is the last node
t, st, ln2 = struct.unpack_from("<BBH", dp, 42 + ln)
check("End node", (t, st, ln2), (0x7F, 0xFF, 4))
check("FilePathListLength consumed exactly", 42 + ln + 4, fpl_len)

# OptionalData is the kernel cmdline, UTF-16LE (stub reads LoadOptions)
cmd = opt.decode("utf-16-le").rstrip("\x00")
check("cmdline", cmd, "root=PARTUUID=d5a1f0e2-3c4b-4a6d-8e7f-102938475650 ro")

# ---- the write path against a fake efivarfs (no ioctls: --no-chattr) ----
with tempfile.TemporaryDirectory() as d:
    def run(*a):
        return subprocess.run([TOOL, "--efivars", d, "--no-chattr"] + list(a),
                              capture_output=True, text=False)
    r = run("set-entry", "0050", *ARGS)
    var = os.path.join(d, "Boot0050-8be4df61-93ca-11d2-aa0d-00e098032b8c")
    body = open(var, "rb").read()
    check("efivarfs write: 4-byte LE attrs 0x7 then payload",
          (body[:4], body[4:]), (b"\x07\x00\x00\x00", raw))
    r2 = run("set-entry", "0050", *ARGS)
    check("idempotent second write skipped",
          b"already in the wanted state" in r2.stderr, True)
    run("boot-next", "0050")
    bn = open(os.path.join(d, "BootNext-8be4df61-93ca-11d2-aa0d-00e098032b8c"), "rb").read()
    check("BootNext = LE UINT16 after attrs", bn, b"\x07\x00\x00\x00\x50\x00")
    run("boot-order", "0050,0051")
    bo = open(os.path.join(d, "BootOrder-8be4df61-93ca-11d2-aa0d-00e098032b8c"), "rb").read()
    check("BootOrder = LE UINT16 array", bo, b"\x07\x00\x00\x00\x50\x00\x51\x00")
    run("delete", "Boot0050")
    check("delete is unlink", os.path.exists(var), False)

print(("VERON-EFIBOOT-ENCODING-OK" if fail == 0 else f"VERON-EFIBOOT-ENCODING-FAIL {fail}"))
sys.exit(1 if fail else 0)
