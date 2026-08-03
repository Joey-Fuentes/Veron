/* BITMASK -- CLOSED by EXPERIMENT-zzzx. Kept as a regression guard.
 *
 * It was: `int v = *(1 ? p1 : p2);` SIGSEGV, while the same selection through
 * a variable was fine. The cause was not the ternary. A pending `*` is parked
 * in num_dereference_after_postfix, and a parenthesised sub-expression read
 * that same global -- so the star landed on the CONDITION and loaded address
 * 1. Identical to the argument-list hazard function_call already documents
 * for `*give(8)`; a different pair of brackets.
 *
 * The ternary is only the loudest way in: its condition is parsed before `?`
 * is seen, so the stray load is already emitted before anything knows a
 * ternary is being parsed.
 *
 * WHY IT STAYS. tccgen.c:2939 in combine_types is
 *     type = *(bt1 == VT_PTR ? type1 : type2);
 * which is on the path of every binary operator and every conditional tcc
 * parses. Bit 1 is the through-a-variable control; if it ever fires, something
 * much broader than this has broken.
 */

struct Sym { int id; int pad; };
struct CType { int t; struct Sym* ref; };

int ga;
int gb;
struct Sym sym_a;
struct Sym sym_b;

int main(void)
{
	int r;
	r = 0;

	ga = 5;
	gb = 6;
	sym_a.id = 11;
	sym_b.id = 22;

	int* p1;
	int* p2;
	p1 = &ga;
	p2 = &gb;

	/* 1 -- through a variable. This works, and it is the control. */
	int* p3;
	p3 = (1 ? p1 : p2);
	int v0;
	v0 = *p3;
	if(v0 != 5) r = r + 1;

	/* 2 -- the reduction. Same selection, same load, `*` applied directly. */
	int v1;
	v1 = *(1 ? p1 : p2);
	if(v1 != 5) r = r + 2;

	/* 4 -- arms swapped, so a one-sided fault can be told from a total one */
	int v2;
	v2 = *(0 ? p1 : p2);
	if(v2 != 6) r = r + 4;

	/* 8 -- tccgen.c:2939 itself: a struct copy whose source is a
	 * dereferenced conditional */
	struct CType c1;
	struct CType c2;
	c1.t = 5; c1.ref = &sym_a;
	c2.t = 6; c2.ref = &sym_b;
	struct CType* q1;
	struct CType* q2;
	q1 = &c1;
	q2 = &c2;
	struct CType t3;
	t3.t = 0;
	t3.ref = 0;
	t3 = *(1 ? q1 : q2);
	if(t3.t != 5) r = r + 8;
	if(t3.ref != &sym_a) r = r + 8;

	/* 16 -- a member read straight through it, no copy */
	int m;
	m = (*(1 ? q1 : q2)).t;
	if(m != 5) r = r + 16;

	return r;
}
