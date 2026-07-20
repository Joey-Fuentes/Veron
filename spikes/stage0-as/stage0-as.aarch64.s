// ============================================================================
// Veron — SPIKE stage0-as   (ARM64 / AArch64)      *** feasibility spike ***
// ============================================================================
//
//   Invariants SUSPENDED. Written in one shot in ordinary ARM64 assembly and
//   built by GNU `as` (the spike ground floor). This is the FIRST tool of a
//   small stage-0 toolkit:
//
//        text mnemonics --[stage0-as]--> raw code bytes
//                        --[labels ]--> (next tool)
//                        --[elf    ]--> runnable       (next tool)
//
//   stage0-as reads a line-oriented assembly program on stdin and writes the
//   raw 4-byte little-endian machine word for each instruction to stdout.
//   No labels, no ELF wrapper yet — just prove text -> correct bytes.
//
// Supported input (one instruction per line; leading spaces OK; '#' = comment):
//        mov x<reg> <decimal-imm>      -> MOVZ  (0..65535 immediate)
//        svc                           -> SVC #0
//
// Encodings (as derived in the stage0 round-trip work):
//        MOVZ Xd,#imm = 0xD2800000 | (imm << 5) | d
//        SVC  #0      = 0xD4000001
//
// Assumes well-formed input (it's a spike; the demo feeds it clean lines).
//
// Linux arm64 ABI: nr in x8, args x0..x2, svc #0.  read=63 write=64 exit=93.
// Registers x19..x25 are callee-saved and survive our syscalls (kernel
// preserves them), so parser state persists across read/write.
//
//   state:  x23 = input base   x22 = input length   x20 = cursor
//           x24 = parsed register number (in mov)
// ============================================================================

    .equ INBUF_SZ, 4096

    .text
    .global _start

_start:
    // ---- slurp all of stdin into inbuf ----
    adr     x23, inbuf              // input base (fixed)
    mov     x22, #0                 // bytes read so far
slurp:
    mov     x0, #0                  // stdin
    add     x1, x23, x22            // inbuf + offset
    mov     x2, #INBUF_SZ
    sub     x2, x2, x22             // remaining space
    cmp     x2, #0
    b.le    slurp_done              // buffer full
    mov     x8, #63                 // read
    svc     #0
    cmp     x0, #0
    b.le    slurp_done              // EOF or error
    add     x22, x22, x0
    b       slurp
slurp_done:
    // x22 = total length; set cursor to 0
    mov     x20, #0

// ---- main line/token loop ----
main_loop:
    bl      skip_ws                 // skip spaces, tabs, newlines
    cmp     x20, x22
    b.ge    done                    // consumed all input

    ldrb    w0, [x23, x20]
    cmp     w0, #0x23               // '#' comment?
    b.eq    skip_line
    cmp     w0, #'m'                // "mov"
    b.eq    do_mov
    cmp     w0, #'s'                // "svc"
    b.eq    do_svc
    b       skip_line               // unknown -> skip the line

skip_line:
    cmp     x20, x22
    b.ge    done
    ldrb    w0, [x23, x20]
    add     x20, x20, #1
    cmp     w0, #0x0A               // newline ends the line
    b.ne    skip_line
    b       main_loop

// ---- mov x<reg> <imm> ----
do_mov:
    add     x20, x20, #3            // skip "mov"
    bl      skip_ws
    ldrb    w0, [x23, x20]
    cmp     w0, #'x'                // expect a register 'x..'
    b.ne    skip_line               // malformed -> skip line
    add     x20, x20, #1
    bl      parse_dec               // w0 = register number
    mov     w24, w0                 // stash reg
    bl      skip_ws
    bl      parse_dec               // w0 = immediate

    // encode MOVZ: 0xD2800000 | (imm<<5) | reg
    lsl     w0, w0, #5
    movz    w2, #0xD280, lsl #16    // w2 = 0xD2800000
    orr     w2, w2, w0              // | (imm<<5)
    orr     w2, w2, w24             // | reg
    bl      emit_word
    b       main_loop

// ---- svc ----
do_svc:
    add     x20, x20, #3            // skip "svc"
    movz    w2, #0x0001             // w2 = 0x00000001
    movk    w2, #0xD400, lsl #16    // w2 = 0xD4000001
    bl      emit_word
    b       main_loop

done:
    mov     x0, #0
    mov     x8, #93                 // exit
    svc     #0

// ============================================================================
// helpers (leaf routines — they never call anything, so x30/lr stays valid,
// and it survives the syscall in emit_word because Linux preserves it)
// ============================================================================

// skip spaces / tabs / newlines / CR, advancing the cursor
skip_ws:
    cmp     x20, x22
    b.ge    sw_ret
    ldrb    w9, [x23, x20]
    cmp     w9, #' '                // 0x20
    b.eq    sw_adv
    cmp     w9, #0x09               // tab
    b.eq    sw_adv
    cmp     w9, #0x0A               // newline
    b.eq    sw_adv
    cmp     w9, #0x0D               // CR
    b.eq    sw_adv
    b       sw_ret
sw_adv:
    add     x20, x20, #1
    b       skip_ws
sw_ret:
    ret

// parse a decimal number at the cursor -> w0 ; advances cursor past digits
parse_dec:
    mov     w9, #0                  // accumulator
pd_loop:
    cmp     x20, x22
    b.ge    pd_ret
    ldrb    w10, [x23, x20]
    cmp     w10, #'0'
    b.lt    pd_ret
    cmp     w10, #'9'
    b.gt    pd_ret
    sub     w10, w10, #'0'
    mov     w11, #10
    mul     w9, w9, w11
    add     w9, w9, w10
    add     x20, x20, #1
    b       pd_loop
pd_ret:
    mov     w0, w9
    ret

// write the 32-bit word in w2 to stdout as 4 little-endian bytes
emit_word:
    adr     x9, outword
    str     w2, [x9]                // store LE (aarch64 is little-endian)
    mov     x0, #1                  // stdout
    mov     x1, x9                  // buf
    mov     x2, #4                  // count
    mov     x8, #64                 // write
    svc     #0
    ret

// ---------------------------------------------------------------------------
    .bss
    .align  4
inbuf:   .space INBUF_SZ
outword: .space 4
