/* A file-scope ARRAY of structs whose members do not fill the struct.
 *
 * The initialiser emitted the members back to back -- no gaps, no tail padding
 * -- while every accessor strides by sizeof. One struct hides it. An array of
 * them drifts by the padding on every element.
 *
 *     struct TCCOption { const char *name; uint16_t index, flags; };
 *
 *     emitted    &str %0 $1 $0     8 + 2 + 2 = 12 bytes
 *     accessed   stride 16, index at 8, flags at 10
 *
 * tcc's option table is that shape, so a single `-B` flag segfaulted a
 * one-line program: tcc_parse_args read the second entry's `name` four bytes
 * early -- 0x100000000, the tail of entry 0 spliced to the head of entry 1 --
 * and dereferenced it.
 *
 * SEQUENTIAL RETURNS, NOT A BITMASK. This case crashes when it fails, and a
 * bitmask cannot be told from a signal: the first version of it returned 139
 * and difftest correctly refused to interpret that. Small distinct codes say
 * which probe failed AND leave 139 meaning SIGSEGV.
 *
 * Probe 3 is the tail padding and probe 5 is the same thing one element along;
 * probe 9 walks with a pointer the way tcc_parse_args does. */
struct Opt {
	char* name;
	unsigned short index;
	unsigned short flags;
};
struct Opt table[] = {
	{ "h", 1, 0 },
	{ "B", 2, 1 },
	{ 0, 0, 0 },
};
int main(void)
{
	struct Opt* p;
	if(table[0].name == 0) return 1;
	if(table[0].name[0] != 'h') return 2;
	if(table[0].index != 1) return 3;
	if(table[1].name == 0) return 4;
	if(table[1].index != 2) return 5;
	if(table[1].flags != 1) return 6;
	if(table[1].name[0] != 'B') return 7;
	p = table;
	p = p + 1;
	if(p->name == 0) return 8;
	if(p->name[0] != 'B') return 9;
	return 0;
}
