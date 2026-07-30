/* `p -= n` must scale by the ELEMENT size, through a typedef too.
 *
 * multiply_by_object_size took object_size as a parameter, TESTED it, and then
 * emitted current_target->type->size -- a different number, because the caller
 * reassigns current_target via promote_type in between. The caller even says
 * so: "We need this before it's changed by the following expression". The
 * hazard was seen, the value was captured to dodge it, and the capture was
 * then ignored.
 *
 * For `struct X *p` the promoted type still happened to give the struct's
 * size, so probe 1 passed and the bug hid. For a pointer to a TYPEDEF'd struct
 * it gives 8 -- the pointer's own width -- and the pointer moves by two WORDS
 * instead of two elements. That is why both spellings are here.
 *
 * tcc's value stack is exactly this shape:
 *
 *     ST_DATA SValue *vtop;     arm64_gen_opil:  vtop -= 2; ... ++vtop;
 *
 * so the pop after a binary operator moved one entry instead of two and tcc
 * reported "internal compiler error: vstack leak (1)" for
 *
 *     int m(void){ int a; int b; return a+b; }
 *
 * while `a+1` and `1+2` escaped, because they constant-fold and never reach
 * the two-operand path. */
struct Raw { long a; long b; long c; };
typedef struct Tdef { long a; long b; long c; } Tdef;
struct Raw rawv[8];
Tdef tdv[8];
struct Raw* rp;
Tdef* tp;
int main(void)
{
	rp = &rawv[4];
	rp -= 2;
	if (rp != &rawv[2]) return 1;

	tp = &tdv[4];
	tp -= 2;
	if (tp != &tdv[2]) return 2;

	tp = &tdv[4];
	tp = tp - 2;
	if (tp != &tdv[2]) return 3;

	tp = &tdv[2];
	tp += 3;
	if (tp != &tdv[5]) return 4;
	return 0;
}
