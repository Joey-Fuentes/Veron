/* `*f(args)` -- A DEREFERENCE APPLIED TO A CALL'S RESULT.
 *
 * CLOSED by EXPERIMENT-zzzh. This case is expected to PASS.
 *
 * It was previously an expected-fail entry, and the first attempt at it
 * (EXPERIMENT-zzzg) regressed mc-tcc from 12/12 to 0/12 on the end-to-end
 * programs and was withdrawn, so the case stays as the guard on all three
 * shapes rather than being deleted.
 *
 * tcc writes every byte of .eh_frame through exactly this shape:
 *
 *     #define dwarf_data1(s,data) \
 *         (*(uint8_t*)section_ptr_add((s), 1) = (data))     tccdbg.c:550
 *
 * THE THREE FAULTS, all fixed together because the case exercises all three:
 *
 *  1. THE PENDING `*` LANDED ON THE ARGUMENT. primary_expr_variable eats the
 *     stars and parks the count in a global for the postfix walk, then returns
 *     early for a function designator WITHOUT clearing it. The arguments are
 *     parsed after that and each is a full expression reading the same global:
 *
 *         mov_x0,8            # primary expr number
 *         ldrsw_x0,[x0]       # <-- dereferencing the literal 8 as an address
 *         str_x0,[x18,-8]!    # function argument
 *
 *     In a small program that address is unmapped and it segfaults. Inside tcc
 *     it is usually mapped, so the write silently lands on the wrong memory --
 *     which is how an allocator node's `next` came to be overwritten, cutting
 *     62 nodes off the list and surfacing much later as
 *     "realloc: pointer was never returned by malloc".
 *
 *  2. THE RETURN TYPE DID NOT REACH current_target, so the dereference used
 *     the wrong WIDTH -- `unsigned char* give(int)` dereferenced gave a
 *     four-byte signed load. THIS CASE ALREADY CAUGHT IT because buf[9] is set
 *     to 66 before buf[8] is read; a case that left the following bytes zero
 *     would have certified a broken compiler, and a throwaway probe written
 *     during the fix did exactly that. Keep the non-zero neighbour.
 *
 *  3. `*f(x) = v` LOADED THROUGH THE RETURNED POINTER. For a variable the
 *     register holds the variable's ADDRESS and one load is right; for a call
 *     result it already holds the pointer, so the load is one step too far.
 *
 * WHAT THIS CASE DOES NOT MEASURE. Closing all three did NOT close tcc's heap
 * corruption -- see MICRO-C.md. A green case here is a green construct, not a
 * working tcc. */
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
