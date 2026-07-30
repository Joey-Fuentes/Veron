/* `&p->ref->type` and `&(p)->ref->type` -- an address applies to the LAST step.
 *
 * TWO SEPARATE BUGS, one per spelling, both the same rule.
 *
 * postfix_expr_arrow computes `chain_continues` and applies it to the prefix
 * ++/-- flag, but not to Address_of -- so `&` suppressed the load at EVERY
 * arrow instead of only the last:
 *
 *     &p->ref->type      ldr [p]  add 8  add 8
 *      p->ref->type.t    ldr [p]  add 8  ldr  add 8  ldr
 *
 * The middle load is how you follow `->ref`; without it the second offset is
 * added to the ADDRESS of ref rather than to what ref points at.
 *
 * The parenthesised spelling failed differently: primary_expr hands Address_of
 * into the parens, which is right for `&(x)` and wrong when a chain follows
 * the `)`, because then the inside must be an ordinary value. That one dropped
 * the FIRST load instead of the middle one.
 *
 * tcc writes the parenthesised form, because pointed_type is a macro:
 *
 *     #define pointed_type(t) (&(t)->ref->type)
 *
 * compare_types calls it for every pointer comparison, so ANY assignment of a
 * pointer-valued expression walked a wild address:
 *
 *     char *p = g();      SIGSEGV        int n = g();      fine
 *
 * found by tracing mc-tcc's own call path:
 *     vstore -> verify_assign_cast -> compare_types
 *            -> is_compatible_unqualified_types -> compare_types
 *
 * Probe 6 is the value form, which was always correct -- it is the control
 * that made the missing load visible in the emission rather than inferred.
 *
 * Closing this also closed case 44, `&((*p)->m)`, open since the start of the
 * spike: same rule, third spelling.
 */
struct Sym;
struct CType { int t; struct Sym* ref; };
struct Sym { int v; struct CType type; };

struct Sym inner;
struct Sym outer;

int main(void)
{
	struct CType* p;
	struct CType* q;

	inner.v = 7;
	inner.type.t = 42;
	outer.v = 1;
	outer.type.t = 99;
	outer.type.ref = &inner;

	p = &outer.type;
	if (p->t != 99) return 1;

	/* the macro, exactly */
	q = &(p)->ref->type;
	if (q != &inner.type) return 2;
	if (q->t != 42) return 3;

	/* and through a plain variable rather than a parenthesised one */
	q = &p->ref->type;
	if (q != &inner.type) return 4;
	if (q->t != 42) return 5;

	/* the value form, which has always worked, as a control */
	if (p->ref->type.t != 42) return 6;
	return 0;
}
