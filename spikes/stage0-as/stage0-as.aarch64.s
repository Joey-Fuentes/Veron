// IMMEDIATES ARE WRITTEN AS LOWERCASE HEX, DELIBERATELY, AND CHARACTER
// LITERALS AS THEIR HEX VALUE WITH THE CHARACTER IN A TRAILING COMMENT.
//
// This is not a style preference. GNU objdump prints every immediate as
// lowercase hex, unconditionally; llvm-objdump does the same by default. With
// the source written the same way, the round-trip check in
// .github/workflows/stage0-selfhost.yml becomes a plain `diff` of the
// comment-stripped source against the disassembly, rather than a comparison
// mediated by a normaliser -- and a normaliser that is itself wrong
// manufactures findings in the thing being measured, which happened twice
// while this check was being built.
//
// Nothing is lost: `#0x23  // '#'` carries the character for the reader and
// the exact bytes for the check. Shift amounts stay decimal because both
// decoders print `lsl #16` decimal even beside a hex immediate.
//
// MEASURED LIMIT: 30 of 785 lines cannot satisfy both decoders whatever the
// source says. llvm-objdump renders 32-bit immediates with the high bit set as
// negative hex (`#-0x2d800000` where GNU prints `#0xd2800000`, 20 lines) and
// prints svc's immediate in decimal (10 lines). Same bits either way -- both
// assemblers reproduce the binary from either disassembly. GNU objdump is
// therefore the exact-diff target; llvm-objdump remains the independent
// cross-check.
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
    mov     x21, #0x0
slurp:
    mov     x0, #0x0
    add     x1, x19, x21
    mov     x2, #INBUF_SZ
    sub     x2, x2, x21
    cmp     x2, #0x0
    b.le    slurp_done
    mov     x8, #0x3f
    svc     #0x0
    cmp     x0, #0x0
    b.le    slurp_done
    add     x21, x21, x0
    b       slurp
slurp_done:
    // a full buffer means the input was almost certainly truncated: fail loudly
    // rather than assembling a silently incomplete program.
    mov     x2, #INBUF_SZ
    cmp     x21, x2
    b.lt    slurp_ok
    mov     x0, #0x2
    adr     x1, inover
    mov     x2, #0x22
    mov     x8, #0x40
    svc     #0x0
    mov     x0, #0x2
    mov     x8, #0x5d
    svc     #0x0
slurp_ok:
    adr     x27, symtab
    mov     x23, #0x1
pass_start:
    mov     x20, #0x0
    mov     x22, #0x0
parse_loop:
    bl      skip_ws
    cmp     x20, x21
    b.ge    pass_end
    mov     x28, x20                        // line start, kept for `die` to echo
    mov     x17, #0x0                       // width: 0 = 64-bit, 1 = 32-bit (w-register)
    ldrb    w0, [x19, x20]
    cmp     w0, #0x23                       // '#'
    b.eq    skip_line
    cmp     w0, #0x3a                       // ':'
    b.eq    do_label
    cmp     w0, #0x2e                       // '.'
    b.eq    do_dot
    cmp     w0, #0x6d                       // 'm'
    b.eq    h_mov
    cmp     w0, #0x61                       // 'a'
    b.eq    h_a
    cmp     w0, #0x63                       // 'c'
    b.eq    h_cmp
    cmp     w0, #0x62                       // 'b'
    b.eq    h_branch
    cmp     w0, #0x6c                       // 'l'
    b.eq    h_l
    cmp     w0, #0x73                       // 's'
    b.eq    h_s
    cmp     w0, #0x72                       // 'r'
    b.eq    h_ret
    cmp     w0, #0x6f                       // 'o'
    b.eq    h_orr
    cmp     w0, #0x75                       // 'u'
    b.eq    h_udiv
    cmp     w0, #0x65                       // 'e'
    b.eq    h_eor
    b       die                             // was `b skip_line`: unknown mnemonics VANISHED
pass_end:
    cmp     x23, #0x2
    b.eq    the_end
    mov     x23, #0x2
    b       pass_start
the_end:
    mov     x0, #0x0
    mov     x8, #0x5d
    svc     #0x0

// ---- die: reject the current line and exit nonzero ------------------------
// Entered with x28 = start of the offending line (saved in parse_loop). Writes
//     stage0-as: rejected: <the line>
// to stderr and exits 2. Never returns, so it clobbers freely.
//
// WHY AN ECHO RATHER THAN A BARE STRING. A fixed message costs eight
// instructions and says only that something, somewhere, was wrong. Echoing the
// line costs about twelve more and says exactly which one. Against a 639-line
// self-host that is the difference between a log you can act on and a bisect.
//
// Every instruction below is inside the subset stage0-as itself accepts, so
// this routine does not enlarge the self-hosting gap it exists to close.
die:
    mov     x0, #0x2
    adr     x1, rejmsg
    mov     x2, #0x15
    mov     x8, #0x40
    svc     #0x0
    mov     x24, x28
die_scan:
    cmp     x24, x21
    b.ge    die_emit
    ldrb    w10, [x19, x24]
    cmp     w10, #0xa
    b.eq    die_emit
    add     x24, x24, #0x1
    b       die_scan
die_emit:
    add     x1, x19, x28
    sub     x2, x24, x28
    mov     x0, #0x2
    mov     x8, #0x40
    svc     #0x0
    mov     x0, #0x2
    adr     x1, rejnl
    mov     x2, #0x1
    mov     x8, #0x40
    svc     #0x0
    mov     x0, #0x2
    mov     x8, #0x5d
    svc     #0x0

skip_line:
    cmp     x20, x21
    b.ge    parse_loop
    ldrb    w10, [x19, x20]
    add     x20, x20, #0x1
    cmp     w10, #0xa
    b.ne    skip_line
    b       parse_loop

do_label:
    add     x20, x20, #0x1                  // skip ':'
    // sym_idx reads BOTH characters itself. The single-character read that
    // used to sit here would consume the first one, leaving sym_idx to take
    // characters two and three -- every label silently resolving to the wrong
    // slot, which is the one failure a symbol table must not have.
    bl      sym_idx
    add     x0, x27, x0
    str     w22, [x0]
    b       parse_loop

// ---- '.' : .byte / .ascii ----
do_dot:
    add     x2, x20, #0x1
    ldrb    w10, [x19, x2]
    cmp     w10, #0x62                      // 'b'
    b.eq    do_byte
    cmp     w10, #0x61                      // 'a'
    b.eq    do_ascii
    b       die                             // unknown '.' directive
do_byte:
    add     x20, x20, #0x5                  // ".byte"
    bl      skip_ws
    bl      parse_dec
    mov     w9, w0
    bl      emit_byte
    b       parse_loop
do_ascii:
    add     x20, x20, #0x6                  // ".ascii"
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x22                       // opening quote
    b.ne    die                             // .ascii with no opening quote
    add     x20, x20, #0x1
asc_loop:
    cmp     x20, x21
    b.ge    parse_loop
    ldrb    w0, [x19, x20]
    add     x20, x20, #0x1
    cmp     w0, #0x22                       // closing quote
    b.eq    parse_loop
    cmp     w0, #0x5c                       // backslash
    b.ne    asc_emit
    ldrb    w0, [x19, x20]                  // escaped char
    add     x20, x20, #0x1
    cmp     w0, #0x6e                       // 'n'
    b.ne    asc_emit
    mov     w0, #0xa
asc_emit:
    mov     w9, w0
    bl      emit_byte
    b       asc_loop

// ---- 'a' : add or adr ----
h_a:
    add     x2, x20, #0x1
    ldrb    w10, [x19, x2]
    cmp     w10, #0x6e                      // 'n'  'and'
    b.eq    h_and
    cmp     w10, #0x73                      // 's'  'asr'
    b.eq    h_asr
    add     x2, x20, #0x2                   // else 'd' -> add / adr
    ldrb    w10, [x19, x2]
    cmp     w10, #0x64                      // 'd'
    b.eq    h_add
    cmp     w10, #0x72                      // 'r'
    b.eq    h_adr
    b       die                             // 'a...' that is not and/asr/add/adr

// ---- mov x<d> <imm>  or  mov x<d> x<n> ----
h_mov:
    add     x2, x20, #0x1
    ldrb    w10, [x19, x2]
    cmp     w10, #0x75                      // 'u'  'mul'
    b.eq    h_mul
    add     x2, x20, #0x3
    ldrb    w10, [x19, x2]
    cmp     w10, #0x6b                      // 'k'  'movk'
    b.eq    h_movk
    add     x20, x20, #0x3
    // USE next_reg, THE WAY h_cmp ALREADY DOES. This parsed the destination
    // inline -- skip_ws, step over the register letter, read the digits -- and
    // so never saw whether the letter was 'x' or 'w'. next_reg does the same
    // work and records the width, which is what makes `mov w0, #5` encode as a
    // 32-bit MOVZ (0x52800000) instead of the 64-bit one (0xD2800000).
    bl      next_reg
    mov     w24, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    // A REGISTER OPERAND MAY BE 'w' OR 'x'. Testing only for 'x' sent every
    // w-register second operand into the immediate parser, which read no digits,
    // returned 0, and left the token behind -- `mov w0 w1` became `movz x0, #0`
    // before input rejection existed, and a hard error after it. The same
    // one-character omission appears in h_add, h_cmp and h_sub; all four are
    // fixed together because they are the same bug, not four bugs.
    cmp     w0, #0x78                       // 'x'
    b.eq    h_mov_reg
    cmp     w0, #0x77                       // 'w'
    b.eq    h_mov_reg
    bl      parse_dec                       // immediate
    // MOVZ CARRIES 16 BITS AND A 2-BIT SHIFT, AND THIS ONLY ENCODED THE LOW
    // HALFWORD. Every constant over 16 bits in this source is X<<16 -- opcode
    // words like 0xd2800000, and INBUF_SZ -- so all 29 of them silently became
    // `mov Rd, #0`. Nothing caught it: the probe substitutes #8 for an
    // immediate, so the large-value path was never exercised. The self-host
    // gate found it the first time it ran, which is what that gate is for.
    mov     w13, #0x0                       // hw = 0
    mov     w11, #0xffff
    and     w12, w0, w11
    cmp     w12, #0x0
    b.ne    hm_lo                           // low bits present -> hw 0
    cmp     w0, #0x0
    b.eq    hm_lo                           // zero -> hw 0
    lsr     w0, w0, #16
    mov     w13, #0x1                       // hw = 1, value was X<<16
hm_lo:
    lsl     w9, w0, #5
    orr     w9, w9, w13, lsl #21            // hw field
    mov     w1, #0xd2800000
    orr     w9, w9, w1
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop
h_mov_reg:
    add     x20, x20, #0x1
    bl      parse_dec                       // src n
    mov     w9, #0x3e0
    movk    w9, #0xaa00, lsl #16
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop

h_add:
    add     x20, x20, #0x3
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x78                       // 'x'
    b.eq    h_add_reg
    cmp     w0, #0x77                       // 'w'
    b.eq    h_add_reg
    bl      parse_dec
    lsl     w9, w0, #10
    mov     w1, #0x91000000
    orr     w9, w9, w1
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop
h_add_reg:
    bl      next_reg
    mov     w9, #0x8b000000
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop

h_adr:
    add     x20, x20, #0x3
    bl      next_reg
    mov     w24, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x40                       // '@'  '@'+digit = numeric pos; else label (incl. label '@')
    b.ne    ha_lab
    add     x2, x20, #0x1
    ldrb    w2, [x19, x2]
    cmp     w2, #0x30                       // '0'
    b.lt    ha_lab
    cmp     w2, #0x39                       // '9'
    b.gt    ha_lab
    add     x20, x20, #0x1                  // skip '@'
    bl      parse_dec                       // w0 = absolute target byte-position
    mov     w1, w0
    b       ha_enc
ha_lab:
    bl      sym_idx
    add     x1, x27, x0
    ldr     w1, [x1]
ha_enc:
    sub     w1, w1, w22
    // Bitmask-immediate forms (N:immr:imms) are not implemented: encoding an
    // arbitrary value into them needs rotation and run-length analysis, which
    // is real logic to put in a trust root a human has to read. Two or three
    // instructions here cost less than that, and the value stays visible.
    mov     w2, #0x3
    and     w2, w1, w2
    asr     w3, w1, #2
    mov     w13, #0xffff
    movk    w13, #0x7, lsl #16              // 0x0007ffff
    and     w3, w3, w13
    mov     w9, #0x10000000
    orr     w9, w9, w2, lsl #29
    orr     w9, w9, w3, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- cmp x<n> x<m>  or  cmp x<n> <imm> ----
h_cmp:
    add     x20, x20, #0x3
    bl      next_reg
    mov     w24, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x78                       // 'x'
    b.eq    h_cmp_reg
    cmp     w0, #0x77                       // 'w'
    b.eq    h_cmp_reg
    bl      parse_dec                       // immediate
    lsl     w9, w0, #10
    mov     w1, #0xf1000000
    orr     w9, w9, w1
    orr     w9, w9, w24, lsl #5
    mov     w1, #0x1f
    orr     w9, w9, w1
    bl      emit_dp
    b       parse_loop
h_cmp_reg:
    add     x20, x20, #0x1
    bl      parse_dec                       // m
    mov     w9, #0xeb000000
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w24, lsl #5
    mov     w0, #0x1f
    orr     w9, w9, w0
    bl      emit_dp
    b       parse_loop

// ---- 'l' : ldrb or ldr ----
h_l:
    add     x2, x20, #0x1
    ldrb    w10, [x19, x2]
    cmp     w10, #0x73                      // 's'  'lsl' / 'lsr'
    b.eq    h_lsl_or_lsr
    add     x2, x20, #0x3                   // else 'd' -> ldr / ldrb
    ldrb    w10, [x19, x2]
    cmp     w10, #0x62                      // 'b'
    b.eq    h_ldrb
    b       h_ldr
h_lsl_or_lsr:
    add     x2, x20, #0x2
    ldrb    w10, [x19, x2]
    cmp     w10, #0x72                      // 'r'
    b.eq    h_lsr
    b       h_lsl
h_ldrb:
    add     x20, x20, #0x4
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    mov     w9, #0x38600000
    movk    w9, #0x6800
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
h_ldr:
    add     x20, x20, #0x3
    bl      skip_ws                         // land on the reg-width letter (w/x)
    ldrb    w10, [x19, x20]
    mov     w9, #0xb9400000                 // 32-bit: ldr w<t>, [x<n>]
    cmp     w10, #0x78                      // 'x'
    b.ne    h_ldr_e
    mov     w9, #0xf9400000                 // 64-bit: ldr x<t>, [x<n>]
h_ldr_e:
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    orr     w9, w9, w0, lsl #5
    orr     w9, w9, w24
    b       h_ls_off

// ---- 's' : svc / sub / str / strb ----
h_s:
    add     x2, x20, #0x1
    ldrb    w10, [x19, x2]
    cmp     w10, #0x76                      // 'v'
    b.eq    h_svc
    cmp     w10, #0x75                      // 'u'
    b.eq    h_sub
    cmp     w10, #0x74                      // 't'
    b.eq    h_st
    b       die                             // 's...' that is not svc/sub/st*
h_svc:
    add     x20, x20, #0x3
    mov     w9, #0x1
    movk    w9, #0xd400, lsl #16
    bl      emit
    b       parse_loop
h_sub:
    add     x20, x20, #0x3
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x78                       // 'x'
    b.eq    h_sub_reg
    cmp     w0, #0x77                       // 'w'
    b.eq    h_sub_reg
    bl      parse_dec
    lsl     w9, w0, #10
    mov     w1, #0xd1000000
    orr     w9, w9, w1
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop
h_sub_reg:
    bl      next_reg
    mov     w9, #0xcb000000
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop
h_st:
    add     x2, x20, #0x3
    ldrb    w10, [x19, x2]
    cmp     w10, #0x62                      // 'b'
    b.eq    h_strb
    b       h_str
h_str:
    add     x20, x20, #0x3
    bl      skip_ws                         // land on the reg-width letter (w/x)
    ldrb    w10, [x19, x20]
    mov     w9, #0xb9000000                 // 32-bit: str w<t>, [x<n>]
    cmp     w10, #0x78                      // 'x'
    b.ne    h_str_e
    mov     w9, #0xf9000000                 // 64-bit: str x<t>, [x<n>]
h_str_e:
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    orr     w9, w9, w0, lsl #5
    orr     w9, w9, w24
    b       h_ls_off

// ---- optional [base, #imm] offset, shared by ldr and str ----
// imm12 sits at bits 21:10 and is SCALED by the access size: the field holds
// offset/8 for the 64-bit form and offset/4 for the 32-bit one. x17 is the
// width next_reg already recorded, and it answers exactly the right question
// here -- only Rt can be a w-register on these forms, the base is always an
// x, so nothing else can set it.
//
// opt_dec, NOT parse_dec. The cursor is sitting on the space before the digit
// and parse_dec does no whitespace skip, which is the same trap shift_imm
// documents above. A line with no third operand leaves the cursor untouched
// and w0 zero, which ORs in as offset 0 -- so the two-operand form emits
// byte-for-byte what it emitted before this existed.
//
// A register shift would read better than the branch below, but `lsr %W, %W,
// %W` is not among the operand forms this file already uses, and introducing
// one to the SOURCE is what breaks the self-host census. Two immediate shifts
// stay inside the existing set.
h_ls_off:
    bl      opt_dec
    cmp     x17, #0x0                       // 0 = x-register, 64-bit access
    b.ne    h_ls_w
    lsr     w0, w0, #3
    b       h_ls_emit
h_ls_w:
    lsr     w0, w0, #2
h_ls_emit:
    orr     w9, w9, w0, lsl #10
    bl      emit
    b       parse_loop
h_strb:
    add     x20, x20, #0x4
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    // THE INDEX REGISTER IS OPTIONAL. `strb w9 x10` is the unsigned-offset form
    // with offset zero, 0x39000000; only `strb w9 x10 x11` is the register form.
    bl      opt_reg
    cmp     w11, #0x0
    b.eq    strb_base
    mov     w9, #0x38200000
    movk    w9, #0x6800
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop
strb_base:
    mov     w9, #0x39000000                 // STRB (immediate), offset 0
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit
    b       parse_loop

// ---- 'b' : b / b.cond ----
h_branch:
    add     x2, x20, #0x1
    ldrb    w10, [x19, x2]
    cmp     w10, #0x2e                      // '.'
    b.eq    h_bcond
    cmp     w10, #0x6c                      // 'l'  'bl' or 'blr'
    b.eq    h_bl_or_blr
    cmp     w10, #0x72                      // 'r'  'br'
    b.eq    h_br
    // plain unconditional  b <L>   or   b @<pos>  (numeric output byte-position)
    add     x20, x20, #0x1
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x40                       // '@'  '@'+digit = numeric pos; else label (incl. label '@')
    b.ne    hb_lab
    add     x2, x20, #0x1
    ldrb    w2, [x19, x2]
    cmp     w2, #0x30                       // '0'
    b.lt    hb_lab
    cmp     w2, #0x39                       // '9'
    b.gt    hb_lab
    add     x20, x20, #0x1                  // skip '@'
    bl      parse_dec                       // w0 = absolute target byte-position
    mov     w1, w0
    b       hb_enc
hb_lab:
    bl      sym_idx
    add     x1, x27, x0
    ldr     w1, [x1]
hb_enc:
    sub     w1, w1, w22
    asr     w1, w1, #2
    mov     w13, #0xffff
    movk    w13, #0x3ff, lsl #16            // 0x03ffffff
    and     w1, w1, w13
    mov     w9, #0x14000000
    orr     w9, w9, w1
    bl      emit
    b       parse_loop

// ---- bl <L>  (branch-and-link; sets x30 automatically) ----
// same as 'b' but base 0x94000000; 'blr' when a 3rd char 'r' follows.
h_bl_or_blr:
    add     x2, x20, #0x2
    ldrb    w10, [x19, x2]
    cmp     w10, #0x72                      // 'r'
    b.eq    h_blr
    add     x20, x20, #0x2                  // skip "bl"
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x40                       // '@'  '@'+digit = numeric pos; else label (incl. label '@')
    b.ne    hbl_lab
    add     x2, x20, #0x1
    ldrb    w2, [x19, x2]
    cmp     w2, #0x30                       // '0'
    b.lt    hbl_lab
    cmp     w2, #0x39                       // '9'
    b.gt    hbl_lab
    add     x20, x20, #0x1                  // skip '@'
    bl      parse_dec                       // w0 = absolute target byte-position
    mov     w1, w0
    b       hbl_enc
hbl_lab:
    bl      sym_idx
    add     x1, x27, x0
    ldr     w1, [x1]
hbl_enc:
    sub     w1, w1, w22
    asr     w1, w1, #2
    mov     w13, #0xffff
    movk    w13, #0x3ff, lsl #16            // 0x03ffffff
    and     w1, w1, w13
    mov     w9, #0x94000000
    orr     w9, w9, w1
    bl      emit
    b       parse_loop

// ---- br x<n>  (branch to register) ----
h_br:
    add     x20, x20, #0x2                  // skip "br"
    bl      next_reg
    mov     w9, #0xd61f0000
    orr     w9, w9, w0, lsl #5
    bl      emit
    b       parse_loop

// ---- blr x<n>  (branch-to-register-and-link) ----
h_blr:
    add     x20, x20, #0x3                  // skip "blr"
    bl      next_reg
    mov     w9, #0xd63f0000
    orr     w9, w9, w0, lsl #5
    bl      emit
    b       parse_loop

// ---- ret  (return via x30) ----
h_ret:
    add     x20, x20, #0x3                  // skip "ret"
    mov     w9, #0x3c0
    movk    w9, #0xd65f, lsl #16
    bl      emit
    b       parse_loop

// ---- orr/and x<d> x<n> x<m>  (combine / mask instruction fields) ----
h_orr:
    add     x20, x20, #0x3                  // skip "orr"
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    mov     w9, #0xaa000000
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    // OPTIONAL SHIFT AMOUNT. `orr Rd Rn Rm 8` is 33 of the 55 lines stage0-as
    // could not yet assemble from its own source. The word was already built
    // correctly; the shift field was simply never read, so bits 15-10 stayed
    // zero and every such line came out 0x2000 short of what GNU as emits.
    bl      opt_dec
    orr     w9, w9, w0, lsl #10             // imm6, bits 15-10
    bl      emit_dp
    b       parse_loop
h_and:
    add     x20, x20, #0x3                  // skip "and"
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    mov     w9, #0x8a000000
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop

h_eor:
    add     x20, x20, #0x3                  // skip "eor"
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    mov     w9, #0xca000000
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop

// ---- lsl/lsr/asr x<d> x<n> x<m>  (variable shift by register) ----
h_lsl:
    add     x20, x20, #0x3                  // skip "lsl"
    mov     w26, #0x2000
    mov     w16, #0x1                        // kind: 0 udiv 1 lsl 2 lsr 3 asr
    b       shift_common
h_lsr:
    add     x20, x20, #0x3                  // skip "lsr"
    mov     w26, #0x2400
    mov     w16, #0x2                        // kind: 0 udiv 1 lsl 2 lsr 3 asr
    b       shift_common
h_udiv:
    add     x20, x20, #0x4                  // skip "udiv"
    mov     w26, #0x800
    mov     w16, #0x0                        // kind: 0 udiv 1 lsl 2 lsr 3 asr                     // UDIV: 0x9AC00800 | m<<16 | n<<5 | d
    b       shift_common
h_asr:
    add     x20, x20, #0x3                  // skip "asr"
    mov     w26, #0x2800
    mov     w16, #0x3                        // kind: 0 udiv 1 lsl 2 lsr 3 asr
shift_common:
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    // REGISTER OR IMMEDIATE. `lsl w9 w0 w1` is LSLV; `lsl w9 w0 5` is an alias
    // for UBFM and a different instruction family entirely. Nine lines of this
    // source use the immediate form and the handler only knew the register one.
    bl      opt_reg
    cmp     w11, #0x0
    b.eq    shift_imm
    mov     w9, #0x9ac00000
    orr     w9, w9, w26                     // 0x2000/0x2400/0x2800 selector
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop

// ---- lsl/lsr/asr w<d> w<n> <imm>  -> UBFM / SBFM ----
//   lsl Wd,Wn,#s = UBFM Wd,Wn,#((32-s)&31),#(31-s)
//   lsr Wd,Wn,#s = UBFM Wd,Wn,#s,#31
//   asr Wd,Wn,#s = SBFM Wd,Wn,#s,#31
// Only the 32-bit form is implemented, which is all this source uses. An
// x-register with an immediate shift needs a different base word (0xd3400000,
// N=1, six-bit fields against 63) so it is REJECTED rather than encoded wrong:
// a silently incorrect encoding is the one failure this assembler must not have.
shift_imm:
    cmp     x17, #0x0                       // 0 = x-register was used
    b.eq    die
    // opt_dec, NOT parse_dec. parse_dec does not skip whitespace -- every other
    // caller in this file pairs it with skip_ws first. Called bare, the cursor
    // was still on the space before the digit, so it returned 0 without
    // consuming anything: the shift encoded as 0 AND the leftover digit became
    // the next "line", which is not a recognised first character, so the
    // assembler died. That is why the probe reported REJECTED rather than
    // WRONG BYTES. opt_dec does the space-and-tab skip without crossing a
    // newline, which is what this position needs.
    bl      opt_dec                         // w0 = shift amount
    mov     w13, #0x1f                      // 31
    // COMPARE THE KIND CODE, NOT THE OPCODE BITS. w26 holds 0x2000/0x2400/
    // 0x2800 because those are the LSLV/LSRV/ASRV selector bits, and two of the
    // three cannot appear in a CMP at all: the immediate is 12 bits, optionally
    // shifted by 12, so 0x2000 encodes as 2<<12 and 0x2400 encodes as nothing.
    // Choosing a value for one purpose and then comparing against it is what
    // broke the build; w16 carries a small code that is always encodable.
    cmp     w16, #0x0                       // udiv has no immediate form
    b.eq    die
    cmp     w16, #0x1                       // lsl?
    b.ne    si_rs
    mov     w11, #0x20                      // 32
    sub     w11, w11, w0
    and     w11, w11, w13                   // immr = (32-s) & 31
    sub     w12, w13, w0                    // imms = 31 - s
    mov     w9, #0x53000000                 // UBFM, 32-bit
    b       si_emit
si_rs:
    mov     w11, w0                         // immr = s
    mov     w12, w13                        // imms = 31
    cmp     w16, #0x2                       // lsr?
    b.eq    si_u
    mov     w9, #0x13000000                 // asr -> SBFM
    b       si_emit
si_u:
    mov     w9, #0x53000000                 // lsr -> UBFM
si_emit:
    orr     w9, w9, w11, lsl #16
    orr     w9, w9, w12, lsl #10
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop

// ---- movk x<d> <imm> <shift>   shift in {0,16,32,48} ----
h_movk:
    add     x20, x20, #0x4                  // skip "movk"
    bl      next_reg                        // d
    mov     w24, w0
    bl      skip_ws
    bl      parse_dec                       // imm16
    mov     w25, w0
    bl      skip_ws
    bl      parse_dec                       // shift
    lsr     w0, w0, #4                      // hw = shift / 16
    mov     w9, #0xf2800000
    orr     w9, w9, w0, lsl #21
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop

// ---- mul x<d> x<n> x<m>  (= madd with xzr) ----
h_mul:
    add     x20, x20, #0x3                  // skip "mul"
    bl      next_reg
    mov     w24, w0
    bl      next_reg
    mov     w25, w0
    bl      next_reg
    mov     w9, #0x9b000000
    movk    w9, #0x7c00
    orr     w9, w9, w0, lsl #16
    orr     w9, w9, w25, lsl #5
    orr     w9, w9, w24
    bl      emit_dp
    b       parse_loop

h_bcond:
    add     x20, x20, #0x2
    ldrb    w2, [x19, x20]
    add     x3, x20, #0x1
    ldrb    w3, [x19, x3]
    add     x20, x20, #0x2
    // BOTH CONDITION CHARACTERS ARE CHECKED, AND THERE IS NO DEFAULT.
    // The previous version tested only the first and left w26 at 14 (AL), so
    // three different inputs assembled to three wrong answers, none of them an
    // error:  b.le -> 11 (LT),  b.gt -> 10 (GE),  b.zz -> an UNCONDITIONAL
    // branch. Nothing above stage0-as emits b.gt or b.le -- stage1-as.s0 and
    // stage2-mini-c.s1 contain none -- which is why the ladder was unaffected.
    // stage0-as's OWN source uses them eight times, so self-hosting on the old
    // code would have produced an assembler with eight inverted comparisons and
    // no diagnostic. Condition codes: EQ 0, NE 1, GE 10, LT 11, GT 12, LE 13.
    cmp     w2, #0x65                       // 'e'
    b.ne    bc_n
    cmp     w3, #0x71                       // 'q'
    b.ne    die
    mov     w26, #0x0                       // eq
    b       bc_go
bc_n:
    cmp     w2, #0x6e                       // 'n'
    b.ne    bc_l
    cmp     w3, #0x65                       // 'e'
    b.ne    die
    mov     w26, #0x1                       // ne
    b       bc_go
bc_l:
    cmp     w2, #0x6c                       // 'l'
    b.ne    bc_g
    cmp     w3, #0x74                       // 't'
    b.ne    bc_le
    mov     w26, #0xb                       // lt
    b       bc_go
bc_le:
    cmp     w3, #0x65                       // 'e'
    b.ne    die
    mov     w26, #0xd                       // le
    b       bc_go
bc_g:
    cmp     w2, #0x67                       // 'g'
    b.ne    die
    cmp     w3, #0x65                       // 'e'
    b.ne    bc_gt
    mov     w26, #0xa                       // ge
    b       bc_go
bc_gt:
    cmp     w3, #0x74                       // 't'
    b.ne    die
    mov     w26, #0xc                       // gt
bc_go:
    bl      skip_ws
    ldrb    w0, [x19, x20]
    cmp     w0, #0x40                       // '@'  '@'+digit = numeric pos; else label (incl. label '@')
    b.ne    bc_lab
    add     x2, x20, #0x1
    ldrb    w2, [x19, x2]
    cmp     w2, #0x30                       // '0'
    b.lt    bc_lab
    cmp     w2, #0x39                       // '9'
    b.gt    bc_lab
    add     x20, x20, #0x1                  // skip '@'
    bl      parse_dec                       // w0 = absolute target byte-position
    mov     w1, w0
    b       bc_enc
bc_lab:
    bl      sym_idx
    add     x1, x27, x0
    ldr     w1, [x1]
bc_enc:
    sub     w1, w1, w22
    asr     w1, w1, #2
    mov     w13, #0xffff
    movk    w13, #0x7, lsl #16              // 0x0007ffff
    and     w1, w1, w13
    mov     w9, #0x54000000
    orr     w9, w9, w1, lsl #5
    orr     w9, w9, w26
    bl      emit
    b       parse_loop

// ============================================================================
// leaf helpers
// ============================================================================
// ONE LABEL, NOT TWO AT THE SAME ADDRESS. `next_reg` and the loop head sat on
// the same byte with no instruction between them, so a disassembler had to pick
// a name: binutils 2.42 printed `bl next_reg`, 2.47 printed the other one.
// Thirty-seven call sites read back as something nobody wrote, and WHICH one
// you got depended on the tool version. For a binary that will be committed and
// audited by reading its disassembly, two names for one address is exactly the
// ambiguity the round-trip exists to catch. The loop branches back to the entry
// instruction, so the second label never carried any information.
next_reg:
    cmp     x20, x21
    b.ge    nr_done
    ldrb    w10, [x19, x20]
    cmp     w10, #0x20                      // ' '
    b.eq    nr_a
    cmp     w10, #0x9
    b.eq    nr_a
    cmp     w10, #0xa
    b.eq    nr_a
    cmp     w10, #0xd
    b.eq    nr_a
    b       nr_done
nr_a:
    add     x20, x20, #0x1
    b       next_reg
nr_done:
    // READ THE LETTER BEFORE SKIPPING IT. This routine already consumed the
    // 'x' or 'w' without looking at it, which is why every data-processing
    // form encoded as 64-bit regardless: `cmp w0, #65` emitted the X-form
    // SUBS (0xF1...) where GNU as emits the W-form (0x71...). Measured across
    // the whole source, 131 lines differed from GNU as by exactly bit 31.
    ldrb    w10, [x19, x20]
    cmp     w10, #0x77                      // 'w'
    b.ne    nr_x
    mov     x17, #0x1
nr_x:
    add     x20, x20, #0x1                  // skip reg letter
    mov     w0, #0x0
nr_dl:
    cmp     x20, x21
    b.ge    nr_r
    ldrb    w10, [x19, x20]
    cmp     w10, #0x30                      // '0'
    b.lt    nr_r
    cmp     w10, #0x39                      // '9'
    b.gt    nr_r
    sub     w10, w10, #0x30                 // '0'
    mov     w11, #0xa
    mul     w0, w0, w11
    add     w0, w0, w10
    add     x20, x20, #0x1
    b       nr_dl
nr_r:
    ret

// ---- optional trailing decimal operand, THIS LINE ONLY ----
// Returns w0 = the value, or 0 with the cursor untouched if the line ends
// first.
//
// It must not call skip_ws. skip_ws treats a newline as whitespace -- that is
// how parse_loop advances from one line to the next -- so using it to look for
// an optional operand would step onto the FOLLOWING line and, if that line
// happened to begin with a digit, silently consume it as this instruction's
// shift amount. Spaces and tabs only, and the cursor is restored when nothing
// is found.
//
// x12 is used to save the cursor because it is referenced nowhere else in this
// file; parse_dec clobbers w0, w10 and w11 and leaves w9 alone, so the caller
// can finish building its word afterwards.
// ---- two-character label -> symbol-table byte offset ----
// Reads two characters at the cursor and returns w0 = (c1-0x21)*94 + (c2-0x21),
// scaled by 4. The cursor is left just past the pair.
//
// WHY TWO. A one-character label indexes a 128-entry table directly, of which
// only about 90 are printable and usable -- and this source now defines 102
// labels, so it no longer fits its own assembler. A pair over the printable
// range gives 94*94 = 8836 slots for a 35 KB .bss table, and .bss is
// demand-zero so an unused reserve costs nothing. The ceiling stops being
// something a future change can walk into.
sym_idx:
    ldrb    w0, [x19, x20]
    add     x20, x20, #0x1
    ldrb    w10, [x19, x20]
    add     x20, x20, #0x1
    sub     w0, w0, #0x21
    sub     w10, w10, #0x21
    mov     w11, #0x5e                      // 94 printable columns
    mul     w0, w0, w11
    add     w0, w0, w10
    lsl     w0, w0, #2                      // 4 bytes per entry
    ret

// ---- optional register operand, THIS LINE ONLY ----
// Returns w0 = register number and w11 = 1 when one is present, or w11 = 0 with
// the cursor untouched when the line ends first. Same newline rule as opt_dec:
// next_reg calls skip_ws, which treats \n as whitespace, so asking it for an
// operand that may not be there walks onto the next line and reads its mnemonic
// as a register. That is why `strb w9, [x10]` was rejected rather than encoded.
opt_reg:
    mov     x14, x30                        // next_reg needs the link register
    mov     x15, x20
or_ws:
    cmp     x20, x21
    b.ge    or_none
    ldrb    w10, [x19, x20]
    cmp     w10, #0x20                      // ' '
    b.eq    or_adv
    cmp     w10, #0x9                       // tab
    b.eq    or_adv
    b       or_chk
or_adv:
    add     x20, x20, #0x1
    b       or_ws
or_chk:
    cmp     w10, #0x77                      // 'w'
    b.eq    or_yes
    cmp     w10, #0x78                      // 'x'
    b.ne    or_none
or_yes:
    bl      next_reg
    mov     w11, #0x1
    mov     x30, x14
    ret
or_none:
    mov     x20, x15                        // nothing there; cursor back
    mov     w0, #0x0
    mov     w11, #0x0
    mov     x30, x14
    ret

opt_dec:
    mov     x12, x20                        // remember the cursor
od_ws:
    cmp     x20, x21
    b.ge    od_none
    ldrb    w10, [x19, x20]
    cmp     w10, #0x20                      // ' '
    b.eq    od_adv
    cmp     w10, #0x9                       // tab
    b.eq    od_adv
    b       od_chk
od_adv:
    add     x20, x20, #0x1
    b       od_ws
od_chk:
    cmp     w10, #0x30                      // '0'
    b.lt    od_none
    cmp     w10, #0x39                      // '9'
    b.gt    od_none
    b       parse_dec                       // tail call: its ret returns to us
od_none:
    mov     x20, x12                        // nothing there; put the cursor back
    mov     w0, #0x0
    ret

skip_ws:
    cmp     x20, x21
    b.ge    sw_r
    ldrb    w10, [x19, x20]
    cmp     w10, #0x20                      // ' '
    b.eq    sw_a
    cmp     w10, #0x9
    b.eq    sw_a
    cmp     w10, #0xa
    b.eq    sw_a
    cmp     w10, #0xd
    b.eq    sw_a
    b       sw_r
sw_a:
    add     x20, x20, #0x1
    b       skip_ws
sw_r:
    ret

parse_dec:
    mov     w0, #0x0
pd_l:
    cmp     x20, x21
    b.ge    pd_r
    ldrb    w10, [x19, x20]
    cmp     w10, #0x30                      // '0'
    b.lt    pd_r
    cmp     w10, #0x39                      // '9'
    b.gt    pd_r
    sub     w10, w10, #0x30                 // '0'
    mov     w11, #0xa
    mul     w0, w0, w11
    add     w0, w0, w10
    add     x20, x20, #0x1
    b       pd_l
pd_r:
    ret

// ---- emit_dp: emit a DATA-PROCESSING word, honouring the register width ---
// Bit 31 is the sf flag for data-processing instructions, so a w-register
// operand means it must be cleared. It is NOT a width flag everywhere: loads
// and stores put a size field in bits 31:30, and `ldr w<t>` is 0xB9400000 --
// clearing bit 31 there would silently turn it into `ldrb`. So this is OPT-IN.
// Only handlers whose opcode genuinely carries sf call it; everything else
// still calls `emit` directly. A handler wrongly left on `emit` shows up as a
// WRONG row in stage0-selfhost's probe table, which is visible and harmless;
// a load wrongly routed through here would be neither.
emit_dp:
    cmp     x17, #0x0
    b.eq    emit
    mov     x13, #0xffff
    movk    x13, #0x7fff, lsl #16
    and     x9, x9, x13
emit:
    cmp     x23, #0x2
    b.ne    e_adv
    adr     x10, outword
    str     w9, [x10]
    mov     x0, #0x1
    mov     x1, x10
    mov     x2, #0x4
    mov     x8, #0x40
    svc     #0x0
e_adv:
    add     x22, x22, #0x4
    ret

emit_byte:
    cmp     x23, #0x2
    b.ne    eb_adv
    adr     x10, outword
    strb    w9, [x10]
    mov     x0, #0x1
    mov     x1, x10
    mov     x2, #0x1
    mov     x8, #0x40
    svc     #0x0
eb_adv:
    add     x22, x22, #0x1
    ret

// STRINGS LIVE IN .rodata, NOT .text. While they sat in .text a disassembler
// decoded them as instructions, which cost three phantom labels and a padding
// word -- the "LINE COUNT DIFFERS by 4" that stopped the round-trip diff from
// being total, and the reason check A could only compare a prefix of the
// section rather than all of it. .text holding only code is also what
// AGENTS.md's round-trip rule implies: every byte of it should decode back to
// a source line.
    .section .rodata
    .balign 8
inover:  .ascii  "stage0-as: input exceeds INBUF_SZ\n"
rejmsg:  .ascii  "stage0-as: rejected: "
rejnl:   .ascii  "\n"

    .bss
    .align  4
    // ORDER MATTERS: adr reaches +-1 MiB, so every adr-referenced symbol must sit
    // NEAR the start of .bss. INBUF_SZ is a 64 MiB demand-zero reserve, so it goes
    // LAST -- anything after it would be unreachable by adr. (Adding a symbol below
    // inbuf will fail to link; lint_asm.py checks for this.)
// A NAME NOBODY REFERENCES, SO THAT symtab IS UNAMBIGUOUS. `__bss_start` is
// generated by the linker at the start of .bss, so whatever comes first there
// shares an address with it and a disassembler must choose a name for that
// byte: binutils 2.47 prints `adr x27, __bss_start`, llvm-objdump prints
// `adr x27, symtab`. Both are right and they are the ONLY thing the two
// decoders disagree about across all 696 instructions. Giving __bss_start its
// own unreferenced symbol to collide with leaves every name the source uses
// unique, and costs 16 bytes of demand-zero .bss -- nothing at runtime.
// Realigned afterwards so symtab keeps the 16-byte alignment it had.
bss_origin: .space 16
    .align  4
symtab:  .space 35344                   // 94*94 entries * 4 bytes
outword: .space 4
inbuf:   .space INBUF_SZ
