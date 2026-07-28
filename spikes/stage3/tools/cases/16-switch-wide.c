/* A switch with many cases, negative values, fallthrough and a default that is
 * not last -- tcc's parser is one long switch and its own test suite covers
 * exactly this. */
static int classify(int c)
{
    int r = 0;
    switch (c) {
    default: r = 100; break;
    case -2: r = 1; break;
    case 0: r = 2;
    case 1: r = r + 10; break;      /* fallthrough into this */
    case 100: r = 4; break;
    case 1000: r = 5; break;
    }
    return r;
}
int main(void)
{
    if (classify(-2) != 1) return 1;
    if (classify(0) != 12) return 2;    /* 2 then +10 */
    if (classify(1) != 10) return 3;
    if (classify(100) != 4) return 4;
    if (classify(1000) != 5) return 5;
    if (classify(77) != 100) return 6;  /* default, declared first */
    return 0;
}
