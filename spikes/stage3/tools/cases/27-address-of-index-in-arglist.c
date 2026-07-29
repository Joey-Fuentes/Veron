/* f(&arr[i]) -- the address of an indexed element computed INSIDE an argument
 * list.
 *
 * Address_of and indexing_an_array are global flags consumed at points other
 * than where they are set, and an argument list is where a second expression
 * gets evaluated between the two. Case 22 already showed that a branch inside
 * an argument list clobbered REGISTER_TEMP; this asks the same question about
 * the flags rather than the registers.
 *
 * Two arguments, so the second is evaluated after the first has already set and
 * consumed the flags once -- which is the condition a single-argument case
 * cannot create.
 *
 * THE ARRAY IS LOCAL ON PURPOSE. It was global in the first version of this
 * case, and the case duly failed -- but so did 24, on the same global-array
 * bug, so this one indicted argument lists for something globals were doing.
 * A case that fails for another case's reason is worse than no case: it will
 * go green when that bug is fixed and nobody will have learned whether the
 * construct it names actually works. Locals pass (case 25), so a failure here
 * now means the argument list.
 */
static long seen_a;
static long seen_b;

static void take2(long* a, long* b)
{
    seen_a = *a;
    seen_b = *b;
}

static long deref(long* a)
{
    return *a;
}

int main(void)
{
    long slots[8];
    int i;
    int j;

    i = 0;
    while (i < 8) { slots[i] = i + 100; i = i + 1; }

    /* two address-of-index arguments in one call */
    take2(&slots[1], &slots[6]);
    if (seen_a != 101) return 1;
    if (seen_b != 106) return 2;

    /* computed indices, and the two flags used twice in one expression */
    i = 2;
    j = 5;
    take2(&slots[i], &slots[j]);
    if (seen_a != 102) return 3;
    if (seen_b != 105) return 4;

    /* address-of-index next to an ordinary expression argument */
    take2(&slots[0], &slots[i + 1]);
    if (seen_a != 100) return 5;
    if (seen_b != 103) return 6;

    /* nested: the argument of one call is the result of another */
    if (deref(&slots[4]) != 104) return 7;
    if (deref(&slots[i]) != 102) return 8;

    /* the address-of-index as the operand of a comparison, not a call */
    if (&slots[3] == &slots[4]) return 9;
    if (&slots[3] != &slots[3]) return 10;

    return 0;
}
