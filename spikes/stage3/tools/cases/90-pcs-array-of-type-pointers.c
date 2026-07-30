/* The exact shape of arm64-gen.c gfunc_call + arm64_pcs_aux.
 *
 *   t = tcc_malloc((nb_args + 1) * sizeof(*t));
 *   t[0] = return_type;
 *   for (i = 0; i < nb_args; i++)
 *       t[nb_args - i] = &vtop[-i].type;
 *   stack = arm64_pcs(variadic, nb_args, t, a);
 *      ... which reads type[i]->t and is handed type + 1
 *
 * An array of POINTERS TO STRUCT, malloc'd, filled with the address of a
 * member of a NEGATIVELY indexed struct pointer, then read back through
 * index-then-arrow, and also through a pointer that has been advanced by one.
 */
struct CType { int t; int pad; };
struct SValue { int r; struct CType type; };

static struct SValue stack_[8];

static int read_back(struct CType **type, int n)
{
    int i;
    int sum = 0;
    for (i = 0; i <= n; i++)
        sum = sum + type[i]->t;         /* index an array of pointers, then arrow */
    return sum;
}

static int read_shifted(struct CType **type, int n)
{
    int i;
    int sum = 0;
    for (i = 0; i < n; i++)
        sum = sum + type[i]->t;
    return sum;
}

int main(void)
{
    struct CType *t[4];
    struct SValue *vtop;
    struct CType ret;
    int i;
    int nb_args = 2;

    for (i = 0; i < 8; i++) { stack_[i].r = 0; stack_[i].type.t = 100 + i; stack_[i].type.pad = 0; }
    ret.t = 7; ret.pad = 0;
    vtop = &stack_[5];                  /* so vtop[-i] is meaningful */

    t[0] = &ret;
    for (i = 0; i < nb_args; i++)
        t[nb_args - i] = &vtop[-i].type;   /* &  of a member of a negative index */

    if (t[0]->t != 7)   return 1;
    if (t[1]->t != 104) return 2;       /* vtop[-1] = stack_[4] -> 104 */
    if (t[2]->t != 105) return 3;       /* vtop[-0] = stack_[5] -> 105 */

    if (read_back(t, nb_args) != 7 + 104 + 105) return 4;
    if (read_shifted(t + 1, nb_args) != 104 + 105) return 5;   /* type + 1 */
    return 0;
}
