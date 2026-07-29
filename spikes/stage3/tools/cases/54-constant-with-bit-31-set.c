/* A CONSTANT WITH BIT 31 SET. BITMASK. WIDE CONSTANTS.
 *
 * THE TWO TARGETS GOT THIS WRONG IN OPPOSITE DIRECTIONS, which is why one
 * threshold serves both and it is the intersection rather than the union:
 *
 *     aarch64   ldr_w<r>,8 loads a WORD and ZERO-extends -- right here,
 *               wrong for every negative value
 *     amd64     mov_<r>, %imm32 is MOV r/m64, imm32 and SIGN-extends --
 *               right for negatives, wrong here
 *
 * One compile of libtcc.c emitted 189 constants in this range. On amd64 every
 * one of them became 0xFFFFFFFF80000000. That is the sixth instance of the
 * amd64-hides/aarch64-faults class MICRO-C.md counts and the first running the
 * other way, which is exactly why the suite is run on both columns.
 *
 * Anchored on shifts and on `< 0`, never on a second wide literal. */
int main(void)
{
	long long r;
	long long v;
	r = 0;

	v = 0x80000000;
	if(v < 0) r = r + 1;
	if((v >> 31) != 1) r = r + 2;
	if((v >> 16) != 0x8000) r = r + 4;

	v = 0xffffffff;
	if(v < 0) r = r + 8;
	if((v >> 16) != 0xffff) r = r + 16;
	if((v >> 31) != 1) r = r + 32;

	return r;
}
