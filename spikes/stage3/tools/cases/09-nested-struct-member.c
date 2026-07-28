/* A struct inside a struct, after chars -- the inner one's members must be
 * aligned relative to the OUTER struct's base, not just its own. */
struct Inner { long x; char* p; };
struct Outer { unsigned char flag; struct Inner in; long tail; };
int main(void)
{
    struct Outer o;
    o.flag = 1;
    o.in.x = 99;
    o.in.p = "inner";
    o.tail = 5;
    if (o.flag != 1) return 1;
    if (o.in.x != 99) return 2;
    if (o.in.p[0] != 'i') return 3;
    if (o.tail != 5) return 4;
    return 0;
}
