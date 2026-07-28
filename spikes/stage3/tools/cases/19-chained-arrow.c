/* s->a->b and s->a->b->c -- chained indirection through struct members, which
 * tcc does through Sym and CType all the way down. */
struct C { int value; };
struct B { struct C* c; int tag; };
struct A { struct B* b; int tag; };
int main(void)
{
    struct C c; struct B b; struct A a;
    c.value = 42;
    b.c = &c; b.tag = 2;
    a.b = &b; a.tag = 1;
    struct A* p = &a;
    if (p->tag != 1) return 1;
    if (p->b->tag != 2) return 2;
    if (p->b->c->value != 42) return 3;
    p->b->c->value = 7;
    if (c.value != 7) return 4;
    return 0;
}
