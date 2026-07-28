/* Calls into compiled tcc code, then exits 42 the same raw way, so a clean
 * exit here means tcc_new returned rather than that some libc path swallowed
 * the result. */
void* tcc_new(void);
int main(int argc, char** argv)
{
    void* s = tcc_new();
    if(0 == s)
    {
        asm("mov_x0,7" "mov_x8,93" "svc_0");
    }
    asm("mov_x0,42"
        "mov_x8,93"
        "svc_0");
    return 0;
}
