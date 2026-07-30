/* BITMASK
 *
 * build_got_entries(), tccelf.c:1395 -- the two-pass loop that allocates GOT
 * entries. A JMP_SLOT is handled on pass 0 and a GLOB_DAT on pass 1:
 *
 *     int pass = 0;
 *   redo:
 *     for (...) {
 *         ...
 *         if (pass != 1) continue;
 *         attr = put_got_entry(s1, R_GLOB_DAT, sym_index);
 *     }
 *     if (++pass < 2)
 *         goto redo;
 *
 * A tcc built by micro-c links a freestanding hello world whose .got holds
 * only the three reserved words, all zero, where the control's holds a fourth
 * with the string's address. The object files are byte-identical, so this is
 * the link and not codegen; and gotplt_entry_type classifies the relocation
 * correctly (case 95). If the second pass never runs, no data symbol ever
 * gets a slot -- which is the shape of what was measured.
 *
 * Probes: the pre-increment in the condition, the backward goto, a `redo`
 * label in more than one function (EXPERIMENT-zza made labels function-scoped;
 * this keeps that honest), and `continue` inside the loop the goto re-enters.
 */

static int other_function_with_the_same_label(int n)
{
    int i = 0;
redo:
    i = i + 1;
    if (i < n)
        goto redo;
    return i;
}

int main(void)
{
    int bits = 0;

    /* 1: ++x in a condition controlling a backward goto -- runs twice */
    {
        int pass = 0;
        int runs = 0;
    redo:
        runs = runs + 1;
        if (++pass < 2)
            goto redo;
        if (runs != 2) bits = bits + 1;
        if (pass != 2) bits = bits + 2;
    }

    /* 4: the value seen INSIDE the body on each pass must be 0 then 1 */
    {
        int pass = 0;
        int seen = 0;
    redo2:
        seen = seen * 10 + pass;
        if (++pass < 2)
            goto redo2;
        if (seen != 1) bits = bits + 4;   /* 0 then 1 -> 0*10+0=0, 0*10+1=1 */
    }

    /* 8: a `continue` in a loop the goto re-enters, guarded on the pass */
    {
        int pass = 0;
        int hits = 0;
        int i;
    redo3:
        for (i = 0; i < 3; i++) {
            if (pass != 1)
                continue;
            hits = hits + 1;
        }
        if (++pass < 2)
            goto redo3;
        if (hits != 3) bits = bits + 8;   /* only pass 1 counts */
    }

    /* 16: the same label name in another function must not be shared */
    if (other_function_with_the_same_label(4) != 4) bits = bits + 16;

    /* 32: post-increment in the same position behaves as C says */
    {
        int pass = 0;
        int runs = 0;
    redo4:
        runs = runs + 1;
        if (pass++ < 1)
            goto redo4;
        if (runs != 2) bits = bits + 32;
    }

    return bits;
}
