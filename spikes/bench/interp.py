import struct
from s0as import assemble

def run(prog, stdin=b'', mem_size=0x40000, trace=False):
    # layout: build byte image + offset->index map
    img = bytearray(mem_size); off=0; idx_at={}
    seq=[]
    for ins in prog:
        idx_at[off]=len(seq); seq.append((off,ins))
        if ins[0]=='.byte': img[off]=ins[1]; off+=1
        else: off+=4
    code_end=off
    brk=[code_end]
    R=[0]*31   # x0..x30
    def M(a): return a  # identity address space (base 0)
    pc=0; out=bytearray(); inbuf=bytearray(stdin); steps=0
    # find instruction index for a byte offset
    def idx(o):
        return idx_at[o]
    i=idx(0)
    while 0<=i<len(seq):
        steps+=1
        if steps>5_000_000: raise RuntimeError("runaway")
        o,ins=seq[i]; op=ins[0]
        nxt=i+1
        if op=='.byte': i=nxt; continue
        if op=='mov_i': R[ins[1]]=ins[2]&0xFFFFFFFFFFFFFFFF
        elif op=='mov_r': R[ins[1]]=R[ins[2]]
        elif op=='movk':
            d,imm,sh=ins[1],ins[2],ins[3]; R[d]=(R[d]&~(0xFFFF<<sh))|((imm&0xFFFF)<<sh)
        elif op=='add': R[ins[1]]=(R[ins[2]]+ins[3])&0xFFFFFFFFFFFFFFFF
        elif op=='sub': R[ins[1]]=(R[ins[2]]-ins[3])&0xFFFFFFFFFFFFFFFF
        elif op in('orr','and'):
            a,b=R[ins[2]],R[ins[3]]; R[ins[1]]=(a|b) if op=='orr' else (a&b)
        elif op=='lsl': R[ins[1]]=(R[ins[2]]<<(R[ins[3]]&63))&0xFFFFFFFFFFFFFFFF
        elif op=='lsr': R[ins[1]]=(R[ins[2]]&0xFFFFFFFFFFFFFFFF)>>(R[ins[3]]&63)
        elif op=='asr':
            v=R[ins[2]]; v=v-(1<<64) if v>>63 else v; R[ins[1]]=(v>>(R[ins[3]]&63))&0xFFFFFFFFFFFFFFFF
        elif op=='cmp_i': cmpflags=(R[ins[1]],ins[2])
        elif op=='cmp_r': cmpflags=(R[ins[1]],R[ins[2]])
        elif op=='adr': R[ins[1]]=ins[2]
        elif op=='ldrb': R[ins[1]]=img[R[ins[2]]+R[ins[3]]]
        elif op=='strb': img[R[ins[2]]+R[ins[3]]]=R[ins[1]]&0xff
        elif op=='ldr': R[ins[1]]=struct.unpack_from('<I',img,R[ins[2]])[0]
        elif op=='str': struct.pack_into('<I',img,R[ins[2]],R[ins[1]]&0xFFFFFFFF)
        elif op=='bl': R[30]=o+4; i=idx(ins[1]); continue
        elif op=='blr': R[30]=o+4; i=idx(R[ins[1]]); continue
        elif op=='br': i=idx(R[ins[1]]); continue
        elif op=='ret': 
            if R[30]==code_end or R[30] not in idx_at: break
            i=idx(R[30]); continue
        elif op=='b': i=idx(ins[1]); continue
        elif op=='bcc':
            a,b=cmpflags; sa=a-(1<<64) if a>>63 else a; sb=b-(1<<64) if b>>63 else b
            take={'b.eq':a==b,'b.ne':a!=b,'b.lt':sa<sb,'b.ge':sa>=sb}[ins[1]]
            if take: i=idx(ins[2]); continue
        elif op=='svc':
            num=R[8]
            if num==93: return R[0]&0xff, bytes(out)          # exit
            elif num==64:  # write(fd,buf,len)
                out+=img[R[1]:R[1]+R[2]]; R[0]=R[2]
            elif num==63:  # read(fd,buf,len)
                n=min(R[2],len(inbuf)); img[R[1]:R[1]+n]=inbuf[:n]; del inbuf[:n]; R[0]=n
            elif num==214:  # brk(addr)
                if R[0]==0: R[0]=brk[0]
                else:
                    brk[0]=R[0]
                    if R[0]>len(img): img.extend(b'\x00'*(R[0]-len(img)))
            else: R[0]=0
        i=nxt
    return None, bytes(out)

def asm_run(text, stdin=b''):
    _,prog,_=assemble(text); return run(prog,stdin)
