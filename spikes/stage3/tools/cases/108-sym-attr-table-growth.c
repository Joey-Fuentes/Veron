/* BITMASK -- get_sym_attr's TABLE GROWTH, tccelf.c:803.
 *
 * THIS IS WHERE THE LINK GOES WRONG. Compiling tests2/00_assignment with
 * mc-tcc and linking the SAME object two ways gives the same got_sh_addr, the
 * same addr and the same sym_index, and exactly one differing input to the
 * relocation:
 *
 *     sym_index   control     mc-tcc
 *         2       0x18        0x18
 *         3       0x20        0x65007374     <-- ASCII bytes
 *         4       0x28        0x20
 *
 * The sequence should be 0x18, 0x20, 0x28. mc-tcc reads one garbage entry and
 * then the rest shift down by one slot, and the garbage is printable ASCII --
 * so the read is landing in string data past the end of the table rather than
 * in the table.
 *
 * THE ORIGINAL:
 *
 *     if (index >= s1->nb_sym_attrs) {
 *         if (!alloc) return s1->sym_attrs;
 *         n = 1;
 *         while (index >= n) n *= 2;
 *         tab = tcc_realloc(s1->sym_attrs, n * sizeof(*s1->sym_attrs));
 *         s1->sym_attrs = tab;
 *         memset(s1->sym_attrs + s1->nb_sym_attrs, 0,
 *                (n - s1->nb_sym_attrs) * sizeof(*s1->sym_attrs));
 *         s1->nb_sym_attrs = n;
 *     }
 *     return &s1->sym_attrs[index];
 *
 * `struct sym_attr` is FOUR 4-byte fields, so sizeof is 16 and the pointer to
 * it is 8. Every line above depends on telling those two apart:
 *
 *   sizeof(*s1->sym_attrs)   sizeof of a DEREFERENCED MEMBER POINTER. If this
 *                            gives the pointer's width the table is allocated
 *                            at half size and indexing runs off the end.
 *   s1->sym_attrs + nb       pointer arithmetic that must scale by 16
 *   &s1->sym_attrs[index]    address of an indexed struct element
 *
 * A table that is allocated with one stride and indexed with another is
 * self-consistent for the first few entries and reads adjacent heap after
 * that, which is exactly the observed pattern.
 *
 * Probes, one bit each:
 *
 *   1  sizeof(struct sym_attr) is 16
 *   2  sizeof(*p) through a plain pointer is 16, not 8
 *   4  sizeof(*s->tab) through a MEMBER pointer is 16, not 8
 *   8  p + n scales by 16
 *  16  &p[i] strides by 16
 *  32  the memset LENGTH is (n - nb) * 16
 *  64  write entries 0..7 and read them all back through the member pointer
 */
struct sym_attr {
	unsigned got_offset;
	unsigned plt_offset;
	int plt_sym;
	int dyn_index;
};

struct State {
	int nb_sym_attrs;
	struct sym_attr* sym_attrs;
};

struct sym_attr table[16];
struct State state_storage;
unsigned char guard[64];

int main(void)
{
	int r;
	r = 0;

	struct State* s1;
	s1 = &state_storage;
	s1->sym_attrs = table;
	s1->nb_sym_attrs = 0;

	/* 1 -- four 4-byte fields */
	if(sizeof(struct sym_attr) != 16) r = r + 1;

	/* 2 -- sizeof through a plain pointer */
	struct sym_attr* p;
	p = table;
	if(sizeof(*p) != 16) r = r + 2;

	/* 4 -- sizeof through a MEMBER pointer, which is the form tcc uses */
	if(sizeof(*s1->sym_attrs) != 16) r = r + 4;

	/* 8 -- pointer arithmetic scales by the struct, not the pointer */
	unsigned long a;
	unsigned long b;
	a = (unsigned long)(s1->sym_attrs);
	b = (unsigned long)(s1->sym_attrs + 3);
	if(b - a != 48) r = r + 8;

	/* 16 -- indexing strides by the struct */
	unsigned long c;
	c = (unsigned long)(&s1->sym_attrs[3]);
	if(c - a != 48) r = r + 16;

	/* 32 -- the memset length, the expression tcc actually writes */
	int n;
	n = 8;
	s1->nb_sym_attrs = 2;
	unsigned long len;
	len = (n - s1->nb_sym_attrs) * sizeof(*s1->sym_attrs);
	if(len != 96) r = r + 32;

	/* 64 -- the round trip. Fill through the member pointer, read back
	 * through it, and require the values to survive -- a table allocated
	 * with one stride and indexed with another passes the first entries
	 * and fails the later ones. */
	int i;
	i = 0;
	while(i < 8) { s1->sym_attrs[i].got_offset = 0x18 + i * 8; i = i + 1; }
	i = 0;
	int bad;
	bad = 0;
	while(i < 8) {
		if(s1->sym_attrs[i].got_offset != (unsigned)(0x18 + i * 8)) bad = 1;
		i = i + 1;
	}
	if(bad) r = r + 64;

	return r;
}
