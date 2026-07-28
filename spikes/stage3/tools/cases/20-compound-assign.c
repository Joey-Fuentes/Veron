/* Compound assignment on members and through pointers. tcc's flag handling is
 * mostly |= and &= on struct fields. */
struct F { long flags; int count; char c; };
int main(void)
{
    struct F f;
    struct F* p = &f;
    f.flags = 0; f.count = 0; f.c = 0;
    f.flags |= 4;
    f.flags |= 8;
    if (f.flags != 12) return 1;
    f.flags &= 8;
    if (f.flags != 8) return 2;
    p->count += 5;
    p->count -= 2;
    if (f.count != 3) return 3;
    p->flags <<= 2;
    if (f.flags != 32) return 4;
    p->flags >>= 1;
    if (f.flags != 16) return 5;
    f.c += 65;
    if (f.c != 65) return 6;
    return 0;
}
