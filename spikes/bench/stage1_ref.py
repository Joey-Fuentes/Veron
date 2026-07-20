"""Reference model of stage 1 (macro-as) capability #1: multi-char labels.
Reads assembly where labels may be multi-character; emits the SAME program with
each label mapped to a unique single char, so stage0-as can assemble it.
Pipeline:  prog.s1 | stage1 | stage0-as | elf

Label positions handled:
  :name                      (definition)
  b/bl/b.eq/b.ne/b.lt/b.ge name   (label = last token)
  adr xR name                (label = last token)
Everything else (incl. br/blr which take registers) passes through verbatim.
"""
POOL="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$@?!%^&~|=<>+"

def stage1(text):
    table={}          # name -> single char
    def mapname(nm):
        if nm not in table:
            table[nm]=POOL[len(table)]
        return table[nm]
    out=[]
    for line in text.split('\n'):
        s=line
        st=s.strip()
        if st=='' :
            out.append(s); continue
        lead=s[:len(s)-len(s.lstrip())]
        body=s.strip()
        # comment-only or trailing comment: keep simple — split off comment
        # (labels never appear in comments in our programs)
        if body.startswith(':'):
            nm=body[1:].split('#',1)[0].strip()
            out.append(lead+':'+mapname(nm)); continue
        toks=body.split()
        m=toks[0]
        takes_label = (m in ('b','bl','b.eq','b.ne','b.lt','b.ge','adr'))
        if takes_label:
            lbl=toks[-1]
            toks[-1]=mapname(lbl)
            out.append(lead+' '.join(toks)); continue
        out.append(s)   # br/blr/everything else verbatim
    return '\n'.join(out)
