/* BITMASK
 * Case 97 showed `n = sizeof(T) + buflen;` is correct when ASSIGNED.
 * tcc_open_bf does not assign it -- it passes it:
 *     bf = tcc_mallocz(sizeof(BufferedFile) + buflen);
 * and the allocation observed was sizeof(T) * (buflen + 1).
 */
struct Big { char pad[1128]; };

static unsigned long seen;
static void *take(unsigned long n) { seen = n; return 0; }
static unsigned long take2(unsigned long a, unsigned long b) { return a + b; }

int main(void)
{
    int bits = 0;
    int buflen = 8192;
    int initlen = 0;

    /* 1: as a lone argument, literal on the right */
    take(sizeof(struct Big) + 8192);
    if (seen != 1128 + 8192) bits = bits + 1;

    /* 2: as a lone argument, variable on the right */
    take(sizeof(struct Big) + buflen);
    if (seen != 1128 + 8192) bits = bits + 2;

    /* 4: the ternary that produces buflen, exactly as tcc writes it */
    {
        int bl = initlen ? initlen : 8192;
        take(sizeof(struct Big) + bl);
        if (seen != 1128 + 8192) bits = bits + 4;
    }

    /* 8: second of two arguments */
    if (take2(1, sizeof(struct Big) + buflen) != 1 + 1128 + 8192) bits = bits + 8;

    /* 16: the ternary INSIDE the argument */
    take(sizeof(struct Big) + (initlen ? initlen : 8192));
    if (seen != 1128 + 8192) bits = bits + 16;

    /* 32: assigned first, then passed -- the control for 1 and 2 */
    {
        unsigned long n = sizeof(struct Big) + buflen;
        take(n);
        if (seen != 1128 + 8192) bits = bits + 32;
    }

    return bits;
}
