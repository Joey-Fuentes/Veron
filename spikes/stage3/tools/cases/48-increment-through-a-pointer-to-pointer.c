/* `++*(p)` -- incrementing a pointer THROUGH a pointer to it.
 *
 * tcc's token reader is
 *
 *     #define TOK_GET(t,p,c) do { \
 *         int _t = **(p); \
 *         if (TOK_HAS_VALUE(_t)) \
 *             tok_get(t, p, c); \
 *         else \
 *             *(t) = _t, ++*(p); \
 *         } while (0)                              tccpp.c:1245
 *
 * `*p` is `const int *`, so `++*(p)` must advance it by sizeof(int). micro-c
 * advanced it by ONE and the next token was read from a misaligned address.
 *
 * WAS A KNOWN GAP. Closed by EXPERIMENT-zz8 -- and NOT by the pointer-scaling
 * patch, which this file previously blamed. Scaling was fixed first and this
 * case did not move. Two different defects were in the way: the prefix-++ test
 * looked two tokens back from the identifier, which is the `*` once stars have
 * been consumed, and `&x` reports x's own type one level short of what it is.
 *
 * STEP 4 IS THE ONE THAT MATTERS and it looks like the artificial one. After
 * macro substitution TOK_GET's `p` is literally `&macro_str`, so tcc's real
 * expression is `++*(&x)` -- the shape below, not the parameter form.
 *
 * Each check names both halves -- the value the expression produced and the
 * value left behind -- because an increment that returns the right number and
 * fails to advance is a different bug from one that advances twice.
 */
static int   ints[4];
static long  longs[4];
static int*  gp;

static void adv_int(int** p)  { ++*(p); }
static void adv_long(long** p) { ++*(p); }

int main(void)
{
    int*  ip;
    long* lp;
    int   v;

    ints[0] = 10; ints[1] = 20; ints[2] = 30; ints[3] = 40;
    longs[0] = 100; longs[1] = 200; longs[2] = 300;

    /* the comma expression on its own -- this one works */
    v = 0;
    if (v) v = 1; else v = 2, ints[3] = 41;
    if (v != 2) return 1;
    if (ints[3] != 41) return 2;

    /* ++ on a pointer held directly: the shape that already works */
    ip = ints;
    ++ip;
    if (*ip != 20) return 3;

    /* ++ THROUGH a pointer to it, in the same function -- TOK_GET's real
     * shape once the macro parameter has been substituted */
    ip = ints;
    ++*(&ip);
    if (*ip != 20) return 4;

    /* and through a parameter */
    ip = ints;
    adv_int(&ip);
    if (*ip != 20) return 5;
    adv_int(&ip);
    if (*ip != 30) return 6;

    /* a wider element, so a one-byte advance is unmistakable */
    lp = longs;
    adv_long(&lp);
    if (*lp != 200) return 7;

    /* through a global pointer */
    gp = ints;
    adv_int(&gp);
    if (*gp != 20) return 8;

    return 0;
}
