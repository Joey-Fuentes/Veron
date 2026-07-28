/* Calls into compiled tcc code. Only meaningful once the bare main above runs
 * with the same link set. */
void* tcc_new(void);
int main(int argc, char** argv)
{
    void* s = tcc_new();
    if(0 == s) return 2;
    return 0;
}
