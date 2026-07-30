/* tcc's OWN hand-rolled 32-to-64 sign extension, arm64-gen.c:494, in load():
 *
 * WIDE CONSTANTS -- 4294967264 and 4294967296 are the whole point of the case,
 * so it is expected to move across EXPERIMENT-zzb. See imm-identity.sh.
 *
 *     uint64_t svcul = (uint32_t)sv->c.i;
 *     svcul = svcul >> 31 & 1 ? svcul - ((uint64_t)1 << 32) : svcul;
 *
 * This is the exact shape that broke every program taking the address of a
 * local aggregate when compiled by a micro-c-built tcc. With the cast a
 * no-op, svcul keeps all 64 bits of a negative offset, the sign test still
 * fires, and 2^32 is subtracted from a value that was never truncated.
 *
 * The sub-steps are separated because five of the six either passed already
 * or failed as a CONSEQUENCE -- zzb and zze had made the shift and the
 * precedence right -- and only the cast was a cause. A case that checked the
 * result alone would say "the idiom is wrong" and name nothing. */
static long extend(long ci)
{
	unsigned long svcul;
	svcul = (unsigned int)ci;
	svcul = svcul >> 31 & 1 ? svcul - ((unsigned long)1 << 32) : svcul;
	return svcul;
}

int main(void)
{
	unsigned long svcul;
	unsigned long t;
	long r;
	r = 0;

	/* the sub-steps, for a local at x29-32 */
	svcul = (unsigned int)(long)-32;
	if(svcul != 4294967264UL) r = r + 1;

	t = svcul >> 31 & 1;
	if(t != 1) r = r + 2;

	t = (unsigned long)1 << 32;
	if(t != 4294967296UL) r = r + 4;

	svcul = svcul >> 31 & 1 ? svcul - ((unsigned long)1 << 32) : svcul;
	if(svcul != (unsigned long)(long)-32) r = r + 8;

	/* -svcul is the byte count back off the frame pointer, and the range
	 * test below is what chooses the immediate encoding at :572 */
	t = -svcul;
	if(t != 32) r = r + 16;
	if(!(-svcul < 4096)) r = r + 32;

	/* the whole idiom, over the offsets tcc actually produces */
	if(extend(-8) != -8) r = r + 64;
	if(extend(-4096) != -4096) r = r + 128;
	if(extend(-65536) != -65536) r = r + 256;
	if(extend(0) != 0) r = r + 512;
	if(extend(16) != 16) r = r + 1024;

	return r;
}
