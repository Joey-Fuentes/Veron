/* BITMASK
 * 92 showed &mp->ref->t is right and &op[0].m.ref->t is wrong. Isolate which
 * part of the prefix does it: the INDEX, the extra member, or both.
 */
typedef struct Inner { int t; int pad; } Inner;
typedef struct Mid   { int t; Inner *ref; } Mid;
typedef struct Outer { Mid m; int c; } Outer;
typedef struct Flat  { int c; Inner *ref; } Flat;

static Inner inner_[4];
static Outer outer_[4];
static Flat  flat_[4];
static Outer *op;
static Flat  *fp;

int main(void)
{
    int bits = 0;
    int i;
    for (i = 0; i < 4; i++) { inner_[i].t = 300 + i; inner_[i].pad = 0; }
    for (i = 0; i < 4; i++) { outer_[i].m.t = 100 + i; outer_[i].m.ref = &inner_[i]; outer_[i].c = 0; }
    for (i = 0; i < 4; i++) { flat_[i].c = 0; flat_[i].ref = &inner_[i]; }
    op = &outer_[2];
    fp = &flat_[2];

    /* 1: INDEX then arrow, NO intermediate member: &flat_[2].ref->t */
    { int *tp = &flat_[2].ref->t; if (*tp != 302) bits = bits + 1; }

    /* 2: index on a pointer, no intermediate member: &fp[0].ref->t */
    { int *tp = &fp[0].ref->t; if (*tp != 302) bits = bits + 2; }

    /* 4: no index, TWO members then arrow: &op->m.ref->t */
    { int *tp = &op->m.ref->t; if (*tp != 302) bits = bits + 4; }

    /* 8: index + one member + arrow (the failing shape from 92) */
    { int *tp = &op[0].m.ref->t; if (*tp != 302) bits = bits + 8; }

    /* 16: the same value WITHOUT & -- a plain read, not an address */
    { if (op[0].m.ref->t != 302) bits = bits + 16; }

    /* 32: & with the index parenthesised away into a temp */
    { Outer *tmp = &op[0]; int *tp = &tmp->m.ref->t; if (*tp != 302) bits = bits + 32; }

    /* 64: & of a LATER member behind the arrow, index present */
    { int *pp = &op[0].m.ref->pad; if (*pp != 0) bits = bits + 64; }

    return bits;
}
