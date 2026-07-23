/* canon.c -- the stage-2 self-host TEST: a compiler-shaped canonicalizer.
 *
 * Reads a source file, tokenizes it into a heap-allocated linked list of
 * token records (the M2-Planet token-list data model), then walks that list
 * recursively to emit one canonical token per line.
 *
 * Canonical form: each maximal run of non-separator bytes on its own line,
 * terminated by a newline. Separators (space, tab, newline) only delimit.
 * The transform is idempotent -- canon(canon(x)) == canon(x) -- so a second
 * generation over the first generation's output is a real fixpoint check.
 *
 * Written in the stage-2 subset. Buffers are calloc'd rather than declared
 * as global arrays: global data emits one .byte per byte and is bounded
 * (m55), so large arrays belong on the heap.
 */

struct Tok {
    int off;
    int len;
    struct Tok* nx;
};

char* IN;
char* OUT;
struct Tok* HEAD;
struct Tok* TAIL;

/* separator classifier; used directly and through a function pointer */
int issep(int c) {
    if (c == 32) { return 1; }
    if (c == 9)  { return 1; }
    if (c == 10) { return 1; }
    return 0;
}

/* first non-separator at or after i */
int skip_seps(int i, int n, int (*sep)(int)) {
    while (i < n) {
        if (sep(IN[i]) == 0) { return i; }
        i = i + 1;
    }
    return i;
}

/* end of the token starting at i: first separator, or n */
int tok_end(int i, int n, int (*sep)(int)) {
    while (i < n) {
        if (sep(IN[i])) { return i; }
        i = i + 1;
    }
    return i;
}

/* allocate one token record */
struct Tok* mk_tok(int off, int len) {
    struct Tok* t;
    t = calloc(1, 24);
    t->off = off;
    t->len = len;
    t->nx = 0;
    return t;
}

/* link a record onto the tail of the global list */
int append(int off, int len) {
    struct Tok* node;
    node = mk_tok(off, len);
    if (HEAD == 0) {
        HEAD = node;
        TAIL = node;
        return 0;
    }
    TAIL->nx = node;
    TAIL = node;
    return 0;
}

/* scan IN[0..n) into the token list; returns the token count */
int lex(int n, int (*sep)(int)) {
    int i;
    int start;
    int end;
    int count;
    i = 0;
    count = 0;
    while (i < n) {
        i = skip_seps(i, n, sep);
        if (i < n) {
            start = i;
            end = tok_end(i, n, sep);
            append(start, end - start);
            count = count + 1;
            i = end;
        }
    }
    return count;
}

/* copy IN[off..off+len) to OUT[dst..); returns the new dst */
int emit_span(int off, int len, int dst) {
    int i;
    i = 0;
    while (i < len) {
        OUT[dst] = IN[off + i];
        dst = dst + 1;
        i = i + 1;
    }
    return dst;
}

/* recursive walk: one token per line. depth == token count. */
int emit_list(struct Tok* p, int dst) {
    if (p == 0) { return dst; }
    dst = emit_span(p->off, p->len, dst);
    OUT[dst] = 10;
    dst = dst + 1;
    return emit_list(p->nx, dst);
}

int main() {
    int fd;
    int n;
    int outlen;

    IN = calloc(1, 8192);
    OUT = calloc(1, 16384);
    HEAD = 0;
    TAIL = 0;

    fd = open("in", 0, 0);
    n = read(fd, IN, 8192);
    close(fd);

    lex(n, issep);
    outlen = emit_list(HEAD, 0);

    fd = open("out", 577, 420);
    write(fd, OUT, outlen);
    close(fd);
    return outlen;
}
