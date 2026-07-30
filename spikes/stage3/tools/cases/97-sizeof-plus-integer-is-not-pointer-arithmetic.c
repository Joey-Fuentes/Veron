/* BITMASK
 *
 * tcc_open_bf(), tccpp.c:
 *
 *     bf = tcc_mallocz(sizeof(BufferedFile) + buflen);
 *
 * A tcc built by micro-c zeroes 23 MB compiling an EMPTY file, where the
 * gcc-built control zeroes 0.23 MB. The memset COUNT matches -- 800 calls
 * against 802 -- so the control flow is identical and every call is simply
 * too large. The three biggest are
 *
 *     9,241,704 = 1128 * 8193 = 1128 + 8192*1128
 *     4,588,704 = 1128 * 4068 = 1128 + 4067*1128
 *
 * 1128 is sizeof(BufferedFile) as micro-c lays it out, 8192 is IO_BUF_SIZE and
 * 4067 is the length of the <command line> predefs buffer. So
 * `sizeof(T) + n` is being evaluated as `sizeof(T) + n * sizeof(T)`:
 * POINTER-ARITHMETIC SCALING APPLIED TO AN INTEGER ADDITION.
 *
 * This is EXPERIMENT-zz7 read backwards. zz7 closed "pointer arithmetic does
 * not scale"; the scaling now fires where the left operand is a `sizeof`,
 * which is an integer and must not scale anything.
 *
 * It is not a crash, which is why nothing caught it: every allocation is
 * merely 1000x too big and the program works, slowly, until something fails
 * for an unrelated-looking reason.
 */

struct Big { char pad[1128]; };
struct Two { long a; long b; };

static unsigned long width(void) { return sizeof(struct Big); }

int main(void)
{
    int bits = 0;

    /* 1: the exact shape from tcc_open_bf */
    {
        unsigned long n = sizeof(struct Big) + 8192;
        if (n != 1128 + 8192) bits = bits + 1;
    }

    /* 2: the same with a variable on the right */
    {
        int buflen = 8192;
        unsigned long n = sizeof(struct Big) + buflen;
        if (n != 1128 + 8192) bits = bits + 2;
    }

    /* 4: sizeof on the RIGHT of the addition */
    {
        int buflen = 8192;
        unsigned long n = buflen + sizeof(struct Big);
        if (n != 1128 + 8192) bits = bits + 4;
    }

    /* 8: a small struct, so the factor is small and easy to miss */
    {
        unsigned long n = sizeof(struct Two) + 3;
        if (n != 16 + 3) bits = bits + 8;
    }

    /* 16: sizeof returned from a function, then added */
    {
        unsigned long n = width() + 8192;
        if (n != 1128 + 8192) bits = bits + 16;
    }

    /* 32: subtraction must not scale either */
    {
        unsigned long n = sizeof(struct Big) - 128;
        if (n != 1128 - 128) bits = bits + 32;
    }

    /* 64: sizeof of a basic type, which has no struct width to scale by */
    {
        unsigned long n = sizeof(long) + 100;
        if (n != 8 + 100) bits = bits + 64;
    }

    return bits;
}
