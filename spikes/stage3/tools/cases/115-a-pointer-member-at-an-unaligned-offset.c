/* AN EIGHT-BYTE MEMBER AT AN OFFSET THAT IS NOT A MULTIPLE OF EIGHT.
 *
 * WIDE CONSTANTS -- 0x1122334455667788 does not fit an immediate field, so
 * this case is expected to move across EXPERIMENT-zzb. See imm-identity.sh.
 *
 * THIS CASE EXISTS BECAUSE A PREVIOUS ONE HEDGED. Case 113 checks the CType
 * copy without asserting CType's size, on the grounds that micro-c's layout
 * differs from gcc's by design. That is true and it is also exactly the kind
 * of reasoning that writes a test which cannot fail. So the layout gets its
 * own case, stated rather than assumed.
 *
 * WHAT THE LAYOUT ACTUALLY IS, MEASURED NOT GUESSED. EXPERIMENT-zzw's own
 * preamble records the corpus rows that moved when int became four bytes:
 *
 *     row 121  returns 8,  expected 16
 *     row 122  returns 12, expected 24
 *     row 123  returns 8,  expected 16
 *
 * Row 122 at TWELVE is the whole story: a struct of an int and a pointer is
 * 4 + 8 with no padding, so THE POINTER SITS AT OFFSET 4. gcc puts it at 8.
 * micro-c does not insert alignment padding, and since zzw made int four
 * bytes wide that is now visible in every struct that mixes widths.
 *
 * WHY THAT IS A LIVE aarch64 QUESTION AND NOT A CURIOSITY. The 64-bit load
 * with an unsigned immediate offset SCALES THAT OFFSET BY EIGHT, so it cannot
 * encode 4 at all. The vocabulary shows it: every 8-byte offset the aarch64
 * table defines is a multiple of eight --
 *
 *     ldr_x0,[x0,8]  ldr_x0,[x0,16]  ldr_x0,[x0,24]  ...  ldr_x0,[x0,128]
 *
 * -- and `add_x0,x0,4` is not in the table at any register. So a member at
 * offset 4 cannot be reached the way members at 8, 16 and 24 are. It has to
 * go through a register-computed address (`add_x0,x0,x5` then `ldr_x0,[x0]`),
 * and the load that lands is then an UNALIGNED 8-byte access.
 *
 * That is legal on aarch64 for normal memory -- LDR and STR tolerate it, and
 * only the exclusives and device memory do not -- so this is expected to
 * PASS. It is written down because "expected to pass" was an assumption
 * nobody had tested, on the exact shape that `struct CType { int t; struct
 * Sym *ref; }` has, which is the struct at the centre of the conditional
 * failure case 113 models. If it fails, every mixed-width struct in tcc is
 * suspect and that is a much bigger finding than the conditional.
 *
 * NOT MARKED KNOWN GAP, DELIBERATELY. The unpadded layout is a declared
 * property and is not what this asserts. What it asserts is that the layout
 * micro-c chose WORKS -- and that has to hold no matter which layout it is.
 *
 * Probes, one bit each:
 *
 *   1  a pointer member after one int round-trips        (offset 4)
 *   2  after three ints                                  (offset 12)
 *   4  after five ints                                   (offset 20)
 *   8  the neighbouring ints are not disturbed by the pointer store
 *  16  the same members survive a whole-struct copy
 *  32  the same through a pointer to the struct, which is how tcc reads them
 *  64  an array of them strides by sizeof and each element is independent
 * 128  a long (8 bytes) at the same odd offsets, not just a pointer
 */

struct Sym { int id; };

struct One   { int a; struct Sym* p; };
struct Three { int a; int b; int c; struct Sym* p; };
struct Five  { int a; int b; int c; int d; int e; struct Sym* p; };
struct Long  { int a; long v; };

struct Sym s1;
struct Sym s2;
struct Sym s3;

int main(void)
{
	int r;
	r = 0;

	s1.id = 101;
	s2.id = 202;
	s3.id = 303;

	/* 1 -- offset 4 under micro-c, offset 8 under gcc. Either way it must
	 * store and load the pointer it was given. */
	struct One o;
	o.a = 7;
	o.p = &s1;
	if(o.p != &s1) r = r + 1;
	if(o.p->id != 101) r = r + 1;

	/* 2 -- offset 12 */
	struct Three t;
	t.a = 1; t.b = 2; t.c = 3;
	t.p = &s2;
	if(t.p != &s2) r = r + 2;
	if(t.p->id != 202) r = r + 2;

	/* 4 -- offset 20 */
	struct Five f;
	f.a = 1; f.b = 2; f.c = 3; f.d = 4; f.e = 5;
	f.p = &s3;
	if(f.p != &s3) r = r + 4;
	if(f.p->id != 303) r = r + 4;

	/* 8 -- the store must not spill over its neighbours. An 8-byte write
	 * at offset 4 covers bytes 4..11; if the compiler thought the member
	 * were at 8 it would cover 8..15 and clip whatever follows. */
	if(o.a != 7) r = r + 8;
	if(t.a != 1 || t.b != 2 || t.c != 3) r = r + 8;
	if(f.a != 1 || f.b != 2 || f.c != 3 || f.d != 4 || f.e != 5) r = r + 8;

	/* 16 -- a whole-struct copy carries the odd-offset member. This is
	 * `type = *type2` from combine_types, on a struct with this shape. */
	struct One o2;
	o2.a = 0;
	o2.p = 0;
	o2 = o;
	if(o2.a != 7) r = r + 16;
	if(o2.p != &s1) r = r + 16;

	struct Three t2;
	t2.a = 0; t2.b = 0; t2.c = 0; t2.p = 0;
	t2 = t;
	if(t2.p != &s2) r = r + 16;
	if(t2.c != 3) r = r + 16;

	/* 32 -- through a pointer, which is how tcc reaches every one of
	 * these: `p->type.ref`, `s1->sym_attrs`, `sec->data`. */
	struct One* op;
	op = &o;
	if(op->p != &s1) r = r + 32;
	if(op->a != 7) r = r + 32;
	op->p = &s2;
	if(o.p != &s2) r = r + 32;
	if(o.a != 7) r = r + 32;
	op->p = &s1;

	/* 64 -- an array strides by sizeof and elements do not overlap. If
	 * the stride and the member offset disagree, element 1's pointer
	 * write lands inside element 0. */
	struct One arr[4];
	int i;
	i = 0;
	while(i < 4) { arr[i].a = 10 + i; arr[i].p = &s1; i = i + 1; }
	arr[1].p = &s2;
	arr[2].p = &s3;
	if(arr[0].p != &s1) r = r + 64;
	if(arr[1].p != &s2) r = r + 64;
	if(arr[2].p != &s3) r = r + 64;
	if(arr[3].p != &s1) r = r + 64;
	i = 0;
	while(i < 4) { if(arr[i].a != 10 + i) r = r + 64; i = i + 1; }

	/* 128 -- a plain 8-byte integer at the same odd offset, so a failure
	 * above can be told apart from something specific to pointers */
	struct Long l;
	l.a = 9;
	l.v = 0x1122334455667788L;
	if(l.v != 0x1122334455667788L) r = r + 128;
	if(l.a != 9) r = r + 128;
	struct Long* lp;
	lp = &l;
	if(lp->v != 0x1122334455667788L) r = r + 128;

	return r;
}
