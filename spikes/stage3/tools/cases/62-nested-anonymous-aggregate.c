/* BITMASK. A member of an anonymous struct nested in an anonymous union.
 *
 * THIS IS THE P151 FAULT IN THIRTY LINES. For five rounds it was recorded as
 * "next() returns and its caller in tccgen faults". It was a member offset.
 *
 * `members` is the SIBLING chain, so the flattening loop for an anonymous
 * aggregate visited one level. A nested anonymous struct sits on that chain as
 * a single entry with its own members on a separate list, and those never got
 * the enclosing offset -- so the inner struct's first member resolved to
 * OFFSET 0 and aliased the outer struct's first member.
 *
 * tcc's Sym has this exact shape, and sym_push2 does
 *
 *     s->v = v;  s->type.t = t;  s->c = c;
 *
 * with c == 0 for a field. The third store wiped the token the first had just
 * written, so EVERY symbol tcc created came back with v == 0, and check_fields
 * indexed table_ident[0 - TOK_IDENT] -- index -256 -- and dereferenced NULL.
 *
 * Probe 1 is the aliasing itself. Probe 32 is the other half of the rule: a
 * direct member of the anonymous UNION was always correct, which is why one
 * level of flattening looked like it worked. */
struct Sym {
	int v;
	int r;
	union {
		struct {
			int c;
			int scope;
		};
		int jnext;
	};
	int tail;
};
struct Sym g;
int main(void)
{
	long r;
	struct Sym* s;
	r = 0;
	s = &g;

	s->v = 333;
	s->c = 0;
	if(s->v != 333) r = r + 1;

	s->c = 7;
	if(s->c != 7) r = r + 2;
	if(s->v != 333) r = r + 4;

	s->scope = 9;
	if(s->scope != 9) r = r + 8;
	if(s->c != 7) r = r + 16;

	s->jnext = 5;
	if(s->c != 5) r = r + 32;

	return r;
}
