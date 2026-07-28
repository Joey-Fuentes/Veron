/* &s->member passed out, written through, read back -- the tcc_set_str
 * pattern, and the shape that follows the last marker tcc reaches. */
struct S { unsigned char pad; char** ary; int n; };
static void grow(char*** pary, int* pn)
{
    pn[0] = pn[0] + 1;
    pary[0] = 0;
}
int main(void)
{
    struct S s;
    s.pad = 1; s.ary = (char**)1; s.n = 0;
    grow(&s.ary, &s.n);
    if (s.n != 1) return 1;
    if (s.ary != 0) return 2;
    if (s.pad != 1) return 3;
    return 0;
}
