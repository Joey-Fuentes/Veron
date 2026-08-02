/* `-p->v` -- A UNARY OPERATOR APPLIES TO THE WHOLE UNARY EXPRESSION.
 *
 * WIDE CONSTANTS -- 0xfffffffffffffff0 and its neighbours do not fit an
 * immediate field, so this case is expected to move across EXPERIMENT-zzb.
 * See imm-identity.sh.
 *
 * MEASURED, and the difference is which side of the arrow the minus lands on:
 *
 *     g.v  = -g.v;      fine      -- a member of a plain variable
 *     p->v = -(p->v);   fine      -- the parentheses group it by hand
 *     t    = -p->v;     SIGSEGV
 *
 * micro-c's unary-minus branch called primary_expr, which consumed only `p`
 * and left `->v` for the caller. The `!` branch twenty lines below it already
 * called postfix_expr, and the cast branch carries the same correction in the
 * same words -- this was the one unary operator that never got it.
 *
 * WHERE IT BIT, AND IT IS NOT A CORNER. tcc's assembler negates an immediate
 * with one line:
 *
 *     if (op == '-') pe->v = -pe->v;                   tccasm.c:178
 *
 * `pe` is a pointer, so mc-tcc segfaulted on EVERY NEGATIVE IMMEDIATE IN
 * ASSEMBLY while every positive one assembled:
 *
 *     stp x29,x30,[sp,-16]!    crash        stp x29,x30,[sp,16]!   fine
 *     ldr x0,[sp,-8]           crash        ldr x0,[sp,8]          fine
 *     mov x0,-16               crash        mov x0,16              fine
 *
 * That is musl's crt/aarch64/crti.s, src/string/aarch64/memcpy.S and
 * memset.S, and it was nine of the nine files that would not compile at rung 2
 * of the stage-4 ladder -- the rung that stops the whole climb, because no
 * crt1.o means nothing can be linked. All nine failed with SIGNAL 11 and no
 * diagnostic, which is why the shape had to be found rather than read.
 *
 * THE CONTROL IS WHAT MADE IT ATTRIBUTABLE. A gcc-hosted tcc built from the
 * same tarball and the same arm64-asm patches assembles all of those, so the
 * assembler is right and the compiler that built it was not. With this patch
 * mc-tcc assembles musl's crti.s to an object BYTE-IDENTICAL to that
 * control's.
 *
 * Probes, one bit each:
 *
 *   1  -g.v      through a plain variable -- the control, always worked
 *   2  -p->v     read side, the defect
 *   4  p->v = -p->v   read and write through the same pointer
 *   8  ~p->v     the other unary operator on the same branch
 *  16  -p->v[i]  an indexed member, so the fix covers the chain and not a step
 *  32  !p->v and -(-p->v), operators that were already right
 *  64  tccasm.c's line, verbatim
 */

struct E { unsigned long v; long arr[4]; };
struct E g;

/* tccasm.c:170-181, reduced to the two lines that matter */
static void asm_negate(struct E* pe, int op)
{
	if (op == '-') pe->v = -pe->v;
	else pe->v = ~pe->v;
}

int main(void)
{
	int r;
	r = 0;

	struct E* p;
	p = &g;
	unsigned long t;

	/* 1 -- a member of a plain variable */
	g.v = 16;
	g.v = -g.v;
	if(g.v != 0xfffffffffffffff0UL) r = r + 1;

	/* 2 -- the same through a pointer, read side only */
	g.v = 16;
	t = -p->v;
	if(t != 0xfffffffffffffff0UL) r = r + 2;

	/* 4 -- read and write through the same pointer */
	g.v = 16;
	p->v = -p->v;
	if(p->v != 0xfffffffffffffff0UL) r = r + 4;

	/* 8 -- the other operator sharing that branch */
	g.v = 16;
	p->v = ~p->v;
	if(p->v != 0xffffffffffffffefUL) r = r + 8;

	/* 16 -- an indexed member: the operator must take the whole chain */
	g.arr[2] = 7;
	long l;
	l = -p->arr[2];
	if(l != -7) r = r + 16;

	/* 32 -- operators that were already right, so a fix that broke them
	 * would show here rather than somewhere else */
	g.v = 0;
	if(!p->v != 1) r = r + 32;
	g.v = 16;
	t = -(-p->v);
	if(t != 16) r = r + 32;

	/* 64 -- tccasm.c's own line */
	g.v = 16;
	asm_negate(p, '-');
	if(g.v != 0xfffffffffffffff0UL) r = r + 64;
	g.v = 16;
	asm_negate(p, '~');
	if(g.v != 0xffffffffffffffefUL) r = r + 64;

	return r;
}
