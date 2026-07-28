/* A ternary used as an ARGUMENT, with more arguments after it.
 *
 * tcc does this in tcc_compile:
 *     tcc_open_bf(s1, filename ? filename : "<string>", len);
 * and the run showed `len` arriving as 0xF9400000D100A688 -- AArch64
 * instructions, i.e. eight bytes read out of the code segment. An argument
 * list that loses its place is one way to get that.
 *
 * The ternary pushes and pops around a branch; if the two paths leave the
 * stack at different depths, every argument after it is read from the wrong
 * slot. */
static int sink3(void* a, char* b, long c) { if (c != 42) return 1; if (b[0] != 'y') return 2; return 0; }
static int sink4(void* a, char* b, long c, long d) { if (c != 42) return 1; if (d != 7) return 2; return 0; }

int main(void)
{
    char* name = 0;
    long len = 42;

    /* the ternary takes its false arm */
    if (sink3(0, name ? name : "yes", len) != 0) return 1;

    /* and its true arm */
    name = "yellow";
    if (sink3(0, name ? name : "no", len) != 0) return 2;

    /* with a further argument after it */
    if (sink4(0, name ? name : "no", len, 7) != 0) return 3;

    /* nested, and in the middle */
    if (sink4(0, len > 0 ? "yes" : "no", len > 40 ? 42 : 0, 7) != 0) return 4;
    return 0;
}
