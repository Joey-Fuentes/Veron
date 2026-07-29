/* BITMASK. Binary operators had no precedence at all. CLOSED.
 *
 * MICRO-C.md listed this under `constant_expression` -- "a|b&c folds
 * right-to-left" -- and scopes it to the constant parser. It is not scoped to
 * the constant parser. These are ordinary runtime expressions and they are
 * wrong in the same direction:
 *
 *     1||0&&0   is 1 || (0 && 0)  = 1, and micro-c returns 0
 *     1|2^3     is 1 | (2 ^ 3)    = 1, and micro-c returns 0
 *     6^3&1     is 6 ^ (3 & 1)    = 7, and micro-c returns 1
 *
 * Arithmetic precedence IS right, which is why this went unnoticed: `1+2*3`
 * is 7. It is the bitwise and logical tiers that have no precedence at all.
 *
 * Rows 193, 196 and 197 of stage 2's conformance corpus. */
int main(void)
{
	long r;
	r = 0;
	if((1 || 0 && 0) != 1) r = r + 1;
	if((1 | 2 ^ 3) != 1) r = r + 2;
	if((6 ^ 3 & 1) != 7) r = r + 4;
	/* the tier that was always right, as a control */
	if((1 + 2 * 3) != 7) r = r + 8;
	return r;
}
