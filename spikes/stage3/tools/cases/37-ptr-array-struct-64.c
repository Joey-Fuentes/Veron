/* An array of 64 pointers to a 48-byte struct.
 *
 * ONE COMBINATION PER FILE, ON PURPOSE. A single case with a bitmask would be
 * better if these merely returned the wrong value -- but 28 and 31 SEGFAULT,
 * and a crash returns no bitmask at all. Separate files each crash or pass on
 * their own, and the return code names the step.
 *
 * The variable being crossed is element type against element count:
 *
 *     34  long*        x8    control -- case 24 already passes this shape
 *     35  long*       x64
 *     36  struct Big*  x8
 *     37  struct Big* x64
 *
 * Cases 32 and 33 ruled out size: a 64-element long array and a 4-element
 * array of 96-byte structs both pass, guards intact. The only two cases in
 * this directory that fail are the only two that hold POINTERS TO A STRUCT in
 * an array, which is a variable nothing has ever controlled for.
 *
 * The emitted M1 for exactly this access is correct -- base loaded, index
 * scaled by 8 -- so if these fail, the emission being readable is not the
 * same as the program being right, and that is worth knowing on its own.
 */
struct Big { long a; long b; long c; long d; long e; long f; };

static struct Big target;
static struct Big* arr[64];

int main(void)
{
    struct Big** pp;
    struct Big*  q;
    int i;

    target.a = 777;

    i = 0;
    while (i < 64) { arr[i] = 0; i = i + 1; }

    arr[40] = &target;

    /* plain index -- this path never went through Address_of */
    q = arr[40];
    if (q != &target) return 1;
    if (q->a != 777) return 2;

    /* address of the element, then read through it */
    pp = &arr[40];
    q = *pp;
    if (q != &target) return 3;
    if (q->a != 777) return 4;

    /* store through the computed address */
    *pp = 0;
    if (arr[40] != 0) return 5;

    /* put it back with a variable index rather than a literal */
    i = 40;
    pp = &arr[i];
    *pp = &target;
    if (arr[40] != &target) return 6;

    q = *pp;
    if (q->a != 777) return 7;

    return 0;
}
