/* the emitted DATA must match the computed layout, gaps and tail included */
struct A { char c; long l; };
struct B { long l; char c; };
struct C { char c; short s; long l; char d; };
struct P { char* name; unsigned short i; unsigned short f; };

struct A ga = { 'x', 111 };
struct B gb = { 222, 'y' };
struct C gc = { 'a', 7, 333, 'b' };
struct A aa[3] = { {'1', 11}, {'2', 22}, {'3', 33} };
struct P pt[3] = { {"h", 1, 0}, {"B", 2, 1}, {0, 0, 0} };

int main(void)
{
	if (ga.c != 'x') return 1;
	if (ga.l != 111) return 2;
	if (gb.l != 222) return 3;
	if (gb.c != 'y') return 4;
	if (gc.c != 'a') return 5;
	if (gc.s != 7) return 6;
	if (gc.l != 333) return 7;
	if (gc.d != 'b') return 8;

	/* every element of an initialised array must be intact */
	if (aa[0].c != '1' || aa[0].l != 11) return 9;
	if (aa[1].c != '2' || aa[1].l != 22) return 10;
	if (aa[2].c != '3' || aa[2].l != 33) return 11;
	if (((char*)&aa[1] - (char*)&aa[0]) != sizeof(struct A)) return 12;

	/* tcc's option-table shape: pointer + two shorts, padded */
	if (pt[0].name[0] != 'h') return 13;
	if (pt[1].name[0] != 'B') return 14;
	if (pt[1].i != 2 || pt[1].f != 1) return 15;
	if (pt[2].name != 0) return 16;
	return 0;
}
