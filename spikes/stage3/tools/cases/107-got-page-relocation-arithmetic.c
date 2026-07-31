/* BITMASK -- THE AArch64 GOT RELOCATION ARITHMETIC, arm64-link.c:299.
 *
 * WIDE CONSTANTS -- 0x1234567890ab does not fit an immediate field, so this
 * case is expected to move across EXPERIMENT-zzb. See imm-identity.sh.
 *
 * This is the expression that decides where every ADRP+LDR pair points, and
 * mc-tcc gets it wrong. Compiling tests2/00_assignment with mc-tcc and linking
 * the SAME object two ways:
 *
 *     mc-tcc -c  ->  control links  ->  42 / 64 / 12, 34   correct
 *     mc-tcc -c  ->  mc-tcc links   ->  42 then SIGSEGV
 *
 * so the code generation is right and the LINKER is not. The single code
 * difference is one ADRP+LDR pair, the relocation for `L.2` -- the second
 * string literal:
 *
 *     control  ADRP pageoff 0x20000     LDR #3744  ->  0x420ea0   sane
 *     mc-tcc   ADRP pageoff 0x65028000  LDR #496   ->  0x654281f0 wild
 *
 * Both the page and the low bits are wrong, so `got->sh_addr + got_offset` is
 * itself wrong rather than only the encoding.
 *
 * THE ORIGINAL:
 *
 *     uint64_t off = (((s1->got->sh_addr +
 *         get_sym_attr(s1, sym_index, 0)->got_offset) >> 12) - (addr >> 12));
 *     if ((off + ((uint64_t)1 << 20)) >> 21) error;
 *     write32le(ptr, ((read32le(ptr) & 0x9f00001f) |
 *                     (off & 0x1ffffc) << 3 | (off & 3) << 29));
 *
 * Three things micro-c has had bugs in, in one expression: a CHAINED ARROW
 * through two structs, a MEMBER ACCESS ON A CALL'S RESULT, and 64-bit shift
 * and mask assembly with constants above 2^31.
 *
 * Probes, one bit each, so one run describes the whole shape:
 *
 *   1  s1->got->sh_addr           chained arrow through two structs
 *   2  get_sym_attr(...)->got_offset   member of a call's result
 *   4  the two SUMMED, which is what the relocation actually uses
 *   8  >> 12 on a 64-bit value keeps the high bits
 *  16  the difference of two shifted addresses
 *  32  the range check (off + (1<<20)) >> 21 is 0 for an in-range off
 *  64  the bit assembly reproduces the encoding byte for byte
 */
typedef struct SymAttr {
	int pad_a;
	unsigned long got_offset;
	unsigned long plt_offset;
} SymAttr;

typedef struct Sec {
	unsigned long data_offset;
	unsigned char* data;
	unsigned long sh_addr;
} Sec;

typedef struct State {
	int pad_b;
	Sec* got;
	Sec* plt;
} State;

Sec got_storage;
Sec plt_storage;
State state_storage;
SymAttr attrs[8];

SymAttr* get_sym_attr(State* s, int idx, int alloc)
{
	if(alloc) return &attrs[0];
	return &attrs[idx];
}

int main(void)
{
	int r;
	r = 0;

	State* s1;
	s1 = &state_storage;
	s1->got = &got_storage;
	s1->plt = &plt_storage;

	/* the real numbers from the failing link */
	s1->got->sh_addr = 0x420000;
	attrs[2].got_offset = 0xea0;

	unsigned long addr;
	addr = 0x400358 + 0x34;

	/* 1 -- a chained arrow through two structs */
	if(s1->got->sh_addr != 0x420000) r = r + 1;

	/* 2 -- a member of a call's RESULT */
	if(get_sym_attr(s1, 2, 0)->got_offset != 0xea0) r = r + 2;

	/* 4 -- the two summed, which is the address the GOT entry lives at */
	unsigned long target;
	target = s1->got->sh_addr + get_sym_attr(s1, 2, 0)->got_offset;
	if(target != 0x420ea0) r = r + 4;

	/* 8 -- >> 12 on a 64-bit value. A 32-bit shift would still give the
	 * right answer for these operands, so make the high half matter. */
	unsigned long wide;
	wide = 0x1234567890ab;
	if((wide >> 12) != 0x123456789) r = r + 8;

	/* 16 -- the difference of two shifted addresses, the ADRP page count */
	unsigned long off;
	off = (target >> 12) - (addr >> 12);
	if(off != 0x20) r = r + 16;

	/* 32 -- the range check. For an in-range off this must be 0; a wrong
	 * width here turns every good relocation into a reported failure or,
	 * worse, lets a bad one through. */
	unsigned long chk;
	chk = (off + ((unsigned long)1 << 20)) >> 21;
	if(chk != 0) r = r + 32;

	/* 64 -- the encoding. Base word is the ADRP with its immediate fields
	 * cleared; the result must be the instruction the control emitted. */
	unsigned long base;
	base = 0x90000000;
	unsigned long insn;
	insn = (base & 0x9f00001f) | ((off & 0x1ffffc) << 3) | ((off & 3) << 29);
	if(insn != 0x90000100) r = r + 64;

	return r;
}
