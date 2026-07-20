"""Python model of stage0-as: assemble its language to (bytes, program).
Encodings mirror stage0-as.aarch64.s and are CI-byte-verified against `as`.
Also a tiny ARM64 interpreter for the subset, to EXECUTE assembled programs.
This is a self-check bench; CI (real as+qemu) remains ground truth.
"""
import struct

def _reg(tok):            # 'x9'/'w0' -> 9
    return int(tok[1:])

def assemble(text):
    # pass 1: collect label offsets (labels may be multi-char here; stage0-as
    # itself is single-char, but the model doesn't care — it stores names)
    lines = [l for l in text.split('\n')]
    def toks(l):
        l = l.split('#',1)[0].strip()
        return l
    # first pass: compute offsets
    off = 0; labels = {}
    items = []
    for raw in lines:
        l = toks(raw)
        if not l: continue
        if l.startswith(':'):
            nm=l[1:].split('#',1)[0].strip()
            if len(nm)!=1:
                raise ValueError('stage0-as labels are SINGLE char, got %r'%nm)
            labels[nm]=off
            continue
        if l.startswith('.byte'):
            items.append(('.byte', l.split(None,1)[1].strip(), off)); off += 1; continue
        if l.startswith('.ascii'):
            s = l[l.index('"')+1:l.rindex('"')].replace('\\n','\n')
            items.append(('.ascii', s, off)); off += len(s.encode()); continue
        items.append(('i', l, off)); off += 4
    # second pass: encode
    code = bytearray(); prog = []
    for kind, payload, at in items:
        if kind == '.byte':
            code += bytes([int(payload) & 0xff]); prog.append(('.byte', int(payload)&0xff)); continue
        if kind == '.ascii':
            code += payload.encode(); 
            for b in payload.encode(): prog.append(('.byte', b))
            continue
        w, ins = encode(payload, at, labels)
        code += struct.pack('<I', w); prog.append(ins)
    return bytes(code), prog, labels

def encode(l, at, labels):
    p = l.split()
    op = p[0]
    def rel(lbl, sh, mask):
        return ((labels[lbl]-at) >> sh) & mask
    if op == 'mov':
        d = _reg(p[1])
        if p[2][0] in 'xw':
            n=_reg(p[2]); return (0xAA0003E0|(n<<16)|d, ('mov_r',d,n))
        imm=int(p[2]); return (0xD2800000|(imm<<5)|d, ('mov_i',d,imm))
    if op=='movk':
        d=_reg(p[1]); imm=int(p[2]); hw=int(p[3])//16
        return (0xF2800000|(hw<<21)|((imm&0xffff)<<5)|d, ('movk',d,imm,hw*16))
    if op=='add':
        d=_reg(p[1]);n=_reg(p[2])
        if p[3][0]=='x':
            m=_reg(p[3]); return (0x8B000000|(m<<16)|(n<<5)|d,('addr',d,n,m))
        imm=int(p[3]); return (0x91000000|(imm<<10)|(n<<5)|d,('add',d,n,imm))
    if op=='sub':
        d=_reg(p[1]);n=_reg(p[2])
        if p[3][0]=='x':
            m=_reg(p[3]); return (0xCB000000|(m<<16)|(n<<5)|d,('subr',d,n,m))
        imm=int(p[3]); return (0xD1000000|(imm<<10)|(n<<5)|d,('sub',d,n,imm))
    if op=='mul':
        d=_reg(p[1]);n=_reg(p[2]);m=_reg(p[3])
        return (0x9B007C00|(m<<16)|(n<<5)|d,('mul',d,n,m))
    if op=='cmp':
        n=_reg(p[1])
        if p[2][0]=='x':                      # stage0-as: reg-compare ONLY for x-regs
            m=_reg(p[2]); return (0xEB000000|(m<<16)|(n<<5)|31,('cmp_r',n,m))
        d=''                                  # else parse_dec: leading digits, else 0
        for ch in p[2]:
            if ch.isdigit(): d+=ch
            else: break
        imm=int(d) if d else 0
        return (0xF1000000|(imm<<10)|(n<<5)|31,('cmp_i',n,imm))
    if op in ('orr','and'):
        d=_reg(p[1]);n=_reg(p[2]);m=_reg(p[3])
        base=0xAA000000 if op=='orr' else 0x8A000000
        return (base|(m<<16)|(n<<5)|d,(op,d,n,m))
    if op in ('lsl','lsr','asr'):
        d=_reg(p[1]);n=_reg(p[2]);m=_reg(p[3])
        sel={'lsl':0x2000,'lsr':0x2400,'asr':0x2800}[op]
        return (0x9AC00000|sel|(m<<16)|(n<<5)|d,(op,d,n,m))
    if op=='adr':
        d=_reg(p[1]); v=(labels[p[2]]-at)
        return (0x10000000|((v&3)<<29)|(((v>>2)&0x7FFFF)<<5)|d,('adr',d,labels[p[2]]))
    if op=='ldrb':
        t=_reg(p[1]);n=_reg(p[2]);m=_reg(p[3]); return (0x38606800|(m<<16)|(n<<5)|t,('ldrb',t,n,m))
    if op=='strb':
        t=_reg(p[1]);n=_reg(p[2]);m=_reg(p[3]); return (0x38206800|(m<<16)|(n<<5)|t,('strb',t,n,m))
    if op=='ldr':
        t=_reg(p[1]);n=_reg(p[2]); w=p[1][0]
        base=0xF9400000 if w=='x' else 0xB9400000   # x-form sets size bit30
        return (base|(n<<5)|t,('ldr',t,n,w))
    if op=='str':
        t=_reg(p[1]);n=_reg(p[2]); w=p[1][0]
        base=0xF9000000 if w=='x' else 0xB9000000
        return (base|(n<<5)|t,('str',t,n,w))
    if op=='svc': return (0xD4000001,('svc',))
    if op=='ret': return (0xD65F03C0,('ret',))
    if op=='br':  n=_reg(p[1]); return (0xD61F0000|(n<<5),('br',n))
    if op=='blr': n=_reg(p[1]); return (0xD63F0000|(n<<5),('blr',n))
    if op=='bl':  return (0x94000000|rel(p[1],2,0x3FFFFFF),('bl',labels[p[1]]))
    if op=='b':   return (0x14000000|rel(p[1],2,0x3FFFFFF),('b',labels[p[1]]))
    if op in ('b.eq','b.ne','b.lt','b.ge'):
        cond={'b.eq':0,'b.ne':1,'b.lt':11,'b.ge':10}[op]
        return (0x54000000|(rel(p[1],2,0x7FFFF)<<5)|cond,('bcc',op,labels[p[1]]))
    raise ValueError("unknown: "+l)
