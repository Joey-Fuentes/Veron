/* `++` and `--` on a GLOBAL or STATIC variable.
 *
 * tccpp.c:480, the statement the micro-c-built tcc dies on:
 *
 *     ts->tok = tok_ident++;
 *
 * tok_ident is a file-scope int. Every form of increment on a global
 * segfaulted -- postfix, prefix, and a bare `n++` with no value used. Locals
 * were always fine.
 *
 * The cause was upstream's own guard in primary_expr_variable:
 *
 *     is_postfix_operator = match("++", ...) && (options != TLO_STATIC
 *                                             && options != TLO_GLOBAL);
 *
 * which is not a guard against anything. It makes a global fall through to
 * the ordinary path, which LOADS its value; the increment code then treats
 * that value as an address and stores through it. A local returns the ADDRESS
 * without loading, which is what the increment needs, and a global scalar's
 * symbol is already the address of its value.
 *
 * M2-Planet's own sources never increment a global, so nothing upstream ever
 * exercised it. tcc does it constantly.
 *
 * EACH CHECK NAMES BOTH HALVES: the value the expression produced and the
 * value left in the variable. A postfix increment that returns the right
 * number and fails to store, or stores and returns the new value, are
 * different bugs and a single check cannot tell them apart.
 */
static int   counter;
static long  wide;
static long  buf[4];
static long* cursor;

struct Ent { int tok; int len; };
static struct Ent ent;

int main(void)
{
    int  i;
    long l;
    long* q;

    /* postfix: yields the OLD value, leaves the new one behind */
    counter = 5;
    i = counter++;
    if (i != 5) return 1;
    if (counter != 6) return 2;

    /* prefix: yields the NEW value */
    counter = 5;
    i = ++counter;
    if (i != 6) return 3;
    if (counter != 6) return 4;

    /* as a statement, with the value discarded */
    counter = 5;
    counter++;
    if (counter != 6) return 5;
    counter--;
    if (counter != 5) return 6;

    /* postfix decrement yields the old value */
    counter = 5;
    i = counter--;
    if (i != 5) return 7;
    if (counter != 4) return 8;

    /* a wider type */
    wide = 100;
    l = wide++;
    if (l != 100) return 9;
    if (wide != 101) return 10;

    /* a global POINTER: ++ must advance by the element, not by one byte */
    buf[0] = 70; buf[1] = 80; buf[2] = 90;
    cursor = buf;
    q = cursor++;
    if (q != buf) return 11;
    if (*cursor != 80) return 12;
    cursor++;
    if (*cursor != 90) return 13;

    /* tcc's exact statement: the result stored into a struct member */
    counter = 256;
    ent.tok = counter++;
    if (ent.tok != 256) return 14;
    if (counter != 257) return 15;

    /* and in a loop condition, where it is read and written each pass */
    counter = 0;
    i = 0;
    while (counter < 4) { i = i + counter++; }
    if (counter != 4) return 16;
    if (i != 6) return 17;      /* 0+1+2+3 */

    return 0;
}
