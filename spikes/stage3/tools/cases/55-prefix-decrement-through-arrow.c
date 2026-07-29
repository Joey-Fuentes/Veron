/* A PREFIX ++/-- WHOSE TARGET IS REACHED THROUGH `->`. BITMASK.
 *
 * `--p->n` computed `&p + offset` -- the member offset added to the address of
 * the LOCAL VARIABLE p -- and decremented whatever stack slot that landed on.
 * The flag that says "do not load this variable, I want its address" is right
 * when the variable IS the target and wrong the moment a `->` stands between
 * them, because then the address wanted is p's VALUE plus the offset. Ninth
 * instance of the one-rule-several-implementations class: `p->n++` was always
 * right, because a POSTFIX operator sits where a lookahead can see it.
 *
 * WHAT IT COST. tal_free_impl does `--al->nb_allocs` on every token string tcc
 * frees. In that frame the stray decrement landed on the caller's saved locals
 * pointer, so expr_preprocess resumed with its whole frame addressed two bytes
 * low: `tok` came back as TOK_LINEFEED << 16, tcc reported "extra tokens after
 * directive" on the first `#if` of its own predefs, and the token stream was
 * desynchronised from there on.
 *
 * `--s.n` on a LOCAL STRUCT is a DIFFERENT bug, found while writing this case
 * and NOT fixed here -- see case 57. It is a separate site with a separate
 * cause, and rolling it in would have made one measurement out of two. */
struct S { struct S *next; unsigned n; };
struct S g;
struct S h;
int main(void)
{
	struct S *p;
	long r;
	r = 0;
	p = &g;

	g.n = 5;   --p->n;        if(g.n != 4) r = r + 1;
	g.n = 5;   ++p->n;        if(g.n != 6) r = r + 2;
	g.n = 5;   p->n--;        if(g.n != 4) r = r + 4;
	g.n = 5;   p->n++;        if(g.n != 6) r = r + 8;
	g.n = 5;   h.n = --p->n;  if(h.n != 4) r = r + 16;
	g.n = 1;   if(0 != --p->n) r = r + 32;

	return r;
}
