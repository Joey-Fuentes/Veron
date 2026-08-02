/* KNOWN GAP -- `*(p)++` advances wrongly, where `*p++` does not.
 *
 * MEASURED, three spellings of one expression:
 *
 *     c = *p++;      value 8, p advances by 1     correct
 *     c = *(p++);    value 8, p advances by 1     correct
 *     c = *(p)++;    value 8, p DOES NOT advance  wrong
 *
 * `*(p)++` parses as `*((p)++)`, so the parenthesised thing is the target of a
 * postfix operator and must yield p's ADDRESS for the increment while the
 * expression as a whole yields the OLD value for the dereference. Case 118's
 * flag suppresses the load, which fixes the advance and then breaks the value
 * -- so it is a different defect wearing the same parentheses, and 118
 * deliberately does not claim it.
 *
 * WHERE tcc WRITES IT, on the same line of the same walk as case 118:
 *
 *     #define dwarf_read_1(ln,end) ((ln) < (end) ? *(ln)++ : 0)   tcc.h:1859
 *
 * tcc_eh_frame_hdr uses dwarf_read_1 and dwarf_read_4 together. 118 fixes the
 * one that segfaulted; this one reads a byte and fails to advance, so the
 * walk sees the same byte repeatedly rather than crashing. A wrong answer
 * where there used to be a fault is progress and is not a fix.
 *
 * WHY IT IS A GAP RATHER THAN A FAILURE. The cause is named and the shape is
 * reduced, but the change is not: the postfix handler needs the address to
 * increment through AND the pre-increment value as the result, and the paths
 * that carry the "do not load an assignment target" rule each decide by
 * looking at the next token. Making the postfix case work through parentheses
 * means giving it both, which is a different edit from 118's. Marked KNOWN GAP
 * so the suite stays meaningful, and so difftest says so loudly when it starts
 * passing.
 *
 * Probes, one bit each:
 *
 *   1  `*p++` -- the control, value and advance
 *   2  `*(p++)` -- parenthesised the other way, also correct
 *   4  `*(p)++` -- the gap
 *   8  `(p)++` on its own, no dereference
 *  16  the dwarf_read_1 macro end to end
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
