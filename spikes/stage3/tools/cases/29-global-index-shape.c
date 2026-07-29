/* WHICH PART of the global-array path is wrong -- all of it in one run.
 *
 * Case 24 fails and case 25, the identical shape on a LOCAL array, passes. So
 * the hole is the global path. This case says WHICH global path, because the
 * code fix is a different one-liner depending on the answer and guessing costs
 * a CI round each time.
 *
 * IT RETURNS A BITMASK, NOT THE FIRST FAILURE. Every other case in this
 * directory returns at the first thing that breaks, which is right for a
 * regression test: you want the earliest signal. It is wrong for a diagnostic,
 * because case 24 returning 1 told us its first check failed and nothing about
 * the other eight. Here each probe sets a bit and the run continues, so one
 * number describes the whole shape.
 *
 *     rc & 1    read  *(&g[0])        index zero, literal
 *     rc & 2    read  *(&g[3])        nonzero literal index
 *     rc & 4    read   g[3]           PLAIN INDEXING, no address-of
 *     rc & 8    write *(&g[3])
 *     rc & 16   decay  p = g; p[3]    no index at the address-of
 *     rc & 32   read  *(&g[i])        variable index
 *     rc & 64   char array            element size 1
 *     rc & 128  array of pointers     element size 8 -- hash_ident's shape
 *
 * If bit 4 is clear and bits 1|2 are set, plain indexing of a global works and
 * only ADDRESS-OF an indexed global is wrong -- which is one site. If bit 4 is
 * also set, global arrays are wrong generally and the fix is elsewhere. Case 18
 * already passes with `static struct Ent table[4]` indexed and then a member
 * selected, so the second is unlikely; this proves it rather than assuming.
 */
static long  g[4];
static char  cg[8];
static long* pg[4];
static long  target;

int main(void)
{
    long* p;
    long** pp;
    char* cp;
    int i;
    int bad;

    bad = 0;

    g[0] = 10; g[1] = 11; g[2] = 12; g[3] = 13;
    cg[0] = 'a'; cg[1] = 'b'; cg[2] = 'c'; cg[3] = 'd';
    pg[0] = 0; pg[1] = 0; pg[2] = 0; pg[3] = 0;
    target = 4242;

    /* 1 -- index zero. The one index where a base that was loaded instead of
     * decayed can still produce a plausible-looking address. */
    p = &g[0];
    if (*p != 10) bad = bad + 1;

    /* 2 -- nonzero literal index */
    p = &g[3];
    if (*p != 13) bad = bad + 2;

    /* 4 -- plain indexing, NO address-of. If this is clean the read path is
     * fine and only the address-of variant is broken. */
    if (g[3] != 13) bad = bad + 4;

    /* 8 -- writing through the computed address */
    p = &g[2];
    *p = 99;
    if (g[2] != 99) bad = bad + 8;

    /* 16 -- decay with no index at all */
    p = g;
    if (p[3] != 13) bad = bad + 16;

    /* 32 -- variable index rather than a constant one */
    i = 1;
    p = &g[i];
    if (*p != 11) bad = bad + 32;

    /* 64 -- element size one, where any scaling error is invisible */
    cp = &cg[2];
    if (*cp != 'c') bad = bad + 64;

    /* 128 -- an array of POINTERS: hash_ident's exact type */
    pg[2] = &target;
    pp = &pg[2];
    if (*pp != &target) bad = bad + 128;
    else if (**pp != 4242) bad = bad + 128;

    return bad;
}
