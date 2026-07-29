/* &p[i] where p is a POINTER VARIABLE, not an array.
 *
 * The fix for case 24 is not "global arrays need a load"; it is that
 * everything except a LOCAL ARRAY needs one, because a local array's slot is
 * its storage and nothing else's is. A global array's symbol is a cell holding
 * the address of the data. A pointer variable's slot holds the pointer. Both
 * must be dereferenced before an index is added to them, and taking an address
 * returned before either happened.
 *
 * So this case should be failing NOW for the same reason 24 does, and should
 * go green with the same change. A case that predicts the effect of a fix is
 * worth more than one written after it, because it can be wrong.
 *
 * tcc reaches this through every `&s->sections[i]`-shaped access where the
 * base arrived as a pointer parameter rather than as a named array.
 */
static long  store[8];
static long* gp;

static long fetch(long* q)
{
    return *q;
}

int main(void)
{
    long* lp;
    long* addr;
    int i;

    i = 0;
    while (i < 8) { store[i] = i + 200; i = i + 1; }

    /* a LOCAL pointer variable */
    lp = store;
    addr = &lp[3];
    if (*addr != 203) return 1;

    addr = &lp[0];
    if (*addr != 200) return 2;

    i = 5;
    addr = &lp[i];
    if (*addr != 205) return 3;

    /* writing through it */
    addr = &lp[6];
    *addr = 77;
    if (store[6] != 77) return 4;

    /* a GLOBAL pointer variable: the cell holds the pointer, one load, same
     * as the local pointer -- not two loads as a global ARRAY would need */
    gp = store;
    addr = &gp[2];
    if (*addr != 202) return 5;

    addr = &gp[0];
    if (*addr != 200) return 6;

    /* as an argument, where the flags have to survive a nested evaluation */
    if (fetch(&lp[4]) != 204) return 7;
    if (fetch(&gp[1]) != 201) return 8;

    /* a pointer PARAMETER indexed and addressed inside the callee is the
     * shape tcc actually uses; fetch above already covers the call, this
     * covers the arithmetic surviving the round trip */
    lp = &store[2];
    addr = &lp[1];
    if (*addr != 203) return 9;

    return 0;
}
