/* Brace initialisers, including nested ones and partial ones. tcc uses them
 * for its type tables and option tables. */
struct Inner { int a; int b; };
struct Outer { int x; struct Inner in; int y; };
static int flat[4] = { 10, 20, 30, 40 };
static struct Inner one = { 1, 2 };
static struct Outer nest = { 7, { 8, 9 }, 10 };
static struct Inner partial = { 5 };        /* b must be zero */
int main(void)
{
    if (flat[0] != 10 || flat[3] != 40) return 1;
    if (one.a != 1 || one.b != 2) return 2;
    if (nest.x != 7) return 3;
    if (nest.in.a != 8 || nest.in.b != 9) return 4;
    if (nest.y != 10) return 5;
    if (partial.a != 5) return 6;
    if (partial.b != 0) return 7;
    return 0;
}
