#!/usr/bin/env python3
# ============================================================================
# Veron — SPIKE elf-proto  (throwaway prototype)
# ============================================================================
#
#   Invariants SUSPENDED. This is NOT the real `elf` tool. It is a throwaway
#   whose only job is to pin down the exact bytes of a minimal, static,
#   AArch64 ELF64 executable and prove the kernel/QEMU accepts them. Once this
#   runs, these field values become the template for the real `elf` tool
#   (which will emit the same header in ARM64 assembly).
#
#   Layout produced:
#       [ ELF header : 64 bytes ]
#       [ program header (1x PT_LOAD) : 56 bytes ]
#       [ code payload ]
#   The single PT_LOAD segment maps the whole file (p_offset=0) at BASE, so:
#       entry vaddr = BASE + 64 + 56 = BASE + 120
#
#   Payload = exit(42), so success is unambiguous: run it, check $? == 42.
#       mov x0, #42   = 0xD2800540      (status 42)
#       mov x8, #93   = 0xD2800BA8      (sys_exit)
#       svc #0        = 0xD4000001
# ============================================================================

import struct

BASE     = 0x400000          # load address for a classic static ET_EXEC
EHSIZE   = 64                # ELF64 header size
PHSIZE   = 56                # ELF64 program-header entry size
CODE_OFF = EHSIZE + PHSIZE   # 120 (0x78) — where code starts in the file
ENTRY    = BASE + CODE_OFF   # 0x400078

# --- payload: exit(42) ------------------------------------------------------
code = struct.pack('<III',
    0xD2800540,   # mov x0, #42
    0xD2800BA8,   # mov x8, #93   (sys_exit)
    0xD4000001,   # svc #0
)

filesz = CODE_OFF + len(code)

# --- ELF header (64 bytes) --------------------------------------------------
e_ident = b'\x7fELF' + bytes([
    2,   # EI_CLASS   = ELFCLASS64
    1,   # EI_DATA    = ELFDATA2LSB (little-endian)
    1,   # EI_VERSION = 1
    0,   # EI_OSABI   = System V
]) + b'\x00' * 8   # EI_ABIVERSION + padding

ehdr = e_ident + struct.pack('<HHIQQQIHHHHHH',
    2,        # e_type      = ET_EXEC
    183,      # e_machine   = EM_AARCH64 (0xB7)
    1,        # e_version   = 1
    ENTRY,    # e_entry
    EHSIZE,   # e_phoff     = 64 (program header right after this header)
    0,        # e_shoff     = 0 (no section headers)
    0,        # e_flags
    EHSIZE,   # e_ehsize    = 64
    PHSIZE,   # e_phentsize = 56
    1,        # e_phnum     = 1
    0,        # e_shentsize = 0
    0,        # e_shnum     = 0
    0,        # e_shstrndx  = 0
)
assert len(ehdr) == 64, len(ehdr)

# --- program header: one PT_LOAD, R+X, maps the whole file ------------------
phdr = struct.pack('<IIQQQQQQ',
    1,          # p_type   = PT_LOAD
    5,          # p_flags  = PF_R | PF_X
    0,          # p_offset = 0 (map from start of file)
    BASE,       # p_vaddr
    BASE,       # p_paddr
    filesz,     # p_filesz
    filesz,     # p_memsz
    0x10000,    # p_align  (p_vaddr ≡ p_offset mod p_align: 0x400000 % 0x10000 == 0)
)
assert len(phdr) == 56, len(phdr)

blob = ehdr + phdr + code
with open('a.elf', 'wb') as f:
    f.write(blob)

# Print the header template (these exact bytes are what the real `elf` tool
# will emit in assembly).
hdr = ehdr + phdr
print("entry  = 0x%x" % ENTRY)
print("filesz = %d bytes" % filesz)
print("header (%d bytes) hex:" % len(hdr))
print(hdr.hex())
