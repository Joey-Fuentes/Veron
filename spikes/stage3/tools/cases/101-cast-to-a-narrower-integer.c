/* A cast to an integer narrower than a register DISCARDS THE HIGH BITS.
 *
 * WIDE CONSTANTS -- 4294967264 and 65504 do not fit an immediate field, so
 * this case is expected to move across EXPERIMENT-zzb. See imm-identity.sh.
 *
 * micro-c treated a cast as a statement about type alone and emitted nothing.
 * That was correct by accident while `int` was eight bytes -- every integer
 * cast was register-width to register-width. EXPERIMENT-zzw ended the
 * accident and EXPERIMENT-zzzc emits the truncation.
 *
 * Each width and each signedness separately, because the six emitted
 * instructions are six different macros and a wrong one is silent. */
int main(void)
{
	long v;
	unsigned long u;
	long s;
	long r;
	r = 0;

	v = -32;

	/* unsigned narrowing: the high bits go, nothing is extended back */
	u = (unsigned int)v;
	if(u != 4294967264UL) r = r + 1;
	u = (unsigned short)v;
	if(u != 65504UL) r = r + 2;
	u = (unsigned char)v;
	if(u != 224UL) r = r + 4;

	/* signed narrowing: the high bits go and the sign comes back */
	s = (int)v;
	if(s != -32) r = r + 8;
	s = (short)v;
	if(s != -32) r = r + 16;
	/* `signed char`, NOT `char`. Plain char's signedness is
	 * implementation-defined and the two targets disagree: it is SIGNED on
	 * x86-64 and UNSIGNED on aarch64, so `(char)-32` is -32 on one and 224
	 * on the other. Written as plain `char` this case encoded the
	 * DEVELOPMENT MACHINE's answer, passed against an x86-64 gcc, and made
	 * gcc itself return 32 on a native aarch64 runner -- reported as
	 * "CASE IS BROKEN: gcc build returns 32", which is difftest correctly
	 * refusing to measure anything against a reference that disagrees with
	 * itself across targets.
	 *
	 * It was invisible locally because difftest-qemu.sh builds the REFERENCE
	 * with the host's x86-64 gcc and runs only the SUBJECT under the
	 * emulator. Only a natively-aarch64 gcc sees it. The narrowing being
	 * tested here is about WIDTH, so pinning the signedness loses nothing --
	 * `(unsigned char)` above already covers the other half. */
	s = (signed char)v;
	if(s != -32) r = r + 32;

	/* a value that does NOT fit re-reads as the truncated pattern */
	v = 300;
	s = (char)v;
	if(s != 44) r = r + 64;
	u = (unsigned char)v;
	if(u != 44UL) r = r + 128;

	/* a positive value inside the range is untouched */
	v = 7;
	if((int)v != 7) r = r + 256;
	if((unsigned int)v != 7UL) r = r + 512;

	/* A POINTER IS NOT NARROWED. If the size test alone decided this, a
	 * cast to a pointer type would be safe only because pointers happen to
	 * be register-width -- so check it, rather than assume it stays true. */
	char buf[8];
	char* p;
	p = (char*)buf;
	if(p != buf) r = r + 1024;

	return r;
}
