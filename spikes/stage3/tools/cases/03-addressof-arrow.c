/* &s->member must load s FIRST and then add the offset. Adding the offset to
 * the SLOT that stores s addresses the stack instead of the struct. */
struct S { int a; char* lib; int b; };
static void set_it(char** pp, char* v) { *pp = v; }
int main(void)
{
    struct S st;
    struct S* s = &st;
    s->a = 1; s->lib = 0; s->b = 3;
    set_it(&s->lib, "ok");
    if (s->lib == 0) return 1;
    if (s->lib[0] != 'o') return 2;
    if (s->a != 1 || s->b != 3) return 3;   /* neighbours untouched */
    return 0;
}
