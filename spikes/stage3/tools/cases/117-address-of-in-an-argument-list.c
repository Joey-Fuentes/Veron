/* AN ARGUMENT THAT BEGINS WITH `&` MUST NOT LEAVE Address_of SET.
 *
 * Regression cover for EXPERIMENT-zzzo. The two lines differ only in the
 * ARGUMENT, and the second one was wrong:
 *
 *     struct CType* give(struct Sym* s) { return &s->type; }
 *
 *     give(sp)->t       42          correct
 *     give(&sym)->t     <address>   the offset is added, the load is not
 *
 * unary_expr sets Address_of when an expression begins with `&` and clears it
 * when it does not. An argument list is parsed in the MIDDLE of the postfix
 * chain, so `&sym` left the flag set and postfix_expr_arrow read it --
 *
 *     ... && (TRUE != Address_of || chain_continues)
 *
 * -- and skipped the load, because a trailing `&` wants the address rather
 * than the value. The `&` belonged to the argument and was applied to the
 * member.
 *
 * WHY IT IS WORTH A CASE OF ITS OWN. This is the third global in cc_core.c
 * that has had to learn the same lesson -- num_dereference_after_postfix and
 * pending_function_designator were both cleared across an argument list for
 * exactly this reason, and each was found separately, in CI, at the cost of a
 * round. An argument list is a separate expression context and every piece of
 * parser state parked across one is a candidate. A cheap local case per flag
 * is the only thing that turns that class from a discovery into a check.
 *
 * WHAT IT COST BEFORE IT WAS FOUND. tcc writes
 *
 *     ((pointed_type(&p->type)->t & VT_BTYPE) == VT_VOID) &&
 *     0 == (pointed_type(&p->type)->t & (VT_CONSTANT | VT_VOLATILE))
 *                                                        tccgen.c:2807
 *
 * an argument beginning with `&`, then `->t` on the result. That is the THIRD
 * clause of is_null_pointer -- the one that recognises `(void*)0` -- so mc-tcc
 * accepted `(c ? 0 : s)->i` and rejected `(c ? (void*)0 : s)->i`, which is
 * tests2/33_ternary_op.c:37 and tcctest.c:4082. A probe inside mc-tcc printed
 * that expression as 6897904 where VT_VOID (0) belongs.
 *
 * IT NEVER FAULTED. The expression yields an address instead of a value, so
 * the type system answers wrongly and nothing crashes, far from where it was
 * asked. That is why it outlived every reduction attempted from the outside.
 *
 * Probes, one bit each:
 *
 *   1  a plain argument, then `->` on the result -- the control, always worked
 *   2  an argument beginning with `&`, then `->` -- the defect
 *   4  a member at a non-zero offset, so it is not offset-0 aliasing
 *   8  `&` on the SECOND argument, not the first
 *  16  a nested call in the argument, with `&` inside it
 *  32  two such calls in one && chain, as is_null_pointer writes it
 *  64  `&` in an argument list must not disturb a following `[` either
 */

struct Sym;
struct CType { int t; struct Sym* ref; };
struct Sym { int v; struct CType type; };

struct Sym sym;
struct Sym other;
int table[4];

static struct CType* give(struct Sym* s)
{
	return &s->type;
}

static struct CType* give2(int n, struct Sym* s)
{
	if(n == 0) return &s->type;
	return &s->type;
}

static struct Sym* ident(struct Sym* s)
{
	return s;
}

static int* givetab(int* p)
{
	return p;
}

int main(void)
{
	int r;
	r = 0;

	sym.v = 1;
	sym.type.t = 42;
	sym.type.ref = &other;
	other.v = 2;
	other.type.t = 7;
	other.type.ref = 0;
	table[0] = 100;
	table[2] = 300;

	struct Sym* sp;
	sp = &sym;

	/* 1 -- the control. A plain argument was always correct. */
	if(give(sp)->t != 42) r = r + 1;

	/* 2 -- the defect: the argument begins with `&` */
	if(give(&sym)->t != 42) r = r + 2;

	/* 4 -- a member at offset 8, so this is not offset-0 aliasing */
	if(give(&sym)->ref != &other) r = r + 4;

	/* 8 -- `&` on the second argument rather than the first */
	if(give2(0, &sym)->t != 42) r = r + 8;

	/* 16 -- a nested call, with the `&` inside the inner argument list */
	if(give(ident(&sym))->t != 42) r = r + 16;

	/* 32 -- two of them in one && chain, which is the shape at
	 * tccgen.c:2807 that this was found through */
	if(!((give(&sym)->t & 0x00ff) == 42 && 0 == (give(&sym)->t & 0x0300)))
		r = r + 32;

	/* 64 -- the same flag also gates indexing, so a `&` argument must not
	 * disturb a following `[` */
	if(givetab(&table[0])[2] != 300) r = r + 64;
	if(givetab(table)[0] != 100) r = r + 64;

	return r;
}
