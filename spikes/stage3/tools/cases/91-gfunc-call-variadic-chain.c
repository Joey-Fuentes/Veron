/* AARCH64 ONLY
 * a bitfield WRITE emits aarch64 mnemonics literally, so amd64 cannot assemble it
 *
 * BITMASK
 *
 * The first two executable lines of arm64-gen.c gfunc_call, which is the
 * function the CI trail dies inside:
 *
 *     int variadic = (vtop[-nb_args].type.ref->f.func_type == FUNC_ELLIPSIS);
 *     int var_nb_arg = n_func_args(&vtop[-nb_args].type);
 *     save_regs(nb_args + 1);                      <- the last marker that fires
 *     ...
 *     stack = arm64_pcs(variadic ? var_nb_arg : 0, nb_args, t, a);
 *
 * `f` is not a plain member. In tcc.h it is reached through
 * union > anonymous struct > anonymous union, and `func_type` is a two-bit
 * bitfield at bit offset 3 of that unit. Getting to it from `vtop` costs a
 * NEGATIVE index, a member, a pointer member, an arrow, three levels of
 * anonymous aggregate and a bitfield extract -- and every one of those has
 * been wrong in micro-c at some point.
 *
 * Case 73 covers `sym->type.ref->f.func_ctor`: a chain, but a POSITIVE one
 * from a plain pointer, and only two levels of nesting. This adds the
 * negative index and Sym's real nesting depth, because gfunc_call uses both
 * and neither is covered anywhere in the suite.
 *
 * The declarations below are copied from tcc.h rather than simplified. A
 * simplified struct is a different struct, and layout is exactly what is in
 * question.
 */

struct FuncAttr {
    unsigned
    func_call   : 3,
    func_type   : 2,
    func_noreturn : 1,
    func_ctor   : 1,
    func_dtor   : 1,
    func_args   : 8,
    func_alwinl : 1,
    xxxx        : 15;
};

struct SymAttr {
    unsigned short
    aligned     : 5,
    packed      : 1,
    weak        : 1,
    visibility  : 2,
    dllexport   : 1,
    nodecorate  : 1,
    dllimport   : 1,
    addrtaken   : 1,
    nodebug     : 1,
    xxxx        : 2;
};

typedef struct CType {
    int t;
    struct Sym *ref;
} CType;

typedef struct Sym {
    int v;
    unsigned short r;
    struct SymAttr a;
    union {
        struct {
            int c;
            union {
                int sym_scope;
                int jnext;
                int jind;
                struct FuncAttr f;
                int auxtype;
            };
        };
        long long enum_val;
        int *d;
        struct Sym *cleanup_func;
    };
    CType type;
    union {
        struct Sym *next;
        int *e;
        int asm_label;
    };
    struct Sym *prev;
} Sym;

typedef struct SValue {
    CType type;
    unsigned short r;
    unsigned short r2;
    int c;
} SValue;

#define FUNC_NEW      1
#define FUNC_ELLIPSIS 2

static SValue stack_[8];
static Sym syms_[8];
static SValue *vtop;

/* n_func_args, as tccgen.c writes it */
static int n_func_args(CType *type)
{
    int n = 0;
    Sym *s;
    s = type->ref;
    while (s->next) {
        n = n + 1;
        s = s->next;
    }
    return n;
}

static int read_through(CType **type, int n)
{
    int i;
    int sum = 0;
    for (i = 0; i <= n; i++)
        sum = sum + type[i]->t;
    return sum;
}

int main(void)
{
    int bits = 0;
    int nb_args = 2;
    CType *t[4];
    CType *return_type;
    int variadic;
    int i;

    for (i = 0; i < 8; i++) {
        syms_[i].v = i;
        syms_[i].c = 0;
        syms_[i].f.func_call = 0;
        syms_[i].f.func_type = 0;
        syms_[i].f.func_ctor = 0;
        syms_[i].type.t = 200 + i;
        syms_[i].type.ref = 0;
        syms_[i].next = 0;
        stack_[i].type.t = 100 + i;
        stack_[i].type.ref = &syms_[i];
        stack_[i].c = 0;
    }
    /* a two-argument function symbol: ref -> next -> next */
    syms_[3].next = &syms_[4];
    syms_[4].next = &syms_[5];
    syms_[3].f.func_type = FUNC_ELLIPSIS;
    syms_[3].f.func_call = 5;

    vtop = &stack_[5];      /* vtop[-2] is stack_[3] */

    /* 1: the bitfield, through the negative index and the whole chain */
    variadic = (vtop[-nb_args].type.ref->f.func_type == FUNC_ELLIPSIS);
    if (!variadic) bits = bits + 1;

    /* 2: the FIRST field of the same unit, same chain -- a fix that only
     *    gets the field at offset 0 right still fails this */
    if (vtop[-nb_args].type.ref->f.func_call != 5) bits = bits + 2;

    /* 3: a field that was never set must still read zero -- a wrong clear
     *    mask when writing func_type above would have wiped it */
    if (vtop[-nb_args].type.ref->f.func_ctor != 0) bits = bits + 4;

    /* 4: address-of a member through the chain, as gfunc_call takes it */
    return_type = &vtop[-nb_args].type.ref->type;
    if (return_type->t != 203) bits = bits + 8;

    /* 5: n_func_args over the same address */
    if (n_func_args(&vtop[-nb_args].type) != 2) bits = bits + 16;

    /* 6: the array of CType* gfunc_call builds, read back index-then-arrow */
    t[0] = return_type;
    for (i = 0; i < nb_args; i++)
        t[nb_args - i] = &vtop[-i].type;
    if (t[1]->t != 104) bits = bits + 32;
    if (read_through(t, nb_args) != 203 + 104 + 105) bits = bits + 64;

    return bits;
}
