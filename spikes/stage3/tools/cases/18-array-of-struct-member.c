/* p[i].member and p[i].member = x -- an array of structs indexed then a member
 * selected. tcc's section and symbol tables are exactly this. */
struct Ent { long key; char* name; int flags; };
static struct Ent table[4];
int main(void)
{
    int i = 0;
    while (i < 4) { table[i].key = i * 10; table[i].name = 0; table[i].flags = i; i = i + 1; }
    if (table[0].key != 0) return 1;
    if (table[3].key != 30) return 2;
    if (table[2].flags != 2) return 3;
    table[1].name = "x";
    if (table[1].name[0] != 'x') return 4;
    if (table[0].name != 0) return 5;

    struct Ent* p = table;
    if (p[3].key != 30) return 6;
    p[3].key = 99;
    if (table[3].key != 99) return 7;
    return 0;
}
