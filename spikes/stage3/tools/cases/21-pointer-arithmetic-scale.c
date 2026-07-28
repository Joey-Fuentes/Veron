/* KNOWN GAP. `p + n` must advance by n * sizeof(*p); micro-c advances n BYTES.
 *
 *     long lbuf[4];  lbuf + 1     should be 8 bytes on, is 1
 *     long *q;       q + 1        the same
 *
 * Indexing is correct -- p[n] scales -- which is why this survived: M2-Planet's
 * own sources index and rarely add. tcc does both.
 *
 * A fix exists (scale_pointer_operand in cc_core.c) and is NOT wired in: it
 * made these pass and broke case 10, so it is recorded rather than shipped.
 * Two shapes it would still get wrong, both needing type information that
 * promote_type has already folded away by the time the operator is handled:
 *     n + p      the scale belongs on the other operand
 *     p - q      the answer is a count of elements, so divide after
 */
int main(void)
{
    long lbuf[4];
    long* q = lbuf;
    lbuf[0] = 0; lbuf[1] = 0;

    if ((char*)(q + 1) - (char*)q != (char*)8) return 1;
    if ((char*)(lbuf + 1) - (char*)lbuf != (char*)8) return 2;

    q = lbuf + 2;
    *q = 55;
    if (lbuf[2] != 55) return 3;
    return 0;
}
