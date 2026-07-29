/* &local[i] -- case 24's shape on a LOCAL array instead of a global one.
 *
 * This case exists to be a CONTROL, not to find a bug. Locals carry array-ness
 * through TLO_LOCAL_ARRAY, globals through array_modifier, members through
 * is_array -- three separate mechanisms for one fact. If 24 fails and 25
 * passes, the hole is the global path specifically and the fix is narrow. If
 * both fail, the address-of-index site is wrong everywhere and the fix is the
 * shared one.
 *
 * A pair of cases that DISAGREE is worth more here than either alone.
 */
int main(void)
{
    long slots[8];
    long* holes[8];
    long* p;
    long** pp;
    int i;

    i = 0;
    while (i < 8) { slots[i] = i + 100; holes[i] = 0; i = i + 1; }

    p = &slots[3];
    if (*p != 103) return 1;

    *p = 999;
    if (slots[3] != 999) return 2;

    p = &slots[0];
    if (*p != 100) return 3;

    pp = &holes[5];
    if (*pp != 0) return 4;

    holes[5] = &slots[3];
    if (*pp != &slots[3]) return 5;
    if (**pp != 999) return 6;

    *pp = &slots[7];
    if (holes[5] != &slots[7]) return 7;
    if (**pp != 107) return 8;

    i = 6;
    pp = &holes[i];
    if (*pp != 0) return 9;

    return 0;
}
