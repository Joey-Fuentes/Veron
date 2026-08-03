/* BITMASK -- CLOSED, in two halves. Kept as a regression guard.
 *
 *     (p)++     EXPERIMENT-zzzw   the parentheses are the target
 *     *(p)++    EXPERIMENT-zzzz   the increment precedes the dereference
 *
 * micro-c read `*(p)++` as `(*p)++` -- a different program: the byte moved and
 * the pointer did not. C reads it as `*((p)++)`, because a postfix operator
 * binds tighter than unary `*`.
 *
 * The compiler already knew the right order: `*p++` increments, then applies
 * the pending star LAST. The parenthesised path walked the dereference itself
 * and then cleared the pending count, so the postfix handler got a value where
 * it wanted an address and had no star left to apply. The fix hands the star
 * on instead of spending it.
 *
 * WHERE tcc WRITES IT, the other half of the pair zzzs closed:
 *     #define dwarf_read_1(ln,end) ((ln) < (end) ? *(ln)++ : 0)   tcc.h:1859
 * tcc_eh_frame_hdr uses dwarf_read_1 and dwarf_read_4 together; zzzs stopped
 * the segfault, this stops the walk seeing the same byte forever.
 *
 * A NEIGHBOUR THAT IS STILL OPEN: `(*p)++`, parentheses around the
 * dereference, segfaults -- and did so before any of this. The comment at
 * cc_core.c's paren_lvalue site names that spelling as one it handles; it does
 * not.
 */

unsigned char buf[32];

#define dwarf_read_1(ln,end) ((ln) < (end) ? *(ln)++ : 0)

int main(void)
{
	int r;
	int i;
	r = 0;
	i = 0;
	while(i < 32) { buf[i] = i; i = i + 1; }

	unsigned char* p;
	unsigned c;

	/* 1 -- the control */
	p = buf + 8;
	c = *p++;
	if(c != 8) r = r + 1;
	if(p != buf + 9) r = r + 1;

	/* 2 -- parentheses around the whole postfix expression */
	p = buf + 8;
	c = *(p++);
	if(c != 8) r = r + 2;
	if(p != buf + 9) r = r + 2;

	/* 4 -- parentheses around the target only */
	p = buf + 8;
	c = *(p)++;
	if(c != 8) r = r + 4;
	if(p != buf + 9) r = r + 4;

	/* 8 -- no dereference at all */
	p = buf + 8;
	(p)++;
	if(p != buf + 9) r = r + 8;

	/* 16 -- the macro tcc writes */
	unsigned char* end;
	p = buf + 8;
	end = buf + 32;
	c = dwarf_read_1(p, end);
	if(c != 8) r = r + 16;
	if(p != buf + 9) r = r + 16;

	return r;
}
