
# pico-c-assembler (stage 2, layer 1): TWO-PASS NUMERIC LABEL RESOLVER.  Retires the single-char pool.
# Reads stdin (asm with multi-char labels); writes stdout: label-free stage-0-as
# assembly with every branch/adr reference rewritten to a numeric @<pos> and every
# ':label' definition dropped. stage-0-as then assembles the numeric output. Label
# count is bounded only by memory (no pool, no 128-symtab cap for pico-c / micro-c code).
# regs: x19 inbuf x20 inpos x21 inlen x22 outbuf x23 outpos
#       x24 nametbl x25 nametbl_wpos x26 namecount x27 postbl x28 pos-accumulator
# Arena: one 256 MB anonymous mmap. MAP_ANONYMOUS is lazily paged, so this
# reserves ADDRESS SPACE, not memory -- an unused reserve costs nothing. Same
# call the emitted calloc runtime already uses (m51); brk is deliberately NOT
# used here because qemu-user's brk region is small.
mov x0 0
mov x1 0
movk x1 4096 16
mov x2 3
mov x3 34
mov x4 0
sub x4 x4 1
mov x5 0
mov x8 222
svc
mov x19 x0
# x18 = number of names pass 2 could not resolve. Each one is reported to stderr
# as it is found, so a SINGLE run lists every missing name, and x18 is checked
# once at p2done. Before this, findlabel returned position 0 for an unknown name
# and stage 1 exited 0 -- so a missing label silently became '@000000000' and the
# pipeline built a program that read address zero. Counting rather than exiting
# on the first one is deliberate: the list is the diagnostic.
mov x18 0
# Read the whole input -- two passes means it MUST be buffered. The bound is the
# arena, and exhausting it is a LOUD failure rather than a silent truncation.
mov x21 0
:A
mov x2 0
movk x2 512 16
sub x2 x2 x21
cmp x2 1
b.lt B
mov x0 0
add x1 x19 x21
mov x8 63
svc
cmp x0 1
b.lt C
add x21 x21 x0
b A
:B
mov x0 2
adr x1 8
mov x2 38
mov x8 64
svc
mov x0 2
mov x8 93
svc
:C
# Region bases DERIVED from the actual input length N (x21) -- no fixed offsets.
# N_r = max(roundup(N,4096), 64K); outbuf gets 4*N_r, nametbl N_r, postbl N_r.
add x1 x21 4095
mov x2 12
lsr x1 x1 x2
lsl x1 x1 x2
mov x2 0
movk x2 1 16
cmp x1 x2
b.ge D
mov x1 x2
:D
add x22 x19 x1
mov x2 2
lsl x3 x1 x2
add x24 x22 x3
add x27 x24 x1
# ===== PASS 1: compute positions, record label definitions =====
mov x20 0
mov x28 0
mov x25 0
mov x26 0
:E
cmp x20 x21
b.ge K
bl Z
cmp x20 x21
b.ge K
ldrb w0 x19 x20
cmp w0 10
b.eq F
cmp w0 35
b.eq G
cmp w0 58
b.eq H
cmp w0 46
b.eq I
add x28 x28 4
bl c
b E
:F
add x20 x20 1
b E
:G
bl c
b E
:H
add x20 x20 1
bl j
bl c
b E
:I
add x2 x20 1
ldrb w1 x19 x2
cmp w1 98
b.eq J
bl z
add x28 x28 x0
bl c
b E
:J
add x28 x28 1
bl c
b E
:K
# ===== PASS 2: emit resolved output =====
mov x20 0
mov x23 0
:L
cmp x20 x21
b.ge X
bl Z
cmp x20 x21
b.ge X
ldrb w0 x19 x20
cmp w0 10
b.eq M
cmp w0 58
b.eq N
cmp w0 35
b.eq W
cmp w0 97
b.eq O
cmp w0 98
b.eq P
b W
:M
add x20 x20 1
b L
:N
bl c
b L
:O
add x2 x20 1
ldrb w1 x19 x2
cmp w1 100
b.ne W
add x3 x20 2
ldrb w2 x19 x3
cmp w2 114
b.eq S
b W
:P
add x2 x20 1
ldrb w1 x19 x2
cmp w1 32
b.eq R
cmp w1 46
b.eq R
cmp w1 108
b.eq Q
b W
:Q
add x3 x20 2
ldrb w2 x19 x3
cmp w2 114
b.eq W
b R
:R
bl e
mov w0 32
strb w0 x22 x23
add x23 x23 1
bl Z
b T
:S
bl e
mov w0 32
strb w0 x22 x23
add x23 x23 1
bl Z
bl e
mov w0 32
strb w0 x22 x23
add x23 x23 1
bl Z
:T
ldrb w0 x19 x20
cmp w0 64
b.eq V
cmp w0 48
b.lt U
cmp w0 58
b.lt V
:U
bl m
mov w1 64
strb w1 x22 x23
add x23 x23 1
bl 4
bl i
b L
:V
bl e
bl i
b L
:W
bl g
b L
:X
# An unresolved name means the output is wrong, so do not write it. Emitting it
# with a non-zero exit would still feed a '|' pipeline; staying silent on stdout
# makes self-assembler fail too, which is the behaviour we want.
cmp x18 0
b.ne Y
mov x0 1
mov x1 x22
mov x2 x23
mov x8 64
svc
mov x0 0
mov x8 93
svc
:Y
mov x0 2
adr x1 $
mov x2 60
mov x8 64
svc
mov x0 3
mov x8 93
svc
# ---- sksp: skip spaces/tabs in input ----
:Z
cmp x20 x21
b.ge b
ldrb w10 x19 x20
cmp w10 32
b.eq a
cmp w10 9
b.eq a
b b
:a
add x20 x20 1
b Z
:b
ret
# ---- skipnl: advance input past next newline ----
:c
cmp x20 x21
b.ge d
ldrb w0 x19 x20
add x20 x20 1
cmp w0 10
b.ne c
:d
ret
# ---- cptok: copy a token (until space/tab/newline) input->output ----
:e
cmp x20 x21
b.ge f
ldrb w0 x19 x20
cmp w0 32
b.eq f
cmp w0 9
b.eq f
cmp w0 10
b.eq f
strb w0 x22 x23
add x23 x23 1
add x20 x20 1
b e
:f
ret
# ---- cpline: copy until newline inclusive input->output ----
:g
cmp x20 x21
b.ge h
ldrb w0 x19 x20
strb w0 x22 x23
add x23 x23 1
add x20 x20 1
cmp w0 10
b.eq h
b g
:h
ret
# ---- emitnl: emit newline to output, skip rest of input line ----
# NOTE: does an internal 'bl', so it must save/restore x30 (else 'ret' loops).
:i
mov x17 x30
mov w0 10
strb w0 x22 x23
add x23 x23 1
bl c
mov x30 x17
ret
# ---- addlabel: pass1 - append name at x20 to nametbl, postbl[count]=x28, count++ ----
:j
mov x6 x20
:k
cmp x6 x21
b.ge l
ldrb w4 x19 x6
cmp w4 32
b.eq l
cmp w4 9
b.eq l
cmp w4 10
b.eq l
strb w4 x24 x25
add x25 x25 1
add x6 x6 1
b k
:l
mov w4 0
strb w4 x24 x25
add x25 x25 1
mov x8 2
lsl x7 x26 x8
add x9 x27 x7
str w28 x9
add x26 x26 1
ret
# ---- findlabel: pass2 - name at x20 -> w0=position; advance x20 past name ----
:m
mov x11 0
mov x12 0
:n
cmp x11 x26
b.ge u
mov x6 x20
mov x7 x12
:o
ldrb w4 x24 x7
mov w8 0
cmp x6 x21
b.ge p
ldrb w5 x19 x6
cmp w5 32
b.eq p
cmp w5 9
b.eq p
cmp w5 10
b.eq p
b q
:p
mov w8 1
:q
cmp w4 0
b.eq r
cmp w8 1
b.eq s
cmp x4 x5
b.ne s
add x6 x6 1
add x7 x7 1
b o
:r
cmp w8 1
b.eq t
:s
ldrb w4 x24 x12
add x12 x12 1
cmp w4 0
b.ne s
add x11 x11 1
b n
:t
mov x8 2
lsl x7 x11 x8
add x9 x27 x7
ldr w0 x9
mov x20 x6
ret
:u
# Name at x20 matched nothing in the table. Report it, count it, and carry on so
# one run prints the whole list. x6 is NOT reusable here: it holds however far
# the last candidate matched, and is untouched when the table is empty -- so
# rescan from x20 to find the real end of the name and advance x20 to it.
# No 'bl' below, so x30 survives and the 'ret' is still the caller's.
mov x0 2
adr x1 9
mov x2 36
mov x8 64
svc
mov x6 x20
:v
cmp x6 x21
b.ge y
ldrb w4 x19 x6
cmp w4 32
b.eq y
cmp w4 9
b.eq y
cmp w4 10
b.eq y
add x6 x6 1
b v
:y
mov x0 2
add x1 x19 x20
sub x2 x6 x20
mov x8 64
svc
mov x0 2
adr x1 _
mov x2 1
mov x8 64
svc
add x18 x18 1
mov x0 0
mov x20 x6
ret
# ---- asciilen: w0 = decoded byte length of the .ascii string on this line ----
:z
mov x6 x20
:0
cmp x6 x21
b.ge 3
ldrb w4 x19 x6
add x6 x6 1
cmp w4 34
b.ne 0
mov x0 0
:1
cmp x6 x21
b.ge 3
ldrb w4 x19 x6
cmp w4 34
b.eq 3
cmp w4 92
b.ne 2
add x6 x6 1
:2
add x0 x0 1
add x6 x6 1
b 1
:3
ret
# ---- emitpos: emit x0 as 9-digit decimal to output tail ----
:4
mov x2 9
add x4 x23 9
:5
mov x5 0
:6
cmp x0 10
b.lt 7
sub x0 x0 10
add x5 x5 1
b 6
:7
add x0 x0 48
sub x4 x4 1
strb w0 x22 x4
mov x0 x5
sub x2 x2 1
cmp x2 0
b.ne 5
add x23 x23 9
ret
:8
.ascii "pico-c-assembler: input exceeds arena\n"
:9
.ascii "pico-c-assembler: unresolved label: "
:_
.ascii "\n"
:$
.ascii "pico-c-assembler: unresolved labels above; refusing to emit\n"
.byte 0

