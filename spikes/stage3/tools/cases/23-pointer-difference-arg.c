/* `f(p, r - p - 1)` -- a pointer DIFFERENCE computed inside an argument list,
 * after a loop that advanced one of the pointers with *r++.
 *
 * This is tccpp_new's keyword-table loop, which is where the micro-c-built tcc
 * faults:
 *
 *     p = tcc_keywords;
 *     while (*p) {
 *         r = p;
 *         for(;;) { c = *r++; if (c == '\0') break; }
 *         tok_alloc(p, r - p - 1);
 *         p = r;
 *     }
 */
static int seen_len;
static char* seen_ptr;
static void sink(char* s, int len) { seen_ptr = s; seen_len = len; }

int main(void)
{
    char table[16];
    char* p;
    char* r;
    int c;
    int n;

    /* two NUL-terminated words back to back, then an empty one to stop */
    table[0]='a'; table[1]='b'; table[2]='c'; table[3]=0;
    table[4]='d'; table[5]='e'; table[6]=0;
    table[7]=0;

    p = table;
    n = 0;
    while (*p) {
        r = p;
        for(;;) {
            c = *r++;
            if (c == 0) break;
        }
        sink(p, r - p - 1);
        if (n == 0) { if (seen_len != 3) return 1; if (seen_ptr[0] != 'a') return 2; }
        if (n == 1) { if (seen_len != 2) return 3; if (seen_ptr[0] != 'd') return 4; }
        p = r;
        n = n + 1;
        if (n > 4) return 5;
    }
    if (n != 2) return 6;
    return 0;
}
