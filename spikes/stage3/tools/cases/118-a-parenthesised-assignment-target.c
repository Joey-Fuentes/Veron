/* `(x) += n` -- A PARENTHESISED ASSIGNMENT TARGET MUST NOT BE LOADED.
 *
 * Four characters apart, and the second one segfaulted:
 *
 *     ln += 4;      correct, and always was
 *     (ln) += 4;    the variable was LOADED and the store wrote through its
 *                   VALUE as if that were an address
 *
 * Every load decision in cc_core.c blanks the load when an assignment
 * follows, and each finds out by looking at the NEXT TOKEN. For `(ln) += 4`
 * the next token is the closing paren, so none of them saw it.
 *
 * WHERE tcc WRITES IT, and why the spelling is parenthesised at all -- it is a
 * macro parameter, so the parentheses are the safe way to write it:
 *
 *     #define dwarf_read_4(ln,end) \
 *         ((ln) + 3 < (end) ? read32le(((ln)+=4) - 4) : 0)     tcc.h:1863
 *
 * tcc_eh_frame_hdr walks .eh_frame with that macro, and it runs for EVERY
 * DYNAMIC OUTPUT. So mc-tcc segfaulted on any link that was not -static:
 *
 *     mc-tcc -nostdlib -static ...   fine
 *     mc-tcc -nostdlib ...           SIGSEGV
 *     mc-tcc -nostdlib -shared ...   SIGSEGV
 *
 * which is the whole libc-facing surface stage 4 needs, and it is invisible to
 * the hermetic job because that job is -static end to end.
 *
 * THE OTHER HALF OF THE RULE IS CASE 49, and getting this wrong broke it. In
 *     *(t) = v
 * `t` is NOT the target -- what it points at is -- so t must be loaded to be
 * followed. Suppressing the load there stored through the address of the
 * variable's own slot. The two are told apart by whether a dereference was
 * eaten before the parenthesis: an address applies to the LAST step of a
 * chain, never to one still to be followed.
 *
 * Probes, one bit each:
 *
 *   1  `ln += 4` on a pointer -- the control, unparenthesised
 *   2  `(ln) += 4` -- the defect
 *   4  the same on an int, where a wrong store is a wrong value not a fault
 *   8  `(x) = v`, plain assignment rather than compound
 *  16  doubled parentheses
 *  32  `*(t) = v` -- case 49's shape, which must NOT be affected
 *  64  the dwarf_read_4 macro end to end, value and advance
 */

unsigned char buf[32];
long sink;

static unsigned read32le(unsigned char* p)
{
	return p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24);
}

#define dwarf_read_4(ln,end) ((ln) + 3 < (end) ? read32le(((ln)+=4) - 4) : 0)

static void put_long(long* t, long v) { *(t) = v; }

int main(void)
{
	int r;
	int i;
	r = 0;
	i = 0;
	while(i < 32) { buf[i] = i; i = i + 1; }

	unsigned char* ln;
	unsigned char* end;

	/* 1 -- the control */
	ln = buf;
	ln += 4;
	if(ln != buf + 4) r = r + 1;

	/* 2 -- the defect */
	ln = buf;
	(ln) += 4;
	if(ln != buf + 4) r = r + 2;

	/* 4 -- an int, so a wrong store shows as a wrong value */
	int n;
	n = 10;
	(n) += 5;
	if(n != 15) r = r + 4;

	/* 8 -- plain assignment, not compound */
	int m;
	m = 0;
	(m) = 7;
	if(m != 7) r = r + 8;

	/* 16 -- doubled parentheses */
	int k;
	k = 1;
	((k)) += 2;
	if(k != 3) r = r + 16;

	/* 32 -- case 49's shape, which the fix must leave alone */
	put_long(&sink, 123456789);
	if(sink != 123456789) r = r + 32;

	/* 64 -- the macro tcc actually writes, value and advance */
	ln = buf;
	end = buf + 32;
	unsigned v;
	v = dwarf_read_4(ln, end);
	if(v != 0x03020100) r = r + 64;
	if(ln != buf + 4) r = r + 64;
	v = dwarf_read_4(ln, end);
	if(v != 0x07060504) r = r + 64;
	ln = buf + 30;                 /* too close to the end -- must not advance */
	v = dwarf_read_4(ln, end);
	if(v != 0) r = r + 64;
	if(ln != buf + 30) r = r + 64;

	return r;
}
