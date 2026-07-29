/* A C label is scoped to its FUNCTION. Two functions may each declare `redo:`.
 *
 * micro-c emitted the bare source name into one flat assembler namespace, so
 * five functions in tccpp.c each writing `redo:` produced five definitions of
 * `:redo`, and every `goto redo` in the unit went to whichever one survived --
 * into an unrelated function.
 *
 * THIS WAS THE tcc BLOCKER. `next()` called macro_subst_tok, tok_str_add and
 * begin_macro, all three returned correctly, and then `goto redo` left for
 * somewhere else. Four rounds of instrumentation pointed at macro expansion
 * because the last completed statement was the begin_macro call. Nothing was
 * wrong with macro expansion.
 *
 * M2-Planet's own source has globally unique labels, which is why upstream
 * never needed this; there is a comment in its switch code saying exactly
 * that. tcc has 509 gotos and no such convention, and neither does most C.
 *
 * The shapes below are the ones that actually occur: a duplicated name in two
 * functions, a backward goto (the loop idiom), a forward goto (the error-exit
 * idiom), and the same name reused a third time in a function that also
 * contains a switch -- because the switch parser has its OWN label-emitting
 * path, and a fix that only covers the ordinary one leaves that copy behind.
 */
static int a(int n)
{
    int r = 0;
redo:
    r = r + 1;
    if (r < n) goto redo;
    return r;
}

static int b(int n)
{
    int r = 100;
redo:
    r = r + 10;
    if (r < n) goto redo;
    return r;
}

/* forward goto, same label name again */
static int c(int n)
{
    int r = 0;
    if (n < 0) goto done;
    r = n * 2;
done:
    return r;
}

static int d(int n)
{
    int r = 0;
    if (n > 100) goto done;
    r = 1;
done:
    return r;
}

/* a third `redo`, in a function that also carries a switch */
static int e(int n)
{
    int r = 0;
redo:
    switch (n) {
    case 1: r = r + 1; break;
    case 2: r = r + 2; break;
    default: r = r + 100; break;
    }
    if (r < 3) { n = 2; goto redo; }
    return r;
}

int main(void)
{
    if (a(3) != 3) return 1;
    if (b(130) != 130) return 2;
    if (a(1) != 1) return 3;
    if (b(101) != 110) return 4;

    if (c(5) != 10) return 5;
    if (c(-1) != 0) return 6;
    if (d(5) != 1) return 7;
    if (d(200) != 0) return 8;

    if (e(1) != 3) return 9;   /* 1 then +2 */
    if (e(2) != 4) return 10;  /* 2 then +2 */
    return 0;
}
