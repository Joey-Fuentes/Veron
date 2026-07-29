/* WHOLE-STRUCT ASSIGNMENT WHERE BOTH SIDES ARE FILE-SCOPE.
 *
 * Case 05 covers the local form and has done since early on. Nothing covered
 * the global form, and it is the one tcc hits:
 *
 *     char_pointer_type = char_type;          tccgen.c:392
 *
 * both static. micro-c loaded the source struct's first eight bytes and used
 * them as the source ADDRESS, so it copied from wherever that integer
 * pointed. The local form was already guarded; the guard tested a variable
 * that only carries the type's real width for locals and arguments.
 *
 * A PAIR, ON PURPOSE. Every check is done on a global and on a local with the
 * same contents, and case 05 is the local-only version. If the global half
 * fails while the local half passes, the storage class is the variable --
 * which is exactly what was true here and what no single-sided case could
 * have said.
 *
 * The struct is deliberately larger than a register and NOT a multiple of it:
 * three longs and a char is 25 bytes of content, so the copy has a tail
 * chunk. A struct that divides evenly hides a whole class of loop-tail bug.
 */
struct S { long a; long b; long c; char d; };

static struct S g_src;
static struct S g_dst;
static long     guard;

int main(void)
{
    struct S l_src;
    struct S l_dst;

    guard = 999;

    /* --- global to global --- */
    g_src.a = 1; g_src.b = 2; g_src.c = 3; g_src.d = 4;
    g_dst = g_src;
    if (g_dst.a != 1) return 1;
    if (g_dst.b != 2) return 2;
    if (g_dst.c != 3) return 3;
    if (g_dst.d != 4) return 4;

    /* --- local to local, the case-05 shape, for comparison --- */
    l_src.a = 5; l_src.b = 6; l_src.c = 7; l_src.d = 8;
    l_dst = l_src;
    if (l_dst.a != 5) return 5;
    if (l_dst.b != 6) return 6;
    if (l_dst.c != 7) return 7;
    if (l_dst.d != 8) return 8;

    /* --- across the boundary, both directions --- */
    g_dst = l_src;
    if (g_dst.a != 5) return 9;
    if (g_dst.d != 8) return 10;

    l_dst = g_src;
    if (l_dst.a != 1) return 11;
    if (l_dst.d != 4) return 12;

    /* the source must be untouched by any of it */
    if (g_src.a != 1) return 13;
    if (l_src.a != 5) return 14;

    /* and nothing may have been written past the destination */
    if (guard != 999) return 15;

    return 0;
}
