"""stage 2 increment: return <expr> with + - * AND parentheses.
Compiler uses shunting-yard (iterative, no compiler recursion) to turn infix into
stack-machine operations. Emitted code uses a VALUE STACK in memory (x9 = stack
pointer into a data region 'S'):
    PUSH n : mov x0 n ; str w0 x9 ; add x9 x9 4
    APPLY o: pop b ; pop a ; a o b ; push
Result ends on the stack; popped into x0 before exit.
"""
def _tokens(s):
    i=0; out=[]
    while i<len(s):
        c=s[i]
        if c in ' \t\n': i+=1; continue
        if c.isdigit():
            j=i
            while j<len(s) and s[j].isdigit(): j+=1
            out.append(('num', s[i:j])); i=j
        elif c in '+-*()':
            out.append(('op', c)); i+=1
        elif c==';': break
        else: i+=1
    return out

PREC={'+':1,'-':1,'*':2}

def _shunt(tokens):
    """infix tokens -> list of ('push',n) / ('apply',op)"""
    out=[]; ops=[]
    for kind,v in tokens:
        if kind=='num': out.append(('push',v))
        elif v=='(':
            ops.append('(')
        elif v==')':
            while ops and ops[-1]!='(': out.append(('apply',ops.pop()))
            if ops and ops[-1]=='(': ops.pop()
        else:  # operator + - *
            while ops and ops[-1]!='(' and PREC[ops[-1]]>=PREC[v]:
                out.append(('apply',ops.pop()))
            ops.append(v)
    while ops:
        op=ops.pop()
        if op!='(': out.append(('apply',op))
    return out

def compile_return(src):
    i=src.find("return"); body = src[i+6:] if i>=0 else ""
    seq=_shunt(_tokens(body))
    code=["adr x9 S"]
    if not seq: seq=[('push','0')]
    for k,v in seq:
        if k=='push':
            code += [f"mov x0 {v}","str w0 x9","add x9 x9 4"]
        else:
            code += ["sub x9 x9 4","ldr w0 x9","sub x9 x9 4","ldr w1 x9"]
            code += {'+':["add x0 x1 x0"],'-':["sub x0 x1 x0"],'*':["mul x0 x1 x0"]}[v]
            code += ["str w0 x9","add x9 x9 4"]
    code += ["sub x9 x9 4","ldr w0 x9","mov x8 93","svc"]
    return "\n".join(code)+"\n"
