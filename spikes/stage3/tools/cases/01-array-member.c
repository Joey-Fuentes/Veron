/* An array member decays to its ADDRESS; it must not be loaded.
 * This is the bug that made tcc_new store include_stack[0] into
 * include_stack_ptr and then dereference null. */
struct S { int a; char* arr[8]; char** ptr; };
int main(void)
{
    struct S s;
    s.arr[0] = "first";
    s.ptr = s.arr;
    if (s.ptr != &s.arr[0]) return 1;
    if (s.ptr[0][0] != 'f') return 2;
    return 0;
}
