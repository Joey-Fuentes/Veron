/* The exact shape of tcc_set_output_type, which is where the micro-c-built
 * tcc dies. Both probes reach the marker after tcc_split_path and neither
 * reaches the next one, so the fault is in the `if` or the return.
 *
 *     static void split(TCCState *s, void *p_ary, int *p_nb, const char *in);
 *     ...
 *     split(s, &s->crt_paths, &s->nb_crt_paths, PREFIX);
 *     if (output_type != OUTPUT_MEMORY && !s->nostdlib)
 *         add_crtbegin(s);
 *     return 0;
 *
 * Everything here is a construct micro-c has had a bug in: address-of a
 * member through a pointer, a pointer-to-pointer written through, an
 * unsigned char field read after it, and && over the two. */
struct State {
    unsigned char verbose;
    unsigned char nostdinc;
    unsigned char nostdlib;
    unsigned char nostdlib_paths;
    char** crt_paths;
    int nb_crt_paths;
    int output_type;
    int tail;
};

static void split(struct State* s, void* p_ary, int* p_nb, char* in)
{
    char*** ary = p_ary;
    if (ary[0] == 0) return;      /* not allocated here; just touch it */
    p_nb[0] = p_nb[0] + 1;
    s->verbose = 1;
}

static int add_crtbegin(struct State* s) { s->tail = 77; return 0; }

static int set_output(struct State* s, int output_type)
{
    s->output_type = output_type;
    split(s, &s->crt_paths, &s->nb_crt_paths, "prefix");
    if (output_type != 1 && !s->nostdlib)
        add_crtbegin(s);
    return 0;
}

int main(void)
{
    struct State st;
    struct State* s = &st;
    int i = 0;
    char* p = (char*)&st;
    while (i < (int)sizeof(struct State)) { p[i] = 0; i = i + 1; }

    if (set_output(s, 1) != 0) return 1;      /* MEMORY: skips add_crtbegin */
    if (s->output_type != 1) return 2;
    if (s->tail != 0) return 3;               /* must NOT have been called */

    if (set_output(s, 2) != 0) return 4;      /* EXE: calls add_crtbegin */
    if (s->tail != 77) return 5;
    return 0;
}
