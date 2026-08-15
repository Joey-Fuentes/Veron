/* Between "everything links and runs" and "tcc_new segfaults" there is one
 * question worth settling first: does the ALLOCATOR work?
 *
 * tcc_new's first act is tcc_malloc, and M2libc's malloc only works if
 * __init_malloc ran at startup -- which libc-full does and libc-core does not.
 * If malloc is broken, tcc_new would fault for a reason that has nothing to do
 * with tcc, and every hour spent reading tccgen.c would be wasted.
 *
 * Exit codes, all through raw syscalls so no libc path can mask them:
 *     42  the allocation worked and was writable
 *      2  malloc returned NULL
 *   fault malloc itself died */
void* malloc(unsigned long n);
int main(int argc, char** argv)
{
    char* p = malloc(64);
    if(0 == p)
    {
        asm("mov_x0,2" "mov_x8,93" "svc_0");
    }
    p[0] = 1;
    p[63] = 1;
    asm("mov_x0,42"
        "mov_x8,93"
        "svc_0");
    return 0;
}
