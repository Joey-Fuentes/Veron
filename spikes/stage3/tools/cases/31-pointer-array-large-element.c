/* AN ARRAY OF POINTERS TO A LARGE STRUCT, ADDRESSED BY INDEX.
 *
 * This is the case the rest of the suite could not have caught, and the
 * omission is the reason three green rounds did not move tcc one statement.
 *
 * postfix_expr_array chooses the element width between two numbers:
 *
 *     current_target->type->size    what a POINTER points at
 *     current_target->size          an ARRAY's element
 *
 * and `indexing_an_array` picks which. Every array-of-pointers probe written
 * so far used `long*`, where both numbers are 8. Those cases cannot detect a
 * wrong choice between them -- they pass either way, and they did.
 *
 * `TokenSym *hash_ident[16384]` is the shape that matters, and there the two
 * differ by about eight to one. With the flag unset the index scaled by
 * sizeof(TokenSym) instead of sizeof(TokenSym*), so &hash_ident[h] with h
 * masked to 16383 landed roughly a megabyte beyond a 128 KB array.
 *
 * struct Big is six longs, so the wrong scale is six times the right one:
 * &table[40] goes 1920 bytes into a 512-byte array. The canary is there to
 * say whether a write through such a pointer lands outside.
 */
struct Big { long a; long b; long c; long d; long e; long f; };

static struct Big  items[4];
static struct Big* table[64];
static long        canary;

int main(void)
{
    struct Big** pp;
    struct Big*  q;
    int i;

    canary = 12345;

    i = 0;
    while (i < 4) { items[i].a = i + 500; i = i + 1; }
    i = 0;
    while (i < 64) { table[i] = 0; i = i + 1; }

    table[0]  = &items[0];
    table[1]  = &items[1];
    table[40] = &items[2];
    table[63] = &items[3];

    /* index 0 -- the one index where a wrong scale is invisible, so a case
     * that only tested this would report success */
    pp = &table[0];
    q = *pp;
    if (q != &items[0]) return 1;
    if (q->a != 500) return 2;

    /* index 1 -- a six-times scale lands on table[6], which is NULL */
    pp = &table[1];
    q = *pp;
    if (q != &items[1]) return 3;
    if (q->a != 501) return 4;

    /* a large index -- a wrong scale leaves the array altogether */
    pp = &table[40];
    q = *pp;
    if (q != &items[2]) return 5;
    if (q->a != 502) return 6;

    pp = &table[63];
    q = *pp;
    if (q != &items[3]) return 7;

    /* a write through the computed address must land inside the array */
    pp = &table[20];
    *pp = &items[1];
    if (table[20] != &items[1]) return 8;
    if (canary != 12345) return 9;

    /* a variable index, which is what tcc actually has */
    i = 40;
    pp = &table[i];
    q = *pp;
    if (q != &items[2]) return 10;

    /* PLAIN INDEXING, no address-of. This path always scaled correctly and is
     * the control: if this fails too, the fault is not in the address-of
     * branch and the diagnosis is wrong. */
    q = table[40];
    if (q != &items[2]) return 11;

    q = table[1];
    if (q != &items[1]) return 12;

    return 0;
}
