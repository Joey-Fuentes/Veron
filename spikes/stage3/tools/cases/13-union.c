/* Unions: every member at offset 0, size of the largest, and writing one
 * member visible through another. tcc's CValue and SValue are unions and it
 * reads them through several members. */
union U { long l; int i; char c[8]; void* p; };
struct WithUnion { unsigned char tag; union U v; long after; };
int main(void)
{
    union U u;
    struct WithUnion w;
    if (sizeof(union U) != 8) return 1;
    u.l = 0;
    u.c[0] = 0x41;
    if ((u.l & 0xff) != 0x41) return 2;   /* written as char, read as long */
    u.p = 0;
    if (u.l != 0) return 3;
    w.tag = 7; w.v.l = 99; w.after = 5;
    if (w.tag != 7) return 4;
    if (w.v.l != 99) return 5;
    if (w.after != 5) return 6;
    return 0;
}
