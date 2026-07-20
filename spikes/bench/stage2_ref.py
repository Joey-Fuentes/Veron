"""stage 2 increment: variables + assignment (single-char names).
Program: int main(){ int a=<expr>; int b=<expr>; ... return <expr>; }
- single-char var names -> labeled data slots :a .. :z in the emitted program
- factor := number | variable(load) | ( expr )
- value stack in brk memory (x9); vars via adr + ldr/str word
"""
PREC={'+':1,'-':1,'*':2}
def _tokens(s):
    i=0;out=[]
    while i<len(s):
        c=s[i]
        if c in ' \t\n': i+=1; continue
        if c.isdigit():
            j=i
            while j<len(s) and s[j].isdigit(): j+=1
            out.append(('num',s[i:j])); i=j
        elif c.isalpha():
            out.append(('var',c)); i+=1     # single-char variable
        elif c in '+-*()':
            out.append(('op',c)); i+=1
        else: i+=1
    return out
def _compile_expr(expr):
    """shunting-yard -> emitted code that pushes the result on the value stack"""
    toks=_tokens(expr); out=[]; ops=[]
    def push_num(n): out.extend([f"mov x0 {n}","str w0 x9","add x9 x9 4"])
    def push_var(c): out.extend([f"adr x1 {c}","ldr w0 x1","str w0 x9","add x9 x9 4"])
    def apply(o):
        out.extend(["sub x9 x9 4","ldr w0 x9","sub x9 x9 4","ldr w1 x9"])
        out.append({'+':"add x0 x1 x0",'-':"sub x0 x1 x0",'*':"mul x0 x1 x0"}[o])
        out.extend(["str w0 x9","add x9 x9 4"])
    for k,v in toks:
        if k=='num': push_num(v)
        elif k=='var': push_var(v)
        elif v=='(': ops.append('(')
        elif v==')':
            while ops and ops[-1]!='(': apply(ops.pop())
            if ops: ops.pop()
        else:
            while ops and ops[-1]!='(' and PREC[ops[-1]]>=PREC[v]: apply(ops.pop())
            ops.append(v)
    while ops:
        o=ops.pop()
        if o!='(': apply(o)
    if not out: out=["mov x0 0","str w0 x9","add x9 x9 4"]
    return out
def compile_program(src):
    lb=src.find('{'); rb=src.rfind('}')
    body=src[lb+1:rb] if lb>=0 else src
    code=["mov x0 0","mov x8 214","svc","mov x9 x0","add x0 x9 1000","mov x8 214","svc"]
    i=0
    def skipws(i):
        while i<len(body) and body[i] in ' \t\n': i+=1
        return i
    def until_semi(i):
        j=i
        while j<len(body) and body[j]!=';': j+=1
        return body[i:j], j
    while i<len(body):
        i=skipws(i)
        if i>=len(body): break
        if body.startswith('int',i):
            i=skipws(i+3); c=body[i]; i=skipws(i+1)
            i+=1  # '='
            expr,i=until_semi(i)
            code+=_compile_expr(expr)
            code+=["sub x9 x9 4","ldr w0 x9",f"adr x1 {c}","str w0 x1"]
            i+=1  # ';'
        elif body.startswith('return',i):
            expr,i=until_semi(i+6)
            code+=_compile_expr(expr)
            code+=["sub x9 x9 4","ldr w0 x9","mov x8 93","svc"]
            i+=1
        else: i+=1
    # emit 26 word slots
    for ch in "abcdefghijklmnopqrstuvwxyz":
        code+=[f":{ch}",'.ascii "____"']
    return "\n".join(code)+"\n"
