/* && and || must not evaluate the right side when the left settles it.
 * tcc relies on this in forty-eight places of the form `p && p->field`. */
static int calls;
struct S { int v; };
static int touch(struct S* p) { calls = calls + 1; return p->v; }
int main(void)
{
    struct S* np = 0;
    calls = 0;
    if (np && touch(np)) return 1;
    if (calls != 0) return 2;
    if (!(1 || touch(np))) return 3;
    if (calls != 0) return 4;
    return 0;
}
