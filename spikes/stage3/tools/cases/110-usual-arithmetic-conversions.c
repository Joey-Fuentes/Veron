/* KNOWN GAP -- THE USUAL ARITHMETIC CONVERSIONS, for an unsigned literal.
 *
 * WIDE CONSTANTS -- 0x87654321 is past INT_MAX and does not fit an immediate
 * field, so this case is expected to move across EXPERIMENT-zzb. That is the
 * whole subject of the case. See imm-identity.sh.
 *
 * Expected to fail. Found while writing case 109, where it masqueraded as a
 * codegen bug: that case compared an `int` against 0x87654321 and failed for
 * this reason rather than the one it was testing. Split out so each case fails
 * for its own reason.
 *
 * C GIVES A HEXADECIMAL LITERAL THE FIRST TYPE IT FITS, from int, unsigned
 * int, long, unsigned long. 0x87654321 is 2,271,560,481 -- past INT_MAX, so it
 * is `unsigned int`. Comparing it against an `int` therefore converts the INT
 * to unsigned, and the comparison succeeds:
 *
 *     int got = (int)0x87654321;    // -2023406815
 *     got != 0x87654321             // FALSE in C: both become 0x87654321
 *
 * micro-c folds constants as SIGNED 64-BIT (see EXPERIMENT-zzb, which made
 * that deliberate and correct for the widening it was solving). So the literal
 * stays +2,271,560,481, the int sign-extends to -2,023,406,815, and the
 * comparison is TRUE -- the opposite answer.
 *
 * WHY IT IS NOT SIMPLY "zzb WAS WRONG". zzb fixed a real and much larger
 * problem: every constant above 2^31 was being truncated or sign-extended by
 * hand at three separate chokepoints. Sixty-four-bit signed folding is right
 * for representing the VALUE. What is missing is the separate rule about the
 * literal's TYPE, and the conversion that type forces on the other operand.
 * Two different questions that happen to meet at the same constant.
 *
 * WHERE tcc HITS IT. Anywhere a mask or a flag word is written in hex above
 * 2^31 and compared against a signed value -- and tcc is full of both. It has
 * not yet been shown to cause a specific tcc failure, which is why this is a
 * measured gap rather than a fix: the cases that would settle it are here, and
 * closing it means implementing the usual arithmetic conversions properly
 * rather than patching one comparison.
 *
 * Probes, one bit each:
 *
 *   1  an int compared against an unsigned-int literal converts the int
 *   2  the same through a variable, so it is not constant folding alone
 *   4  0x7FFFFFFF stays signed and is unaffected -- the boundary
 *   8  an explicit (unsigned) cast agrees, which is why case 109 uses one
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
