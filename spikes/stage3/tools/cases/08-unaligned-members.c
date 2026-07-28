/* Every field kind after a run of chars, which is TCCState's shape. On
 * aarch64 an unaligned 8-byte load FAULTS; on amd64 it merely costs time, so
 * this case is only meaningful on the runner. */
struct Mixed {
    unsigned char a; unsigned char b; unsigned char c;
    char*  p;
    long   l;
    int    i;
    short  s;
    char*  q;
};
int main(void)
{
    struct Mixed m;
    m.a = 1; m.b = 2; m.c = 3;
    m.p = "abc"; m.l = 123456789; m.i = 42; m.s = 7; m.q = "xyz";
    if (m.a != 1 || m.c != 3) return 1;
    if (m.p[0] != 'a') return 2;
    if (m.l != 123456789) return 3;
    if (m.i != 42) return 4;
    if (m.s != 7) return 5;
    if (m.q[2] != 'z') return 6;
    return 0;
}
