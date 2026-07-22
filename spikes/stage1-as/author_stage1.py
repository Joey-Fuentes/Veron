#!/usr/bin/env python3
# Author the new stage-1 (two-pass numeric label resolver) with READABLE labels,
# then map each label to a distinct single character (stage-0-as symtab is per-byte,
# so stage-1's own labels must be single-char). Emits the final stage1-as.s0.
import re, sys

SRC = r"""
# stage1 (macro-as): TWO-PASS NUMERIC LABEL RESOLVER.  Retires the single-char pool.
# Reads stdin (asm with multi-char labels); writes stdout: label-free stage-0-as
# assembly with every branch/adr reference rewritten to a numeric @<pos> and every
# ':label' definition dropped. stage-0-as then assembles the numeric output. Label
# count is bounded only by memory (no pool, no 128-symtab cap for stage-2/3 code).
# regs: x19 inbuf x20 inpos x21 inlen x22 outbuf x23 outpos
#       x24 nametbl x25 nametbl_wpos x26 namecount x27 postbl x28 pos-accumulator
mov x0 0
mov x8 214
svc
mov x19 x0
mov x1 0
movk x1 4 16
add x22 x19 x1
mov x1 0
movk x1 8 16
add x24 x19 x1
mov x1 0
movk x1 9 16
add x27 x19 x1
mov x1 32768
movk x1 9 16
add x0 x19 x1
mov x8 214
svc
mov x21 0
:rdloop
mov x2 0
movk x2 4 16
sub x2 x2 x21
cmp x2 1
b.lt rddone
mov x0 0
add x1 x19 x21
mov x8 63
svc
cmp x0 1
b.lt rddone
add x21 x21 x0
b rdloop
:rddone
# ===== PASS 1: compute positions, record label definitions =====
mov x20 0
mov x28 0
mov x25 0
mov x26 0
:p1
cmp x20 x21
b.ge p1done
bl sksp
cmp x20 x21
b.ge p1done
ldrb w0 x19 x20
cmp w0 10
b.eq p1nl
cmp w0 35
b.eq p1skip
cmp w0 58
b.eq p1label
cmp w0 46
b.eq p1dir
add x28 x28 4
bl skipnl
b p1
:p1nl
add x20 x20 1
b p1
:p1skip
bl skipnl
b p1
:p1label
add x20 x20 1
bl addlabel
bl skipnl
b p1
:p1dir
add x2 x20 1
ldrb w1 x19 x2
cmp w1 98
b.eq p1byte
bl asciilen
add x28 x28 x0
bl skipnl
b p1
:p1byte
add x28 x28 1
bl skipnl
b p1
:p1done
# ===== PASS 2: emit resolved output =====
mov x20 0
mov x23 0
:p2
cmp x20 x21
b.ge p2done
bl sksp
cmp x20 x21
b.ge p2done
ldrb w0 x19 x20
cmp w0 10
b.eq p2nl
cmp w0 58
b.eq p2drop
cmp w0 35
b.eq p2copy
cmp w0 97
b.eq p2a
cmp w0 98
b.eq p2b
b p2copy
:p2nl
add x20 x20 1
b p2
:p2drop
bl skipnl
b p2
:p2a
add x2 x20 1
ldrb w1 x19 x2
cmp w1 100
b.ne p2copy
add x3 x20 2
ldrb w2 x19 x3
cmp w2 114
b.eq p2adr
b p2copy
:p2b
add x2 x20 1
ldrb w1 x19 x2
cmp w1 32
b.eq p2ref
cmp w1 46
b.eq p2ref
cmp w1 108
b.eq p2bl
b p2copy
:p2bl
add x3 x20 2
ldrb w2 x19 x3
cmp w2 114
b.eq p2copy
b p2ref
:p2ref
bl cptok
mov w0 32
strb w0 x22 x23
add x23 x23 1
bl sksp
b p2reflab
:p2adr
bl cptok
mov w0 32
strb w0 x22 x23
add x23 x23 1
bl sksp
bl cptok
mov w0 32
strb w0 x22 x23
add x23 x23 1
bl sksp
:p2reflab
ldrb w0 x19 x20
cmp w0 64
b.eq p2asis
cmp w0 48
b.lt p2resolve
cmp w0 58
b.lt p2asis
:p2resolve
bl findlabel
mov w1 64
strb w1 x22 x23
add x23 x23 1
bl emitpos
bl emitnl
b p2
:p2asis
bl cptok
bl emitnl
b p2
:p2copy
bl cpline
b p2
:p2done
mov x0 1
mov x1 x22
mov x2 x23
mov x8 64
svc
mov x0 0
mov x8 93
svc
# ---- sksp: skip spaces/tabs in input ----
:sksp
cmp x20 x21
b.ge skspx
ldrb w10 x19 x20
cmp w10 32
b.eq skspa
cmp w10 9
b.eq skspa
b skspx
:skspa
add x20 x20 1
b sksp
:skspx
ret
# ---- skipnl: advance input past next newline ----
:skipnl
cmp x20 x21
b.ge skipnlx
ldrb w0 x19 x20
add x20 x20 1
cmp w0 10
b.ne skipnl
:skipnlx
ret
# ---- cptok: copy a token (until space/tab/newline) input->output ----
:cptok
cmp x20 x21
b.ge cptokx
ldrb w0 x19 x20
cmp w0 32
b.eq cptokx
cmp w0 9
b.eq cptokx
cmp w0 10
b.eq cptokx
strb w0 x22 x23
add x23 x23 1
add x20 x20 1
b cptok
:cptokx
ret
# ---- cpline: copy until newline inclusive input->output ----
:cpline
cmp x20 x21
b.ge cplinex
ldrb w0 x19 x20
strb w0 x22 x23
add x23 x23 1
add x20 x20 1
cmp w0 10
b.eq cplinex
b cpline
:cplinex
ret
# ---- emitnl: emit newline to output, skip rest of input line ----
# NOTE: does an internal 'bl', so it must save/restore x30 (else 'ret' loops).
:emitnl
mov x17 x30
mov w0 10
strb w0 x22 x23
add x23 x23 1
bl skipnl
mov x30 x17
ret
# ---- addlabel: pass1 - append name at x20 to nametbl, postbl[count]=x28, count++ ----
:addlabel
mov x6 x20
:addla
cmp x6 x21
b.ge addlb
ldrb w4 x19 x6
cmp w4 32
b.eq addlb
cmp w4 9
b.eq addlb
cmp w4 10
b.eq addlb
strb w4 x24 x25
add x25 x25 1
add x6 x6 1
b addla
:addlb
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
:findlabel
mov x11 0
mov x12 0
:finda
cmp x11 x26
b.ge findfail
mov x6 x20
mov x7 x12
:findb
ldrb w4 x24 x7
mov w8 0
cmp x6 x21
b.ge finddelim
ldrb w5 x19 x6
cmp w5 32
b.eq finddelim
cmp w5 9
b.eq finddelim
cmp w5 10
b.eq finddelim
b findcmp
:finddelim
mov w8 1
:findcmp
cmp w4 0
b.eq findsend
cmp w8 1
b.eq findnext
cmp x4 x5
b.ne findnext
add x6 x6 1
add x7 x7 1
b findb
:findsend
cmp w8 1
b.eq findhit
:findnext
ldrb w4 x24 x12
add x12 x12 1
cmp w4 0
b.ne findnext
add x11 x11 1
b finda
:findhit
mov x8 2
lsl x7 x11 x8
add x9 x27 x7
ldr w0 x9
mov x20 x6
ret
:findfail
mov x0 0
mov x20 x6
ret
# ---- asciilen: w0 = decoded byte length of the .ascii string on this line ----
:asciilen
mov x6 x20
:alenq
cmp x6 x21
b.ge alenx
ldrb w4 x19 x6
add x6 x6 1
cmp w4 34
b.ne alenq
mov x0 0
:alenc
cmp x6 x21
b.ge alenx
ldrb w4 x19 x6
cmp w4 34
b.eq alenx
cmp w4 92
b.ne alenn
add x6 x6 1
:alenn
add x0 x0 1
add x6 x6 1
b alenc
:alenx
ret
# ---- emitpos: emit x0 as 6-digit decimal to output tail ----
:emitpos
mov x2 6
add x4 x23 6
:emitposa
mov x5 0
:emitposb
cmp x0 10
b.lt emitposc
sub x0 x0 10
add x5 x5 1
b emitposb
:emitposc
add x0 x0 48
sub x4 x4 1
strb w0 x22 x4
mov x0 x5
sub x2 x2 1
cmp x2 0
b.ne emitposa
add x23 x23 6
ret
"""

# --- map readable labels to distinct single chars (avoid lowercase w/x, ':' , '#') ---
defs = re.findall(r'^:(\w+)', SRC, re.M)
seen=[]
for d in defs:
    if d not in seen: seen.append(d)
# candidate single-char label bytes: A-Z, a-z (minus w,x), 0-9, safe punct
cands = [chr(c) for c in range(ord('A'),ord('Z')+1)]
cands += [chr(c) for c in range(ord('a'),ord('z')+1) if chr(c) not in 'wx']
cands += [chr(c) for c in range(ord('0'),ord('9')+1)]
cands += list("_$?!%^&~|=<>+()*-./;[]{}")
assert len(seen) <= len(cands), f"need {len(seen)} labels, have {len(cands)}"
m = {name: cands[i] for i,name in enumerate(seen)}

out=[]
for line in SRC.split('\n'):
    st=line.strip()
    if st.startswith('#') or st=='':
        out.append(line); continue
    if st.startswith(':'):
        nm=st[1:]
        out.append(':'+m[nm]); continue
    toks=st.split()
    # rewrite branch/adr label operands (last token) if it's a known label
    if toks[0] in ('b','bl','b.eq','b.ne','b.lt','b.ge','b.gt','b.le','adr') and toks[-1] in m:
        toks[-1]=m[toks[-1]]
        out.append(' '.join(toks)); continue
    out.append(line)
open('spikes/stage1-as/stage1-as.s0','w').write('\n'.join(out)+'\n')
print(f"wrote stage1-as.s0 with {len(seen)} labels mapped to single chars")
print("label map (readable -> char):")
for k,v in m.items(): print(f"   {k:10} -> {v!r}")
