/* `p + n` advances by n * sizeof(*p), not by n bytes.
 *
 *     long lbuf[4];  lbuf + 1     eight bytes on
 *     long *q;       q + 1        the same
 *
 * Indexing always scaled -- p[n], p++ and p += n all did -- and this one
 * arithmetic path did not, which is why it survived: M2-Planet's own sources
 * index rather than add.
 *
 * WAS A KNOWN GAP. Closed by EXPERIMENT-zz7. It stayed open for two rounds
 * because the obvious fix does not work on its own: an integer literal had no
 * type, so `q + 1` reported a pointer on BOTH sides and read as a pointer
 * difference. See the patch preamble -- four losses had to be closed, and each
 * was invisible until the one before it was fixed.
 *
 * The array form below is the one that needs decay: an array's type IS its
 * element type in this compiler, so `lbuf` looks like a `long` rather than a
 * `long*` and nothing was there to scale by.
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
