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

def run(prog, stdin=b'', mem_size=0x40000, trace=False, oob_trap=True, files=None):
    # --- file I/O model (A12, m53) -------------------------------------------
    # The real ladder does file I/O through raw syscalls: openat(56)/read(63)/
    # write(64)/close(57) (there is no bare `open` on aarch64 — M2libc's `_open`
    # is openat(AT_FDCWD, ...)). To witness a compiled program that reads a source
    # file and writes an output file, the interp models a tiny in-memory
    # filesystem plus a per-fd table. `files` is a {path: bytes} dict standing in
    # for the on-disk tree; it is updated IN PLACE as the program creates/writes
    # files, so a caller can inspect what a compiled program produced. fds 0/1/2
    # keep their console meaning (stdin/stdout/stderr) exactly as before — the
    # existing pipeline writes only fd 1 and reads only fd 0, so it is unaffected.
    # This mirrors the m51 lesson (model the syscall so the bench witnesses the
    # real behaviour) without becoming MORE capable than reality: an open of a
    # missing file for reading fails (-1), a read past EOF returns 0, and a write
    # to a bad fd returns -1 — the same failures hardware would take.
    fs = {} if files is None else files          # {path(str): bytes} — mutated in place
    openf = {}                                    # fd -> {'path','data','pos','w'}
    nextfd = [3]
    stderr = bytearray()
    def rd_cstr(a):                               # read a NUL-terminated path from memory
        e = a
        while e < len(img) and img[e] != 0: e += 1
        return bytes(img[a:e]).decode('latin-1')
    def back(a, n):                               # lazily back a valid syscall buffer
        if a + n > len(img) and a + n <= brk[0]:
            img.extend(b'\x00' * (a + n - len(img)))
    def flush(fd):
        f = openf.get(fd)
        if f and f['w']: fs[f['path']] = bytes(f['data'])
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
        if oob_trap and (addr < NULLFLOOR or addr + n > brk[0]):
            raise OOBAccess(
                f"{'store' if store else 'load'} of {n}B at 0x{addr:x} "
                f"outside [0x{NULLFLOOR:x}, 0x{brk[0]:x}) (brk={brk[0]:#x})")
        # lazily back a valid address that lies in a mapped-but-untouched page
        # (mmap/brk raised the ceiling; physical img grows only as pages are used)
        if addr + n <= brk[0] and addr + n > len(img):
            img.extend(b'\x00' * (addr + n - len(img)))
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
        elif op in('orr','and','eor'):
            a,b=R[ins[2]],R[ins[3]]
            R[ins[1]]=(a|b) if op=='orr' else ((a&b) if op=='and' else (a^b))
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
            if num==93:                                        # exit(code)
                for fd in list(openf): flush(fd)
                return R[0]&0xff, bytes(out)
            elif num==64:  # write(fd,buf,len) -> fd 1 stdout, fd 2 stderr, else a file
                fd,buf,n=R[0],R[1],R[2]; back(buf,n); data=img[buf:buf+n]
                if fd==1:   out+=data;    R[0]=n
                elif fd==2: stderr+=data; R[0]=n
                elif fd in openf and openf[fd]['w']:
                    openf[fd]['data']+=data; R[0]=n
                else: R[0]=(-1)&0xFFFFFFFFFFFFFFFF          # EBADF
            elif num==63:  # read(fd,buf,len) -> fd 0 stdin, else an open file
                fd,buf,cnt=R[0],R[1],R[2]
                if fd==0:
                    n=min(cnt,len(inbuf)); back(buf,n)
                    img[buf:buf+n]=inbuf[:n]; del inbuf[:n]; R[0]=n
                elif fd in openf:
                    f=openf[fd]; n=min(cnt,len(f['data'])-f['pos']); back(buf,n)
                    img[buf:buf+n]=f['data'][f['pos']:f['pos']+n]; f['pos']+=n; R[0]=n
                else: R[0]=(-1)&0xFFFFFFFFFFFFFFFF          # EBADF
            elif num==56:  # openat(dirfd, name, flags, mode) -> fd, or -1
                name=rd_cstr(R[1]); flags=R[2]; acc=flags&3
                writ=(acc==1 or acc==2); creat=bool(flags&0o100); trunc=bool(flags&0o1000)
                if name in fs and not (trunc and writ):
                    data=bytearray(fs[name])
                elif writ and (creat or trunc):
                    data=bytearray(); fs[name]=b''            # create/truncate
                elif name in fs:
                    data=bytearray(fs[name])
                else:
                    R[0]=(-1)&0xFFFFFFFFFFFFFFFF; i=nxt; continue   # ENOENT
                fd=nextfd[0]; nextfd[0]+=1
                openf[fd]={'path':name,'data':data,'pos':0,'w':writ}
                R[0]=fd
            elif num==57:  # close(fd)
                fd=R[0]
                if fd in openf: flush(fd); del openf[fd]; R[0]=0
                elif fd in (0,1,2): R[0]=0
                else: R[0]=(-1)&0xFFFFFFFFFFFFFFFF
            elif num==214:  # brk(addr)
                if R[0]==0: R[0]=brk[0]
                else:
                    brk[0]=R[0]
                    if R[0]>len(img): img.extend(b'\x00'*(R[0]-len(img)))
            elif num==222:  # mmap(addr,length,prot,flags,fd,offset) -> anon, zero-filled
                # model a successful anonymous mapping: hand back a fresh region at
                # the current ceiling and raise the ceiling by its length. Pages are
                # zero and lazily backed (chk grows img on first touch), so a bump
                # allocator over mmap never faults inside its arena — matching real
                # MAP_ANONYMOUS. This is why calloc uses mmap, not brk: qemu-user's
                # brk region is small, but an anonymous mapping of any size is fine.
                length=R[1]; base=brk[0]; brk[0]=brk[0]+length; R[0]=base
            else: R[0]=0
        i=nxt
    for fd in list(openf): flush(fd)
    return None, bytes(out)

def asm_run(text, stdin=b''):
    _,prog,_=assemble(text); return run(prog,stdin)
