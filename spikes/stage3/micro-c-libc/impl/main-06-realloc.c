/* realloc IS THE ONE ALLOCATOR PATH NOTHING HAS TESTED.
 *
 * E3 proved tcc_malloc, which is reallocator(0, size) -- realloc with a NULL
 * pointer, the branch that just calls malloc. GROWING an existing block is
 * different code, and it is what cstr_cat does inside tcc_split_path, which is
 * the last function both probes got through before dying at different points
 * afterwards. Corruption there would show up later, exactly like that.
 *
 * M2libc's realloc also contains
 *
 *     struct _malloc_node* i = _allocated_list;   ... later ...  int i;
 *
 * two declarations of i in one function. How micro-c resolves that is worth
 * knowing on its own.
 *
 *   42  grew a block and every byte survived
 *    2  the first allocation failed
 *    3  realloc returned NULL
 *    4  the contents did not survive the move
 */
void* malloc(unsigned long n);
void* realloc(void* p, unsigned long n);
int write(int fd, char* buf, int count);
static void mark(char* s) { write(2, s, 3); }

int main(int argc, char** argv)
{
    char* p;
    int i;

    mark("R1\n");
    p = malloc(32);
    if(0 == p) { asm("mov_x0,2" "mov_x8,93" "svc_0"); }

    i = 0;
    while(i < 32) { p[i] = i + 1; i = i + 1; }

    mark("R2\n");
    p = realloc(p, 4096);          /* force a move, not an in-place grow */
    if(0 == p) { asm("mov_x0,3" "mov_x8,93" "svc_0"); }

    mark("R3\n");
    i = 0;
    while(i < 32)
    {
        if(p[i] != i + 1) { asm("mov_x0,4" "mov_x8,93" "svc_0"); }
        i = i + 1;
    }

    /* and that the new space is usable */
    p[4095] = 7;
    if(7 != p[4095]) { asm("mov_x0,4" "mov_x8,93" "svc_0"); }

    mark("R4\n");
    asm("mov_x0,42" "mov_x8,93" "svc_0");
    return 0;
}
