"""stage 2 reference: variables, assignment, reassignment, if, while.
Program: int main(){ <stmt>* }
  stmt := int <c> = <expr> ;        (declare, word slot)
        | <c> = <expr> ;            (reassign)
        | return <expr> ;
        | if ( <expr> ) { <stmt>* }
        | while ( <expr> ) { <stmt>* }
Single-char var names -> labeled 4-byte (word) slots :a..:z in the emitted program.
Expressions: number | var | ( expr ), with + - * (precedence, parens), shunting-yard.
Truth test: nonzero (C semantics). No comparison operators yet.

Codegen is ITERATIVE with an explicit block stack (mirrors the asm: no cheap
recursion). Control-flow jump targets use uppercase labels A,B,... (var slots use
a..z, so they don't collide); up to 26 control-flow labels per program.
"""
PREC={'<':0,'>':0,'+':1,'-':1,'*':2}

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
            out.append(('var',c)); i+=1
        elif c in '+-*<>()':
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
        if o=='<':      # a<b (unsigned32) = (a-b)>>63
            out.extend(["sub x0 x1 x0","mov x2 63","lsr x0 x0 x2"])
        elif o=='>':    # a>b = (b-a)>>63
            out.extend(["sub x0 x0 x1","mov x2 63","lsr x0 x0 x2"])
        else:
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
    lb=src.find('{')
    body=src[lb+1:] if lb>=0 else src   # includes nested braces + final }
    code=["mov x0 0","mov x8 214","svc","mov x9 x0","add x0 x9 1000","mov x8 214","svc"]
    labelctr=[0]
    def newlabel():
        c=chr(ord('A')+labelctr[0]); labelctr[0]+=1; return c
    blockstack=[]
    def store_to(c): return ["sub x9 x9 4","ldr w0 x9",f"adr x1 {c}","str w0 x1"]
    def cond_test(L): return ["sub x9 x9 4","ldr w0 x9","cmp x0 0",f"b.eq {L}"]
    def skipws(i):
        while i<len(body) and body[i] in ' \t\n': i+=1
        return i
    def until_semi(i):
        j=i
        while j<len(body) and body[j]!=';': j+=1
        return body[i:j], j
    def read_cond(i):   # from '(' up to '{'
        j=i
        while j<len(body) and body[j]!='{': j+=1
        return body[i:j], j
    i=0
    while i<len(body):
        i=skipws(i)
        if i>=len(body): break
        c=body[i]
        if c=='}':
            if not blockstack: break     # end of function
            blk=blockstack.pop()
            if blk[0]=='if':
                code.append(f":{blk[1]}")
            else:                        # while
                code.append(f"b {blk[1]}")
                code.append(f":{blk[2]}")
            i+=1; continue
        if body.startswith('int',i):
            i=skipws(i+3); c2=body[i]; i=skipws(i+1); i+=1  # '='
            expr,i=until_semi(i); code+=_compile_expr(expr); code+=store_to(c2); i+=1
        elif body.startswith('if',i):
            i=skipws(i+2)
            cond,i=read_cond(i); code+=_compile_expr(cond)
            L=newlabel(); code+=cond_test(L)
            blockstack.append(('if',L))
            i=skipws(i); i+=1            # skip '{'
        elif body.startswith('while',i):
            i=skipws(i+5)
            Ltop=newlabel(); code.append(f":{Ltop}")
            cond,i=read_cond(i); code+=_compile_expr(cond)
            Lexit=newlabel(); code+=cond_test(Lexit)
            blockstack.append(('while',Ltop,Lexit))
            i=skipws(i); i+=1            # skip '{'
        elif body.startswith('return',i):
            expr,i=until_semi(i+6); code+=_compile_expr(expr)
            code+=["sub x9 x9 4","ldr w0 x9","mov x8 93","svc"]; i+=1
        else:                            # reassignment  <c> = <expr> ;
            c2=body[i]; i=skipws(i+1); i+=1  # '='
            expr,i=until_semi(i); code+=_compile_expr(expr); code+=store_to(c2); i+=1
    for ch in "abcdefghijklmnopqrstuvwxyz":
        code+=[f":{ch}",".byte 0",".byte 0",".byte 0",".byte 0"]
    return "\n".join(code)+"\n"


# ------- independent interpreter of the C subset (test ORACLE, not codegen) -------
def evaluate(src):
    lb=src.find('{'); body=src[lb+1:]
    env={}; ret=[None]
    def ev_expr(s):
        toks=_tokens(s); out=[]; ops=[]
        for k,v in toks:
            if k=='num': out.append(('n',int(v)))
            elif k=='var': out.append(('v',v))
            elif v=='(': ops.append('(')
            elif v==')':
                while ops and ops[-1]!='(': out.append(('o',ops.pop()))
                if ops: ops.pop()
            else:
                while ops and ops[-1]!='(' and PREC[ops[-1]]>=PREC[v]: out.append(('o',ops.pop()))
                ops.append(v)
        while ops:
            o=ops.pop()
            if o!='(': out.append(('o',o))
        st=[]
        for k,v in out:
            if k=='n': st.append(v & 0xFFFFFFFF)
            elif k=='v': st.append(env.get(v,0) & 0xFFFFFFFF)
            else:
                b=st.pop(); a=st.pop()
                if v=='<':   r=1 if (a & 0xFFFFFFFF) < (b & 0xFFFFFFFF) else 0
                elif v=='>': r=1 if (a & 0xFFFFFFFF) > (b & 0xFFFFFFFF) else 0
                else:        r={'+':a+b,'-':a-b,'*':a*b}[v]
                st.append(r & 0xFFFFFFFF)
        return (st[-1] if st else 0) & 0xFFFFFFFF
    def skipws(i):
        while i<len(body) and body[i] in ' \t\n': i+=1
        return i
    def until(i,ch):
        j=i
        while j<len(body) and body[j]!=ch: j+=1
        return body[i:j], j
    def match_brace(i):   # i at '{'; return index just past matching '}'
        d=0; j=i
        while j<len(body):
            if body[j]=='{': d+=1
            elif body[j]=='}':
                d-=1
                if d==0: return j+1
            j+=1
        return j
    def run_block(i,end):
        while i<end and ret[0] is None:
            i=skipws(i)
            if i>=end: break
            if body.startswith('int',i):
                k=skipws(i+3); c=body[k]; k=skipws(k+1); k+=1
                e,k=until(k,';'); env[c]=ev_expr(e); i=k+1
            elif body.startswith('if',i):
                k=skipws(i+2); cond,k=until(k,'{'); v=ev_expr(cond)
                bstart=skipws(k); bend=match_brace(bstart)
                if v!=0: run_block(bstart+1,bend-1)
                i=bend
            elif body.startswith('while',i):
                k=skipws(i+5); condtxt,k=until(k,'{')
                bstart=skipws(k); bend=match_brace(bstart); guard=0
                while ev_expr(condtxt)!=0 and ret[0] is None:
                    run_block(bstart+1,bend-1); guard+=1
                    if guard>1000000: raise RuntimeError("oracle runaway")
                i=bend
            elif body.startswith('return',i):
                e,k=until(i+6,';'); ret[0]=ev_expr(e); i=k+1
            elif body[i]=='}':
                break
            else:  # reassignment
                c=body[i]; k=skipws(i+1); k+=1
                e,k=until(k,';'); env[c]=ev_expr(e); i=k+1
        return i
    run_block(0,len(body))
    return (ret[0] if ret[0] is not None else 0) & 0xff
