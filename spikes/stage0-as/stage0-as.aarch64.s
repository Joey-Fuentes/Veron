// ============================================================================
// Veron — SPIKE stage0-as  (ARM64 / AArch64)       *** feasibility spike ***
// ============================================================================
//
//   Invariants SUSPENDED. Written in ARM64 assembly, built by GNU `as`.
//   Toolkit tool #1: mnemonics + labels -> raw code bytes (two-pass).
//   Shot A adds MEMORY + ADDRESSING so a program can touch buffers/tables.
//
// Input (one item per line; leading spaces OK; '#' = comment; labels 1 char):
//   mov  x<d> <imm>            MOVZ  Xd,#imm
//   add  x<d> x<n> <imm>       ADD   Xd,Xn,#imm
//   cmp  x<n> x<m>             CMP   Xn,Xm
//   b / b.eq/ne/lt/ge <L>      branch to label
//   svc                        SVC   #0
//   :<L>                       define label
//   adr  x<d> <L>              ADR   Xd,<label>      (address of label)
//   ldrb w<t> x<n> x<m>        LDRB  Wt,[Xn,Xm]
//   strb w<t> x<n> x<m>        STRB  Wt,[Xn,Xm]
//   ldr  w<t> x<n>             LDR   Wt,[Xn]         (word, offset 0)
//   str  w<t> x<n>             STR   Wt,[Xn]
//   (register operands: one letter w/x then a number)
//
// Encodings:
//   mov  = 0xD2800000 | (imm<<5) | d
//   add  = 0x91000000 | (imm<<10) | (n<<5) | d
//   cmp  = 0xEB000000 | (m<<16) | (n<<5) | 31
//   b    = 0x14000000 | (off26 & 0x3FFFFFF)
//   b.c  = 0x54000000 | ((off19 & 0x7FFFF)<<5) | cond    (eq0 ne1 ge10 lt11)
//   svc  = 0xD4000001
//   adr  = 0x10000000 | ((V&3)<<29) | (((V>>2)&0x7FFFF)<<5) | d   (V=target-here)
//   ldrb = 0x38606800 | (m<<16) | (n<<5) | t
//   strb = 0x38206800 | (m<<16) | (n<<5) | t
//   ldr  = 0xB9400000 | (n<<5) | t
//   str  = 0xB9000000 | (n<<5) | t
//
// state: x19 base  x20 cursor  x21 len  x22 offset  x23 pass  x27 symtab
//        x24,x25 reg temps ; helpers use x0-x11
// ============================================================================

    .equ INBUF_SZ, 0x4000

    .text
    .global _start

_start:
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
    mov     x23, #1
pass_start:
    mov     x20, #0
    mov     x22, #0
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
    b.eq    h_a
    cmp     w0, #'c'
    b.eq    h_cmp
    cmp     w0, #'b'
    b.eq    h_branch
    cmp     w0, #'l'
    b.eq    h_l
    cmp     w0, #'s'
    b.eq    h_s
    b       skip_line
pass_end:
    cmp     x23, #2
    b.eq    the_end
    mov     x23, #2
    b       pass_start
the_end:
    mov     x0, #0
    mov     x8, #93
    svc     #0

skip_line:
    cmp     x20, x21
    b.ge    parse_loop
    ldrb    w10, [x19, x20]
    add     x20, x20, #1
    cmp     w10, #0x0A
    b.ne    skip_line
    b       parse_loop

do_label:
    add     x20, x20, #1
    ldrb    w0, [x19, x20]
    add     x20, x20, #1
    str     w22, [x27, w0, uxtw #2]
    b       parse_loop

// ---- 'a' : add or adr ----
h_a:
    add     x2, x20, #2
    ldrb    w10, [x19, x2]
    cmp     w10, #'d'
    b.eq    h_add
    cmp     w10, #'r'
    b.eq    h_adr
    b       skip_line

h_mov:
    add     x20, x20, #3
    bl      skip_ws
    add     x20, x20, #1            // skip reg letter
    bl      parse_dec
    mov     w24, w0
    bl      skip_ws
    bl      parse_dec
    lsl     w9, w0, #5
    movz    w1, #0xD280, lsl #16
    orr     w9, w9, w1
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

h_add:
    add     x20, x20, #3
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      skip_ws
    bl      parse_dec
    lsl     w9, w0, #10
    movz    w1, #0x9100, lsl #16
    orr     w9, w9, w1
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

h_cmp:
    add     x20, x20, #3
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    movz    w9, #0xEB00, lsl #16
    orr     w9, w9, w25, lsl #16
    orr     w9, w9, w24, lsl #5
    orr     w9, w9, #31
    bl      emit
    b       parse_loop

h_adr:
    add     x20, x20, #3
    bl      next_reg
    mov     w24, w0                 // d
    bl      skip_ws
    ldrb    w0, [x19, x20]          // label char
    add     x20, x20, #1
    ldr     w1, [x27, w0, uxtw #2]  // target offset
    sub     w1, w1, w22             // V = target - here
    and     w2, w1, #3              // immlo
    asr     w3, w1, #2
    and     w3, w3, #0x7FFFF        // immhi
    movz    w9, #0x1000, lsl #16
    orr     w9, w9, w2, lsl #29
    orr     w9, w9, w3, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- 'l' : ldrb or ldr ----
h_l:
    add     x2, x20, #3
    ldrb    w10, [x19, x2]
    cmp     w10, #'b'
    b.eq    h_ldrb
    b       h_ldr
h_ldrb:
    add     x20, x20, #4
    bl      next_reg
    mov     w24, w0                 // t
    bl      next_reg
    mov     w25, w0                 // n
    bl      next_reg                // w0 = m
    movz    w9, #0x3860, lsl #16
    movk    w9, #0x6800
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_ldr:
    add     x20, x20, #3
    bl      next_reg
    mov     w24, w0                 // t
    bl      next_reg                // w0 = n
    movz    w9, #0xB940, lsl #16
    orr     w9, w9, w0, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- 's' : svc / str / strb ----
h_s:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'v'
    b.eq    h_svc
    cmp     w10, #'t'
    b.eq    h_st
    b       skip_line
h_svc:
    add     x20, x20, #3
    movz    w9, #0x0001
    movk    w9, #0xD400, lsl #16
    bl      emit
    b       parse_loop
h_st:
    add     x2, x20, #3
    ldrb    w10, [x19, x2]
    cmp     w10, #'b'
    b.eq    h_strb
    b       h_str
h_str:
    add     x20, x20, #3
    bl      next_reg
    mov     w24, w0                 // t
    bl      next_reg                // w0 = n
    movz    w9, #0xB900, lsl #16
    orr     w9, w9, w0, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_strb:
    add     x20, x20, #4
    bl      next_reg
    mov     w24, w0                 // t
    bl      next_reg
    mov     w25, w0                 // n
    bl      next_reg                // w0 = m
    movz    w9, #0x3820, lsl #16
    movk    w9, #0x6800
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- 'b' : b / b.cond ----
h_branch:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'.'
    b.eq    h_bcond
    add     x20, x20, #1
    bl      skip_ws
    ldrb    w0, [x19, x20]
    add     x20, x20, #1
    ldr     w1, [x27, w0, uxtw #2]
    sub     w1, w1, w22
    asr     w1, w1, #2
    and     w1, w1, #0x3FFFFFF
    movz    w9, #0x1400, lsl #16
    orr     w9, w9, w1
    bl      emit
    b       parse_loop
h_bcond:
    add     x20, x20, #2
    ldrb    w2, [x19, x20]
    add     x3, x20, #1
    ldrb    w3, [x19, x3]
    add     x20, x20, #2
    mov     w26, #14
    cmp     w2, #'e'
    b.ne    bc_n
    cmp     w3, #'q'
    b.ne    bc_go
    mov     w26, #0
    b       bc_go
bc_n:
    cmp     w2, #'n'
    b.ne    bc_l
    mov     w26, #1
    b       bc_go
bc_l:
    cmp     w2, #'l'
    b.ne    bc_g
    mov     w26, #11
    b       bc_go
bc_g:
    cmp     w2, #'g'
    b.ne    bc_go
    mov     w26, #10
bc_go:
    bl      skip_ws
    ldrb    w0, [x19, x20]
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
// leaf helpers (no nested bl)
// ============================================================================

// skip ws, then a single register letter (w/x), then parse the number -> w0
next_reg:
    // inline skip_ws
nr_ws:
    cmp     x20, x21
    b.ge    nr_ws_done
    ldrb    w10, [x19, x20]
    cmp     w10, #' '
    b.eq    nr_adv
    cmp     w10, #0x09
    b.eq    nr_adv
    cmp     w10, #0x0A
    b.eq    nr_adv
    cmp     w10, #0x0D
    b.eq    nr_adv
    b       nr_ws_done
nr_adv:
    add     x20, x20, #1
    b       nr_ws
nr_ws_done:
    add     x20, x20, #1            // skip the register letter (w or x)
    // inline parse_dec
    mov     w0, #0
nr_dl:
    cmp     x20, x21
    b.ge    nr_r
    ldrb    w10, [x19, x20]
    cmp     w10, #'0'
    b.lt    nr_r
    cmp     w10, #'9'
    b.gt    nr_r
    sub     w10, w10, #'0'
    mov     w11, #10
    mul     w0, w0, w11
    add     w0, w0, w10
    add     x20, x20, #1
    b       nr_dl
nr_r:
    ret

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

    .bss
    .align  4
inbuf:   .space INBUF_SZ
symtab:  .space 512
outword: .space 4
