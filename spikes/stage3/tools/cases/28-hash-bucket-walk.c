/* tok_alloc, reduced to what it does and nothing else.
 *
 *     static TokenSym *hash_ident[TOK_HASH_SIZE];
 *
 *     h = TOK_HASH_INIT;
 *     for(i=0;i<len;i++) h = TOK_HASH_FUNC(h, ((unsigned char *)str)[i]);
 *     h &= (TOK_HASH_SIZE - 1);
 *     pts = &hash_ident[h];
 *     for(;;) {
 *         ts = *pts;
 *         if (!ts) break;
 *         if (ts->len == len && !memcmp(ts->str, str, len)) return ts;
 *         pts = &(ts->hash_next);
 *     }
 *
 * Cases 24-27 each isolate one construct. This one is the whole idiom, because
 * a chain of correct pieces can still be a broken chain: the bucket walk stores
 * a pointer to a STRUCT MEMBER (&ts->hash_next) back into the same variable
 * that held a pointer into a GLOBAL ARRAY (&hash_ident[h]) -- two of the three
 * array-ness mechanisms feeding one pointer, alternately, in a loop.
 *
 * No allocation: entries come from a static pool, so this links against
 * libc-core like every other case and a failure cannot be blamed on malloc.
 */
#define POOL 8
#define NBUCKET 16

struct Sym {
    struct Sym* hash_next;
    int   len;
    char* str;
};

static struct Sym* buckets[NBUCKET];
static struct Sym  pool[POOL];
static int         pool_used;

static int hash_of(char* s, int len)
{
    int h;
    int i;
    h = 1;
    i = 0;
    while (i < len) {
        h = h * 263 + s[i];
        i = i + 1;
    }
    if (h < 0) h = 0 - h;
    return h & (NBUCKET - 1);
}

static int same(char* a, char* b, int len)
{
    int i;
    i = 0;
    while (i < len) {
        if (a[i] != b[i]) return 0;
        i = i + 1;
    }
    return 1;
}

/* returns the entry for str, creating it if absent -- tok_alloc's contract */
static struct Sym* intern(char* str, int len)
{
    struct Sym** pts;
    struct Sym*  ts;
    int h;

    h = hash_of(str, len);
    pts = &buckets[h];
    for (;;) {
        ts = *pts;
        if (ts == 0) break;
        if (ts->len == len) {
            if (same(ts->str, str, len)) return ts;
        }
        pts = &(ts->hash_next);
    }
    if (pool_used >= POOL) return 0;
    ts = &pool[pool_used];
    pool_used = pool_used + 1;
    ts->hash_next = 0;
    ts->len = len;
    ts->str = str;
    *pts = ts;                  /* store back through the bucket pointer */
    return ts;
}

int main(void)
{
    struct Sym* a;
    struct Sym* b;
    struct Sym* c;
    char  table[16];
    char* p;
    char* r;
    int   n;
    int   ch;
    int   i;

    /* an empty table must not fault on the first lookup */
    a = intern("int", 3);
    if (a == 0) return 1;
    if (a->len != 3) return 2;
    if (pool_used != 1) return 3;

    /* the same key again must find the existing entry, not make a second */
    b = intern("int", 3);
    if (b != a) return 4;
    if (pool_used != 1) return 5;

    /* a different key */
    c = intern("char", 4);
    if (c == 0) return 6;
    if (c == a) return 7;
    if (pool_used != 2) return 8;
    if (c->len != 4) return 9;

    /* walk the keyword table the way tccpp_new does, so the pointer
     * difference in an argument list is exercised in place. Declarations are
     * at the top of the function on purpose: a nested block with its own
     * declarations is a separate question and this case is not asking it. */
    table[0]='i'; table[1]='f'; table[2]=0;
    table[3]='d'; table[4]='o'; table[5]=0;
    table[6]='f'; table[7]='o'; table[8]='r'; table[9]=0;
    table[10]=0;

    p = table;
    n = 0;
    while (*p) {
        r = p;
        for (;;) {
            ch = *r++;
            if (ch == 0) break;
        }
        if (intern(p, r - p - 1) == 0) return 10;
        p = r;
        n = n + 1;
        if (n > 8) return 11;
    }
    if (n != 3) return 12;

    /* three more entries, none of them colliding with the first two */
    if (pool_used != 5) return 13;

    /* every entry must still be findable: a corrupted bucket pointer shows up
     * as a re-intern rather than a fault */
    if (intern("int", 3) != a) return 14;
    if (intern("char", 4) != c) return 15;
    if (pool_used != 5) return 16;

    /* force a collision chain: fill the pool and confirm the walk reaches the
     * end rather than looping or faulting */
    i = 0;
    while (pool_used < POOL) {
        if (intern("aa", 2) == 0) return 17;
        if (intern("bb", 2) == 0) return 18;
        if (intern("cc", 2) == 0) return 19;
        i = i + 1;
        if (i > 8) return 20;
    }
    if (pool_used != POOL) return 21;

    return 0;
}
