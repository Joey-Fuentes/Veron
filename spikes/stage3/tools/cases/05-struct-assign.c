/* Whole-struct assignment, including sizes that are not a multiple of the
 * register width -- the 27-byte case that produced a 3-byte load. */
struct S { long a; long b; int c; char d; };
int main(void)
{
    struct S x;
    struct S y;
    x.a = 1; x.b = 2; x.c = 3; x.d = 4;
    y = x;
    if (y.a != 1 || y.b != 2 || y.c != 3 || y.d != 4) return 1;
    return 0;
}
