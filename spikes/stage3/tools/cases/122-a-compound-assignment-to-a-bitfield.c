/* `field |= x` -- A COMPOUND ASSIGNMENT TO A BITFIELD IS A READ-MODIFY-WRITE.
 *
 * The plain `=` path masked and shifted; the compound path did not. It loaded
 * the whole unit, applied the operator to it, and stored the whole unit back:
 *
 *     ldr_x1,[x1]         # the whole unit, not the field
 *     orr_x0,x1,x0
 *     strh_w0,[x1]        # no mask, no shift
 *
 * so every |=, &=, ^=, += on a bitfield landed on BIT ZERO of the unit.
 *
 * WHAT IT COST. tcc merges symbol attributes with
 *     sa->weak |= sa1->weak;                    tccgen.c, merge_symattr
 * and `weak` is bit 6, so the bit never arrived and the alias came out
 * STB_GLOBAL. musl declares __acquire_ptc, __release_ptc and __malloc_atfork
 * hidden in a header and weak-aliases each in one unit while another defines
 * it, so all three collided and GNU make would not link at rung 3.5:
 *
 *     libc.a: error: '__acquire_ptc' defined twice
 *
 * The neighbours matter as much as the field: a write that lands in the wrong
 * place usually damages something else in the same unit, so every case here
 * checks what was NOT meant to change.
 */

struct bits {
	unsigned short a5 : 5;
	unsigned short p1 : 1;
	unsigned short w1 : 1;
	unsigned short v2 : 2;
	unsigned short r7 : 7;
};

struct wide {
	unsigned int lo : 3;
	unsigned int mid : 12;
	unsigned int hi : 17;
};

static struct bits B;
static struct wide W;

static void merge(struct bits *d, struct bits *s)
{
	d->p1 |= s->p1;
	d->w1 |= s->w1;
}

int main()
{
	int r;
	r = 0;

	/* the exact shape tcc's merge_symattr uses, through pointers */
	B.a5 = 3; B.p1 = 0; B.w1 = 0; B.v2 = 2; B.r7 = 9;
	{
		struct bits s;
		s.a5 = 0; s.p1 = 0; s.w1 = 1; s.v2 = 0; s.r7 = 0;
		merge(&B, &s);
	}
	if (B.w1 != 1) r = r + 1;
	if (B.a5 != 3) r = r + 2;      /* neighbours below must survive */
	if (B.v2 != 2) r = r + 4;      /* and above */
	if (B.r7 != 9) r = r + 8;
	if (B.p1 != 0) r = r + 16;

	/* the other operators, at a non-zero offset */
	B.w1 = 1;
	B.w1 &= 0;
	if (B.w1 != 0) r = r + 32;
	if (B.a5 != 3 || B.v2 != 2) r = r + 64;

	B.v2 = 1;
	B.v2 += 2;                      /* 1 + 2 = 3, fits in two bits */
	if (B.v2 != 3) r = r + 128;
	if (B.a5 != 3 || B.r7 != 9) r = r + 256;

	B.a5 = 5;
	B.a5 ^= 3;                      /* 5 ^ 3 = 6 */
	if (B.a5 != 6) r = r + 512;

	B.r7 = 100;
	B.r7 -= 1;
	if (B.r7 != 99) r = r + 1024;

	/* a field at offset zero, where the bug was invisible */
	W.lo = 5; W.mid = 4000; W.hi = 70000;
	W.lo |= 2;
	if (W.lo != 7) r = r + 2048;
	if (W.mid != 4000 || W.hi != 70000) r = r + 4096;

	/* a wide field high in the unit */
	W.hi |= 1;
	if (W.hi != 70001) r = r + 8192;
	if (W.lo != 7 || W.mid != 4000) r = r + 16384;

	/* the right-hand side is itself a bitfield read, which is what
	 * overwrites the pending field description if it is not captured first */
	W.mid = 0;
	W.mid |= W.lo;
	if (W.mid != 7) r = r + 32768;
	if (W.lo != 7 || W.hi != 70001) r = r + 65536;

	return r;
}
