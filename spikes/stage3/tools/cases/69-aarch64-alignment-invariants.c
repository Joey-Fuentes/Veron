/* aarch64 layout invariants, checked without assuming gcc's absolute offsets */
struct A { char c; long l; };
struct B { long l; char c; };
struct C { char c; short s; long l; char d; };
struct D { char c; struct A a; };
struct E { char c; long l; };
struct E earr[4];
struct A aarr[4];
struct C carr[4];

int main(void)
{
	char* p;
	char* q;

	/* a long member must be 8-aligned within its struct */
	struct A a;
	p = (char*)&a; q = (char*)&a.l;
	if (((q - p) % 8) != 0) return 1;

	/* trailing padding: sizeof must be a multiple of the strictest alignment */
	if ((sizeof(struct A) % 8) != 0) return 2;
	if ((sizeof(struct B) % 8) != 0) return 3;
	if ((sizeof(struct C) % 8) != 0) return 4;

	/* short must be 2-aligned, long 8-aligned, in the same struct */
	struct C c;
	p = (char*)&c;
	if ((((char*)&c.s - p) % 2) != 0) return 5;
	if ((((char*)&c.l - p) % 8) != 0) return 6;

	/* a nested struct inherits its own alignment */
	struct D d;
	p = (char*)&d;
	if ((((char*)&d.a - p) % 8) != 0) return 7;
	if ((((char*)&d.a.l - p) % 8) != 0) return 8;

	/* ARRAY STRIDE MUST EQUAL sizeof -- the thing zzi got wrong for globals */
	if (((char*)&aarr[1] - (char*)&aarr[0]) != sizeof(struct A)) return 9;
	if (((char*)&carr[1] - (char*)&carr[0]) != sizeof(struct C)) return 10;
	if (((char*)&earr[2] - (char*)&earr[0]) != 2 * sizeof(struct E)) return 11;

	/* and every element of a global array is itself aligned */
	if ((((char*)&earr[1].l - (char*)&earr[0]) % 8) != 0) return 12;
	return 0;
}
