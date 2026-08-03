/* BITMASK -- CLOSED by EXPERIMENT-zzzy. Kept as a regression guard.
 *
 * micro-c has no prototype form that registers a function without defining
 * it, so mutual recursion could not be written in its natural order:
 *
 *     int ev(int n){ if(n) return od(n-1); return 1; }
 *     int od(int n){ if(n) return ev(n-1); return 0; }
 *
 *     micro-c: od is not a defined symbol
 *
 * C89 6.3.2.2 declares an undeclared identifier called with parentheses as a
 * function returning int with external linkage. That is stage 2 conformance
 * corpus row 118, which this mirrors so the differential suite carries it too
 * -- the corpus runs only in its own step, and a construct with one home gets
 * rediscovered rather than protected.
 *
 * WHAT IS NOT COVERED HERE, because a case cannot assert a compile failure:
 * a bare unknown NAME must still be an error. `x = nosuchvar;` still stops
 * with "nosuchvar is not a defined symbol", and a call to a name that truly
 * does not exist still fails at link time out of hex2 as "Target label
 * FUNCTION_nosuchfn is not valid". Both are checked by hand in zzzy's notes.
 *
 * Probes, one bit each:
 *
 *   1  the forward call itself -- od used before it is seen
 *   2  the mutual recursion actually alternates, ten deep
 *   4  the odd answer, so it is not returning a constant
 *   8  a forward call whose argument is an expression
 *  16  a forward call used inside a larger expression
 */

int fwd_two(int n);          /* referenced below before its definition */

int ev(int n)
{
	if(n) { return od(n - 1); }
	return 1;
}

int od(int n)
{
	if(n) { return ev(n - 1); }
	return 0;
}

int later(int a, int b)
{
	return a * 10 + b;
}

int fwd_two(int n)
{
	return n + 1;
}

int main(void)
{
	int r;
	r = 0;

	/* 1 -- od is called from ev before od has been seen */
	if(ev(2) != 1) r = r + 1;

	/* 2 -- ten deep, so it alternates rather than short-circuiting */
	if(ev(10) != 1) r = r + 2;

	/* 4 -- the odd answer, so a constant return would not pass */
	if(ev(7) != 0) r = r + 4;

	/* 8 -- the argument is an expression, not a bare name */
	if(later(1 + 1, 3) != 23) r = r + 8;

	/* 16 -- the call sits inside a larger expression */
	if((fwd_two(4) * 2) - 1 != 9) r = r + 16;

	return r;
}
