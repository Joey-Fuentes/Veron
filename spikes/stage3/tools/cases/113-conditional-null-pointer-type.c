/* THE TERNARY WHOSE ARMS ARE A NULL CONSTANT AND A STRUCT POINTER.
 *
 * TWO WITNESSES, ONE CONSTRUCT. mc-tcc fails both of these and the gcc-built
 * control passes both, from the same source:
 *
 *     tests2/33_ternary_op.c:37   int i1 = (i != 0 ? 0 : s)->i;
 *     tests/tcctest.c:4082        int i1 = (i == 0 ? 0 : s)->i;
 *
 * both reporting `error: struct or union expected`. tcctest.c is the file
 * test1/test2/test3 begin with, so this construct is the gate on tcc's own
 * test suite, and 33_ternary_op is the same thing in miniature.
 *
 * WHAT tcc DOES WITH IT. tccgen.c:2932, in combine_types:
 *
 *     else if (is_null_pointer (op2)) type = *type1;
 *     else if (is_null_pointer (op1)) type = *type2;
 *
 * `type` is a local CType -- `struct CType { int t; struct Sym *ref; }`, two
 * fields, sixteen bytes -- and it was zeroed field by field just above:
 *
 *     type.t = VT_VOID;
 *     type.ref = NULL;
 *
 * So a copy that moves `t` and not `ref` leaves `ref` NULL from that
 * initialisation, and the merged type is a pointer to nothing. The `->` that
 * follows then asks what it points at, gets a null ref, and reports
 * "struct or union expected" -- WITHOUT a preceding warning, which is what
 * distinguishes this from the other way the merge can go wrong. If the merge
 * had fallen through to the mismatch branch at tccgen.c:2935 instead, it would
 * print "pointer/integer mismatch in conditional expression" first. Line 26 of
 * 33_ternary_op does print that warning, and passes. Line 37 does not, and
 * fails. That is the observation this case is built from.
 *
 * WHY IT IS NOT COVERED. The 97-case suite is 94 pass / 0 fail natively on
 * aarch64, so whatever this is, no existing case reaches it. A struct
 * assignment IS covered -- 05-struct-assign -- but as `a = b` between two
 * locals. Every form below is a copy whose SOURCE is a dereference, and two of
 * them dereference something that is not a plain variable.
 *
 * Probes, one bit each:
 *
 *   1  sizeof matches the array stride, and a copy moves that whole width
 *   2  local = *pointer            copies BOTH fields
 *   4  (moved to case 116 -- dereferencing a conditional segfaults, and that
 *      is a SEPARATE defect that would mask this one)
 *   8  *pointer = local            the `*dest = type` at the end of the merge
 *  16  (cond ? 0 : s)->i           the literal construct, null constant second
 *  32  (cond ? s : 0)->i           and with the arms the other way round
 *  64  (cond ? (void*)0 : s)->i    the same with an explicit void* null
 * 128  the whole merge, written as tcc writes it, both selections
 */

struct Sym { int id; int pad; };

struct CType {
	int t;
	struct Sym* ref;
};

struct condstruct {
	int i;
};

/* Standing in for VT_VOID / VT_PTR. The values do not matter; that they
 * survive a copy does. */
#define T_VOID 0
#define T_PTR  5

struct Sym sym_a;
struct Sym sym_b;
struct condstruct cs;

/* combine_types' shape: a destination written through a pointer, and the
 * chosen type reached by dereferencing one of two pointers. */
static int merge(struct CType* dest, struct CType* type1, struct CType* type2,
                 int pick2)
{
	struct CType type;

	type.t = T_VOID;
	type.ref = 0;

	if(pick2) type = *type2;
	else type = *type1;

	*dest = type;
	return 0;
}

int main(void)
{
	int r;
	r = 0;

	sym_a.id = 11;
	sym_b.id = 22;
	cs.i = 7;

	struct CType c1;
	struct CType c2;
	c1.t = T_PTR; c1.ref = &sym_a;
	c2.t = T_PTR; c2.ref = &sym_b;

	/* 1 -- SELF-CONSISTENT, AND THE LAYOUT ITSELF IS CASE 115's JOB.
	 *
	 * `int t` followed by a pointer is TWELVE bytes under micro-c and
	 * sixteen under gcc: it inserts no alignment padding, so `ref` sits at
	 * offset 4. That is measured, not assumed -- EXPERIMENT-zzw records
	 * corpus row 122 returning 12 where the corpus expects 24, which is
	 * this shape exactly.
	 *
	 * Asserting 16 here would fire on every run and bury the probes that
	 * mean something; asserting nothing would be a test written so it
	 * cannot fail. So the layout is asserted in 115, on its own, where a
	 * failure says "every mixed-width struct in tcc is suspect" rather
	 * than being lost inside a case about conditionals. What 113 needs is
	 * only that sizeof agrees with the stride the compiler indexes at --
	 * a struct copied at one width and indexed at another is the failure
	 * this case is looking for, and that is measurable either way. */
	struct CType arr[4];
	unsigned long e0;
	unsigned long e1;
	e0 = (unsigned long)&arr[0];
	e1 = (unsigned long)&arr[1];
	if(e1 - e0 != sizeof(struct CType)) r = r + 1;
	/* and the whole width really is both fields */
	if(sizeof(struct CType) < sizeof(int) + sizeof(struct Sym*)) r = r + 1;

	/* 2 -- local = *pointer. The copy tcc makes at tccgen.c:2932. If only
	 * the first field moves, `ref` keeps the NULL it was initialised with
	 * and the merged type points at nothing. */
	struct CType* p2;
	p2 = &c2;
	struct CType t2;
	t2.t = T_VOID;
	t2.ref = 0;
	t2 = *p2;
	if(t2.t != T_PTR) r = r + 2;
	if(t2.ref != &sym_b) r = r + 2;

	/* 4 -- MOVED TO CASE 116, and the move is the point.
	 *
	 * tccgen.c:2939 writes `type = *(bt1 == VT_PTR ? type1 : type2);` -- a
	 * dereference applied to the RESULT OF A CONDITIONAL. That segfaults
	 * under micro-c, it does so with plain int pointers and no struct
	 * anywhere near it, and it reproduces under the compiler as it was
	 * before the conditional-type fix -- so it is a second and independent
	 * defect, not a consequence of the first.
	 *
	 * Leaving it here would make this case fail for a reason it is not
	 * about, and a case that fails for two reasons at once names neither.
	 * 116 carries it, reduced, as a declared gap. */
	struct CType* p1;
	p1 = &c1;

	/* 8 -- *pointer = local, the `*dest = type` the merge ends on */
	struct CType out;
	out.t = T_VOID;
	out.ref = 0;
	struct CType* op;
	op = &out;
	*op = c2;
	if(out.t != T_PTR) r = r + 8;
	if(out.ref != &sym_b) r = r + 8;

	/* 16 -- the construct itself. `0` is a null pointer constant, so the
	 * type of the conditional is `struct condstruct *` and the `->` is
	 * legal. This is 33_ternary_op.c:37 and tcctest.c:4082. */
	struct condstruct* s;
	s = &cs;
	/* THE CONDITION IS A VARIABLE, NOT A LITERAL, and it is chosen so the
	 * arm that actually RUNS is always `s`. The type merge happens at
	 * compile time for both arms either way -- which is the thing under
	 * test -- but evaluating the null arm would dereference it, and a case
	 * that segfaults under gcc measures nothing. A literal condition would
	 * also let the compiler fold the conditional away and skip the merge
	 * entirely. */
	int zero;
	int one;
	zero = 0;
	one = 1;

	int i1;
	i1 = (zero != 0 ? 0 : s)->i;   /* false, so `s` is taken */
	if(i1 != 7) r = r + 16;
	i1 = (one == 0 ? 0 : s)->i;    /* false, so `s` is taken */
	if(i1 != 7) r = r + 16;

	/* 32 -- arms the other way round, which takes the other branch of the
	 * merge: is_null_pointer(op2) rather than is_null_pointer(op1) */
	int i2;
	i2 = (one != 0 ? s : 0)->i;
	if(i2 != 7) r = r + 32;
	i2 = (zero == 0 ? s : 0)->i;
	if(i2 != 7) r = r + 32;

	/* 64 -- an explicit void* null rather than a bare 0. tcc reaches these
	 * through different arms of is_null_pointer -- VT_PTR with a void
	 * target, against VT_INT with value zero -- so they are two probes. */
	int i3;
	i3 = (zero != 0 ? (void*)0 : s)->i;
	if(i3 != 7) r = r + 64;
	i3 = (one != 0 ? s : (void*)0)->i;
	if(i3 != 7) r = r + 64;

	/* 128 -- the merge as a function, both selections, checking that the
	 * ref survives the trip through a local and out through a pointer */
	struct CType got;
	got.t = T_VOID;
	got.ref = 0;
	merge(&got, &c1, &c2, 1);
	if(got.ref != &sym_b) r = r + 128;
	got.t = T_VOID;
	got.ref = 0;
	merge(&got, &c1, &c2, 0);
	if(got.ref != &sym_a) r = r + 128;

	return r;
}
