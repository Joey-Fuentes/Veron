/* KNOWN GAP. `++*(p)` -- incrementing a pointer THROUGH a pointer to it.
 *
 * This is case 21 -- pointer arithmetic does not scale -- reached from a new
 * direction, and it is no longer theoretical. tcc's token reader is
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
 * advances it by ONE, so the next token is read from a misaligned address.
 *
 * That macro runs for every token tcc reads. The micro-c-built tcc gets
 * through the first iteration of macro_subst's loop -- the initial pointer is
 * valid -- and faults on the second.
 *
 * The comma expression next to it, `*(t) = _t, ++*(p);` as a braceless else
 * body, is NOT the problem; it is checked below and behaves.
 *
 * WHY THIS IS A GAP AND NOT A FIX. A patch exists in the experiment series as
 * scale_pointer_operand and is deliberately not wired in: it made two cases
 * pass and broke a third, because promote_type has folded the pointee type
 * away by the time the operator is handled. The same information loss is
 * behind the nineteen load sites. Shipping a semantic change that trades one
 * failure for another is worse than a documented gap.
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

    /* ++ THROUGH a pointer to it, in the same function */
    ip = ints;
    ++*(&ip);
    if (*ip != 20) return 4;

    /* and through a parameter, which is TOK_GET's shape */
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
