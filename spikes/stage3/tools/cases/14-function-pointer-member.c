/* A function pointer stored in a struct and called through it. tcc keeps
 * several -- the reallocator, backend hooks -- and calling through a member is
 * different from calling through a plain variable. */
struct Ops { int (*add)(int, int); int (*mul)(int, int); int tag; };
static int do_add(int a, int b) { return a + b; }
static int do_mul(int a, int b) { return a * b; }
int main(void)
{
    struct Ops o;
    o.add = do_add; o.mul = do_mul; o.tag = 3;
    if (o.add(2, 3) != 5) return 1;
    if (o.mul(4, 5) != 20) return 2;
    if (o.tag != 3) return 3;
    struct Ops* p = &o;
    if (p->add(10, 1) != 11) return 4;
    if (p->mul(6, 7) != 42) return 5;
    return 0;
}
