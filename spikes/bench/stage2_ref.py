"""stage 2 increment: return <expr> with + - * and precedence.
Recursive descent over: expr := term (('+'|'-') term)* ; term := num (('*') num)*
Register codegen: value accumulates in x0; a term is computed in x1 (with x2 as
scratch for multiply), then combined into x0 with add/sub REGISTER ops.

Emitted shape for  2 + 3*4 :
    mov x0 2          ; first term into x0
    mov x1 3          ; next term into x1
    mov x2 4
    mul x1 x1 x2      ; 3*4
    add x0 x0 x1      ; 2 + 12
This keeps only ONE running accumulator (x0) plus one term register (x1); good
enough for flat precedence with + - *.
"""
class P:
    def __init__(s,t): s.t=t; s.i=0
    def sk(s):
        while s.i<len(s.t) and s.t[s.i] in ' \t\n': s.i+=1
    def num(s):
        s.sk(); d=''
        while s.i<len(s.t) and s.t[s.i].isdigit(): d+=s.t[s.i]; s.i+=1
        return d or '0'
    def peek(s):
        s.sk(); return s.t[s.i] if s.i<len(s.t) else ''

def compile_return(src):
    i=src.find("return"); body = src[i+6:] if i>=0 else ""
    p=P(body); out=[]
    # first term -> x0
    _term(p,out,'x0','x1','x2')
    while True:
        c=p.peek()
        if c=='+':
            p.i+=1; _term(p,out,'x1','x1','x2'); out.append("add x0 x0 x1")
        elif c=='-':
            p.i+=1; _term(p,out,'x1','x1','x2'); out.append("sub x0 x0 x1")
        else: break
    out += ["mov x8 93","svc"]
    return "\n".join(out)+"\n"

def _term(p,out,dst,tmp,scr):
    # term := num ('*' num)* ; result in dst
    out.append(f"mov {dst} {p.num()}")
    while p.peek()=='*':
        p.i+=1
        out.append(f"mov {scr} {p.num()}")
        out.append(f"mul {dst} {dst} {scr}")
