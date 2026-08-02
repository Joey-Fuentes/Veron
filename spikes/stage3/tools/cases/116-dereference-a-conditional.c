/* KNOWN GAP -- dereferencing the RESULT of a conditional segfaults.
 *
 * REDUCED TO THIS, with plain int pointers and no struct anywhere:
 *
 *     int v = *(1 ? p1 : p2);        SIGSEGV
 *
 * And the shape that WORKS, which is what makes it a compiler defect rather
 * than a missing feature:
 *
 *     int* p3 = (1 ? p1 : p2);       fine
 *     int  v  = *p3;                 fine
 *
 * Same two pointers, same selection, same load. Putting the `*` directly on
 * the conditional is the only difference.
 *
 * WHERE tcc WRITES IT. tccgen.c:2939, inside combine_types -- the function
 * that decides the type of every binary operator and every conditional in the
 * program it is compiling:
 *
 *     type = *(bt1 == VT_PTR ? type1 : type2);
 *
 * so this is on the path of essentially every expression tcc parses.
 *
 * FOUND BY SPLITTING CASE 113. That case was written for the conditional's
 * TYPE, hit this on its way, and would have failed for a reason it is not
 * about -- a case that fails two ways at once names neither. This is the
 * second half, on its own.
 *
 * IT IS NOT CAUSED BY THE TYPE FIX. EXPERIMENT-zzzn corrects the conditional's
 * result type; this reproduces identically under the compiler built WITHOUT
 * that patch. It was simply unreachable before, because the type error stopped
 * the parse first. Two independent defects on the same construct, which is why
 * one CI symptom had two causes.
 *
 * WHY IT IS A GAP AND NOT A FAILURE. The cause is not yet named. The ternary
 * pushes and pops REGISTER_TEMP around both arms to protect the aarch64 far
 * jump, and the prefix `*` emits its load afterwards; whether the fault is in
 * that pairing, in what the arms leave in REGISTER_ZERO, or in the prefix
 * operator's idea of what it is applied to, is exactly what a marker trail
 * through emit_pop and the deref path should settle. Marked KNOWN GAP so the
 * suite stays meaningful while that is done -- and so that difftest reports it
 * loudly the moment it starts passing.
 *
 * Probes, one bit each:
 *
 *   1  int* through a variable first -- the shape that works, so a failure
 *      here means something much broader than this gap
 *   2  *(cond ? p1 : p2) on int pointers -- the reduction
 *   4  the same with the arms swapped
 *   8  a struct copy from a dereferenced conditional, which is tcc's line
 *  16  a member read through a dereferenced conditional
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
