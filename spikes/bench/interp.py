import struct
from s0as import assemble

# --- memory-fault model (m50) ------------------------------------------------
# The real ladder runs under qemu-user on an ELF with one R+W+X segment: a load
# or store to an address the program never mapped SIGSEGVs. The bench used to be
# *more capable than reality* here — a wild address just indexed the flat `img`
# and read 0 (or some nearby byte) without faulting. That is exactly what masked
# the m49 `&member` bug (a bad `&p.x` produced address 0 / a junk-scaled address
# that the model tolerated but hardware killed). So the interp now traps accesses
# outside the region a correct program can legitimately touch:
#   valid data window = [NULLFLOOR, brk)   (brk = the current program break)
# Everything a well-formed program addresses lives there: emitted code+data
# labels sit in [0, code_end) and the runtime value stack / frames / heap live in
# the brk-grown block [code_end, brk). Accesses below NULLFLOOR catch near-null
# derefs (the `adr x0 <undef>` -> @0 shape); accesses at/above brk catch the
# junk-scaled / over-allocated-image shape (the bench's `img` may be far larger
# than what the program actually brk'd, so bounding by `brk` — not len(img) — is
# what makes the model fault like hardware). NULLFLOOR is small (a couple words):
# the interp is base-0, so real data labels can sit at low offsets and must not be
# rejected — we only guard the genuine near-null band.
NULLFLOOR = 16

class OOBAccess(RuntimeError):
    """A load/store outside [NULLFLOOR, brk) — a fault the real hardware would take."""

def run(prog, stdin=b'', mem_size=0x40000, trace=False, oob_trap=True):
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
    def chk(addr, n, store):
        # fault on anything a correct program could never legitimately reach
        if not oob_trap: return
        if addr < NULLFLOOR or addr + n > brk[0]:
            raise OOBAccess(
                f"{'store' if store else 'load'} of {n}B at 0x{addr:x} "
                f"outside [0x{NULLFLOOR:x}, 0x{brk[0]:x}) (brk={brk[0]:#x})")
    pc=0; out=bytearray(); inbuf=bytearray(stdin); steps=0
    # find instruction index for a byte offset
    def idx(o):
        return idx_at[o]
    i=idx(0)
    while 0<=i<len(seq):
        steps+=1
        if steps>200_000_000: raise RuntimeError("runaway")
        o,ins=seq[i]; op=ins[0]
        nxt=i+1
        if op=='.byte': i=nxt; continue
        if op=='mov_i': R[ins[1]]=ins[2]&0xFFFFFFFFFFFFFFFF
        elif op=='mov_r': R[ins[1]]=R[ins[2]]
        elif op=='movk':
            d,imm,sh=ins[1],ins[2],ins[3]; R[d]=(R[d]&~(0xFFFF<<sh))|((imm&0xFFFF)<<sh)
        elif op=='add': R[ins[1]]=(R[ins[2]]+ins[3])&0xFFFFFFFFFFFFFFFF
        elif op=='sub': R[ins[1]]=(R[ins[2]]-ins[3])&0xFFFFFFFFFFFFFFFF
        elif op=='addr': R[ins[1]]=(R[ins[2]]+R[ins[3]])&0xFFFFFFFFFFFFFFFF
        elif op=='subr': R[ins[1]]=(R[ins[2]]-R[ins[3]])&0xFFFFFFFFFFFFFFFF
        elif op=='mul':  R[ins[1]]=(R[ins[2]]*R[ins[3]])&0xFFFFFFFFFFFFFFFF
        elif op=='udiv': R[ins[1]]=(R[ins[2]]//R[ins[3]]) if R[ins[3]] else 0   # aarch64: /0 -> 0
        elif op in('orr','and'):
            a,b=R[ins[2]],R[ins[3]]; R[ins[1]]=(a|b) if op=='orr' else (a&b)
        elif op=='lsl': R[ins[1]]=(R[ins[2]]<<(R[ins[3]]&63))&0xFFFFFFFFFFFFFFFF
        elif op=='lsr': R[ins[1]]=(R[ins[2]]&0xFFFFFFFFFFFFFFFF)>>(R[ins[3]]&63)
        elif op=='asr':
            v=R[ins[2]]; v=v-(1<<64) if v>>63 else v; R[ins[1]]=(v>>(R[ins[3]]&63))&0xFFFFFFFFFFFFFFFF
        elif op=='cmp_i': cmpflags=(R[ins[1]],ins[2])
        elif op=='cmp_r': cmpflags=(R[ins[1]],R[ins[2]])
        elif op=='adr': R[ins[1]]=ins[2]
        elif op=='ldrb': a=R[ins[2]]+R[ins[3]]; chk(a,1,False); R[ins[1]]=img[a]
        elif op=='strb': a=R[ins[2]]+R[ins[3]]; chk(a,1,True);  img[a]=R[ins[1]]&0xff
        elif op=='ldr':
            a=R[ins[2]]
            if len(ins)>3 and ins[3]=='x': chk(a,8,False); R[ins[1]]=struct.unpack_from('<Q',img,a)[0]
            else:                          chk(a,4,False); R[ins[1]]=struct.unpack_from('<I',img,a)[0]
        elif op=='str':
            a=R[ins[2]]
            if len(ins)>3 and ins[3]=='x': chk(a,8,True); struct.pack_into('<Q',img,a,R[ins[1]]&0xFFFFFFFFFFFFFFFF)
            else:                          chk(a,4,True); struct.pack_into('<I',img,a,R[ins[1]]&0xFFFFFFFF)
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
