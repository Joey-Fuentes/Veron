/* BITMASK
 * Narrowing 91: which step of `&vtop[-n].type.ref->type` is wrong?
 * Each probe adds exactly one step to the chain in front of the final `->`.
 */
typedef struct Inner { int t; int pad; } Inner;
typedef struct Mid   { int t; Inner *ref; } Mid;
typedef struct Outer { Mid m; int c; } Outer;

static Inner inner_[4];
static Outer outer_[4];
static Outer *op;
static Mid   *mp;

int main(void)
{
    int bits = 0;
    int i;

    for (i = 0; i < 4; i++) { inner_[i].t = 300 + i; inner_[i].pad = 0; }
    for (i = 0; i < 4; i++) { outer_[i].m.t = 100 + i; outer_[i].m.ref = &inner_[i]; outer_[i].c = 0; }
    op = &outer_[2];
    mp = &outer_[2].m;

    /* 1: a plain read down the chain, no & at all -- the baseline */
    { Inner *r = mp->ref; if (r->t != 302) bits = bits + 1; }

    /* 2: & of a member reached through ONE arrow from a plain pointer */
    { Inner **rr = &mp->ref; if ((*rr)->t != 302) bits = bits + 2; }

    /* 4: & of a member BEHIND an arrow: &mp->ref->t */
    { int *tp = &mp->ref->t; if (*tp != 302) bits = bits + 4; }

    /* 8: same, but the base reached by INDEX first: &outer_[2].m.ref->t */
    { int *tp = &outer_[2].m.ref->t; if (*tp != 302) bits = bits + 8; }

    /* 16: same, base reached by index on a POINTER: &op[0].m.ref->t */
    { int *tp = &op[0].m.ref->t; if (*tp != 302) bits = bits + 16; }

    /* 32: NEGATIVE index, exactly as gfunc_call writes it */
    { Outer *v = &outer_[3]; int *tp = &v[-1].m.ref->t; if (*tp != 302) bits = bits + 32; }

    /* 64: taking the ADDRESS OF THE WHOLE STRUCT behind the arrow */
    { Inner *r = &op[0].m.ref[0]; if (r->t != 302) bits = bits + 64; }

    return bits;
}
