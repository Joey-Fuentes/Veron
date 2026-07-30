/* BITMASK
 * Cases 97 and 98 pass with `sizeof(struct Tag) + n`. tcc writes
 * `sizeof(BufferedFile) + buflen` where BufferedFile is a TYPEDEF NAME.
 */
struct Tag { char pad[1128]; };
typedef struct Tag Named;
typedef struct { char pad[1128]; } Anon;

static unsigned long seen;
static void take(unsigned long n) { seen = n; }

int main(void)
{
    int bits = 0;
    int buflen = 8192;

    /* 1: struct tag -- known good, the control for the rest */
    if (sizeof(struct Tag) + buflen != 1128 + 8192) bits = bits + 1;

    /* 2: typedef name for the same struct */
    if (sizeof(Named) + buflen != 1128 + 8192) bits = bits + 2;

    /* 4: typedef of an anonymous struct, as tcc declares BufferedFile */
    if (sizeof(Anon) + buflen != 1128 + 8192) bits = bits + 4;

    /* 8: typedef name, passed as an argument */
    take(sizeof(Named) + buflen);
    if (seen != 1128 + 8192) bits = bits + 8;

    /* 16: anonymous typedef, passed as an argument -- tcc's exact shape */
    take(sizeof(Anon) + buflen);
    if (seen != 1128 + 8192) bits = bits + 16;

    /* 32: the typedef'd size alone must still be the size */
    if (sizeof(Named) != 1128) bits = bits + 32;

    return bits;
}
