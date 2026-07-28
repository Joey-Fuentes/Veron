/* PROBE 1: does the runtime's allocator work?
 *
 * M2libc's malloc needs __init_malloc to have run at startup. tcc_new calls
 * tcc_malloc almost immediately, so if malloc is broken every later probe
 * fails for a reason that has nothing to do with tcc. */
void* malloc(unsigned long n);
int main(int argc, char** argv)
{
    char* p = malloc(64);
    if(0 == p) return 2;
    p[0] = 1;
    p[63] = 1;
    return 0;
}
