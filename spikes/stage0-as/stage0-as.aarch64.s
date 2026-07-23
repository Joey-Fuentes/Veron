// ============================================================================
// Veron — SPIKE stage0-as  (ARM64 / AArch64)       *** feasibility spike ***
// ============================================================================
//
//   Invariants SUSPENDED. Toolkit tool #1: mnemonics + labels -> code bytes.
//   Shot B adds sub, mov-reg, cmp-imm, and data directives (.byte/.ascii).
//   With the writable segment from the (updated) elf tool, stage 0 is now
//   "assembler-complete": read input, manipulate memory, emit output, embed
//   data. The next rungs are written in THIS language, not hand-encoded.
//
// Input (one item per line; leading spaces OK; '#' = comment; labels 1 char):
//   mov  x<d> <imm>            mov  x<d> x<n>          add x<d> x<n> <imm>
//   sub  x<d> x<n> <imm>       cmp  x<n> x<m>          cmp x<n> <imm>
//   b / b.eq/ne/lt/ge <L>      svc                     :<L>
//   b / b.eq/ne/lt/ge @<pos>   (numeric PC-rel: <pos>=absolute output byte-pos;
//                               offset = (pos - here); '@'+digit only, so the
//                               pool label '@' — '@' then non-digit — still works)
//   bl <L>  ret  br x<n>  blr x<n>   (subroutines; base for stage 1)
//   orr/and/lsl/lsr/asr x<d> x<n> x<m>    movk x<d> <imm> <shift>
//   add/sub x<d> x<n> x<m> (register)     mul/udiv x<d> x<n> x<m>
//   adr  x<d> <L> | @<pos>     ldrb/strb w<t> x<n> x<m>   ldr/str w<t> x<n>
//   ldr/str x<t> x<n>          (64-bit load/store; first reg's width selects size)
//   .byte <imm>                .ascii "text"           (\n supported)
//
// Encodings:
//   mov#  = 0xD2800000|(imm<<5)|d      movr = 0xAA0003E0|(n<<16)|d
//   add   = 0x91000000|(imm<<10)|(n<<5)|d   sub = 0xD1000000|(imm<<10)|(n<<5)|d
//   cmpr  = 0xEB000000|(m<<16)|(n<<5)|31    cmpi= 0xF1000000|(imm<<10)|(n<<5)|31
//   b=0x14000000|off26   b.c=0x54000000|(off19<<5)|cond   svc=0xD4000001
//   adr=0x10000000|((V&3)<<29)|(((V>>2)&0x7FFFF)<<5)|d
//   ldrb=0x38606800|(m<<16)|(n<<5)|t    strb=0x38206800|(m<<16)|(n<<5)|t
//   ldr w=0xB9400000|(n<<5)|t   ldr x=0xF9400000|(n<<5)|t   (size bit30)
//   str w=0xB9000000|(n<<5)|t   str x=0xF9000000|(n<<5)|t
//   cond: eq0 ne1 ge10 lt11
// ============================================================================

    .equ INBUF_SZ, 0x4000000      // 64 MiB reserve. .bss is demand-zero-paged,
                                  // so an unused reserve costs nothing; overflow
                                  // is reported (see slurp_done), never truncated.

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
    // a full buffer means the input was almost certainly truncated: fail loudly
    // rather than assembling a silently incomplete program.
    mov     x2, #INBUF_SZ
    cmp     x21, x2
    b.lt    slurp_ok
    mov     x0, #2
    adr     x1, inover
    mov     x2, #34
    mov     x8, #64
    svc     #0
    mov     x0, #2
    mov     x8, #93
    svc     #0
slurp_ok:
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
    cmp     w0, #'.'
    b.eq    do_dot
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
    cmp     w0, #'r'
    b.eq    h_ret
    cmp     w0, #'o'
    b.eq    h_orr
    cmp     w0, #'u'
    b.eq    h_udiv
    cmp     w0, #'e'
    b.eq    h_eor
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

// ---- '.' : .byte / .ascii ----
do_dot:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'b'
    b.eq    do_byte
    cmp     w10, #'a'
    b.eq    do_ascii
    b       skip_line
do_byte:
    add     x20, x20, #5            // ".byte"
    bl      skip_ws
    bl      parse_dec
    mov     w9, w0
    bl      emit_byte
    b       parse_loop
do_ascii:
    add     x20, x20, #6            // ".ascii"
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x22               // opening quote
    b.ne    skip_line
    add     x20, x20, #1
asc_loop:
    cmp     x20, x21
    b.ge    parse_loop
    ldrb    w0, [x19, x20]
    add     x20, x20, #1
    cmp     w0, #0x22               // closing quote
    b.eq    parse_loop
    cmp     w0, #0x5C               // backslash
    b.ne    asc_emit
    ldrb    w0, [x19, x20]          // escaped char
    add     x20, x20, #1
    cmp     w0, #'n'
    b.ne    asc_emit
    mov     w0, #0x0A
asc_emit:
    mov     w9, w0
    bl      emit_byte
    b       asc_loop

// ---- 'a' : add or adr ----
h_a:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'n'               // 'and'
    b.eq    h_and
    cmp     w10, #'s'               // 'asr'
    b.eq    h_asr
    add     x2, x20, #2             // else 'd' -> add / adr
    ldrb    w10, [x19, x2]
    cmp     w10, #'d'
    b.eq    h_add
    cmp     w10, #'r'
    b.eq    h_adr
    b       skip_line

// ---- mov x<d> <imm>  or  mov x<d> x<n> ----
h_mov:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'u'               // 'mul'
    b.eq    h_mul
    add     x2, x20, #3
    ldrb    w10, [x19, x2]
    cmp     w10, #'k'               // 'movk'
    b.eq    h_movk
    add     x20, x20, #3
    bl      skip_ws
    add     x20, x20, #1
    bl      parse_dec
    mov     w24, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.eq    h_mov_reg
    bl      parse_dec               // immediate
    lsl     w9, w0, #5
    movz    w1, #0xD280, lsl #16
    orr     w9, w9, w1
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_mov_reg:
    add     x20, x20, #1
    bl      parse_dec               // src n
    movz    w9, #0x03E0
    movk    w9, #0xAA00, lsl #16
    orr     w9, w9, w0, lsl #16
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
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.eq    h_add_reg
    bl      parse_dec
    lsl     w9, w0, #10
    movz    w1, #0x9100, lsl #16
    orr     w9, w9, w1
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_add_reg:
    bl      next_reg
    movz    w9, #0x8B00, lsl #16
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

h_adr:
    add     x20, x20, #3
    bl      next_reg
    mov     w24, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'@'               // '@'+digit = numeric pos; else label (incl. label '@')
    b.ne    ha_lab
    add     x2, x20, #1
    ldrb    w2, [x19, x2]
    cmp     w2, #'0'
    b.lt    ha_lab
    cmp     w2, #'9'
    b.gt    ha_lab
    add     x20, x20, #1           // skip '@'
    bl      parse_dec              // w0 = absolute target byte-position
    mov     w1, w0
    b       ha_enc
ha_lab:
    add     x20, x20, #1
    ldr     w1, [x27, w0, uxtw #2]
ha_enc:
    sub     w1, w1, w22
    and     w2, w1, #3
    asr     w3, w1, #2
    and     w3, w3, #0x7FFFF
    movz    w9, #0x1000, lsl #16
    orr     w9, w9, w2, lsl #29
    orr     w9, w9, w3, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- cmp x<n> x<m>  or  cmp x<n> <imm> ----
h_cmp:
    add     x20, x20, #3
    bl      next_reg
    mov     w24, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.eq    h_cmp_reg
    bl      parse_dec               // immediate
    lsl     w9, w0, #10
    movz    w1, #0xF100, lsl #16
    orr     w9, w9, w1
    orr     w9, w9, w24, lsl #5
    orr     w9, w9, #31
    bl      emit
    b       parse_loop
h_cmp_reg:
    add     x20, x20, #1
    bl      parse_dec               // m
    movz    w9, #0xEB00, lsl #16
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w24, lsl #5
    orr     w9, w9, #31
    bl      emit
    b       parse_loop

// ---- 'l' : ldrb or ldr ----
h_l:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'s'               // 'lsl' / 'lsr'
    b.eq    h_lsl_or_lsr
    add     x2, x20, #3             // else 'd' -> ldr / ldrb
    ldrb    w10, [x19, x2]
    cmp     w10, #'b'
    b.eq    h_ldrb
    b       h_ldr
h_lsl_or_lsr:
    add     x2, x20, #2
    ldrb    w10, [x19, x2]
    cmp     w10, #'r'
    b.eq    h_lsr
    b       h_lsl
h_ldrb:
    add     x20, x20, #4
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    movz    w9, #0x3860, lsl #16
    movk    w9, #0x6800
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_ldr:
    add     x20, x20, #3
    bl      skip_ws                 // land on the reg-width letter (w/x)
    ldrb    w10, [x19, x20]
    movz    w9, #0xB940, lsl #16    // 32-bit: ldr w<t>, [x<n>]
    cmp     w10, #'x'
    b.ne    h_ldr_e
    movz    w9, #0xF940, lsl #16    // 64-bit: ldr x<t>, [x<n>]
h_ldr_e:
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    orr     w9, w9, w0, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- 's' : svc / sub / str / strb ----
h_s:
    add     x2, x20, #1
    ldrb    w10, [x19, x2]
    cmp     w10, #'v'
    b.eq    h_svc
    cmp     w10, #'u'
    b.eq    h_sub
    cmp     w10, #'t'
    b.eq    h_st
    b       skip_line
h_svc:
    add     x20, x20, #3
    movz    w9, #0x0001
    movk    w9, #0xD400, lsl #16
    bl      emit
    b       parse_loop
h_sub:
    add     x20, x20, #3
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'x'
    b.eq    h_sub_reg
    bl      parse_dec
    lsl     w9, w0, #10
    movz    w1, #0xD100, lsl #16
    orr     w9, w9, w1
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_sub_reg:
    bl      next_reg
    movz    w9, #0xCB00, lsl #16
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
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
    bl      skip_ws                 // land on the reg-width letter (w/x)
    ldrb    w10, [x19, x20]
    movz    w9, #0xB900, lsl #16    // 32-bit: str w<t>, [x<n>]
    cmp     w10, #'x'
    b.ne    h_str_e
    movz    w9, #0xF900, lsl #16    // 64-bit: str x<t>, [x<n>]
h_str_e:
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    orr     w9, w9, w0, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_strb:
    add     x20, x20, #4
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
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
    cmp     w10, #'l'               // 'bl' or 'blr'
    b.eq    h_bl_or_blr
    cmp     w10, #'r'               // 'br'
    b.eq    h_br
    // plain unconditional  b <L>   or   b @<pos>  (numeric output byte-position)
    add     x20, x20, #1
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'@'               // '@'+digit = numeric pos; else label (incl. label '@')
    b.ne    hb_lab
    add     x2, x20, #1
    ldrb    w2, [x19, x2]
    cmp     w2, #'0'
    b.lt    hb_lab
    cmp     w2, #'9'
    b.gt    hb_lab
    add     x20, x20, #1           // skip '@'
    bl      parse_dec              // w0 = absolute target byte-position
    mov     w1, w0
    b       hb_enc
hb_lab:
    add     x20, x20, #1
    ldr     w1, [x27, w0, uxtw #2]
hb_enc:
    sub     w1, w1, w22
    asr     w1, w1, #2
    and     w1, w1, #0x3FFFFFF
    movz    w9, #0x1400, lsl #16
    orr     w9, w9, w1
    bl      emit
    b       parse_loop

// ---- bl <L>  (branch-and-link; sets x30 automatically) ----
// same as 'b' but base 0x94000000; 'blr' when a 3rd char 'r' follows.
h_bl_or_blr:
    add     x2, x20, #2
    ldrb    w10, [x19, x2]
    cmp     w10, #'r'
    b.eq    h_blr
    add     x20, x20, #2            // skip "bl"
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #'@'               // '@'+digit = numeric pos; else label (incl. label '@')
    b.ne    hbl_lab
    add     x2, x20, #1
    ldrb    w2, [x19, x2]
    cmp     w2, #'0'
    b.lt    hbl_lab
    cmp     w2, #'9'
    b.gt    hbl_lab
    add     x20, x20, #1           // skip '@'
    bl      parse_dec              // w0 = absolute target byte-position
    mov     w1, w0
    b       hbl_enc
hbl_lab:
    add     x20, x20, #1
    ldr     w1, [x27, w0, uxtw #2]
hbl_enc:
    sub     w1, w1, w22
    asr     w1, w1, #2
    and     w1, w1, #0x3FFFFFF
    movz    w9, #0x9400, lsl #16
    orr     w9, w9, w1
    bl      emit
    b       parse_loop

// ---- br x<n>  (branch to register) ----
h_br:
    add     x20, x20, #2            // skip "br"
    bl      next_reg
    movz    w9, #0xD61F, lsl #16
    orr     w9, w9, w0, lsl #5
    bl      emit
    b       parse_loop

// ---- blr x<n>  (branch-to-register-and-link) ----
h_blr:
    add     x20, x20, #3            // skip "blr"
    bl      next_reg
    movz    w9, #0xD63F, lsl #16
    orr     w9, w9, w0, lsl #5
    bl      emit
    b       parse_loop

// ---- ret  (return via x30) ----
h_ret:
    add     x20, x20, #3            // skip "ret"
    movz    w9, #0x03C0
    movk    w9, #0xD65F, lsl #16
    bl      emit
    b       parse_loop

// ---- orr/and x<d> x<n> x<m>  (combine / mask instruction fields) ----
h_orr:
    add     x20, x20, #3            // skip "orr"
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    movz    w9, #0xAA00, lsl #16
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_and:
    add     x20, x20, #3            // skip "and"
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    movz    w9, #0x8A00, lsl #16
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

h_eor:
    add     x20, x20, #3            // skip "eor"
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    movz    w9, #0xCA00, lsl #16
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- lsl/lsr/asr x<d> x<n> x<m>  (variable shift by register) ----
h_lsl:
    add     x20, x20, #3            // skip "lsl"
    movz    w26, #0x2000
    b       shift_common
h_lsr:
    add     x20, x20, #3            // skip "lsr"
    movz    w26, #0x2400
    b       shift_common
h_udiv:
    add     x20, x20, #4            // skip "udiv"
    movz    w26, #0x0800            // UDIV: 0x9AC00800 | m<<16 | n<<5 | d
    b       shift_common
h_asr:
    add     x20, x20, #3            // skip "asr"
    movz    w26, #0x2800
shift_common:
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    movz    w9, #0x9AC0, lsl #16
    orr     w9, w9, w26             // 0x2000/0x2400/0x2800 selector
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- movk x<d> <imm> <shift>   shift in {0,16,32,48} ----
h_movk:
    add     x20, x20, #4            // skip "movk"
    bl      next_reg                // d
    mov     w24, w0
    bl      skip_ws
    bl      parse_dec               // imm16
    mov     w25, w0
    bl      skip_ws
    bl      parse_dec               // shift
    lsr     w0, w0, #4              // hw = shift / 16
    movz    w9, #0xF280, lsl #16
    orr     w9, w9, w0, lsl #21
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- mul x<d> x<n> x<m>  (= madd with xzr) ----
h_mul:
    add     x20, x20, #3            // skip "mul"
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    movz    w9, #0x9B00, lsl #16
    movk    w9, #0x7C00
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
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
    cmp     w0, #'@'               // '@'+digit = numeric pos; else label (incl. label '@')
    b.ne    bc_lab
    add     x2, x20, #1
    ldrb    w2, [x19, x2]
    cmp     w2, #'0'
    b.lt    bc_lab
    cmp     w2, #'9'
    b.gt    bc_lab
    add     x20, x20, #1           // skip '@'
    bl      parse_dec              // w0 = absolute target byte-position
    mov     w1, w0
    b       bc_enc
bc_lab:
    add     x20, x20, #1
    ldr     w1, [x27, w0, uxtw #2]
bc_enc:
    sub     w1, w1, w22
    asr     w1, w1, #2
    and     w1, w1, #0x7FFFF
    movz    w9, #0x5400, lsl #16
    orr     w9, w9, w1, lsl #5
    orr     w9, w9, w26
    bl      emit
    b       parse_loop

// ============================================================================
// leaf helpers
// ============================================================================
next_reg:
nr_ws:
    cmp     x20, x21
    b.ge    nr_done
    ldrb    w10, [x19, x20]
    cmp     w10, #' '
    b.eq    nr_a
    cmp     w10, #0x09
    b.eq    nr_a
    cmp     w10, #0x0A
    b.eq    nr_a
    cmp     w10, #0x0D
    b.eq    nr_a
    b       nr_done
nr_a:
    add     x20, x20, #1
    b       nr_ws
nr_done:
    add     x20, x20, #1            // skip reg letter
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
    b.ne    e_adv
    adr     x10, outword
    str     w9, [x10]
    mov     x0, #1
    mov     x1, x10
    mov     x2, #4
    mov     x8, #64
    svc     #0
e_adv:
    add     x22, x22, #4
    ret

emit_byte:
    cmp     x23, #2
    b.ne    eb_adv
    adr     x10, outword
    strb    w9, [x10]
    mov     x0, #1
    mov     x1, x10
    mov     x2, #1
    mov     x8, #64
    svc     #0
eb_adv:
    add     x22, x22, #1
    ret

    .bss
    .align  4
inover:  .ascii  "stage0-as: input exceeds INBUF_SZ\n"
        .balign 8
inbuf:   .space INBUF_SZ
symtab:  .space 512
outword: .space 4
