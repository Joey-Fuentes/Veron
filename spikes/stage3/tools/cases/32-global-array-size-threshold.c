/* BITMASK. Does a global array stop working above some size?
 *
 * Every case in this directory that PASSES has a global array of eight
 * elements or fewer. The two that fail have sixteen and sixty-four. That is a
 * variable nothing has controlled for, and it was invisible because every
 * case was written to test a construct rather than a size.
 *
 * This case tests NO construct. No address-of, no pointers, no structs --
 * only `static long a[N]`, filled and read back. If it fails, the problem is
 * not the codegen for any expression; it is the storage.
 *
 *     rc & 1    4 elements     32 bytes
 *     rc & 2    8 elements     64 bytes
 *     rc & 4   16 elements    128 bytes
 *     rc & 8   32 elements    256 bytes
 *     rc & 16  64 elements    512 bytes
 *
 * A bit is set if the array does not read back what was written OR if the
 * guard that follows it changed. The guards catch a write running past the
 * end of an under-reserved array; the readback catches storage that was never
 * there. They fail differently and it is worth knowing which.
 *
 * ONE MORE REASON THIS MATTERS. difftest links against libc-core while tcc is
 * built against libc-full, and tcc's own `TokenSym *hash_ident[16384]` is
 * memset over its full 128 KB without faulting. If a 512-byte array fails
 * here and a 128 KB one works there, the fault is in this harness, not in
 * micro-c -- and every conclusion drawn from a failing case would be wrong.
 */
static long a4[4];    static long guard4  = 4444;
static long a8[8];    static long guard8  = 8888;
static long a16[16];  static long guard16 = 1616;
static long a32[32];  static long guard32 = 3232;
static long a64[64];  static long guard64 = 6464;

int main(void)
{
    int i;
    int bad;

    bad = 0;

    i = 0;
    while (i < 4)  { a4[i]  = i + 100; i = i + 1; }
    i = 0;
    while (i < 8)  { a8[i]  = i + 200; i = i + 1; }
    i = 0;
    while (i < 16) { a16[i] = i + 300; i = i + 1; }
    i = 0;
    while (i < 32) { a32[i] = i + 400; i = i + 1; }
    i = 0;
    while (i < 64) { a64[i] = i + 500; i = i + 1; }

    i = 0;
    while (i < 4)  { if (a4[i]  != i + 100) { bad = bad | 1;  i = 4;  } i = i + 1; }
    if (guard4 != 4444) bad = bad | 1;

    i = 0;
    while (i < 8)  { if (a8[i]  != i + 200) { bad = bad | 2;  i = 8;  } i = i + 1; }
    if (guard8 != 8888) bad = bad | 2;

    i = 0;
    while (i < 16) { if (a16[i] != i + 300) { bad = bad | 4;  i = 16; } i = i + 1; }
    if (guard16 != 1616) bad = bad | 4;

    i = 0;
    while (i < 32) { if (a32[i] != i + 400) { bad = bad | 8;  i = 32; } i = i + 1; }
    if (guard32 != 3232) bad = bad | 8;

    i = 0;
    while (i < 64) { if (a64[i] != i + 500) { bad = bad | 16; i = 64; } i = i + 1; }
    if (guard64 != 6464) bad = bad | 16;

    return bad;
}
