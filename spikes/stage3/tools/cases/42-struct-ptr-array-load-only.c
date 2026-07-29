/* The other half of 41: a LOAD from an array of struct pointers, with no
 * store to that array anywhere in the program.
 *
 * BSS is zeroed, so arr[0] is a null pointer and reading it is defined
 * without anything having written it first. That is what makes this the
 * complement of 41 rather than a variation of it -- if 41 crashes and this
 * does not, the store is at fault, and the reverse if it is the other way
 * round. If both crash, the two share whatever is wrong and the next look is
 * at the emitted M1 for the index itself.
 */
struct Big { long a; long b; long c; long d; long e; long f; };

static struct Big* arr[8];

int main(void)
{
    struct Big* q;

    q = arr[0];
    if (q != 0) return 1;

    q = arr[7];
    if (q != 0) return 2;

    return 0;
}
