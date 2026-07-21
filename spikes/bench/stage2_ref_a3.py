"""stage 2 reference — A2: functions + a real call stack + recursion.

Builds on A1's tokenizer. The three A1 seams go live:
  * SymTab / Frame  — the frame allocator is now **declaration-order bump**
      (params first, then locals), consulted by name — so **multi-char variable
      names** work and there is no letter-map. offset_of REQUIRES a declaration.
  * functions       — the program is now one-or-more `int name(params){body}`.
      A call `f(a,b)` is a primary in any expression.

Runtime model of the EMITTED program (three regions in one brk block):
  x9  = value stack  (expression temporaries AND argument passing / return value)
  x10 = current frame base (params+locals at x10+off, declaration order, 64-bit word slots)
  x11 = frame stack top   (frames nest here so recursion works)
Per-call frame on the frame stack: [ saved caller x10 (8) | saved x30 (8) |
  params+locals (word slots) ], 16-byte aligned. x10 points just past the 16-byte
  save area. Calling convention:
    caller: evaluate args L->R onto the value stack, then `bl f`.
    callee prologue: save caller x10 and x30, open a fresh frame, pop the P args
      off the value stack (reverse) into param slots 0..P-1.
    `return e`: evaluate e (result on the value stack), restore x10/x30/x11, `ret`
      — the result is left on the value stack for the caller, exactly like a
      number or variable would be.
  The whole program starts by `bl main`; main's returned value becomes the exit
  code. Functions are emitted as `:name` and called with `bl name`; control flow
  (if/while) stays NUMERIC backpatched (`b.eq @<pos>`). stage1 resolves the
  function labels and passes the numeric branches through untouched, so the
  compiled pipeline is `prog.c | stage2 | stage1 | stage0-as | elf`.
"""

KEYWORDS = {'int', 'return', 'if', 'while'}
TWO_OPS  = {'<=', '>=', '==', '!='}
PREC = {'==':0, '!=':0, '<':1, '>':1, '<=':1, '>=':1, '+':2, '-':2, '*':3, '/':3, '%':3}


# ---------------------------------------------------------------------------
# lexer (A1 + comma for argument lists)
# ---------------------------------------------------------------------------
def lex(src):
    toks = []; i = 0; n = len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            i += 1; continue
        if c.isdigit():
            j = i
            while j < n and src[j].isdigit(): j += 1
            toks.append(('num', src[i:j])); i = j; continue
        if c.isalpha() or c == '_':
            j = i
            while j < n and (src[j].isalnum() or src[j] == '_'): j += 1
            w = src[i:j]
            toks.append(('kw', w) if w in KEYWORDS else ('id', w)); i = j; continue
        if src[i:i+2] in TWO_OPS:
            toks.append(('op', src[i:i+2])); i += 2; continue
        if c in '+-*/%<>':
            toks.append(('op', c)); i += 1; continue
        if c in '(){};=,':
            toks.append(('punct', c)); i += 1; continue
        i += 1
    return toks


# ---------------------------------------------------------------------------
# symbol table + declaration-order frame allocator (now LIVE)
# ---------------------------------------------------------------------------
class Sym:
    __slots__ = ('name', 'kind', 'size', 'indir', 'off')
    def __init__(self, name, kind, size, indir, off):
        self.name, self.kind, self.size, self.indir, self.off = name, kind, size, indir, off

class Frame:
    def __init__(self):
        self.by_name = {}
        self.next_off = 0
    def declare(self, name, kind='local', size=8):
        s = Sym(name, kind, size, 0, self.next_off)
        self.by_name[name] = s
        self.next_off += size
        return s
    def offset_of(self, name):
        return self.by_name[name].off          # requires prior declaration
    def nslots(self):
        return self.next_off // 8


# ---------------------------------------------------------------------------
# emitter: tracks instruction count so numeric branch targets skip label lines
# ---------------------------------------------------------------------------
class Emit:
    def __init__(self):
        self.lines = []
        self.ic = 0                            # instruction count (labels are 0 bytes)
    def i(self, s):
        self.lines.append(s); self.ic += 1
    def lbl(self, name):
        self.lines.append(":" + name)
    def pc(self):
        return self.ic * 4
    def slot(self, s):                         # emit a to-be-patched branch; return index
        idx = len(self.lines); self.i(s); return idx
    def patch(self, idx, s):
        self.lines[idx] = s
    def text(self):
        return "\n".join(self.lines) + "\n"


def frame_bump(nslots):
    # 16-byte save area + word slots, padded so the frame stack stays 16-aligned
    total = 16 + nslots * 8
    return (total + 15) // 16 * 16


# ---------------------------------------------------------------------------
# parser: split the program into functions
# ---------------------------------------------------------------------------
def parse_functions(toks):
    funcs = {}                                 # name -> (params, body_tokens)
    order = []
    i = 0
    while i < len(toks):
        if toks[i] != ('kw', 'int'):
            i += 1; continue
        name = toks[i+1][1]; i += 2
        assert toks[i] == ('punct', '('), "expected ( after function name"
        i += 1
        params = []
        while toks[i] != ('punct', ')'):
            if toks[i] == ('kw', 'int'): i += 1
            if toks[i][0] == 'id':
                params.append(toks[i][1]); i += 1
            if toks[i] == ('punct', ','): i += 1
        i += 1                                 # ')'
        assert toks[i] == ('punct', '{'), "expected { to open function body"
        depth = 0; j = i
        while j < len(toks):
            if   toks[j] == ('punct', '{'): depth += 1
            elif toks[j] == ('punct', '}'):
                depth -= 1
                if depth == 0: break
            j += 1
        funcs[name] = (params, toks[i+1:j])
        order.append(name)
        i = j + 1
    return funcs, order


def match_brace(toks, i):                      # i at '{'; return index of matching '}'
    depth = 0
    while i < len(toks):
        if   toks[i] == ('punct', '{'): depth += 1
        elif toks[i] == ('punct', '}'):
            depth -= 1
            if depth == 0: return i
        i += 1
    return i


# ---------------------------------------------------------------------------
# expression codegen (shunting-yard) with function calls
# ---------------------------------------------------------------------------
def compile_expr(toks, pos, frame, funcs, em, stops):
    ops = []; depth = 0

    def push_num(nstr):
        em.i(f"mov x0 {nstr}"); em.i("str x0 x9"); em.i("add x9 x9 8")

    def push_var(name):
        off = frame.offset_of(name)
        em.i(f"add x1 x10 {off:04d}"); em.i("ldr x0 x1"); em.i("str x0 x9"); em.i("add x9 x9 8")

    def apply(o):
        em.i("sub x9 x9 8"); em.i("ldr x0 x9"); em.i("sub x9 x9 8"); em.i("ldr x1 x9")
        if   o == '<':  [em.i(s) for s in ("sub x0 x1 x0", "mov x2 63", "lsr x0 x0 x2")]
        elif o == '>':  [em.i(s) for s in ("sub x0 x0 x1", "mov x2 63", "lsr x0 x0 x2")]
        elif o == '<=': [em.i(s) for s in ("sub x0 x0 x1", "mov x2 63", "lsr x0 x0 x2", "mov x2 1", "sub x0 x2 x0")]
        elif o == '>=': [em.i(s) for s in ("sub x0 x1 x0", "mov x2 63", "lsr x0 x0 x2", "mov x2 1", "sub x0 x2 x0")]
        elif o == '!=': [em.i(s) for s in ("sub x0 x1 x0", "mov x2 0", "sub x2 x2 x0", "orr x0 x0 x2", "mov x2 63", "lsr x0 x0 x2")]
        elif o == '==': [em.i(s) for s in ("sub x0 x1 x0", "mov x2 0", "sub x2 x2 x0", "orr x0 x0 x2", "mov x2 63", "lsr x0 x0 x2", "mov x2 1", "sub x0 x2 x0")]
        elif o == '/':  em.i("udiv x0 x1 x0")
        elif o == '%':  [em.i(t) for t in ("udiv x2 x1 x0", "mul x2 x2 x0", "sub x0 x1 x2")]
        else:           em.i({'+':"add x0 x1 x0", '-':"sub x0 x1 x0", '*':"mul x0 x1 x0"}[o])
        em.i("str x0 x9"); em.i("add x9 x9 8")

    while pos < len(toks):
        k, v = toks[pos]
        if k == 'punct' and depth == 0 and v in stops:
            break
        if k == 'num':
            push_num(v); pos += 1
        elif k == 'id':
            if pos + 1 < len(toks) and toks[pos+1] == ('punct', '('):
                pos = compile_call(toks, pos, frame, funcs, em)   # result pushed by callee
            else:
                push_var(v); pos += 1
        elif k == 'punct' and v == '(':
            ops.append('('); depth += 1; pos += 1
        elif k == 'punct' and v == ')':
            while ops and ops[-1] != '(': apply(ops.pop())
            if ops: ops.pop()
            depth -= 1; pos += 1
        elif k == 'op':
            while ops and ops[-1] != '(' and PREC[ops[-1]] >= PREC[v]:
                apply(ops.pop())
            ops.append(v); pos += 1
        else:
            pos += 1
    while ops:
        o = ops.pop()
        if o != '(': apply(o)
    return pos


def compile_call(toks, pos, frame, funcs, em):
    fname = toks[pos][1]; pos += 2             # skip id and '('
    if toks[pos] != ('punct', ')'):
        while True:
            pos = compile_expr(toks, pos, frame, funcs, em, stops=(',', ')'))
            if toks[pos] == ('punct', ','): pos += 1; continue
            break
    pos += 1                                   # ')'
    em.i(f"bl {fname}")                        # args on value stack; result left on it
    return pos


# ---------------------------------------------------------------------------
# statement / body codegen
# ---------------------------------------------------------------------------
def emit_epilogue(em):
    em.i("sub x11 x10 16")                     # pop frame (x11 back to save area base)
    em.i("add x1 x11 8")
    em.i("ldr x30 x1")                         # restore return address
    em.i("ldr x10 x11")                        # restore caller frame
    em.i("ret")


def compile_body(em, body, frame, funcs):
    blocks = []
    p = 0
    def store_to(name):
        off = frame.offset_of(name)
        em.i("sub x9 x9 8"); em.i("ldr x0 x9"); em.i(f"add x1 x10 {off:04d}"); em.i("str x0 x1")
    while p < len(body):
        t = body[p]
        if t == ('punct', '}'):
            blk = blocks.pop()
            if blk[0] == 'if':
                em.patch(blk[1], f"b.eq @{em.pc():06d}")
            else:
                em.i(f"b @{blk[1]:06d}")
                em.patch(blk[2], f"b.eq @{em.pc():06d}")
            p += 1
        elif t == ('kw', 'int'):
            name = body[p+1][1]; frame.declare(name); p += 3
            p = compile_expr(body, p, frame, funcs, em, stops=(';',)); store_to(name); p += 1
        elif t == ('kw', 'return'):
            p = compile_expr(body, p+1, frame, funcs, em, stops=(';',))
            emit_epilogue(em); p += 1
        elif t == ('kw', 'if'):
            p = compile_expr(body, p+1, frame, funcs, em, stops=('{',))
            em.i("sub x9 x9 8"); em.i("ldr x0 x9"); em.i("cmp x0 0")
            s = em.slot("b.eq @000000"); blocks.append(('if', s)); p += 1
        elif t == ('kw', 'while'):
            top = em.pc()
            p = compile_expr(body, p+1, frame, funcs, em, stops=('{',))
            em.i("sub x9 x9 8"); em.i("ldr x0 x9"); em.i("cmp x0 0")
            s = em.slot("b.eq @000000"); blocks.append(('while', top, s)); p += 1
        elif t[0] == 'id':
            name = t[1]; p += 2
            p = compile_expr(body, p, frame, funcs, em, stops=(';',)); store_to(name); p += 1
        else:
            p += 1


def compile_function(em, fname, params, body, funcs):
    frame = Frame()
    for pn in params:
        frame.declare(pn, kind='param')
    nlocals = sum(1 for t in body if t == ('kw', 'int'))
    bump = frame_bump(len(params) + nlocals)
    em.lbl(fname)
    em.i("str x10 x11")                        # save caller frame
    em.i("add x1 x11 8"); em.i("str x30 x1")   # save return address
    em.i("add x10 x11 16")                     # new frame base
    em.i(f"add x11 x11 {bump}")                # reserve frame (16-aligned)
    for idx in reversed(range(len(params))):   # pop args -> param slots (reverse)
        em.i("sub x9 x9 8"); em.i("ldr x0 x9")
        em.i(f"add x1 x10 {idx*8:04d}"); em.i("str x0 x1")
    compile_body(em, body, frame, funcs)
    em.i("mov x0 0"); em.i("str x0 x9"); em.i("add x9 x9 8")   # fallthrough: return 0
    emit_epilogue(em)


def compile_program(src):
    toks = lex(src)
    funcs, order = parse_functions(toks)
    em = Emit()
    # prologue: brk, then value stack (x9), frame stack (x11), then call main
    for s in ("mov x0 0", "mov x8 214", "svc",
              "mov x2 x0", "mov x9 x2",
              "mov x1 32768", "add x11 x2 x1",
              "mov x1 0", "movk x1 1 16", "add x0 x2 x1",
              "mov x8 214", "svc",
              "bl main",
              "sub x9 x9 8", "ldr x0 x9", "mov x8 93", "svc"):
        em.i(s)
    for name in order:
        params, body = funcs[name]
        compile_function(em, name, params, body, funcs)
    return em.text()


# ---------------------------------------------------------------------------
# oracle: an independent interpreter (functions + recursion), exit = main()&0xff
# ---------------------------------------------------------------------------
class _Ret(Exception):
    def __init__(self, v): self.v = v

def evaluate(src):
    toks = lex(src)
    funcs, _ = parse_functions(toks)
    M = 0xFFFFFFFFFFFFFFFF

    def binop(o, a, b):
        a &= M; b &= M
        if   o == '<':  return 1 if a <  b else 0
        elif o == '>':  return 1 if a >  b else 0
        elif o == '<=': return 1 if a <= b else 0
        elif o == '>=': return 1 if a >= b else 0
        elif o == '==': return 1 if a == b else 0
        elif o == '!=': return 1 if a != b else 0
        elif o == '+':  return (a + b) & M
        elif o == '-':  return (a - b) & M
        elif o == '/':  return (a // b) & M if b else 0   # unsigned; aarch64 /0 -> 0
        elif o == '%':  return (a - (a // b) * b) & M if b else 0
        else:           return (a * b) & M

    def ev_expr(t, pos, env, stops):
        out = []; ops = []; depth = 0
        def popop():
            o = ops.pop(); b = out.pop(); a = out.pop(); out.append(binop(o, a, b))
        while pos < len(t):
            k, v = t[pos]
            if k == 'punct' and depth == 0 and v in stops: break
            if k == 'num':
                out.append(int(v) & M); pos += 1
            elif k == 'id':
                if pos + 1 < len(t) and t[pos+1] == ('punct', '('):
                    val, pos = ev_call(t, pos, env); out.append(val)
                else:
                    out.append(env.get(v, 0) & M); pos += 1
            elif k == 'punct' and v == '(':
                ops.append('('); depth += 1; pos += 1
            elif k == 'punct' and v == ')':
                while ops and ops[-1] != '(': popop()
                if ops: ops.pop()
                depth -= 1; pos += 1
            elif k == 'op':
                while ops and ops[-1] != '(' and PREC[ops[-1]] >= PREC[v]: popop()
                ops.append(v); pos += 1
            else:
                pos += 1
        while ops:
            if ops[-1] == '(':
                ops.pop()
            else:
                popop()
        return (out[-1] if out else 0) & M, pos

    def ev_call(t, pos, env):
        fname = t[pos][1]; pos += 2
        args = []
        if t[pos] != ('punct', ')'):
            while True:
                val, pos = ev_expr(t, pos, env, stops=(',', ')'))
                args.append(val)
                if t[pos] == ('punct', ','): pos += 1; continue
                break
        pos += 1
        return call(fname, args), pos

    def run_body(body, env):
        i = 0
        while i < len(body):
            t = body[i]
            if t == ('kw', 'int'):
                name = body[i+1][1]; i += 3
                val, i = ev_expr(body, i, env, stops=(';',)); env[name] = val; i += 1
            elif t == ('kw', 'return'):
                val, i = ev_expr(body, i+1, env, stops=(';',)); raise _Ret(val)
            elif t == ('kw', 'if'):
                val, i = ev_expr(body, i+1, env, stops=('{',))
                bs = i + 1; be = match_brace(body, i)
                if val != 0: run_body(body[bs:be], env)
                i = be + 1
            elif t == ('kw', 'while'):
                cs = i + 1
                _, ce = ev_expr(body, i+1, env, stops=('{',))
                bs = ce + 1; be = match_brace(body, ce); guard = 0
                while True:
                    val, _ = ev_expr(body, cs, env, stops=('{',))
                    if val == 0: break
                    run_body(body[bs:be], env); guard += 1
                    if guard > 2000000: raise RuntimeError("oracle runaway")
                i = be + 1
            elif t[0] == 'id':
                name = t[1]; i += 2
                val, i = ev_expr(body, i, env, stops=(';',)); env[name] = val; i += 1
            else:
                i += 1

    def call(name, args):
        params, body = funcs[name]
        env = dict(zip(params, args))
        try:
            run_body(body, env)
        except _Ret as r:
            return r.v & M
        return 0

    return call('main', []) & 0xff
