/* tcc_new past its allocation does only two things:
 *
 *     s->include_stack_ptr = s->include_stack;   (address of an array member)
 *     tcc_set_lib_path(s, CONFIG_TCCDIR);        (tcc_set_str -> tcc_strdup)
 *
 * tcc_set_options is #ifdef CONFIG_TCC_SWITCHES and that is not defined here,
 * so it never runs.
 *
 * tcc_strdup is tcc_malloc(strlen(str) + 1) then strcpy -- reachable without a
 * TCCState, so it can be probed directly. If it works, what is left is the
 * struct writes themselves, and micro-c's EIGHT-BYTE `int` changing every
 * offset in TCCState becomes the remaining explanation.
 *
 *     42  strdup returned the same bytes back
 *      2  it returned NULL
 *      3  the copy does not match
 *   fault strlen, strcpy or the allocation inside it died */
char* tcc_strdup(char* str);
int main(int argc, char** argv)
{
    char* src = "micro-c";
    char* p = tcc_strdup(src);
    if(0 == p)
    {
        asm("mov_x0,2" "mov_x8,93" "svc_0");
    }
    if(p[0] != 'm')
    {
        asm("mov_x0,3" "mov_x8,93" "svc_0");
    }
    if(p[6] != 'c')
    {
        asm("mov_x0,3" "mov_x8,93" "svc_0");
    }
    if(p[7] != 0)
    {
        asm("mov_x0,3" "mov_x8,93" "svc_0");
    }
    asm("mov_x0,42"
        "mov_x8,93"
        "svc_0");
    return 0;
}
