/* THE ACTUAL QUESTION: can this tcc compile anything?
 *
 * tcc_new works, so the next thing worth asking is whether the compiler it
 * returns can be driven. tcc_set_output_type(TCC_OUTPUT_MEMORY) then
 * tcc_compile_string on the smallest possible program.
 *
 * This is EXPECTED TO FAIL, and the failure is the point -- it will be the
 * first one that comes from tcc doing compiler work rather than from
 * plumbing. Twenty-five of the runtime functions underneath are stubs that
 * return 0, `int` is eight bytes so every struct tcc lays out differs from
 * what a real compiler would produce, and float is an integer.
 *
 *     42  tcc_compile_string returned success
 *      2  tcc_new returned NULL
 *      3  tcc_set_output_type failed
 *      4  tcc_compile_string returned an error
 *   other it did not get that far */
void* tcc_new(void);
int tcc_set_output_type(void* s, int output_type);
int tcc_compile_string(void* s, char* buf);

int main(int argc, char** argv)
{
    void* s = tcc_new();
    if(0 == s)
    {
        asm("mov_x0,2" "mov_x8,93" "svc_0");
    }
    /* TCC_OUTPUT_MEMORY is 1 */
    if(0 != tcc_set_output_type(s, 1))
    {
        asm("mov_x0,3" "mov_x8,93" "svc_0");
    }
    if(0 != tcc_compile_string(s, "int main(){ return 0; }"))
    {
        asm("mov_x0,4" "mov_x8,93" "svc_0");
    }
    asm("mov_x0,42"
        "mov_x8,93"
        "svc_0");
    return 0;
}
