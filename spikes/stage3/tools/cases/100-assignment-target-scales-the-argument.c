/* BITMASK
 *
 * libtcc.c tcc_open_bf:
 *     BufferedFile *bf;
 *     bf = tcc_mallocz(sizeof(BufferedFile) + buflen);
 *
 * Measured in the running compiler: sizeof(BufferedFile) is 1128, buflen is
 * 8192, and `sizeof(BufferedFile) + buflen` reports 9320 when handed to a
 * probe on the line above -- but tcc_mallocz receives 9,241,704, which is
 * 1128 * (8192 + 1). The addition is scaled by sizeof(BufferedFile).
 *
 * Cases 97, 98 and 99 all pass: the same expression is correct when assigned
 * to an integer, when passed as an argument, and with a typedef name. The one
 * thing they do not do is assign the CALL'S RESULT to a pointer.
 *
 * If the pointer target's element width leaks into the argument expression,
 * every `p = alloc(sizeof(T) + n)` in the program over-allocates by a factor
 * of sizeof(T). It never crashes -- it just asks for a thousand times too
 * much and zeroes it. tcc zeroes 23 MB compiling an empty file where the
 * gcc-built control zeroes 0.23 MB, with the same number of memset calls.
 */
typedef struct { char pad[1128]; } BF;
typedef struct { char pad[16]; } Small;

static unsigned long seen;
static void *alloc(unsigned long n) { seen = n; return 0; }

int main(void)
{
    int bits = 0;
    int buflen = 8192;
    BF *bf;
    Small *sp;
    unsigned long n;
    char *cp;

    /* 1: the exact shape -- result assigned to a wide pointer */
    bf = alloc(sizeof(BF) + buflen);
    if (seen != 1128 + 8192) bits = bits + 1;

    /* 2: same, with a narrow pointer, so the factor differs */
    sp = alloc(sizeof(Small) + buflen);
    if (seen != 16 + 8192) bits = bits + 2;

    /* 4: result assigned to an integer -- the control */
    n = (unsigned long)alloc(sizeof(BF) + buflen);
    if (seen != 1128 + 8192) bits = bits + 4;

    /* 8: result assigned to char*, whose element width is 1 */
    cp = alloc(sizeof(BF) + buflen);
    if (seen != 1128 + 8192) bits = bits + 8;

    /* 16: a plain integer argument with a pointer target */
    bf = alloc(buflen);
    if (seen != 8192) bits = bits + 16;

    /* 32: two integers added, no sizeof, pointer target */
    bf = alloc(buflen + 7);
    if (seen != 8199) bits = bits + 32;

    (void)bf; (void)sp; (void)cp; (void)n;
    return bits;
}
