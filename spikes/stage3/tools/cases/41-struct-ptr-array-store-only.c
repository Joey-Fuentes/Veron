/* THE SMALLEST PROGRAM THAT MIGHT CRASH. One store, nothing else.
 *
 * 38 passes: a struct pointer in a plain global variable is fine, assigned
 * and read.
 * 39 fails: the same pointer in an array, reached by PLAIN INDEX -- no
 * address-of anywhere. 40 fails too, but 39 failing means 40's extra
 * construct is not what breaks it.
 *
 * 34 (long* arr[8]) passes. The only difference from 39 is the pointee type.
 *
 * So the question left is whether it is the STORE or the LOAD, and neither 39
 * nor 36 can say, because they do both before checking anything. This does
 * one store and returns. If it crashes, the reproducer is three lines.
 *
 * The array is deliberately larger than the index touched, so a crash cannot
 * be a bounds problem: element 0 of an 8-element array.
 */
struct Big { long a; long b; long c; long d; long e; long f; };

static struct Big  target;
static struct Big* arr[8];

int main(void)
{
    target.a = 777;

    arr[0] = 0;
    arr[1] = &target;

    return 0;
}
