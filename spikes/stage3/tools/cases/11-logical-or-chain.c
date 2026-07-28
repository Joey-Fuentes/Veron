/* A chain of || in a condition, which is what case 05 used to hide behind.
 * micro-c does not short-circuit, so both sides of every || are evaluated --
 * harmless here, since none of the operands can fault. If THIS passes on
 * aarch64 while 05 fails, the fault is the struct copy; if both fail, it is
 * the || itself. */
int main(void)
{
    int a = 1; int b = 2; int c = 3; int d = 4;
    if (a != 1 || b != 2 || c != 3 || d != 4) return 1;
    if (!(a == 1 && b == 2 && c == 3 && d == 4)) return 2;
    if (a == 9 || b == 9) return 3;
    return 0;
}
