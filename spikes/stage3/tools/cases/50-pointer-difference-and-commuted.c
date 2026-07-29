/* The three pointer-arithmetic shapes that are NOT `p + n`.
 *
 *     n + p    legal C, and the scale belongs on the LEFT operand
 *     p - n    scales like the addition
 *     p - q    a count of ELEMENTS, so the divide comes AFTER the subtraction
 *
 * MICRO-C.md recorded the first and third as knowingly wrong and left them
 * without a case, so nothing measured them. EXPERIMENT-zz7 handles all four
 * shapes; this file is the half that case 21 does not reach.
 *
 * ELEMENT WIDTHS DIFFER: char is 1, long is 8, and the struct is deliberately
 * not a power of two after padding, so a difference that forgets to divide, or
 * divides by the wrong number, cannot come out right by luck.
 */
struct odd { long a; char b; };

static long  larr[8];
static char  carr[8];
static struct odd oarr[4];

int main(void)
{
    long* lp;
    long* lq;
    char* cp;
    char* cq;
    struct odd* op;
    struct odd* oq;
    int i;

    for (i = 0; i < 8; i = i + 1) { larr[i] = i; carr[i] = (char)i; }

    /* n + p is p + n */
    lp = larr + 3;
    lq = 3 + larr;
    if (lp != lq) return 1;
    if (*lq != 3) return 2;

    cp = carr + 5;
    cq = 5 + carr;
    if (cp != cq) return 3;
    if (*cq != 5) return 4;

    /* p - n */
    lp = larr + 6;
    lp = lp - 2;
    if (*lp != 4) return 5;

    /* p - q is a count of elements, not of bytes */
    lp = larr + 7;
    lq = larr + 2;
    if (lp - lq != 5) return 6;
    if (lq - lp != -5) return 7;

    cp = carr + 7;
    cq = carr + 2;
    if (cp - cq != 5) return 8;

    op = oarr + 3;
    oq = oarr + 1;
    if (op - oq != 2) return 9;

    /* the identity that ties the two together */
    lp = larr + 1;
    lq = lp + 4;
    if (lq - lp != 4) return 10;
    if (*(lp + (lq - lp)) != 5) return 11;

    return 0;
}
