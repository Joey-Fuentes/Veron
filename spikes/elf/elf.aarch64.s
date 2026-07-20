// ============================================================================
// Veron — SPIKE elf   (ARM64 / AArch64)            *** feasibility spike ***
// ============================================================================
//
//   Invariants SUSPENDED. Written in ARM64 assembly, built by GNU `as`.
//   Toolkit tool #2: wraps raw code bytes in a minimal, runnable, static ELF.
//
//       program.s | stage0-as | elf OUTPATH        (produces a runnable file)
//
//   Reads raw code bytes on stdin, writes a complete ELF executable to the
//   path given as argv[1], and sets it executable itself (openat mode 0755 +
//   fchmod) — so the output runs with no host `chmod`.
//
//   The 120-byte header is the fixed template proven by elf-proto. Only two
//   fields depend on the input: p_filesz and p_memsz (= 120 + code length),
//   patched at runtime. e_entry is the constant 0x400078 (BASE + 120).
//
//   If run with no output path (e.g. by the generic spike harness), it exits 0
//   as a harmless no-op.
//
//   Linux arm64 ABI: nr in x8, args x0..x5, svc #0.
//     read=63 write=64 openat=56 fchmod=52 close=57 exit=93
//     AT_FDCWD = -100 ; O_WRONLY|O_CREAT|O_TRUNC = 0x241 ; mode 0755 = 0x1ED
//
//   state (callee-saved, survive syscalls):
//     x19 = output path (argv[1])   x20 = code length
//     x21 = output fd               x22 = code buffer base   x23 = header base
// ============================================================================

    .equ CODEBUF_SZ, 0x8000        // 32 KiB is plenty for spike programs
    .equ HDR_LEN,    120

    .text
    .global _start

_start:
    ldr     x0, [sp]               // argc
    cmp     x0, #2
    b.lt    clean_exit             // no output path -> harmless no-op success
    ldr     x19, [sp, #16]         // argv[1] = output path

    // ---- slurp raw code bytes from stdin into codebuf ----
    adr     x22, codebuf
    mov     x20, #0                // code length
read_loop:
    mov     x0, #0                 // stdin
    add     x1, x22, x20
    mov     x2, #CODEBUF_SZ
    sub     x2, x2, x20            // remaining space
    cmp     x2, #0
    b.le    read_done
    mov     x8, #63                // read
    svc     #0
    cmp     x0, #0
    b.le    read_done              // EOF or error
    add     x20, x20, x0
    b       read_loop
read_done:

    // ---- patch p_filesz / p_memsz = 120 + code length ----
    adr     x23, header
    mov     x24, #HDR_LEN
    add     x24, x24, x20          // filesz
    str     x24, [x23, #96]        // p_filesz
    str     x24, [x23, #104]       // p_memsz

    // ---- open the output file (creates it 0755) ----
    mov     x0, #-100              // AT_FDCWD
    mov     x1, x19                // path
    mov     x2, #0x241             // O_WRONLY|O_CREAT|O_TRUNC
    mov     x3, #0x1ED             // mode 0755
    mov     x8, #56                // openat
    svc     #0
    cmp     x0, #0
    b.lt    open_error
    mov     x21, x0                // fd

    // ---- write header (120 bytes) ----
    mov     x0, x21
    adr     x1, header
    mov     x2, #HDR_LEN
    mov     x8, #64                // write
    svc     #0

    // ---- write code bytes ----
    mov     x0, x21
    adr     x1, codebuf
    mov     x2, x20                // code length
    mov     x8, #64                // write
    svc     #0

    // ---- make sure it's executable (belt & suspenders vs umask) ----
    mov     x0, x21
    mov     x1, #0x1ED             // 0755
    mov     x8, #52                // fchmod
    svc     #0

    // ---- close ----
    mov     x0, x21
    mov     x8, #57                // close
    svc     #0

clean_exit:
    mov     x0, #0
    mov     x8, #93                // exit
    svc     #0

open_error:
    mov     x0, #1                 // exit 1 on open failure
    mov     x8, #93
    svc     #0

// ---------------------------------------------------------------------------
// The 120-byte ELF header template (proven by elf-proto). p_filesz (offset 96)
// and p_memsz (offset 104) are patched at runtime; everything else is fixed.
// Lives in .data because we write into it.
// ---------------------------------------------------------------------------
    .data
    .align  4
header:
    // --- ELF header (64 bytes) ---
    .byte 0x7f,0x45,0x4c,0x46, 0x02,0x01,0x01,0x00   // magic, class64, LSB, v1, SysV
    .byte 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00   // e_ident padding
    .byte 0x02,0x00, 0xb7,0x00                        // e_type=ET_EXEC, e_machine=AArch64
    .byte 0x01,0x00,0x00,0x00                         // e_version=1
    .byte 0x78,0x00,0x40,0x00, 0x00,0x00,0x00,0x00    // e_entry=0x400078
    .byte 0x40,0x00,0x00,0x00, 0x00,0x00,0x00,0x00    // e_phoff=64
    .byte 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00    // e_shoff=0
    .byte 0x00,0x00,0x00,0x00                         // e_flags=0
    .byte 0x40,0x00, 0x38,0x00, 0x01,0x00             // e_ehsize=64, e_phentsize=56, e_phnum=1
    .byte 0x00,0x00, 0x00,0x00, 0x00,0x00             // e_shentsize=0, e_shnum=0, e_shstrndx=0
    // --- program header (56 bytes), one PT_LOAD ---
    .byte 0x01,0x00,0x00,0x00                         // p_type=PT_LOAD
    .byte 0x07,0x00,0x00,0x00                         // p_flags=R+W+X (spike: writable so stores work)
    .byte 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00    // p_offset=0
    .byte 0x00,0x00,0x40,0x00, 0x00,0x00,0x00,0x00    // p_vaddr=0x400000
    .byte 0x00,0x00,0x40,0x00, 0x00,0x00,0x00,0x00    // p_paddr=0x400000
    .byte 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00    // p_filesz  (PATCHED, offset 96)
    .byte 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00    // p_memsz   (PATCHED, offset 104)
    .byte 0x00,0x00,0x01,0x00, 0x00,0x00,0x00,0x00    // p_align=0x10000

    .bss
    .align  4
codebuf: .space CODEBUF_SZ
