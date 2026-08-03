/* BITMASK -- CLOSED by EXPERIMENT-zzzza. Kept as a regression guard.
 *
 * C gives a constant the first type it fits, and the BASE and SUFFIX choose
 * the list: 0x87654321 is unsigned int, 2271560481 is long, 0x87654321L is
 * long. Everything was typed `integer`, so an int compared against such a
 * literal gave the opposite answer from C.
 *
 * THIS CASE IS NOT THE MEASUREMENT, and should not be read as one. Its four
 * probes were written FROM the bug, so passing them proves very little -- the
 * same trap this file records elsewhere as "a test suite written from bugs
 * already found measures what has been fixed, not what remains". With this
 * case green, tools/uac-sweep.sh then found four more faults: the l/L suffix,
 * the u/L combination, operands narrower than int, and the result of `*` and
 * `+` keeping bits unsigned int does not have.
 *
 * The sweep generates the space -- nine operand types, fifteen literal
 * spellings, twelve operators, eight values, gcc as the oracle, 12,960 points
 * per architecture in about ninety seconds. That is what says the conversions
 * are implemented. This file is the cheap guard that runs with every other
 * case.
 */
int main(void)
{
	int r;
	r = 0;

	/* 1 -- the literal is unsigned int, so the int converts to unsigned */
	int got;
	got = (int)0x87654321;
	if(got != 0x87654321) r = r + 1;

	/* 2 -- through a variable, past any constant folding */
	unsigned char b[4];
	b[0] = 0x21; b[1] = 0x43; b[2] = 0x65; b[3] = 0x87;
	int viaptr;
	viaptr = *(int*)b;
	if(viaptr != 0x87654321) r = r + 2;

	/* 4 -- the boundary. 0x7FFFFFFF fits int, stays signed, and must be
	 * unaffected by whatever fixes the above. */
	int pos;
	pos = 0x7FFFFFFF;
	if(pos != 0x7FFFFFFF) r = r + 4;

	/* 8 -- the explicit form agrees, and is the workaround case 109 uses */
	unsigned int u;
	u = 0x87654321u;
	if(u != 0x87654321u) r = r + 8;

	return r;
}
