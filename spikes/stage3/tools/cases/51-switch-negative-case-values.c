/* Negative `case` labels, on both architectures.
 *
 * `case -2:` was loaded as 4294967294. The case value is kept in the case list
 * as its LABEL SPELLING, which is rendered unsigned, and the jump table
 * recovered the constant by strtoint()ing that name back -- so the sign was
 * laundered out through a string. The switch value in the other register is
 * sign-extended to the full width, so nothing matched and every negative case
 * fell through to default.
 *
 * IT PASSED ON amd64 AND FAILED ON aarch64, which is the whole reason this
 * file exists as well as case 16. x86-64's `mov_rax,%imm32` sign-extends, so
 * the wrong constant landed on the right value; aarch64 builds immediates
 * zero-extended and does not. Case 16 has a single `case -2:` among six
 * probes and caught it. This one is the class, not the instance:
 *
 *   -1        the boundary, where magnitude-minus-one is zero
 *   -2        case 16's value
 *   -1000     past a byte
 *   -65536    past a halfword, so the immediate needs more than one movz
 *   large     near the 32-bit limit
 *
 * The positives beside them are there so a fix that breaks ordinary switches
 * to repair negative ones is caught in the same run, and `default` is probed
 * because a case that silently does not match reaches it instead -- which is
 * exactly what the bug looked like from outside.
 */
static int f(int c)
{
    switch (c) {
    case -1:          return 11;
    case -2:          return 12;
    case -1000:       return 13;
    case -65536:      return 14;
    case -2147483647: return 15;
    case 0:           return 16;
    case 5:           return 17;
    case 65536:       return 18;
    default:          return 99;
    }
}

/* fallthrough and a negative label in the middle of it */
static int g(int c)
{
    int r = 0;
    switch (c) {
    case -7: r = 1;
    case -8: r = r + 10; break;
    case  9: r = 5; break;
    }
    return r;
}

int main(void)
{
    if (f(-1) != 11) return 1;
    if (f(-2) != 12) return 2;
    if (f(-1000) != 13) return 3;
    if (f(-65536) != 14) return 4;
    if (f(-2147483647) != 15) return 5;
    if (f(0) != 16) return 6;
    if (f(5) != 17) return 7;
    if (f(65536) != 18) return 8;
    if (f(-3) != 99) return 9;
    if (f(1) != 99) return 10;

    if (g(-7) != 11) return 11;   /* 1 then +10 */
    if (g(-8) != 10) return 12;
    if (g(9) != 5) return 13;
    if (g(0) != 0) return 14;
    return 0;
}
