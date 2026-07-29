/* `*(t) = x` -- a store through a PARENTHESISED dereference.
 *
 * This is the defect that was actually holding tcc up, and it is four
 * characters wide:
 *
 *     *(t) = 7;      stored through the LOADED VALUE -- SIGSEGV
 *     *t   = 7;      correct, and has been all along
 *
 * An assignment target must not be loaded: the register wants the pointer's
 * VALUE as the destination address. cc_core.c carries that rule in eight
 * places under the name `assigning` and the parenthesised dereference path was
 * the one that never got it -- the same one-rule-many-implementations shape
 * MICRO-C.md counts nineteen of for load_value.
 *
 * tcc writes the parenthesised form because TOK_GET is a macro and `*(t)` is
 * how a macro parameter is dereferenced safely. So it is not a rare spelling
 * there; it is the only spelling.
 *
 * WIDTHS DIFFER ON PURPOSE. char is 1 and long is 8, so a store that uses the
 * pointer's own width instead of the pointed-to width is visible rather than
 * accidentally right. That is case 31's lesson: every array-of-pointers probe
 * once used `long*`, where both numbers are 8, and no case could tell them
 * apart.
 */
static long sink_l;
static char sink_c;

static void put_long(long* t, long v) { *(t) = v; }
static void put_char(char* t, char v) { *(t) = v; }
static void bump_long(long* t)        { *(t) = *(t) + 1; }

int main(void)
{
    long  l;
    char  c;
    char  buf[4];

    /* through a parameter -- TOK_GET's shape */
    put_long(&sink_l, 123456789);
    if (sink_l != 123456789) return 1;

    put_char(&sink_c, 'Z');
    if (sink_c != 'Z') return 2;

    /* a byte store must write ONE byte, not eight */
    buf[0] = 1; buf[1] = 2; buf[2] = 3; buf[3] = 4;
    put_char(&buf[1], 9);
    if (buf[0] != 1) return 3;
    if (buf[1] != 9) return 4;
    if (buf[2] != 3) return 5;
    if (buf[3] != 4) return 6;

    /* read and write through the same parenthesised form */
    l = 41;
    bump_long(&l);
    if (l != 42) return 7;

    /* a local, no call in the way */
    c = 'a';
    *(&c) = 'b';
    if (c != 'b') return 8;

    /* two levels: **(p) = x */
    {
        long* lp = &l;
        long** lpp = &lp;
        **(lpp) = 77;
        if (l != 77) return 9;
    }

    return 0;
}
