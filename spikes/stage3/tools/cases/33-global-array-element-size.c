/* BITMASK. Total BYTES or element COUNT -- which one is the limit?
 *
 * Case 32 varies the count with an 8-byte element, so count and bytes move
 * together and it cannot tell them apart. This one holds the count at four
 * and grows the element instead. Four elements is a size every passing case
 * in this directory already uses.
 *
 *     rc & 1    long   x4       32 bytes   -- the known-good shape
 *     rc & 2    S24    x4       96 bytes
 *     rc & 4    S48    x4      192 bytes
 *     rc & 8    S96    x4      384 bytes
 *
 * If 32 fails above some count and this passes at every size, the limit is
 * the count. If both fail at about the same number of BYTES, it is the
 * storage reservation and the count is a coincidence.
 *
 * Still no address-of and no pointer arrays: only `arr[i].first` and
 * `arr[i].last`, so a failure cannot be attributed to any of the expression
 * bugs found so far. first and last bracket each element, which is what
 * catches an element STRIDE that is wrong without the storage being wrong.
 */
struct S24 { long first; long mid;  long last; };
struct S48 { long first; long b; long c; long d; long e; long last; };
struct S96 { long first; long b; long c; long d; long e; long f;
             long g; long h; long i; long j; long k; long last; };

static long        plain[4];  static long guardp = 1111;
static struct S24  s24[4];    static long guard24 = 2424;
static struct S48  s48[4];    static long guard48 = 4848;
static struct S96  s96[4];    static long guard96 = 9696;

int main(void)
{
    int i;
    int bad;

    bad = 0;

    i = 0;
    while (i < 4) { plain[i] = i + 10; i = i + 1; }
    i = 0;
    while (i < 4) { s24[i].first = i + 20; s24[i].last = i + 25; i = i + 1; }
    i = 0;
    while (i < 4) { s48[i].first = i + 40; s48[i].last = i + 45; i = i + 1; }
    i = 0;
    while (i < 4) { s96[i].first = i + 90; s96[i].last = i + 95; i = i + 1; }

    i = 0;
    while (i < 4) { if (plain[i] != i + 10) { bad = bad | 1; i = 4; } i = i + 1; }
    if (guardp != 1111) bad = bad | 1;

    i = 0;
    while (i < 4)
    {
        if (s24[i].first != i + 20) { bad = bad | 2; i = 4; }
        else if (s24[i].last != i + 25) { bad = bad | 2; i = 4; }
        i = i + 1;
    }
    if (guard24 != 2424) bad = bad | 2;

    i = 0;
    while (i < 4)
    {
        if (s48[i].first != i + 40) { bad = bad | 4; i = 4; }
        else if (s48[i].last != i + 45) { bad = bad | 4; i = 4; }
        i = i + 1;
    }
    if (guard48 != 4848) bad = bad | 4;

    i = 0;
    while (i < 4)
    {
        if (s96[i].first != i + 90) { bad = bad | 8; i = 4; }
        else if (s96[i].last != i + 95) { bad = bad | 8; i = 4; }
        i = i + 1;
    }
    if (guard96 != 9696) bad = bad | 8;

    return bad;
}
