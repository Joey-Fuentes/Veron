/* &global[i] -- the address of an element of a GLOBAL array whose elements are
 * eight bytes wide.
 *
 * This is tccpp.c:509 in tok_alloc:
 *
 *     static TokenSym *hash_ident[TOK_HASH_SIZE];
 *     ...
 *     pts = &hash_ident[h];
 *     ts = *pts;                <- the micro-c-built tcc segfaults HERE
 *
 * h is masked by `h &= (TOK_HASH_SIZE - 1)` on the line before, so the index is
 * in range whatever else is wrong. That leaves the address computation itself.
 *
 * The reason to suspect it: "is this an array" is not a property of the type in
 * micro-c. It is carried by the global flag `indexing_an_array`, set from three
 * different places -- is_array for struct members, TLO_LOCAL_ARRAY for locals,
 * array_modifier for globals -- and reset after one use. Address_of is a second
 * global flag read at a different point. &global[i] needs both at once.
 *
 * hash_ident lives in BSS, so if the base is LOADED rather than decayed to an
 * address the base reads as 0 and pts comes out as a small integer -- which is
 * exactly what a fault on the following dereference looks like.
 */
static long slots[8];
static long* holes[8];          /* array of POINTERS: hash_ident's shape */

int main(void)
{
    long* p;
    long** pp;
    int i;

    i = 0;
    while (i < 8) { slots[i] = i + 100; holes[i] = 0; i = i + 1; }

    /* read through the address of an element */
    p = &slots[3];
    if (*p != 103) return 1;

    /* write through it */
    *p = 999;
    if (slots[3] != 999) return 2;

    /* index 0 must not be a special case: it is the one index where a base
     * that was loaded instead of decayed can still look plausible */
    p = &slots[0];
    if (*p != 100) return 3;

    /* the hash_ident shape exactly: a pointer INTO a global array of pointers */
    pp = &holes[5];
    if (*pp != 0) return 4;

    holes[5] = &slots[3];
    if (*pp != &slots[3]) return 5;
    if (**pp != 999) return 6;

    /* store through the pointer-to-pointer, as tok_alloc_new does */
    *pp = &slots[7];
    if (holes[5] != &slots[7]) return 7;
    if (**pp != 107) return 8;

    /* a computed index, not a literal -- h is a variable at the real site */
    i = 6;
    pp = &holes[i];
    if (*pp != 0) return 9;

    return 0;
}
