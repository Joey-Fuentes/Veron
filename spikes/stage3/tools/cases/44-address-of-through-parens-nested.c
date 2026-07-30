/* CLOSED by EXPERIMENT-zzr. `&((*p)->m)` -- grouping parens around a DEREFERENCE.
 *
 * `&(p->m)` works (case 43). This does not, and the reason is structural
 * rather than a missing guard.
 *
 * Address_of is a global. `&(X)` needs it TRUE at the final lvalue step of X
 * and FALSE everywhere inside X. For `&(ts->hash_next)` those are the same
 * point, so handing the flag through the parens is enough. For
 * `&((*pp)->next)` they are not: the `*pp` in the middle must evaluate
 * normally, and the `->next` after it must not. One global cannot say both.
 *
 * Clearing it for the inner expression makes the arrow load the member;
 * keeping it set makes the dereference yield the address of pp. Both are
 * wrong, which is why this is recorded rather than half-fixed -- the same
 * call made for pointer scaling in case 21.
 *
 * The fix is the one this whole file keeps pointing at: carry address-of on
 * the expression instead of in a global, so the final step can be identified.
 * That is a refactor of every site that reads the flag and is not worth doing
 * blind.
 *
 * Whether tcc needs this shape is unmeasured. tccpp.c:516 uses the simple
 * `&(ts->hash_next)`, which works.
  *
 * CLOSED. It was the same rule the arrow and array sites already carried: an
 * address applies to the LAST step of a chain, never to a step that still has
 * to be followed. Two spellings were wrong -- `&p->a->b` dropped the middle
 * load, `&(p)->a->b` dropped the first -- and this case is the third,
 * `&((*p)->m)`. Fixing the other two closed it without it being touched, which
 * is the tell that they were one bug wearing three faces.
*/
struct Node { struct Node* next; long value; };

static struct Node  pool[4];
static struct Node* head;

int main(void)
{
    struct Node** pp;

    pool[0].next = &pool[1];
    pool[1].next = 0;
    head = &pool[0];

    pp = &head->next;
    if (*pp != &pool[1]) return 1;

    pp = &((*pp)->next);
    if (*pp != 0) return 2;

    return 0;
}
