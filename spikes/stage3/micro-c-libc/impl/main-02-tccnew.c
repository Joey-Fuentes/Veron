/* PROBE 2: does compiled tcc code run?
 *
 * tcc_new allocates a TCCState and fills it in -- the first substantial piece
 * of tcc's own logic. A fault here and not in probes 0 or 1 means the problem
 * is in what micro-c emitted for tcc, which is the interesting answer. */
void* tcc_new(void);
int main(int argc, char** argv)
{
    void* s = tcc_new();
    if(0 == s) return 2;
    return 0;
}
