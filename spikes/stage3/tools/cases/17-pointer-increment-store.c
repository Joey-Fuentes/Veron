/* `*p++ = x` and friends. tcc writes tokens this way constantly --
 * `*s->include_stack_ptr++ = file` is the exact idiom. */
int main(void)
{
    char buf[8];
    char* p = buf;
    int i = 0;
    while (i < 8) { buf[i] = 0; i = i + 1; }
    *p++ = 'a';
    *p++ = 'b';
    *p = 'c';
    if (buf[0] != 'a') return 1;
    if (buf[1] != 'b') return 2;
    if (buf[2] != 'c') return 3;
    if (p != buf + 2) return 4;

    long lbuf[4];
    long* q = lbuf;
    *q++ = 100;
    *q++ = 200;
    if (lbuf[0] != 100) return 5;
    if (lbuf[1] != 200) return 6;
    /* `lbuf + 2` needs POINTER ARITHMETIC SCALING, which micro-c does not do --
     * see case 21. Checked here by element instead so this case tests the
     * increment idiom it is named for and nothing else. */
    if (lbuf[0] != 100) return 7;
    return 0;
}
