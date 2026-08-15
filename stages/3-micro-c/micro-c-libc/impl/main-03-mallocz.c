/* E3 proved tcc_malloc(64) works. tcc_new's first act is
 *
 *     s = tcc_mallocz(sizeof(TCCState));
 *
 * which is tcc_malloc plus memset over a MUCH larger block -- TCCState is
 * several kilobytes, and micro-c's eight-byte `int` makes it larger still than
 * a normal compiler would produce.
 *
 * Two things differ from E3 and this separates them from tcc's logic:
 * a big allocation, and memset across it. The writes at both ends catch a
 * block that was allocated but not actually mapped.
 *
 *     42  8 KB allocated, zeroed, writable at both ends
 *      2  it returned NULL
 *      3  memset did not actually zero it
 *   fault the allocation or the memset died */
void* tcc_mallocz(unsigned long size);
int main(int argc, char** argv)
{
    char* p = tcc_mallocz(8192);
    if(0 == p)
    {
        asm("mov_x0,2" "mov_x8,93" "svc_0");
    }
    if(0 != p[0])
    {
        asm("mov_x0,3" "mov_x8,93" "svc_0");
    }
    if(0 != p[8191])
    {
        asm("mov_x0,3" "mov_x8,93" "svc_0");
    }
    p[0] = 1;
    p[8191] = 1;
    asm("mov_x0,42"
        "mov_x8,93"
        "svc_0");
    return 0;
}
