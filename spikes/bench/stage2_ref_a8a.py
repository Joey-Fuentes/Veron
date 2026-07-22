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

KEYWORDS = {'int', 'char', 'return', 'if', 'while', 'else', 'struct', 'sizeof'}
TWO_OPS  = {'<=', '>=', '==', '!=', '<<', '>>', '->'}
PREC = {'|':4, '&':6, '==':7, '!=':7, '<':8, '>':8, '<=':8, '>=':8,
        '<<':9, '>>':9, '+':10, '-':10, '*':11, '/':11, '%':11,
        'u-':12, 'u!':12, 'u~':12}


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
        if c == "'":                            # char literal -> its ASCII value
            if src[i+1] == '\\':
                m = {'n':10, 't':9, '0':0, 'r':13, '\\':92, "'":39}
                toks.append(('num', str(m[src[i+2]]))); i += 4; continue
            toks.append(('num', str(ord(src[i+1])))); i += 3; continue
        if c == '"':                            # string literal -> ('str', decoded)
            j = i + 1; buf = []
            while src[j] != '"':
                if src[j] == '\\':
                    m = {'n':10, 't':9, '0':0, 'r':13, '\\':92, '"':34, "'":39}
                    buf.append(chr(m[src[j+1]])); j += 2
                else:
                    buf.append(src[j]); j += 1
            toks.append(('str', ''.join(buf))); i = j + 1; continue
        if src[i:i+2] in TWO_OPS:
            toks.append(('op', src[i:i+2])); i += 2; continue
        if c in '+-*/%<>&!~|.':
            toks.append(('op', c)); i += 1; continue
        if c in '(){}[];=,':
            toks.append(('punct', c)); i += 1; continue
        i += 1
    return toks


# ---------------------------------------------------------------------------
# symbol table + declaration-order frame allocator (now LIVE)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# struct type table (A8a): file-scope `struct Tag { field; ... };` definitions.
# LAYOUT CHOICE: every field is one 64-bit word (offset = field_index*8, struct
# size = nfields*8). This keeps every field naturally aligned so plain `ldr x`/
# `str x` at [Xn] is always valid, and — since the compiler only ever talks to
# itself and to programs it compiles — is a perfectly self-consistent ABI. char
# fields are word-stored (like char scalars already are). Field types allowed:
# int, char, int*, char*, and struct-Tag* pointers (which is what makes linked
# structures — the symbol tables / AST nodes a self-hosted stage 2 needs — work).
# Nested struct *value* fields and array fields are out of subset (they would
# break one-word-per-field); struct *pointer* fields are in.
STRUCTS = {}                                   # tag -> StructType

class Field:
    __slots__ = ('name', 'off', 'is_char', 'is_ptr', 'stag')
    def __init__(self, name, off, is_char, is_ptr, stag):
        self.name, self.off, self.is_char, self.is_ptr, self.stag = name, off, is_char, is_ptr, stag

class StructType:
    __slots__ = ('tag', 'fields', 'size')
    def __init__(self, tag, fields, size):
        self.tag, self.fields, self.size = tag, fields, size   # fields: dict name->Field

class Sym:
    __slots__ = ('name', 'kind', 'size', 'is_char', 'is_ptr', 'off', 'stag')
    def __init__(self, name, kind, size, is_char, off, is_ptr=False, stag=None):
        self.name, self.kind, self.size, self.is_char, self.off = name, kind, size, is_char, off
        self.is_ptr = is_ptr                   # declared with '*' (indirection level 1)
        self.stag = stag                       # struct tag if this is a struct value/pointer

class Frame:
    def __init__(self):
        self.by_name = {}
        self.next_off = 0
    def declare(self, name, kind='local', size=8, is_char=False, is_ptr=False, stag=None):
        s = Sym(name, kind, size, is_char, self.next_off, is_ptr, stag)
        self.by_name[name] = s
        self.next_off += size
        return s
    def offset_of(self, name):
        return self.by_name[name].off          # requires prior declaration
    def is_array(self, name):
        return self.by_name[name].kind == 'array'
    def is_char(self, name):
        return self.by_name[name].is_char
    def is_ptr(self, name):
        return self.by_name[name].is_ptr
    def nslots(self):
        return self.next_off // 8


# ---------------------------------------------------------------------------
# emitter: tracks instruction count so numeric branch targets skip label lines
# ---------------------------------------------------------------------------
class Emit:
    def __init__(self):
        self.lines = []
        self.ic = 0                            # instruction count (labels are 0 bytes)
        self.data = []                         # static data section, emitted AFTER code
        self.datacount = 0                     # anonymous-data label counter (__dN)
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
    def add_data(self, byte_values, label=None):
        # Append a labeled run of bytes to the static data section (addressed by
        # `adr`). label=None -> generate __dN (anonymous, e.g. string literals);
        # a caller-supplied label serves named data (globals, next milestone).
        if label is None:
            label = f"__d{self.datacount}"; self.datacount += 1
        self.data.append(":" + label)
        for b in byte_values:
            self.data.append(f".byte {b & 0xFF}")
        return label
    def add_string(self, sval):                # null-terminated string -> label
        return self.add_data([ord(c) for c in sval] + [0])
    def text(self):
        # code first, then the data section; stage1 resolves data labels (forward
        # refs) to numeric positions past the code, `adr` reaches them PC-relative.
        return "\n".join(self.lines + self.data) + "\n"


def frame_bump(nslots):
    # 16-byte save area + word slots, padded so the frame stack stays 16-aligned
    total = 16 + nslots * 8
    return (total + 15) // 16 * 16


# ---------------------------------------------------------------------------
# parser: split the program into functions
# ---------------------------------------------------------------------------
GLOBALS = {}                                   # name -> GSym (file-scope variables)

class GSym:
    __slots__ = ('is_char', 'is_array', 'size', 'init', 'is_ptr', 'stag')
    def __init__(self, is_char, is_array, size, init, is_ptr=False, stag=None):
        self.is_char, self.is_array, self.size, self.init = is_char, is_array, size, init
        self.is_ptr = is_ptr
        self.stag = stag                       # struct tag if this is a struct value/pointer global

def _stag(frame, name):                        # struct tag of a variable (frame first, then globals)
    if name in frame.by_name: return frame.by_name[name].stag
    return GLOBALS[name].stag if name in GLOBALS else None

def _is_char(frame, name):                     # char? (frame first, then globals)
    if name in frame.by_name: return frame.is_char(name)
    return GLOBALS[name].is_char

def _is_array(frame, name):
    if name in frame.by_name: return frame.is_array(name)
    return GLOBALS[name].is_array

def _is_ptr(frame, name):                      # declared pointer? (frame first, then globals)
    if name in frame.by_name: return frame.by_name[name].is_ptr
    return GLOBALS[name].is_ptr

# --- the type descriptor the roadmap called for, in its minimal useful form ---
# A value's "ptype" = the pointee/element size to scale by when it is used as the
# pointer operand of + or -, or 0 when it is a plain (non-pointer) word.
#   char*/char[]  -> 1      int*/int[]/other ptr -> 8      plain int/char -> 0
def _elem_size(frame, name):                   # element/pointee size of an array or pointer
    return 1 if _is_char(frame, name) else 8

def _ptype_var(frame, name):                   # ptype produced by reading a variable
    if _is_array(frame, name): return _elem_size(frame, name)   # array decays to elem ptr
    if _is_ptr(frame, name):   return _elem_size(frame, name)   # pointer value
    return 0                                                    # plain scalar

def _ptype_addr(frame, name):                  # ptype of &name (address-of a scalar)
    # &char_scalar -> char* (1); &int / &ptr / &array -> word-pointee (8)
    if _is_char(frame, name) and not _is_ptr(frame, name) and not _is_array(frame, name):
        return 1
    return 8

def _emit_addr(em, frame, reg, name):          # address of name -> reg
    if name in frame.by_name:
        em.i(f"add {reg} x10 {frame.offset_of(name):04d}")   # local: frame-relative
    else:
        em.i(f"adr {reg} g_{name}")                          # global: data-section label

def _parse_struct_def(toks, i):
    # i at ('kw','struct'); toks[i+1]=tag ; toks[i+2]='{'.  Each field is one word.
    tag = toks[i+1][1]; j = i + 3
    fields = {}; foff = 0
    while toks[j] != ('punct', '}'):
        fic = False; fip = False; fstag = None
        if   toks[j] == ('kw', 'int'):  j += 1
        elif toks[j] == ('kw', 'char'): fic = True; j += 1
        elif toks[j] == ('kw', 'struct'): fstag = toks[j+1][1]; j += 2   # struct Tag2* field
        if toks[j] == ('op', '*'): fip = True; j += 1
        fname = toks[j][1]; j += 1
        fields[fname] = Field(fname, foff, fic, fip, fstag)
        foff += 8                                              # one word per field
        if toks[j] == ('punct', ';'): j += 1
    STRUCTS[tag] = StructType(tag, fields, foff)
    j += 1                                                     # past '}'
    if j < len(toks) and toks[j] == ('punct', ';'): j += 1
    return j

def parse_program(toks):
    # file scope is a mix of struct type definitions, function definitions, and
    # global declarations. A type is int/char/`struct Tag` (+ optional '*'); a '('
    # after the name marks a function, otherwise it's a global.
    funcs = {}; order = []; gorder = []
    i = 0
    while i < len(toks):
        ti = toks[i]
        if ti == ('kw','struct') and i+2 < len(toks) and toks[i+2] == ('punct','{'):
            i = _parse_struct_def(toks, i); continue          # ---- struct definition ----
        if ti not in (('kw','int'), ('kw','char'), ('kw','struct')):
            i += 1; continue
        ischar = (ti == ('kw','char')); stag = None
        if ti == ('kw','struct'): stag = toks[i+1][1]; i += 2  # `struct Tag` type
        else: i += 1
        isptr = False
        if toks[i] == ('op','*'): isptr = True; i += 1
        name = toks[i][1]; i += 1
        if toks[i] == ('punct','('):                         # ---- function ----
            i += 1
            params = []
            while toks[i] != ('punct',')'):
                pc = False; pp = False; ps = None
                if   toks[i] == ('kw','int'): i += 1
                elif toks[i] == ('kw','char'): pc = True; i += 1
                elif toks[i] == ('kw','struct'): ps = toks[i+1][1]; i += 2
                if toks[i] == ('op','*'): pp = True; i += 1
                if toks[i][0] == 'id': params.append((toks[i][1], pc, pp, ps)); i += 1
                if toks[i] == ('punct',','): i += 1
            i += 1                                           # ')'
            depth = 0; j = i
            while j < len(toks):
                if   toks[j] == ('punct','{'): depth += 1
                elif toks[j] == ('punct','}'):
                    depth -= 1
                    if depth == 0: break
                j += 1
            funcs[name] = (params, toks[i+1:j]); order.append(name); i = j + 1
        else:                                                # ---- global ----
            if toks[i] == ('punct','['):
                n = int(toks[i+1][1])
                sz = (((n + 7)//8)*8) if ischar else n*8
                GLOBALS[name] = GSym(ischar, True, sz, None, is_ptr=isptr, stag=stag); i += 4  # [ N ] ;
            elif toks[i] == ('punct','='):
                GLOBALS[name] = GSym(ischar, False, 8, int(toks[i+1][1]), is_ptr=isptr, stag=stag); i += 3  # = num ;
            elif stag and not isptr:                          # struct VALUE global -> full size
                GLOBALS[name] = GSym(False, False, STRUCTS[stag].size, None, is_ptr=False, stag=stag); i += 1
            else:
                GLOBALS[name] = GSym(ischar, False, 8, None, is_ptr=isptr, stag=stag); i += 1  # ;
            gorder.append(name)
    return funcs, order, gorder

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
            ischar = False; isptr = False
            if toks[i] == ('kw', 'int'): i += 1
            elif toks[i] == ('kw', 'char'): ischar = True; i += 1
            if toks[i] == ('op', '*'): isptr = True; i += 1   # pointer param (word-sized)
            if toks[i][0] == 'id':
                params.append((toks[i][1], ischar, isptr)); i += 1
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
# ---------------------------------------------------------------------------
# struct member access (A8a) — a SYNTACTIC parser walk. A `.`/`->` chain that
# starts at a declared name is resolved statically: the struct tag of each step
# comes from the previous field's declared type, so no runtime type stack is
# needed (member access threads its type through the parser, like a[i]/*p do).
#   base:  struct value  -> address = &name ;  struct pointer -> address = *name
#   each field: x1 += field_offset ; if not the last field, follow the pointer
#   (ldr x1 x1) into the next struct. `.` and `->` are treated identically at
#   codegen — correctness comes from the base kind + following pointers between
#   steps. A field is one word: char fields byte-loaded, the rest word-loaded.
# ---------------------------------------------------------------------------
def collect_member_chain(toks, pos):           # pos at first '.'/'->'; returns (fields, pos-after)
    chain = []
    while pos < len(toks) and toks[pos] in (('op', '.'), ('op', '->')):
        chain.append(toks[pos+1][1]); pos += 2
    return chain, pos

def emit_member_addr(em, frame, name, chain):  # leaves &(last field) in x1; returns last Field
    if _is_ptr(frame, name):                   # struct pointer: base address = its value
        _emit_addr(em, frame, "x1", name); em.i("ldr x1 x1")
    else:                                      # struct value: base address = &name
        _emit_addr(em, frame, "x1", name)
    tag = _stag(frame, name); fl = None
    for k, fname in enumerate(chain):
        fl = STRUCTS[tag].fields[fname]
        if fl.off: em.i(f"add x1 x1 {fl.off}")            # x1 = &field (off = idx*8)
        if k != len(chain) - 1:                           # intermediate: follow pointer field
            em.i("ldr x1 x1"); tag = fl.stag
    return fl

def _ptype_member(fl):                         # ptype of a loaded field value
    if fl.is_ptr and fl.stag is None:          # int*/char* field -> its pointee size
        return 1 if fl.is_char else 8
    return 0                                   # plain, or struct* (struct-ptr arith out of subset)


def compile_expr(toks, pos, frame, funcs, em, stops):
    ops = []; depth = 0
    expect_operand = True                       # True where a unary * / & or value may start
    tstack = []                                 # compile-time type stack, MIRRORS the
                                                # runtime value stack: each entry is the
                                                # value's ptype (0=plain, else pointee size).
    def tpush(t): tstack.append(t)

    def push_num(nstr):
        em.i(f"mov x0 {nstr}"); em.i("str x0 x9"); em.i("add x9 x9 8"); tpush(0)

    def push_var(name):
        if _is_array(frame, name):              # array name decays to &a[0]
            _emit_addr(em, frame, "x0", name); em.i("str x0 x9"); em.i("add x9 x9 8")
        else:
            _emit_addr(em, frame, "x1", name); em.i("ldr x0 x1"); em.i("str x0 x9"); em.i("add x9 x9 8")
        tpush(_ptype_var(frame, name))

    def emit_base_x1(name):                     # base address into x1
        _emit_addr(em, frame, "x1", name)                   # array: base = its address
        if not _is_array(frame, name): em.i("ldr x1 x1")    # pointer: base = its value

    def push_subscript(name):                   # a[i] rvalue (index already pushed)
        em.i("sub x9 x9 8"); em.i("ldr x2 x9")              # pop index
        emit_base_x1(name)
        if _is_char(frame, name):                           # char: byte at base+index
            em.i("ldrb w0 x1 x2")
        else:                                               # int: word at base + index*8
            em.i("mov x3 3"); em.i("lsl x2 x2 x3"); em.i("add x1 x1 x2"); em.i("ldr x0 x1")
        em.i("str x0 x9"); em.i("add x9 x9 8")
        tpush(0)                                            # element value (plain); index was
                                                            # compiled by a nested compile_expr
                                                            # (its own tstack), so nothing to pop

    def push_elem_addr(name):                   # &a[i] (index already pushed)
        em.i("sub x9 x9 8"); em.i("ldr x2 x9")
        emit_base_x1(name)
        if not _is_char(frame, name): em.i("mov x3 3"); em.i("lsl x2 x2 x3")
        em.i("add x1 x1 x2")
        em.i("mov x0 x1"); em.i("str x0 x9"); em.i("add x9 x9 8")
        tpush(_elem_size(frame, name))                      # -> pointer to element (index on
                                                            # nested tstack, nothing to pop)

    def push_addr(name):                        # &name -> push the variable's address
        _emit_addr(em, frame, "x0", name); em.i("str x0 x9"); em.i("add x9 x9 8")
        tpush(_ptype_addr(frame, name))

    def push_deref(name):                       # *name -> load through the pointer
        _emit_addr(em, frame, "x1", name); em.i("ldr x1 x1")
        if _is_char(frame, name):
            em.i("mov x2 0"); em.i("ldrb w0 x1 x2")
        else:
            em.i("ldr x0 x1")
        em.i("str x0 x9"); em.i("add x9 x9 8"); tpush(0)    # pointee value (plain, in subset)

    def push_member(name, chain):               # name.f / p->f / a->b->c  (rvalue)
        fl = emit_member_addr(em, frame, name, chain)       # x1 = &field
        if fl.is_char and not fl.is_ptr:
            em.i("mov x2 0"); em.i("ldrb w0 x1 x2")         # char field: byte load
        else:
            em.i("ldr x0 x1")                               # word load
        em.i("str x0 x9"); em.i("add x9 x9 8"); tpush(_ptype_member(fl))

    def push_member_addr(name, chain):          # &(name.f) — address of a member
        fl = emit_member_addr(em, frame, name, chain)       # x1 = &field
        em.i("mov x0 x1"); em.i("str x0 x9"); em.i("add x9 x9 8")
        tpush(1 if (fl.is_char and not fl.is_ptr) else 8)

    def scale(reg, sz):                          # reg *= sz  (sz in {1,8}); 1 is a no-op
        if sz == 8: em.i("mov x3 3"); em.i(f"lsl {reg} {reg} x3")

    def apply(o):
        if o in ('u-', 'u!', 'u~'):             # unary: pop one, push one
            em.i("sub x9 x9 8"); em.i("ldr x0 x9")
            if   o == 'u-': [em.i(x) for x in ("mov x2 0", "sub x0 x2 x0")]
            elif o == 'u~': [em.i(x) for x in ("mov x2 0", "sub x0 x2 x0", "mov x2 1", "sub x0 x0 x2")]
            else:           [em.i(x) for x in ("mov x2 0", "sub x2 x2 x0", "orr x0 x0 x2",
                                               "mov x2 63", "lsr x0 x0 x2", "mov x2 1", "sub x0 x2 x0")]
            em.i("str x0 x9"); em.i("add x9 x9 8")
            tstack.pop(); tpush(0); return
        em.i("sub x9 x9 8"); em.i("ldr x0 x9"); em.i("sub x9 x9 8"); em.i("ldr x1 x9")
        tb = tstack.pop(); ta = tstack.pop()    # rhs=x0 type, lhs=x1 type
        # --- pointer arithmetic: scale the integer operand by the pointee size ---
        if o == '+':
            if   ta and not tb: scale("x0", ta); em.i("add x0 x1 x0"); em.i("str x0 x9"); em.i("add x9 x9 8"); tpush(ta); return
            elif tb and not ta: scale("x1", tb); em.i("add x0 x1 x0"); em.i("str x0 x9"); em.i("add x9 x9 8"); tpush(tb); return
        elif o == '-':
            if   ta and not tb: scale("x0", ta); em.i("sub x0 x1 x0"); em.i("str x0 x9"); em.i("add x9 x9 8"); tpush(ta); return
            elif ta and tb:     # pointer difference: byte-diff / pointee size -> plain int
                em.i("sub x0 x1 x0")
                if ta == 8: em.i("mov x3 3"); em.i("lsr x0 x0 x3")
                em.i("str x0 x9"); em.i("add x9 x9 8"); tpush(0); return
        tpush(0)                                 # every other result is a plain word
        if   o == '<':  [em.i(s) for s in ("sub x0 x1 x0", "mov x2 63", "lsr x0 x0 x2")]
        elif o == '>':  [em.i(s) for s in ("sub x0 x0 x1", "mov x2 63", "lsr x0 x0 x2")]
        elif o == '<=': [em.i(s) for s in ("sub x0 x0 x1", "mov x2 63", "lsr x0 x0 x2", "mov x2 1", "sub x0 x2 x0")]
        elif o == '>=': [em.i(s) for s in ("sub x0 x1 x0", "mov x2 63", "lsr x0 x0 x2", "mov x2 1", "sub x0 x2 x0")]
        elif o == '!=': [em.i(s) for s in ("sub x0 x1 x0", "mov x2 0", "sub x2 x2 x0", "orr x0 x0 x2", "mov x2 63", "lsr x0 x0 x2")]
        elif o == '==': [em.i(s) for s in ("sub x0 x1 x0", "mov x2 0", "sub x2 x2 x0", "orr x0 x0 x2", "mov x2 63", "lsr x0 x0 x2", "mov x2 1", "sub x0 x2 x0")]
        elif o == '&':  em.i("and x0 x1 x0")
        elif o == '|':  em.i("orr x0 x1 x0")
        elif o == '<<': em.i("lsl x0 x1 x0")
        elif o == '>>': em.i("lsr x0 x1 x0")
        elif o == '/':  em.i("udiv x0 x1 x0")
        elif o == '%':  [em.i(t) for t in ("udiv x2 x1 x0", "mul x2 x2 x0", "sub x0 x1 x2")]
        else:           em.i({'+':"add x0 x1 x0", '-':"sub x0 x1 x0", '*':"mul x0 x1 x0"}[o])
        em.i("str x0 x9"); em.i("add x9 x9 8")

    while pos < len(toks):
        k, v = toks[pos]
        if k == 'punct' and depth == 0 and v in stops:
            break
        if k == 'num':
            push_num(v); pos += 1; expect_operand = False
        elif k == 'kw' and v == 'sizeof':       # sizeof ( int|char|struct Tag [*] ) -> const
            j = pos + 2                          # skip 'sizeof' '('
            sz = 8
            if   toks[j] == ('kw', 'char'): sz = 1; j += 1
            elif toks[j] == ('kw', 'int'):  sz = 8; j += 1
            elif toks[j] == ('kw', 'struct'): sz = STRUCTS[toks[j+1][1]].size; j += 2
            if toks[j] == ('op', '*'): sz = 8; j += 1        # any pointer -> one word
            j += 1                               # skip ')'
            push_num(str(sz)); pos = j; expect_operand = False
        elif k == 'str':                        # "..." -> char* to data-section bytes
            label = em.add_string(v)
            em.i(f"adr x0 {label}"); em.i("str x0 x9"); em.i("add x9 x9 8"); tpush(1)
            pos += 1; expect_operand = False
        elif k == 'op' and v == '&' and expect_operand:
            nm = toks[pos+1][1]
            if pos + 2 < len(toks) and toks[pos+2] == ('punct', '['):
                pos = compile_expr(toks, pos+3, frame, funcs, em, stops=(']',))
                pos += 1; push_elem_addr(nm)               # skip ']'
            elif pos + 2 < len(toks) and toks[pos+2] in (('op', '.'), ('op', '->')):
                chain, pos = collect_member_chain(toks, pos+2)   # &(name.f)
                push_member_addr(nm, chain)
            else:
                push_addr(nm); pos += 2
            expect_operand = False
        elif k == 'op' and v == '*' and expect_operand:
            push_deref(toks[pos+1][1]); pos += 2; expect_operand = False
        elif k == 'op' and v in ('-', '!', '~') and expect_operand:
            ops.append('u' + v); pos += 1        # unary prefix; still expecting an operand
        elif k == 'id':
            if pos + 1 < len(toks) and toks[pos+1] == ('punct', '('):
                pos = compile_call(toks, pos, frame, funcs, em)   # result pushed by callee
                tpush(0)                                          # return value is a plain int
            elif pos + 1 < len(toks) and toks[pos+1] == ('punct', '['):
                nm = v
                pos = compile_expr(toks, pos+2, frame, funcs, em, stops=(']',))
                pos += 1; push_subscript(nm)                # skip ']'
            elif pos + 1 < len(toks) and toks[pos+1] in (('op', '.'), ('op', '->')):
                chain, pos = collect_member_chain(toks, pos+1)    # name.f / p->f / chains
                push_member(v, chain)
            else:
                push_var(v); pos += 1
            expect_operand = False
        elif k == 'punct' and v == '(':
            ops.append('('); depth += 1; pos += 1; expect_operand = True
        elif k == 'punct' and v == ')':
            while ops and ops[-1] != '(': apply(ops.pop())
            if ops: ops.pop()
            depth -= 1; pos += 1; expect_operand = False
        elif k == 'op':                         # binary operator
            while ops and ops[-1] != '(' and PREC[ops[-1]] >= PREC[v]:
                apply(ops.pop())
            ops.append(v); pos += 1; expect_operand = True
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
        em.i("sub x9 x9 8"); em.i("ldr x0 x9"); _emit_addr(em, frame, "x1", name); em.i("str x0 x1")
    def emit_subscript_store(name):             # stack: [index, value] -> mem[base+i] = value
        em.i("sub x9 x9 8"); em.i("ldr x0 x9")             # pop value
        em.i("sub x9 x9 8"); em.i("ldr x2 x9")             # pop index
        _emit_addr(em, frame, "x1", name)
        if not _is_array(frame, name): em.i("ldr x1 x1")
        if _is_char(frame, name):
            em.i("strb w0 x1 x2")
        else:
            em.i("mov x3 3"); em.i("lsl x2 x2 x3"); em.i("add x1 x1 x2"); em.i("str x0 x1")
    def emit_member_store(name, chain):         # value already on the value stack -> field
        fl = emit_member_addr(em, frame, name, chain)      # x1 = &field (uses x1; not the stack)
        em.i("sub x9 x9 8"); em.i("ldr x0 x9")             # pop value
        if fl.is_char and not fl.is_ptr:
            em.i("mov x2 0"); em.i("strb w0 x1 x2")
        else:
            em.i("str x0 x1")
    while p < len(body):
        t = body[p]
        if t == ('punct', '}'):
            blk = blocks.pop()
            if blk[0] == 'if':
                if p + 1 < len(body) and body[p+1] == ('kw', 'else'):
                    s2 = em.slot("b @000000")                    # skip else-body after then
                    em.patch(blk[1], f"b.eq @{em.pc():06d}")     # cond false -> else-body
                    blocks.append(('else', s2))
                    p += 2                                       # consume  }  else
                    if p < len(body) and body[p] == ('punct', '{'):
                        p += 1                                   # consume  {
                    continue
                em.patch(blk[1], f"b.eq @{em.pc():06d}")
            elif blk[0] == 'else':
                em.patch(blk[1], f"b @{em.pc():06d}")            # end of else-body
            else:                                               # while
                em.i(f"b @{blk[1]:06d}")
                em.patch(blk[2], f"b.eq @{em.pc():06d}")
            p += 1
        elif t in (('kw', 'int'), ('kw', 'char')):
            ischar = (t == ('kw', 'char'))
            q = p + 1; isptr = False
            if body[q] == ('op', '*'): isptr = True; q += 1  # pointer decl (word-sized)
            name = body[q][1]; q += 1
            if body[q] == ('punct', '['):                  # NAME[ N ] — array
                n = int(body[q+1][1])
                sz = (((n + 7)//8)*8) if ischar else n*8   # char[N] byte-packed (8-aligned)
                frame.declare(name, kind='array', size=sz, is_char=ischar, is_ptr=isptr)
                p = q + 4                                  # skip  [ N ] ;
            else:
                frame.declare(name, is_char=ischar, is_ptr=isptr)
                if body[q] == ('punct', '='):
                    p = compile_expr(body, q + 1, frame, funcs, em, stops=(';',))
                    store_to(name); p += 1
                else:
                    p = q + 1                              # uninitialised
        elif t == ('kw', 'struct'):                         # struct Tag v;  /  struct Tag* p [= e];
            tag = body[p+1][1]; q = p + 2; isptr = False
            if body[q] == ('op', '*'): isptr = True; q += 1
            name = body[q][1]; q += 1
            if isptr:
                frame.declare(name, is_ptr=True, stag=tag)              # struct pointer (one word)
                if body[q] == ('punct', '='):
                    p = compile_expr(body, q + 1, frame, funcs, em, stops=(';',)); store_to(name); p += 1
                else:
                    p = q + 1
            else:
                frame.declare(name, kind='struct', size=STRUCTS[tag].size, stag=tag)  # value struct
                p = q + 1                                              # `struct T v;` (no initializer)
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
        elif t == ('op', '*'):                              # *name = expr
            name = body[p+1][1]; p += 3                     # skip  * name =
            p = compile_expr(body, p, frame, funcs, em, stops=(';',))
            _emit_addr(em, frame, "x1", name); em.i("ldr x1 x1")   # x1 = dest addr (pointer value)
            em.i("sub x9 x9 8"); em.i("ldr x0 x9")
            if _is_char(frame, name):
                em.i("mov x2 0"); em.i("strb w0 x1 x2")
            else:
                em.i("str x0 x1")
            p += 1
        elif t[0] == 'id':
            if body[p+1] == ('punct', '('):                # bare call statement: f(args);
                p = compile_call(body, p, frame, funcs, em) # callee pushes a return value
                em.i("sub x9 x9 8")                         # discard the unused result
                if p < len(body) and body[p] == ('punct', ';'): p += 1
            elif body[p+1] == ('punct', '['):              # a[expr] = e
                name = t[1]
                p = compile_expr(body, p+2, frame, funcs, em, stops=(']',))   # push index
                p += 2                                     # skip ']' '='
                p = compile_expr(body, p, frame, funcs, em, stops=(';',))     # push value
                emit_subscript_store(name); p += 1
            elif body[p+1] in (('op', '.'), ('op', '->')): # name.f = e / p->f = e / a->b->c = e
                name = t[1]
                chain, q = collect_member_chain(body, p+1)  # q now at '='
                p = compile_expr(body, q + 1, frame, funcs, em, stops=(';',))  # RHS -> value stack
                emit_member_store(name, chain); p += 1
            else:                                          # reassignment: name = expr;
                name = t[1]; p += 2
                p = compile_expr(body, p, frame, funcs, em, stops=(';',)); store_to(name); p += 1
        else:
            p += 1


def count_local_slots(body):
    # total local WORD slots, counting an int a[N] declaration as N slots (not 1),
    # so the prologue reserves a frame big enough for arrays.
    slots = 0; i = 0
    while i < len(body):
        if body[i] == ('kw', 'struct'):
            tag = body[i+1][1]; j = i + 2
            isptr = (body[j] == ('op', '*'))
            if isptr: j += 1
            slots += 1 if isptr else (STRUCTS[tag].size // 8)   # value struct -> its words
            i = j + 1                                            # name (';' handled by loop)
        elif body[i] in (('kw', 'int'), ('kw', 'char')):
            ischar = body[i] == ('kw', 'char')
            j = i + 1
            if body[j] == ('op', '*'): j += 1               # pointer decl
            if j + 1 < len(body) and body[j+1] == ('punct', '['):
                n = int(body[j+2][1])
                slots += ((n + 7)//8) if ischar else n      # char[N]: ceil(N/8) words
            else:
                slots += 1
            i = j + 1
        else:
            i += 1
    return slots

def compile_function(em, fname, params, body, funcs):
    frame = Frame()
    for pn, pc, pp, ps in params:
        frame.declare(pn, kind='param', is_char=pc, is_ptr=pp, stag=ps)
    bump = frame_bump(len(params) + count_local_slots(body))
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
    GLOBALS.clear()
    funcs, order, gorder = parse_program(toks)
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
    for gname in gorder:                        # emit global storage into the data section
        gs = GLOBALS[gname]
        if gs.init is not None:
            em.add_data([(gs.init >> (8*k)) & 0xFF for k in range(8)], label=f"g_{gname}")
        else:
            em.add_data([0] * gs.size, label=f"g_{gname}")
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
        elif o == '&':  return (a & b) & M
        elif o == '|':  return (a | b) & M
        elif o == '<<': return (a << b) & M
        elif o == '>>': return (a >> b) & M
        elif o == '/':  return (a // b) & M if b else 0   # unsigned; aarch64 /0 -> 0
        elif o == '%':  return (a - (a // b) * b) & M if b else 0
        else:           return (a * b) & M

    def ev_expr(t, pos, env, stops):
        out = []; ops = []; depth = 0; want = True
        def popop():
            o = ops.pop()
            if o in ('u-', 'u!', 'u~'):
                x = out.pop() & M
                out.append((-x) & M if o == 'u-' else ((~x) & M if o == 'u~' else (0 if x else 1)))
            else:
                b = out.pop(); a = out.pop(); out.append(binop(o, a, b))
        while pos < len(t):
            k, v = t[pos]
            if k == 'punct' and depth == 0 and v in stops: break
            if k == 'num':
                out.append(int(v) & M); pos += 1; want = False
            elif k == 'id':
                if pos + 1 < len(t) and t[pos+1] == ('punct', '('):
                    val, pos = ev_call(t, pos, env); out.append(val)
                else:
                    out.append(env.get(v, 0) & M); pos += 1
                want = False
            elif k == 'punct' and v == '(':
                ops.append('('); depth += 1; pos += 1; want = True
            elif k == 'punct' and v == ')':
                while ops and ops[-1] != '(': popop()
                if ops: ops.pop()
                depth -= 1; pos += 1; want = False
            elif k == 'op' and v in ('-', '!', '~') and want:
                ops.append('u' + v); pos += 1
            elif k == 'op':
                while ops and ops[-1] != '(' and PREC[ops[-1]] >= PREC[v]: popop()
                ops.append(v); pos += 1; want = True
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
        env = dict(zip([p[0] for p in params], args))
        try:
            run_body(body, env)
        except _Ret as r:
            return r.v & M
        return 0

    return call('main', []) & 0xff
