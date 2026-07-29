/* `&(x)` MUST MEAN `&x`. Grouping parens are transparent to address-of.
 *
 * tccpp.c:516, the bucket walk in tok_alloc:
 *
 *     pts = &(ts->hash_next);
 *
 * with the parens, as tcc writes it. micro-c parsed that as a LOAD of
 * hash_next rather than its address, so pts became whatever the member held --
 * NULL on a fresh entry -- and the next *pts faulted.
 *
 * The cause is that primary_expr's first act is
 *
 *     if(match("&", ...)) Address_of = TRUE; else Address_of = FALSE;
 *
 * and a grouping paren re-enters primary_expr for the inner expression, where
 * the token is no longer `&`. The flag its own caller set two frames up was
 * cleared by the callee. `&ts->hash_next` -- the same expression without the
 * parens -- never re-enters and was always correct.
 *
 * EVERY CHECK BELOW IS A PAIR: the parenthesised form and the bare form, which
 * must agree. A case that only tested the parenthesised form could pass by
 * both being broken the same way.
 */
struct Node { struct Node* next; long value; };

static struct Node  pool[4];
static struct Node* head;
static long         scalar;

int main(void)
{
    struct Node** pp;
    struct Node** qq;
    long* lp;
    long* lq;

    pool[0].next = 0;
    pool[0].value = 100;
    pool[1].next = 0;
    pool[1].value = 200;
    scalar = 777;

    /* a struct member, both ways */
    pp = &(pool[0].next);
    qq = &pool[0].next;
    if (pp != qq) return 1;
    /* ANCHORED, not just paired. Comparing the two forms against each other
     * passes when both are broken identically -- which is exactly what
     * happened: &pool[0].next LOADED the member, so did &(pool[0].next), and
     * `pp != qq` was false. pool[0].next is the first member of the first
     * element, so its address is the address of the array itself. */
    if (pp != (struct Node**)pool) return 2;
    if (*pp != 0) return 3;

    *pp = &pool[1];
    if (pool[0].next != &pool[1]) return 3;

    /* through a pointer, with the arrow -- tcc's exact shape */
    head = &pool[0];
    pp = &(head->next);
    qq = &head->next;
    if (pp != qq) return 4;
    if (*pp != &pool[1]) return 5;

    *pp = 0;
    if (pool[0].next != 0) return 6;

    /* a plain scalar */
    lp = &(scalar);
    lq = &scalar;
    if (lp != lq) return 7;
    if (*lp != 777) return 8;

    /* an array element */
    pp = &(pool[1].next);
    qq = &pool[1].next;
    if (pp != qq) return 9;

    /* doubled parens must not double the damage */
    lp = &((scalar));
    if (lp != lq) return 10;

    /* the walk itself: pts moves from an array element to a member */
    pool[0].next = &pool[1];
    pp = &head->next;
    if (*pp != &pool[1]) return 11;
    pp = &(pool[1].next);
    if (*pp != 0) return 12;

    /* &((*p)->m) -- parens around a DEREFERENCE -- is case 44, a known gap. */

    return 0;
}
