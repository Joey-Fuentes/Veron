"""stage 2 increment: return <expr> with + and - (left-to-right).
Emits mov + add/sub IMMEDIATE chains (no new stage0-as ops needed):
    return 2+3-1;  ->  mov x0 2 / add x0 x0 3 / sub x0 x0 1
"""
def stage2(src):
    i = src.find("return"); j = (i+6) if i>=0 else len(src)
    def sk(j):
        while j<len(src) and src[j] in ' \t\n': j+=1
        return j
    def num(j):
        d=''
        while j<len(src) and src[j].isdigit(): d+=src[j]; j+=1
        return (d or '0'), j
    out=[]
    j=sk(j); d,j=num(j); out.append("mov x0 "+d)
    while True:
        j=sk(j)
        if j<len(src) and src[j]=='+':
            j=sk(j+1); d,j=num(j); out.append("add x0 x0 "+d)
        elif j<len(src) and src[j]=='-':
            j=sk(j+1); d,j=num(j); out.append("sub x0 x0 "+d)
        else: break
    out += ["mov x8 93","svc"]
    return "\n".join(out)+"\n"
