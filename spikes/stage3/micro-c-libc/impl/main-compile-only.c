/* COMPILE WITHOUT LINKING.
 *
 * TCC_OUTPUT_MEMORY (1) skips the crt paths and crtbegin entirely, so this
 * exercises the PARSER and CODE GENERATOR without the linker. That separation
 * is worth having on its own: a compiler that compiles but cannot link is a
 * far better position than one that cannot compile, and a single test that
 * does both cannot tell you which you have.
 *
 * tcc_compile_string is the narrowest entry point there is -- no file I/O, no
 * include search, just text in.
 *
 *   42  it compiled
 *    2  tcc_new returned NULL
 *    3  tcc_set_output_type failed
 *    4  tcc_compile_string reported an error
 */
void* tcc_new(void);
int tcc_set_output_type(void* s, int output_type);
int tcc_compile_string(void* s, char* buf);
int write(int fd, char* buf, int count);

static void mark(char* s) { write(2, s, 3); }

int main(int argc, char** argv)
{
    void* s;

    mark("C1\n");
    s = tcc_new();
    if(0 == s)
    {
        asm("mov_x0,2" "mov_x8,93" "svc_0");
    }

    mark("C2\n");
    /* 1 is TCC_OUTPUT_MEMORY */
    if(0 != tcc_set_output_type(s, 1))
    {
        asm("mov_x0,3" "mov_x8,93" "svc_0");
    }

    mark("C3\n");
    if(0 != tcc_compile_string(s, "int answer(void){ return 42; }"))
    {
        asm("mov_x0,4" "mov_x8,93" "svc_0");
    }

    mark("C4\n");
    asm("mov_x0,42"
        "mov_x8,93"
        "svc_0");
    return 0;
}
