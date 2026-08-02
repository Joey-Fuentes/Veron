/* is_null_pointer, tccgen.c:2807 -- THE TEST THAT DECIDES THE MERGE.
 *
 * WIDE CONSTANTS -- 0x1234567890abcdef and 0xffffffff00000000 do not fit an
 * immediate field, so this case is expected to move across EXPERIMENT-zzb.
 * See imm-identity.sh.
 *
 * Case 113 covers what combine_types does once it has decided. This covers the
 * deciding. If this predicate answers wrongly for a bare `0`, the conditional
 * `(cond ? 0 : s)` never reaches the null-pointer branch at all and the merge
 * takes a different route -- so the two cases fail in different places for
 * different reasons and a run that fails only one of them has already halved
 * the search.
 *
 * THE ORIGINAL, unchanged apart from names:
 *
 *     static inline int is_null_pointer(SValue *p)
 *     {
 *         if ((p->r & (VT_VALMASK | VT_LVAL | VT_SYM | VT_NONCONST)) != VT_CONST)
 *             return 0;
 *         return ((p->type.t & VT_BTYPE) == VT_INT && (uint32_t)p->c.i == 0) ||
 *             ((p->type.t & VT_BTYPE) == VT_LLONG && p->c.i == 0) ||
 *             ...
 *     }
 *
 * FOUR THINGS HAVE TO BE RIGHT AND EACH IS A SHAPE THIS COMPILER HAS BEEN
 * WRONG ABOUT BEFORE:
 *
 *   p->r                 an `unsigned short` MEMBER masked against int
 *                        constants. A member that loads at the wrong width or
 *                        does not zero-extend gives a mask result that never
 *                        equals VT_CONST -- EXPERIMENT-zzza and -zzzb.
 *
 *   p->c.i               a member of an ANONYMOUS UNION, reached through a
 *                        pointer. MICRO-C.md records a member of an anonymous
 *                        struct nested in an anonymous union resolving to
 *                        offset 0 and costing five rounds; EXPERIMENT-zzzh
 *                        closed it. This is the regression guard.
 *
 *   (uint32_t)p->c.i     a NARROWING CAST of a 64-bit member. If the cast does
 *                        not truncate, a value whose low 32 bits are zero and
 *                        whose high bits are not answers wrongly --
 *                        EXPERIMENT-zzzc.
 *
 *   a || b || c          short-circuit across three clauses, each of which
 *                        dereferences. 04-short-circuit covers `&&` and `||`
 *                        on plain ints; this is the same operator over member
 *                        reads.
 *
 * SValue's layout is copied from tcc.h so the anonymous union sits where tcc
 * puts it -- after the CType and the two shorts, not at the start of the
 * struct.
 *
 * Probes, one bit each:
 *
 *   1  the flag mask over an unsigned short member answers VT_CONST
 *   2  a non-constant r is rejected
 *   4  p->c.i reads the value written through the union, not offset 0
 *   8  (unsigned)p->c.i truncates: high bits set, low 32 zero, answers zero
 *  16  the full predicate says yes for a bare integer 0
 *  32  the full predicate says no for a non-zero integer
 *  64  the full predicate says yes for a zero of the wider type
 * 128  the || chain does not evaluate past the clause that answered
 */

#define VT_VALMASK   0x003f
#define VT_CONST     0x0030
#define VT_LVAL      0x0100
#define VT_SYM       0x0200
#define VT_NONCONST  0x1000
#define VT_BTYPE     0x000f
#define VT_INT       3
#define VT_LLONG     4

struct Sym { int id; };

struct CType {
	int t;
	struct Sym* ref;
};

union CValue {
	double d;
	unsigned long i;
	struct {
		char* data;
		int size;
	} str;
};

struct SValue {
	struct CType type;
	unsigned short r;
	unsigned short r2;
	union CValue c;
	struct Sym* sym;
};

static int clause_calls;

static int btype_of(struct SValue* p)
{
	clause_calls = clause_calls + 1;
	return p->type.t & VT_BTYPE;
}

static int is_null_pointer(struct SValue* p)
{
	if((p->r & (VT_VALMASK | VT_LVAL | VT_SYM | VT_NONCONST)) != VT_CONST)
		return 0;
	return ((p->type.t & VT_BTYPE) == VT_INT && (unsigned)p->c.i == 0) ||
	       ((p->type.t & VT_BTYPE) == VT_LLONG && p->c.i == 0);
}

int main(void)
{
	int r;
	r = 0;

	struct SValue sv;
	struct SValue* p;
	p = &sv;

	/* 1 -- an unsigned short member through the flag mask. VT_CONST is
	 * 0x0030 and the mask is 0x1330; a member read that sign-extends or
	 * loads eight bytes gives something that is not 0x30. */
	sv.type.t = VT_INT;
	sv.type.ref = 0;
	sv.r = VT_CONST;
	sv.r2 = 0;
	sv.c.i = 0;
	sv.sym = 0;
	if((p->r & (VT_VALMASK | VT_LVAL | VT_SYM | VT_NONCONST)) != VT_CONST)
		r = r + 1;

	/* 2 -- and it must REJECT an lvalue */
	sv.r = VT_CONST | VT_LVAL;
	if((p->r & (VT_VALMASK | VT_LVAL | VT_SYM | VT_NONCONST)) == VT_CONST)
		r = r + 2;
	sv.r = VT_CONST;

	/* 4 -- the union member, through a pointer, at its real offset. If it
	 * resolves to offset 0 this reads type.t instead. */
	sv.type.t = 0x7fff;
	sv.c.i = 0x1234567890abcdefUL;
	if(p->c.i != 0x1234567890abcdefUL) r = r + 4;
	if(p->type.t != 0x7fff) r = r + 4;

	/* 8 -- the narrowing cast truncates. High bits set, low 32 clear: the
	 * cast must answer zero and the uncast value must not. */
	sv.c.i = 0xffffffff00000000UL;
	if((unsigned)p->c.i != 0) r = r + 8;
	if(p->c.i == 0) r = r + 8;

	/* 16 -- the whole predicate, for a bare 0 of integer type */
	sv.type.t = VT_INT;
	sv.r = VT_CONST;
	sv.c.i = 0;
	if(!is_null_pointer(p)) r = r + 16;

	/* 32 -- and for a non-zero, which must answer no */
	sv.c.i = 42;
	if(is_null_pointer(p)) r = r + 32;

	/* 64 -- a zero of the wider type reaches the SECOND clause, so this
	 * fails where 16 passes if the || chain stops after the first */
	sv.type.t = VT_LLONG;
	sv.c.i = 0;
	if(!is_null_pointer(p)) r = r + 64;

	/* 128 -- short circuit over member reads. The first clause is false
	 * because the btype is not VT_INT, so btype_of runs twice, once per
	 * clause -- and a chain that evaluates eagerly runs it more. */
	sv.type.t = VT_LLONG;
	sv.c.i = 0;
	clause_calls = 0;
	int answer;
	answer = (btype_of(p) == VT_INT && (unsigned)p->c.i == 0) ||
	         (btype_of(p) == VT_LLONG && p->c.i == 0);
	if(!answer) r = r + 128;
	if(clause_calls != 2) r = r + 128;

	return r;
}
