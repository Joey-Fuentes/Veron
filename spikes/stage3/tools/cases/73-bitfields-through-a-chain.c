/* AARCH64 ONLY
 * a bitfield WRITE emits aarch64 mnemonics literally, so amd64 cannot assemble it
 *
 * Bitfields reached through a pointer chain, the way gen_function reaches them:
 *
 *     if (sym->type.ref->f.func_ctor)                   tccgen.c:8524
 *         add_array(tcc_state, ".init_array", sym->c);
 *
 * THE CLEAR MASK WAS ZERO. Writing a bitfield read-modify-writes its storage
 * unit, and the mask of bits to KEEP was computed as
 *
 *     (~(bf_mask << bf_off)) & ((1 << unit_bits) - 1)
 *
 * with unit_bits 64 -- because micro-c makes `int` and `unsigned` eight bytes,
 * so the unit is eight bytes for essentially every bitfield there is. A shift
 * count is taken modulo the register width, so `1 << 64` is 1, `(1 << 64) - 1`
 * is 0, and the emission became
 *
 *     mov_x0,0        # bitfield: clear mask
 *     and_x0,x1,x0    # the whole unit, gone
 *
 * Writing ONE field wiped every other field sharing the unit. It fired always,
 * not in a corner. tcc keeps its function attributes exactly so --
 * func_call:3, func_type:2, func_noreturn:1, func_ctor:1, func_dtor:1 -- so
 * setting the calling convention cleared func_ctor, and gen_function then
 * branched on whatever survived.
 *
 * Probe 1 is the first field in the unit and probes 2-7 the rest: a fix that
 * merely got the first one right would still fail them. The amd64 column
 * cannot run any of it, which is why the clear-mask bug survived every round
 * of a two-column suite.
 */
struct FuncAttr {
	unsigned
	func_call   : 3,
	func_type   : 2,
	func_noreturn : 1,
	func_ctor   : 1,
	func_dtor   : 1,
	func_args   : 8,
	func_alwinl : 1,
	xxxx        : 15;
};

struct CT { int t; struct Sym* ref; };
struct Sym { int v; struct CT type; struct FuncAttr f; };

struct Sym a;
struct Sym b;

int main(void)
{
	struct Sym* s;

	b.f.func_call = 5;
	b.f.func_type = 2;
	b.f.func_noreturn = 1;
	b.f.func_ctor = 1;
	b.f.func_dtor = 0;
	b.f.func_args = 200;
	b.f.func_alwinl = 1;

	a.type.ref = &b;
	s = &a;

	if (s->type.ref->f.func_call != 5) return 1;
	if (s->type.ref->f.func_type != 2) return 2;
	if (s->type.ref->f.func_noreturn != 1) return 3;
	if (s->type.ref->f.func_ctor != 1) return 4;
	if (s->type.ref->f.func_dtor != 0) return 5;
	if (s->type.ref->f.func_args != 200) return 6;
	if (s->type.ref->f.func_alwinl != 1) return 7;

	/* and the FUNC_ELLIPSIS test gen_function does two lines earlier */
	if ((s->type.ref->f.func_type == 2) != 1) return 8;
	return 0;
}
