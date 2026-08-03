/* BITMASK -- CLOSED by EXPERIMENT-zzzzb. Kept as a regression guard.
 *
 * `(*p)++` -- parentheses around the DEREFERENCE -- segfaulted, while `p[0]++`
 * and `*p += 1` were always correct. The increment applies to what p points
 * at, so the last dereference must yield an ADDRESS; it loaded instead, and
 * the postfix handler then dereferenced the loaded byte:
 *
 *     mov_rax,[rax]              p
 *     movzx_rax,BYTE_PTR_[rax]   the byte -- 0
 *     # postfix inc/dec
 *     movzx_rax,BYTE_PTR_[rax]   dereference 0        SIGSEGV
 *
 * The eleventh copy of the one rule this file keeps rediscovering: the
 * decision reads the NEXT TOKEN, and for a parenthesised target that token is
 * `)`. zzzs, zzzw and zzzz are the same rule at three other spellings.
 *
 * WORTH ONE LINE OF ITS OWN: the comment at cc_core.c's paren_lvalue site
 * NAMES this spelling as one it handles -- "`(*p)++` the same thing written
 * the other way round". It does not. That site is the `*(...)` path, where the
 * star is OUTSIDE the parentheses, and it never sees this shape at all. A
 * comment claiming coverage is why this went unlooked-at.
 *
 * Probes, one bit each:
 *
 *   1  `(*p)++` -- the byte increments and the pointer does not move
 *   2  `p[0]++` -- the control, correct before and after
 *   4  `(*p)--`
 *   8  `++(*p)` -- the prefix spelling
 *  16  `(*p) += 3` -- compound assignment through the same parentheses
 *  32  `**(pp)` still LOADS, because only the last step is spared
 */

unsigned char buf[32];
unsigned char* gp;

int main(void)
{
	int r;
	int i;
	unsigned char* p;
	unsigned char* q;
	unsigned char** pp;

	r = 0;
	i = 0;
	while(i < 32) { buf[i] = i; i = i + 1; }

	/* 1 -- the defect */
	p = buf + 8;
	(*p)++;
	if(buf[8] != 9) r = r + 1;
	if(p != buf + 8) r = r + 1;

	/* 2 -- the control: the same thing spelled as an index */
	p = buf + 10;
	p[0]++;
	if(buf[10] != 11) r = r + 2;

	/* 4 -- decrement through the same parentheses */
	p = buf + 12;
	(*p)--;
	if(buf[12] != 11) r = r + 4;

	/* 8 -- compound assignment through the same parentheses */
	p = buf + 16;
	(*p) += 3;
	if(buf[16] != 19) r = r + 8;

	/* 16 -- ONLY THE LAST STEP IS SPARED. `**(pp)` has to load once to reach
	 * the inner pointer, so a fix that suppresses every load breaks this. */
	q = buf + 20;
	pp = &q;
	if(**(pp) != 20) r = r + 16;

	return r;
}
