/* Is &chain->member the address of the POINTED-TO object, or of the POINTER
 * CELL itself?  i.e. is the load of the pointer being skipped?
 *   returns 0 = correct   1 = it is the pointer cell (load skipped)   2 = other
 */
typedef struct Inner { long t; long pad; } Inner;
typedef struct Mid   { long t; Inner *ref; } Mid;
typedef struct Outer { Mid m; long c; } Outer;

static Inner inner_;
static Outer outer_;
static Outer *op;

int main(void)
{
    long want, got, cell;
    inner_.t = 302; inner_.pad = 0;
    outer_.m.t = 100; outer_.m.ref = &inner_; outer_.c = 0;
    op = &outer_;

    want = (long)&inner_.t;          /* what &op->m.ref->t must equal */
    cell = (long)&op->m.ref;         /* the address of the pointer field */
    got  = (long)&op->m.ref->t;

    if (got == want) return 0;
    if (got == cell) return 1;
    return 2;
}
