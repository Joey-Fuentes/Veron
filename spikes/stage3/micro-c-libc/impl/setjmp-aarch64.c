/* micro-c: setjmp and longjmp for aarch64.
 *
 * tcc wraps every compilation in one:
 *
 *     if (setjmp(s1->error_jmp_buf) == 0) { ... compile ... }
 *
 * and tcc_error longjmps out of it. Without a working pair, a compile that
 * hits any error walks off the end of the world, and even a SUCCESSFUL
 * compile returns through the setjmp path.
 *
 * WHY THIS IS NOT A GENERAL setjmp. A portable aarch64 setjmp saves x19-x28,
 * the frame pointer, the link register and sp, because the ABI says those are
 * callee-saved. micro-c uses NONE of x19-x28 -- its convention is
 *
 *     x13  locals pointer
 *     x17  base pointer
 *     x18  stack pointer
 *     lr   return address
 *
 * and everything else lives on the x18 stack. So saving those four is
 * sufficient FOR CODE THIS COMPILER GENERATES, which is all of it here.
 *
 * Linking this against code from any other compiler would be wrong, and that
 * is worth stating plainly rather than discovering later.
 *
 * WHY IT IS WRITTEN THIS WAY. M2libc's aarch64 macro vocabulary is much
 * narrower than the instruction set. There is no mov_x0,lr and no br_x0; there
 * IS mov_x16,x0 and br_x16, and mov_x17,x1 and mov_x18,x17. The sequences
 * below are shaped by what exists, not by what would be natural.
 *
 * The jmp_buf layout, four words:
 *     [0]  x18   stack pointer at the setjmp call
 *     [1]  x17   base pointer
 *     [2]  x13   locals pointer
 *     [3]  lr    where to resume
 */

/* Saving lr needs it in a general register, and there is no mov_x0,lr. Pushing
 * it onto the x18 stack and popping it into x0 is the way round that: both
 * str_lr,[x18,-8]! and ldr_x0,[x18],8 exist. */

int setjmp(void* env)
{
	asm("mov_x0,x17"          /* base pointer */
	    "sub_x0,x0,8"
	    "ldr_x0,[x0]"         /* x0 = env */
	    "mov_x1,x0"           /* x1 = env, the store base */

	    "mov_x0,x18"          /* [0] = stack pointer */
	    "str_x0,[x1]"

	    "mov_x0,x17"          /* [1] = base pointer */
	    "str_x0,[x1,8]"

	    "mov_x0,x13"          /* [2] = locals pointer */
	    "str_x0,[x1,16]"

	    "str_lr,[x18,-8]!"    /* [3] = return address, via the stack because */
	    "ldr_x0,[x18],8"      /*       there is no mov_x0,lr */
	    "str_x0,[x1,24]"

	    "mov_x0,0");          /* setjmp returns 0 when called directly */
}

/* longjmp does not return. It restores the four registers and branches to the
 * saved return address, which lands exactly where setjmp's own return would
 * have -- so the caller's epilogue runs normally from there.
 *
 * ORDER MATTERS. x18 has to be restored through x17 (mov_x17,x1 then
 * mov_x18,x17 -- there is no mov_x18,x0), so x17 is clobbered on the way and
 * must be restored AFTER x18, not before. */

void longjmp(void* env, int val)
{
	/* BOTH ARGUMENTS ARE READ FIRST. They live at x17-8 and x17-16, and x17
	 * is about to be overwritten with the value setjmp saved -- after which
	 * this function's own arguments are unreachable. */
	asm("mov_x0,x17"
	    "sub_x0,x0,8"
	    "ldr_x0,[x0]"
	    "mov_x14,x0"          /* x14 = env */

	    "mov_x0,x17"
	    "sub_x0,x0,16"
	    "ldr_x0,[x0]"
	    "mov_x15,x0"          /* x15 = val */

	    /* x18 first, and only through x17: there is no mov_x18,x0. That
	     * clobbers x17, which is why x17 is restored after it and not
	     * before. */
	    "mov_x0,x14"
	    "ldr_x1,[x0]"
	    "mov_x17,x1"
	    "mov_x18,x17"

	    "mov_x0,x14"
	    "ldr_x0,[x0,8]"
	    "mov_x1,x0"
	    "mov_x17,x1"          /* base pointer */

	    "mov_x0,x14"
	    "ldr_x0,[x0,16]"
	    "mov_x13,x0"          /* locals pointer */

	    "mov_x0,x14"
	    "ldr_x0,[x0,24]"
	    "mov_x16,x0"          /* where to resume */

	    "mov_x0,x15"          /* what setjmp appears to return */
	    "br_x16");
}

/* _setjmp and __sigsetjmp are the same thing to tcc, which only ever uses the
 * plain form; these exist because the names appear in tcctok.h. */
int _setjmp(void* env) { return setjmp(env); }
