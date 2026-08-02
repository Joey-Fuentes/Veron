/* KNOWN GAP -- a member reached through the RESULT OF A CALL is not loaded.
 *
 * THIS IS THE ONE THAT STOPS tcctest.c, and it was found by instrumenting
 * mc-tcc rather than by reducing from the outside, because every hand-written
 * model of the failing construct passed.
 *
 * REDUCED:
 *
 *     struct CType* give(struct Sym* s) { return &s->type; }
 *
 *     struct CType* p = give(&sym);
 *     p->t                     42        correct
 *     give(&sym)->t            <address> WRONG -- the pointer, not the value
 *
 * Same call, same member, same load. Putting the `->` directly on the call
 * result is the only difference, and BOTH member offsets are affected -- it is
 * not the offset-0 aliasing that `&x->first == x` would explain.
 *
 * HOW IT WAS FOUND, because the route matters. mc-tcc accepts
 *
 *     (c ? 0 : s)->i           bare 0, both arm orders
 *
 * and rejects
 *
 *     (c ? (void*)0 : s)->i    `struct or union expected`
 *
 * which is tests2/33_ternary_op.c:37 and tcctest.c:4082. Those two spellings
 * differ by exactly one thing in tcc: which clause of is_null_pointer answers.
 * A bare 0 is caught by the first clause, `(void*)0` by the THIRD -- and the
 * third is the only one that calls pointed_type():
 *
 *     ((p->type.t & VT_BTYPE) == VT_PTR &&
 *      (PTR_SIZE == 4 ? (uint32_t)p->c.i == 0 : p->c.i == 0) &&
 *      ((pointed_type(&p->type)->t & VT_BTYPE) == VT_VOID) &&        <--
 *      0 == (pointed_type(&p->type)->t & (VT_CONSTANT | VT_VOLATILE)))
 *                                                        tccgen.c:2807
 *
 * A probe inside mc-tcc printed that expression as 6897904 -- an ADDRESS where
 * VT_VOID (0) belongs. Rewritten as
 *
 *     CType *pt = pointed_type(q);  ... pt->t
 *
 * the same probe printed 0. The call is right, the member offset is right, the
 * struct layout is right; the load after the call is missing.
 *
 * WHAT ELSE THIS EXPLAINS. `pointed_type(x)->t` is written throughout tccgen,
 * and every use of it silently yields an address. That is a wrong VALUE rather
 * than a crash, which is why it survived: nothing faults, the type system just
 * answers wrongly, far from where it was asked.
 *
 * WHAT IT IS NOT. Not the conditional's result type -- EXPERIMENT-zzzn fixes
 * that, and it is a real defect, but mc-tcc came out BYTE-IDENTICAL with and
 * without it, so it changed nothing tcc depends on. Not dereferencing a
 * conditional either; case 116 carries that separately. Three distinct
 * defects met on one line of one test, which is why the CI symptom resisted
 * being reduced.
 *
 * MECHANISM, NOT YET NAMED. cc_core.c already carries `last_expr_was_call`,
 * introduced by EXPERIMENT-zzzh so that `*f()` starts its chain one step
 * further along. postfix_expr sets it FALSE at the top of the trailing-star
 * walk, and the member-access path never consults it -- so `->` after a call
 * takes the ordinary lvalue route, which assumes the register holds the
 * ADDRESS OF a storage slot rather than a value. That is the shape of the fix
 * and it is not made here: the member path is shared by every `.`/`->`/`[` in
 * the compiler and 99 differential cases depend on it, so it wants its own
 * change with the suite run either side.
 *
 * Probes, one bit each:
 *
 *   1  member at offset 0 through a variable -- the control
 *   2  member at offset 8 through a variable -- the control
 *   4  member at offset 0 directly on the call result
 *   8  member at offset 8 directly on the call result
 *  16  the same, used in a condition rather than a comparison
 *  32  two calls in one expression, as is_null_pointer writes it
 */

struct Sym;
struct CType { int t; struct Sym* ref; };
struct Sym { int v; struct CType type; };

struct Sym sym;
struct Sym other;

static struct CType* give(struct Sym* s)
{
	return &s->type;
}

int main(void)
{
	int r;
	r = 0;

	sym.v = 1;
	sym.type.t = 42;
	sym.type.ref = &other;
	other.v = 2;
	other.type.t = 0;
	other.type.ref = 0;

	/* 1, 2 -- through a variable. These work, and they are the control:
	 * a failure here is something far broader than this gap. */
	struct CType* p;
	p = give(&sym);
	if(p->t != 42) r = r + 1;
	if(p->ref != &other) r = r + 2;

	/* 4, 8 -- the same two members, straight off the call */
	if(give(&sym)->t != 42) r = r + 4;
	if(give(&sym)->ref != &other) r = r + 8;

	/* 16 -- as a truth test rather than a comparison, since tcc's use is
	 * inside a && chain */
	if(!(give(&sym)->t == 42)) r = r + 16;

	/* 32 -- two calls in one expression, which is how is_null_pointer's
	 * third clause is actually written */
	if(!((give(&sym)->t & 0x00ff) == 42 && 0 == (give(&sym)->t & 0x0300)))
		r = r + 32;

	return r;
}
