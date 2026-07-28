/* `x != K && !s->member` -- the exact shape that faulted in
 * tcc_set_output_type, where splitting it into two assignments and then
 * `if (a && b)` worked. Both are &&; the difference is a UNARY NOT applied to
 * a struct member as the right operand.
 *
 * Short-circuit means the right operand is only reached when the left is
 * true, so the two calls below exercise both paths deliberately. */
struct S { unsigned char nostdlib; unsigned char other; int type; };
static int reached;

static int check(struct S* s, int type)
{
    if (type != 1 && !s->nostdlib) { reached = reached + 1; return 1; }
    return 0;
}

int main(void)
{
    struct S s;
    s.nostdlib = 0; s.other = 9; s.type = 0;
    reached = 0;

    /* left false -> short-circuits, right never evaluated */
    if (check(&s, 1) != 0) return 1;
    if (reached != 0) return 2;

    /* left true, right true -> body runs */
    if (check(&s, 2) != 1) return 3;
    if (reached != 1) return 4;

    /* left true, right false */
    s.nostdlib = 1;
    if (check(&s, 2) != 0) return 5;
    if (reached != 1) return 6;

    /* the || mirror, with the not on the left */
    if (!(!s.nostdlib || s.other == 9)) return 7;
    return 0;
}
