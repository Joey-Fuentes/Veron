/* A LABEL IS A PREFIX TO A STATEMENT, NOT A STATEMENT.
 *
 * `lab: stmt;` is ONE labelled statement in C. Treating the label as complete
 * in itself is invisible inside a block -- the block loop parses the next line
 * anyway and the output is identical -- and wrong wherever exactly one
 * statement is expected.
 *
 *     if (t0 == TOK_PPJOIN)
 *     bad_twosharp:
 *         tcc_error("'##' cannot appear at either end of macro");
 *                                                        tccpp.c:1621
 *
 * The if got the label as its whole body and the tcc_error ran
 * unconditionally, so every #define tcc preprocessed raised that error.
 *
 * THE PAIRS ARE THE POINT. Each construct is checked with the branch NOT
 * taken and with it taken. A case that only tried the taken branch would pass
 * with the body outside the if entirely, since the body still runs -- which is
 * exactly the bug.
 */
static int hit;
static int steps;

static int side(int v) { steps = steps + v; return v; }

int main(void)
{
    int t;
    int i;

    /* --- if, branch NOT taken: the body must not run --- */
    hit = 0; t = 0;
    if (t == 1)
lab_a:
        hit = 1;
    if (hit != 0) return 1;

    /* --- if, branch taken --- */
    hit = 0; t = 1;
    if (t == 1)
lab_b:
        hit = 1;
    if (hit != 1) return 2;

    /* --- goto still reaches the label, and only the labelled statement --- */
    hit = 0; steps = 0;
    goto lab_c;
    hit = 99;                      /* skipped */
lab_c:
    hit = 7;
    if (hit != 7) return 3;

    /* --- else branch, braceless, labelled --- */
    hit = 0; t = 0;
    if (t == 1)
        hit = 1;
    else
lab_d:
        hit = 2;
    if (hit != 2) return 4;

    /* --- while body, braceless and labelled: must run exactly n times --- */
    steps = 0; i = 0;
    while (i < 3)
lab_e:
    {
        side(1);
        i = i + 1;
    }
    if (steps != 3) return 5;

    /* --- a label that is jumped to from inside a loop --- */
    steps = 0; i = 0;
    while (i < 5)
    {
        i = i + 1;
        if (i == 2) goto lab_f;
        steps = steps + 10;
    }
    return 6;
lab_f:
    if (i != 2) return 7;
    if (steps != 10) return 8;

    /* --- two labels in a row on one statement --- */
    hit = 0;
lab_g:
lab_h:
    hit = 5;
    if (hit != 5) return 9;

    return 0;
}
