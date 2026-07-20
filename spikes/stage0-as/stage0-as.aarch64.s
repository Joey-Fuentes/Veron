// ============================================================================
// Veron — SPIKE stage0-as  (ARM64 / AArch64)       *** feasibility spike ***
// ============================================================================
//
//   Invariants SUSPENDED. Written in ARM64 assembly, built by GNU `as`.
//   Toolkit tool #1, now with LABELS + control flow (two-pass).
//
//   text (mnemonics + labels) --[stage0-as]--> raw code bytes
//
//   This is intended to be the LAST tool hand-written in raw assembly: it is
//   expressive enough that the next rung (stage 1) is written in *this*
//   language instead of hand-encoded.
//
// Input (one item per line; leading spaces OK; '#' = comment):
//        mov x<d> <imm>            MOVZ  Xd,#imm
//        add x<d> x<n> <imm>       ADD   Xd,Xn,#imm
//        cmp x<n> x<m>             CMP   Xn,Xm      (subs xzr,Xn,Xm)
//        b   <L>                   B     to label
//        b.eq/b.ne/b.lt/b.ge <L>   B.cond to label
//        svc                       SVC   #0
//        :<L>                      define label <L> at current position
//   Labels are a SINGLE character (e.g. :a ... b.ne a). Multi-char labels are
//   a natural stage-1 capability. Well-formed input assumed (it's a spike).
//
// Two passes over the input: pass 1 records label positions (no output),
// pass 2 emits bytes. Branch offsets are (target - here)/4 in instruction
// units — a difference of OUTPUT positions, so it needs no load address.
//
// Encodings:
//   mov  Xd,#imm  = 0xD2800000 | (imm<<5) | d
//   add  Xd,Xn,#i = 0x91000000 | (i<<10) | (n<<5) | d
//   cmp  Xn,Xm    = 0xEB000000 | (m<<16) | (n<<5) | 31
//   b    L        = 0x14000000 | (off26 & 0x3FFFFFF)
//   b.c  L        = 0x54000000 | ((off19 & 0x7FFFF)<<5) | cond
//   svc           = 0xD4000001                cond: eq0 ne1 ge10 lt11
//
// state (callee-saved, survive syscalls):
//   x19 inbuf base   x20 cursor   x21 inbuf length   x22 output offset
//   x23 pass(1/2)    x24,x25,x26 temps   x27 symtab base
// ============================================================================

    .equ INBUF_SZ, 0x4000

    .text
    .global _start

_start:
    // ---- slurp stdin ----
    adr     x19, inbuf
    mov     x21, #0
slurp:
    mov     x0, #0
    add     x1, x19, x21
    mov     x2, #INBUF_SZ
    sub     x2, x2, x21
    cmp     x2, #0
    b.le    slurp_done
    mov     x8, #63
    svc     #0
    cmp     x0, #0
    b.le    slurp_done
    add     x21, x21, x0
    b       slurp
slurp_done:
    adr     x27, symtab
    mov     x23, #1                 // pass 1

pass_start:
    mov     x20, #0                 // cursor
    mov     x22, #0                 // output offset

parse_loop:
    bl      skip_ws
    cmp     x20, x21
    b.ge    pass_end
    ldrb    w0, [x19, x20]
    cmp     w0, #'#'
    b.eq    skip_line
    cmp     w0, #':'
    b.eq    do_label
    cmp     w0, #'m'
    b.eq    h_mov
    cmp     w0, #'a'
    b.eq    h_add
    cmp     w0, #'c'
    b.eq    h_cmp
    cmp     w0, #'b'
    b.eq    h_branch
    cmp     w0, #'s'
    b.eq    h_svc
    b       skip_line               // unknown -> skip line

pass_end:
    cmp     x23, #2
    b.eq    the_end
    mov     x23, #2                 // switch to pass 2
    b       pass_start
the_end:
    mov     x0, #0
    mov     x8, #93
    svc     #0

// ---- skip to end of line (comments / unknown) ----
skip_line:
    cmp     x20, x21
    b.ge    parse_loop
    ldrb    w10, [x19, x20]
    add     x20, x20, #1
    cmp     w10, #0x0A
    b.ne    skip_line
    b       parse_loop

// ---- :L  define label ----
do_label:
    add     x20, x20, #1            // past ':'
    ldrb    w0, [x19, x20]          // label char
    add     x20, x20, #1
    str     w22, [x27, w0, uxtw #2] // symtab[char] = current offset
    b       parse_loop

// ---- mov x<d> <imm> ----
h_mov:
    add     x20, x20, #3
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.ne    skip_line
    add     x20, x20, #1
    bl      parse_dec               // w0 = d
    mov     w24, w0
    bl      skip_ws
    bl      parse_dec               // w0 = imm
    lsl     w9, w0, #5
    movz    w1, #0xD280, lsl #16
    orr     w9, w9, w1
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- add x<d> x<n> <imm> ----
h_add:
    add     x20, x20, #3
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.ne    skip_line
    add     x20, x20, #1
    bl      parse_dec               // d
    mov     w24, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.ne    skip_line
    add     x20, x20, #1
    bl      parse_dec               // n
    mov     w25, w0
    bl      skip_ws
    bl      parse_dec               // imm
    lsl     w9, w0, #10
    movz    w1, #0x9100, lsl #16
    orr     w9, w9, w1
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- cmp x<n> x<m> ----
h_cmp:
    add     x20, x20, #3
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.ne    skip_line
    add     x20, x20, #1
    bl      parse_dec               // n
    mov     w24, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.ne    skip_line
    add     x20, x20, #1
    bl      parse_dec               // m
    mov     w25, w0
    movz    w9, #0xEB00, lsl #16
    orr     w9, w9, w25, lsl #16
    orr     w9, w9, w24, lsl #5
    orr     w9, w9, #31
    bl      emit
    b       parse_loop

// ---- svc ----
h_svc:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'v'               // ensure "svc"
    b.ne    skip_line
    add     x20, x20, #3
    movz    w9, #0x0001
    movk    w9, #0xD400, lsl #16
    bl      emit
    b       parse_loop

// ---- b / b.cond ----
h_branch:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'.'
    b.eq    h_bcond
    // unconditional B
    add     x20, x20, #1            // past 'b'
    bl      skip_ws
    ldrb    w0, [x19, x20]          // label char
    add     x20, x20, #1
    ldr     w1, [x27, w0, uxtw #2]  // target offset
    sub     w1, w1, w22             // target - here
    asr     w1, w1, #2
    and     w1, w1, #0x3FFFFFF
    movz    w9, #0x1400, lsl #16
    orr     w9, w9, w1
    bl      emit
    b       parse_loop
h_bcond:
    add     x20, x20, #2            // past "b."
    ldrb    w2, [x19, x20]          // cond char 1
    add     x3, x20, #1
    ldrb    w3, [x19, x3]           // cond char 2
    add     x20, x20, #2            // past cond
    mov     w26, #14                // default AL
    cmp     w2, #'e'
    b.ne    bc_n
    cmp     w3, #'q'
    b.ne    bc_go
    mov     w26, #0                 // eq
    b       bc_go
bc_n:
    cmp     w2, #'n'
    b.ne    bc_l
    mov     w26, #1                 // ne
    b       bc_go
bc_l:
    cmp     w2, #'l'
    b.ne    bc_g
    mov     w26, #11                // lt
    b       bc_go
bc_g:
    cmp     w2, #'g'
    b.ne    bc_go
    mov     w26, #10                // ge
bc_go:
    bl      skip_ws
    ldrb    w0, [x19, x20]          // label char
    add     x20, x20, #1
    ldr     w1, [x27, w0, uxtw #2]
    sub     w1, w1, w22
    asr     w1, w1, #2
    and     w1, w1, #0x7FFFF
    movz    w9, #0x5400, lsl #16
    orr     w9, w9, w1, lsl #5
    orr     w9, w9, w26
    bl      emit
    b       parse_loop

// ============================================================================
// leaf helpers (no nested bl; x30 preserved, and survives the svc in emit)
// ============================================================================

// skip spaces/tabs/newlines/CR
skip_ws:
    cmp     x20, x21
    b.ge    sw_r
    ldrb    w10, [x19, x20]
    cmp     w10, #' '
    b.eq    sw_a
    cmp     w10, #0x09
    b.eq    sw_a
    cmp     w10, #0x0A
    b.eq    sw_a
    cmp     w10, #0x0D
    b.eq    sw_a
    b       sw_r
sw_a:
    add     x20, x20, #1
    b       skip_ws
sw_r:
    ret

// parse decimal at cursor -> w0 ; advance cursor
parse_dec:
    mov     w0, #0
pd_l:
    cmp     x20, x21
    b.ge    pd_r
    ldrb    w10, [x19, x20]
    cmp     w10, #'0'
    b.lt    pd_r
    cmp     w10, #'9'
    b.gt    pd_r
    sub     w10, w10, #'0'
    mov     w11, #10
    mul     w0, w0, w11
    add     w0, w0, w10
    add     x20, x20, #1
    b       pd_l
pd_r:
    ret

// emit the 32-bit word in w9 (only in pass 2); always advance offset by 4
emit:
    cmp     x23, #2
    b.ne    emit_adv
    adr     x10, outword
    str     w9, [x10]
    mov     x0, #1
    mov     x1, x10
    mov     x2, #4
    mov     x8, #64
    svc     #0
emit_adv:
    add     x22, x22, #4
    ret

// ---------------------------------------------------------------------------
    .bss
    .align  4
inbuf:   .space INBUF_SZ
symtab:  .space 512          // 128 single-char labels x 4-byte offset
outword: .space 4
