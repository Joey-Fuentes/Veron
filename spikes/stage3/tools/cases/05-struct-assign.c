/* Whole-struct assignment, including sizes that are not a multiple of the
 * register width -- the 27-byte case that produced a 3-byte load. */
struct S { long a; long b; int c; char d; };
int main(void)
{
    struct S x;
    struct S y;
    x.a = 1; x.b = 2; x.c = 3; x.d = 4;
    y = x;
    /* SEPARATE ifs ON PURPOSE. Written as one `||` chain this case could not
     * distinguish a broken struct copy from the known non-short-circuit `||`
     * -- and on aarch64 it failed while passing on amd64, which is exactly
     * the ambiguity you do not want in a case meant to isolate one thing.
     * Each field now names itself. */
    if (y.a != 1) return 1;
    if (y.b != 2) return 2;
    if (y.c != 3) return 3;
    if (y.d != 4) return 4;
    return 0;
}
