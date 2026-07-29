/* A pointer to a struct, in a global variable. No array anywhere.
 *
 * 36 and 37 (struct Big* x8 and x64) both SEGFAULT; 34 and 35 (long* at the
 * same two sizes) both pass. The element type is confirmed and the count is
 * irrelevant. What is not known is WHICH statement dies, because a crash
 * carries no return code, and 36 has six steps.
 *
 * These three split 36 along the only axes left. Each is the smallest program
 * that can ask its question:
 *
 *     38  a struct pointer, NO ARRAY at all
 *     39  a struct pointer in an array, PLAIN INDEX only -- no address-of
 *     40  a struct pointer in an array, ADDRESS-OF INDEX only
 *
 * If 38 fails, arrays have nothing to do with it. If 38 passes and 39 fails,
 * it is storing or loading a struct pointer through an index. If both pass
 * and 40 fails, it is the address-of path specifically, with a struct pointer
 * as the element -- and the emitted M1 for that access reads correct, which
 * would mean reading an emission is not a measurement.
 */
struct Big { long a; long b; long c; long d; long e; long f; };

static struct Big  target;
static struct Big* slot;

int main(void)
{
    struct Big* q;

    target.a = 777;

    slot = &target;

    q = slot;
    if (q != &target) return 1;
    if (q->a != 777) return 2;

    slot = 0;
    if (slot != 0) return 3;

    slot = &target;
    q = slot;
    if (q->a != 777) return 4;

    return 0;
}
