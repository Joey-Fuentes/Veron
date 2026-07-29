/* AN INTEGER LITERAL IS SIXTY-FOUR BITS WIDE. BITMASK. WIDE CONSTANTS.
 *
 * M2libc's strtoint() returns int and finishes with a deliberate
 * sign-extension from bit 31. micro-c is built by gcc, where int IS 32 bits,
 * so a literal wider than that could not be REPRESENTED in the source micro-c
 * compiles: 0x100000000 was 0 and 0x7fffffffffffffff was 0xffffffff.
 *
 * It is not a corner. tcc's parse_number tests
 *
 *     if (n >= 0x8000000000000000ULL)
 *
 * That literal was 0, so the test read `n >= 0` -- true for everything -- and
 * the same statement marked the constant UNSIGNED. Every constant the tcc we
 * build reads was mis-typed, and it said so on each one:
 *
 *     <command line>:27: warning: integer constant overflow
 *
 * EVERY ANCHOR HERE IS A SHIFT OR A LITERAL BELOW 2^31, never a wide literal
 * compared against another wide literal. Case 43 passed for three rounds
 * because both sides of its comparison were broken identically; a case that
 * compares two forms of one construct tests only that they agree. */
int main(void)
{
	long long r;
	long long v;
	r = 0;

	v = 0x100000000;
	if(v == 0) r = r + 1;
	if((v >> 32) != 1) r = r + 2;

	v = 0x7fffffffffffffff;
	if((v >> 32) != 0x7fffffff) r = r + 4;
	if((v >> 48) != 0x7fff) r = r + 8;

	v = 0x123456789abcdef0;
	if((v >> 32) != 0x12345678) r = r + 16;
	if(((v >> 16) & 0xffff) != 0x9abc) r = r + 32;

	/* decimal, not hex: a different branch of the reader */
	v = 1099511627776;
	if((v >> 40) != 1) r = r + 64;

	return r;
}
