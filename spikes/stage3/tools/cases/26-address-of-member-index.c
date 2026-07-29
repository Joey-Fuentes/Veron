/* &s.arr[i] and &s->arr[i] -- the third mechanism for array-ness.
 *
 * Members carry it through is_array, which was added for the arrow site and
 * then had to be added AGAIN at the dot site, because the two are separate
 * copies of one rule. Taking the address of an indexed member needs is_array
 * and Address_of to survive together, which is the same collision case 24
 * tests on globals.
 *
 * tcc does this in its section handling -- &s1->sections[i] and friends.
 */
struct Tab {
    long  pad;
    long  arr[4];
    char  buf[8];
    long* ptrs[4];
};

static struct Tab g;

int main(void)
{
    struct Tab  s;
    struct Tab* q;
    long* p;
    long** pp;
    char* cp;
    int i;

    i = 0;
    while (i < 4) { s.arr[i] = i + 10; s.ptrs[i] = 0; i = i + 1; }
    s.pad = -1;

    /* dot */
    p = &s.arr[2];
    if (*p != 12) return 1;
    *p = 77;
    if (s.arr[2] != 77) return 2;

    /* arrow */
    q = &s;
    p = &q->arr[3];
    if (*p != 13) return 3;
    *p = 88;
    if (s.arr[3] != 88) return 4;

    /* element 0 through the arrow: the address of the member itself */
    p = &q->arr[0];
    if (*p != 10) return 5;

    /* a char member -- element width is 1, not the register size */
    i = 0;
    while (i < 8) { s.buf[i] = 'a' + i; i = i + 1; }
    cp = &s.buf[3];
    if (*cp != 'd') return 6;
    *cp = 'z';
    if (s.buf[3] != 'z') return 7;
    if (s.buf[4] != 'e') return 8;      /* the write must not have been wide */

    /* pointer-to-pointer into a member array */
    pp = &q->ptrs[1];
    if (*pp != 0) return 9;
    s.ptrs[1] = &s.arr[2];
    if (**pp != 77) return 10;

    /* the same on a GLOBAL struct, where the base is not on the stack */
    i = 0;
    while (i < 4) { g.arr[i] = i + 20; i = i + 1; }
    p = &g.arr[2];
    if (*p != 22) return 11;
    q = &g;
    p = &q->arr[1];
    if (*p != 21) return 12;

    return 0;
}
