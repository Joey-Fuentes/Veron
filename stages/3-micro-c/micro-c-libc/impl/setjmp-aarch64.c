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
 * and everything else lives on the x18 stack. Saving those four is sufficient
 * for code THIS COMPILER generates.
 *
 * IT IS NO LONGER ALL OF IT, AND THE OLD NOTE HERE PREDICTED THIS EXACTLY:
 * "Linking this against code from any other compiler would be wrong, and that
 * is worth stating plainly rather than discovering later." Later arrived with
 * tcc's -run. The program tcc compiles into memory is TCC-generated, so it
 * follows AAPCS64 and freely uses x19-x28, the frame pointer and the real sp.
 * When it calls exit, tccrun.c's rt_exit longjmps back to a setjmp made in
 * micro-c-compiled code -- across the boundary between the two conventions.
 * Restoring four registers left the other twelve holding whatever the JIT'd
 * program had put there, and `-run` printed its output and then segfaulted on
 * the way out:
 *
 *     mc-tcc -run hello.c    ->  "hello from -run", then SIGSEGV
 *
 * So this now saves the full AAPCS64 callee-saved set as well as micro-c's
 * four. That is what tcc's test1, test2 and test3 need, all three being
 * `tcc -run tcc.c ... -run tcctest.c`.
 *
 * d8-d15 ARE NOT SAVED YET. AAPCS64 makes the low half of those callee-saved
 * too, and M1's vocabulary has no d-register load or store at all -- adding
 * them is the same exercise as the twenty-eight integer defines this needed.
 * It is recorded here rather than left to be discovered: a JIT'd program that
 * keeps a double in d8 across the call to exit would still corrupt it.
 *
 * WHY IT IS WRITTEN THIS WAY. M2libc's aarch64 macro vocabulary is much
 * narrower than the instruction set. There is no mov_x0,lr and no br_x0; there
 * IS mov_x16,x0 and br_x16, and mov_x17,x1 and mov_x18,x17. The sequences
 * below are shaped by what exists, not by what would be natural.
 *
 * The jmp_buf layout, sixteen words of the thirty-two jmp_buf reserves:
 *     [0]   x18   micro-c stack pointer at the setjmp call
 *     [1]   x17   micro-c base pointer
 *     [2]   x13   micro-c locals pointer
 *     [3]   lr    where to resume
 *     [4..14] x19-x29, the AAPCS64 callee-saved integer set
 *     [15]  sp    the REAL stack pointer, which tcc-generated code uses
 */

/* Saving lr needs it in a general register, and there is no mov_x0,lr. Pushing
 * it onto the x18 stack and popping it into x0 is the way round that: both
 * str_lr,[x18,-8]! and ldr_x0,[x18],8 exist. */

int setjmp(void* env)
{
	asm("mov_x0,x17"
	    "sub_x0,x0,8"
	    "ldr_x0,[x0]"
	    "mov_x1,x0"

	    "mov_x0,x18"          /* [0]  micro-c stack pointer */
	    "str_x0,[x1]"
	    "mov_x0,x17"          /* [1]  micro-c base pointer  */
	    "str_x0,[x1,8]"
	    "mov_x0,x13"          /* [2]  micro-c locals        */
	    "str_x0,[x1,16]"
	    "str_lr,[x18,-8]!"    /* [3]  return address        */
	    "ldr_x0,[x18],8"
	    "str_x0,[x1,24]"

	    "str_x19,[x1,32]"     /* [4..14] AAPCS64 callee-saved */
	    "str_x20,[x1,40]"
	    "str_x21,[x1,48]"
	    "str_x22,[x1,56]"
	    "str_x23,[x1,64]"
	    "str_x24,[x1,72]"
	    "str_x25,[x1,80]"
	    "str_x26,[x1,88]"
	    "str_x27,[x1,96]"
	    "str_x28,[x1,104]"
	    "str_x29,[x1,112]"

	    "mov_x0,sp"           /* [15] the REAL stack pointer */
	    "str_x0,[x1,120]"

	    "mov_x0,0");
}

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

	    /* THE AAPCS64 SET FIRST, while x14 still points at the buffer and
	     * before x17 and x18 are disturbed. These registers belong to the
	     * tcc-generated code that called us; restoring them is the whole
	     * point of the wider buffer. */
	    "ldr_x19,[x14,32]"
	    "ldr_x20,[x14,40]"
	    "ldr_x21,[x14,48]"
	    "ldr_x22,[x14,56]"
	    "ldr_x23,[x14,64]"
	    "ldr_x24,[x14,72]"
	    "ldr_x25,[x14,80]"
	    "ldr_x26,[x14,88]"
	    "ldr_x27,[x14,96]"
	    "ldr_x28,[x14,104]"
	    "ldr_x29,[x14,112]"

	    /* the real stack pointer, which micro-c never touches but
	     * tcc-generated code does */
	    "ldr_x0,[x14,120]"
	    "mov_sp,x0"

	    /* x18 next, and only through x17: there is no mov_x18,x0. That
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
