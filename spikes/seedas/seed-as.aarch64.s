// ============================================================================
// Veron — SPIKE seed-as  (ARM64 / AArch64)   *** feasibility spike ***
// ============================================================================
//
//   Invariants SUSPENDED. This is a throwaway spike, written in one shot in
//   normal ARM64 assembly and built by the GNU assembler. It is NOT the real,
//   bijectively-hand-encoded seed-as. The point is only to prove that a program
//   WE wrote in ARM64 assembly can read input and emit a runnable binary on our
//   qemu-user CI setup — i.e. that "stage 0 as an assembler" is buildable here.
//
// What it does (a hex0-style loader — the classic minimal seed):
//   * reads stdin
//   * keeps only hex digits [0-9a-fA-F]; ignores whitespace, and treats '#'
//     as a line comment (skips to newline)
//   * packs each pair of hex digits into one byte
//   * writes the resulting raw bytes to stdout
//
// So `seed-as < prog.hex > out` turns a commented hex dump into a raw binary.
// (Emitting a full ELF wrapper is a later concern; here we just prove the
// read -> decode -> write core works.)
//
// Build/run via the spike runner (it assembles + links static + runs qemu):
//   tools/spike.sh aarch64 spikes/seedas/seed-as.aarch64.s
//   ...but seed-as reads stdin, so to actually exercise it, pipe hex in:
//   (see spikes/seedas/README for a demo one-liner)
//
// Linux arm64 ABI: nr in x8, args x0..x2, `svc #0`.
//   read=63  write=64  exit=93     fds: stdin=0 stdout=1
// ============================================================================

    .text
    .global _start

// ---- register usage -------------------------------------------------------
//   w19 : "have a pending high nibble?" flag (0/1)
//   w20 : the pending high nibble value (0..15), then the assembled byte
//   w21 : '#' comment mode flag (0/1) — skip until newline
//   x23 : bytes in the current read chunk
//   x24 : base address of inbuf
//   x25 : index within the current chunk
// x19..x25 are callee-saved and survive our svc calls (the kernel preserves
// them), so our loop state persists across read/write syscalls.

_start:
    mov     w19, #0                 // no pending nibble yet
    mov     w21, #0                 // not in a comment

read_loop:
    // read(0, inbuf, 256)
    mov     x0, #0                  // fd = stdin
    adr     x1, inbuf               // buf
    mov     x2, #256                // count
    mov     x8, #63                 // read
    svc     #0
    // x0 = bytes read; <=0 means EOF or error -> done
    cmp     x0, #0
    b.le    done

    mov     x23, x0                 // x23 = number of bytes in this chunk
    adr     x24, inbuf              // x24 = cursor into inbuf
    mov     x25, #0                 // x25 = index within chunk

byte_loop:
    cmp     x25, x23
    b.ge    read_loop               // consumed the chunk -> read more

    ldrb    w0, [x24, x25]          // w0 = current character
    add     x25, x25, #1            // advance index

    // --- comment handling ---------------------------------------------------
    cmp     w21, #1
    b.ne    not_in_comment
    // in comment: only a newline (0x0A) ends it
    cmp     w0, #0x0A
    b.ne    byte_loop               // still in comment, skip char
    mov     w21, #0                 // newline -> leave comment
    b       byte_loop
not_in_comment:
    cmp     w0, #0x23               // start of a comment?  ('#' == 0x23)
    b.ne    not_hash
    mov     w21, #1
    b       byte_loop
not_hash:

    // --- classify as hex digit, else skip ----------------------------------
    // '0'..'9'
    cmp     w0, #'0'
    b.lt    skip
    cmp     w0, #'9'
    b.gt    try_af_lower
    sub     w0, w0, #'0'            // 0..9
    b       got_nibble
try_af_lower:
    // 'a'..'f'
    cmp     w0, #'a'
    b.lt    try_af_upper
    cmp     w0, #'f'
    b.gt    skip
    sub     w0, w0, #'a'
    add     w0, w0, #10            // 10..15
    b       got_nibble
try_af_upper:
    // 'A'..'F'
    cmp     w0, #'A'
    b.lt    skip
    cmp     w0, #'F'
    b.gt    skip
    sub     w0, w0, #'A'
    add     w0, w0, #10            // 10..15
    b       got_nibble

skip:
    b       byte_loop              // not a hex digit -> ignore

got_nibble:
    // w0 = this nibble (0..15). Do we already have a high nibble pending?
    cmp     w19, #1
    b.eq    have_high
    // no: stash it as the high nibble
    mov     w20, w0
    mov     w19, #1
    b       byte_loop
have_high:
    // yes: combine (high<<4 | low) and emit one byte
    lsl     w20, w20, #4
    orr     w20, w20, w0
    adr     x1, outbuf             // x1 = address of outbuf
    strb    w20, [x1]              // store the assembled byte there
    // write(1, outbuf, 1)  (x1 already = outbuf, preserved across the setup below)
    mov     x0, #1                 // fd = stdout
    mov     x2, #1                 // count
    mov     x8, #64                // write
    svc     #0
    mov     w19, #0                // clear pending
    b       byte_loop

done:
    // exit(0)
    mov     x0, #0
    mov     x8, #93                // exit
    svc     #0

// ---------------------------------------------------------------------------
    .bss
    .align  4
inbuf:  .space 256
outbuf: .space 1
