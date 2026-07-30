/* `&arr[i]->member` -- an arrow after an index still needs the element loaded.
 *
 * THE FAULT THAT BLOCKED STAGE 3. postfix_expr_array blanked the element load
 * in every lvalue context including `&`. That is right for the others: in an
 * lvalue context the ADDRESS of the element is the answer. An arrow is not
 * like the others -- the element is a POINTER, and the thing being addressed
 * is at the other end of it.
 *
 *     ps = &table_ident[v - TOK_IDENT]->sym_identifier;      tccgen.c
 *
 * The member offset was added to the address of the ARRAY SLOT instead of the
 * struct. sym_identifier is at offset 32, entries are 8 bytes, so the write
 * landed exactly four slots along: index 195 clobbered slot 199, index 1086
 * clobbered slot 1090. tcc corrupted its own token table two entries at a
 * time, on every declaration with an asm rename.
 *
 * Probes 1-3 are the shape itself. Probe 4 checks that the NEIGHBOURING slots
 * are untouched, because "+4 slots along" is the specific signature and a fix
 * that merely moved the damage would still pass the first three.
 *
 * The dot form is deliberately here too: `&arr[i].member` must NOT load, since
 * there the element IS the struct. A fix that over-reaches breaks probe 6. */
struct T { long a; long b; long c; long d; long* m; };
struct T t;
struct T* tbl[8];
struct T flat[4];

int main(void)
{
	long** p;
	tbl[2] = &t;
	t.m = &t.a;

	p = &tbl[2]->m;
	if(p != &t.m) return 1;
	if(*p != &t.a) return 2;
	*p = &t.b;
	if(t.m != &t.b) return 3;

	/* the four slots that used to be collateral */
	if(tbl[3] != 0) return 4;
	if(tbl[6] != 0) return 5;

	/* the dot form: the element IS the struct, so no load is correct */
	flat[1].m = &flat[1].c;
	if(&flat[1].m != &(flat[1].m)) return 6;
	if(*(&flat[1].m) != &flat[1].c) return 7;

	/* and an ordinary rvalue read through the same shape */
	if(tbl[2]->m != &t.b) return 8;
	return 0;
}
