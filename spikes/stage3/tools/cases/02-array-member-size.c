/* An array member's size is count * sizeof(element), where the element of
 * `char *x[8]` is a POINTER. Sizing it by the pointer's TARGET put every
 * later member at the wrong offset. */
struct S { char* arr[8]; int after; };
int main(void)
{
    struct S s;
    int i = 0;
    while (i < 8) { s.arr[i] = 0; i = i + 1; }
    s.after = 12345;
    /* if arr were sized as 8 bytes rather than 64, writing arr[1..7]
     * would have clobbered `after` */
    if (s.after != 12345) return 1;
    return 0;
}
