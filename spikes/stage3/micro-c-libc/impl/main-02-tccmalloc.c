/* E2 proved M2libc's malloc works. tcc does not call it directly:
 *
 *     static void *(*reallocator)(void*, unsigned long) = default_reallocator;
 *     PUB_FUNC void *tcc_malloc(unsigned long size) { return reallocator(0, size); }
 *
 * That is an INDIRECT CALL through a global function pointer initialised with
 * a function name -- which micro-c only learned to emit at libtcc.c:265, near
 * the end of the walk, and which nothing has exercised since. If the address
 * in that global is wrong, the call goes somewhere arbitrary and the fault is
 * a segfault in tcc_malloc rather than anything to do with tcc's logic.
 *
 *     42  tcc_malloc returned writable memory
 *      2  it returned NULL
 *   fault the indirect call is bad */
void* tcc_malloc(unsigned long size);
int main(int argc, char** argv)
{
    char* p = tcc_malloc(64);
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
