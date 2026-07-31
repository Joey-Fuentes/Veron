/* KNOWN GAP -- `*f(args)`, A DEREFERENCE APPLIED TO A CALL'S RESULT.
 *
 * Expected to fail, and it does. One of three faults in this shape is fixed;
 * the case stays red until all three are, and difftest reports loudly if it
 * ever goes green.
 *
 * tcc writes every byte of .eh_frame through exactly this shape:
 *
 *     #define dwarf_data1(s,data) \
 *         (*(uint8_t*)section_ptr_add((s), 1) = (data))     tccdbg.c:550
 *
 * The half that IS fixed: a pending `*` used to leak into the ARGUMENT list.
 * primary_expr_variable eats the stars and parks the count in a global for the
 * postfix walk to apply, but the arguments are parsed in between and each is a
 * full expression that reads the same global, so the star landed on an
 * argument:
 *
 *     mov_x0,8            # primary expr number
 *     ldrsw_x0,[x0]       # <-- dereferencing the literal 8 as an address
 *     str_x0,[x18,-8]!    # function argument
 *
 * In a small program that address is unmapped and it segfaults. Inside tcc it
 * is usually mapped, so the access silently succeeds against the wrong memory
 * -- which is how an allocator node's `next` came to be overwritten, cutting
 * 62 nodes off the list and surfacing much later as
 * "realloc: pointer was never returned by malloc".
 *
 * THE TWO THAT REMAIN, both measured:
 *
 *  1. THE RETURN TYPE DOES NOT REACH current_target, so the dereference uses
 *     the wrong WIDTH. `unsigned char* give(int)` dereferenced gives a
 *     four-byte signed load, not one byte. Note that `*give(9)` PASSES while
 *     `*give(8)` fails -- the bytes after buf[9] happen to be zero, so the
 *     wrong-width load returns the right answer. A case built only from the
 *     passing form would certify a broken compiler, which is the third time
 *     this file has recorded that trap.
 *
 *  2. `*f(x) = v` LOADS THROUGH THE RETURNED POINTER and stores through the
 *     loaded value. For a variable the register holds the variable's ADDRESS
 *     and one load is right; for a call result it already holds the pointer,
 *     so the load is one step too far. That asymmetry lives in the lvalue
 *     path MICRO-C.md counts eight implementations of. */
unsigned char buf[64];
int ints[8];

unsigned char* give(int i) { return buf + i; }
unsigned char* give0(void) { return buf + 4; }
int* givei(int i) { return ints + i; }

int main(void)
{
	int r;
	r = 0;

	buf[8] = 65;
	buf[9] = 66;
	buf[4] = 67;
	ints[2] = 4242;

	/* READ through a call result -- with an argument, and without */
	if(*give(8) != 65) r = r + 1;
	if(*give(9) != 66) r = r + 2;
	if(*give0() != 67) r = r + 4;
	if(*givei(2) != 4242) r = r + 8;

	/* the argument must NOT be dereferenced: a literal, an expression, and a
	 * second argument each reached the same global */
	if(*give(4 + 4) != 65) r = r + 16;
	if(*(unsigned char*)give(8) != 65) r = r + 32;

	/* and the plain-pointer form still works */
	unsigned char* p;
	p = give(8);
	if(*p != 65) r = r + 64;

	/* the assignment form -- tcc's dwarf_data1 shape */
	*give(16) = 99;
	if(buf[16] != 99) r = r + 128;

	return r;
}
