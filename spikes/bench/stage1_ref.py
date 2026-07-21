"""
Reference model of stage 1: a two-pass NUMERIC label resolver (retires the pool).
Reads assembly with multi-character labels; emits label-free stage-0-as assembly
with every reference rewritten to a numeric position. Pipeline: prog | stage1 |
stage0-as | elf.  This replaces the old single-char pool mapper.

Instead of mapping multi-char labels onto a fixed pool of single bytes (capped at
stage-0-as's 128-entry symtab), stage 1 becomes a real assembler pass:

  PASS 1  walk the input, compute each label's assembled byte position
          (instruction = 4 bytes; .byte = 1; .ascii = decoded length; label/comment/blank = 0),
          storing name -> position in a DYNAMIC multi-character symbol table (no pool).
  PASS 2  drop ':label' definition lines and rewrite every reference numerically:
            b/bl/b.cond name  ->  b/bl/b.cond @<pos>     (m27 numeric branch)
            adr xR name       ->  adr xR @<pos>          (new numeric adr in stage-0-as)

Output is fully label-free stage-0-as assembly, so the 128-symtab is never in the
path for stage-2/3 code.  Label count is bounded only by memory: no ceiling, ever.
"""
BR = ('b','bl','b.eq','b.ne','b.lt','b.ge','b.gt','b.le','adr')

def _ascii_len(raw):
    # bytes emitted by  .ascii "raw"  (escape seq = 1 byte)
    n=0;i=0
    while i<len(raw):
        if raw[i]=='\\': n+=1; i+=2
        else:            n+=1; i+=1
    return n

def _size(st):
    if st=='' or st.startswith('#') or st.startswith(':'): return 0
    if st.startswith('.byte'):  return 1
    if st.startswith('.ascii'):
        raw=st[st.index('"')+1:st.rindex('"')]; return _ascii_len(raw)
    return 4   # one instruction

def stage1_numeric(text):
    lines=text.split('\n')
    # PASS 1 — positions
    pos=0; lp={}
    for line in lines:
        st=line.strip()
        if st.startswith(':'):
            lp[st[1:].split('#',1)[0].strip()]=pos
        else:
            pos+=_size(st)
    # PASS 2 — rewrite refs, drop defs
    out=[]
    for line in lines:
        st=line.strip()
        if st.startswith(':'): continue          # drop label definition (0 bytes)
        if st=='' or st.startswith('#'): out.append(line); continue
        toks=st.split()
        if toks[0] in BR and toks[-1] in lp:
            toks[-1]='@'+str(lp[toks[-1]])
            out.append(' '.join(toks))
        else:
            out.append(line)
    return '\n'.join(out)

# historical name used by docs/tests:
def stage1(text): return stage1_numeric(text)
