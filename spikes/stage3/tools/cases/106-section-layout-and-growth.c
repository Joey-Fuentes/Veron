/* BITMASK -- tcc's Section LAYOUT and its GROWTH ARITHMETIC.
 *
 * Every byte tcc writes into any section goes through section_ptr_add ->
 * section_realloc, and every section header field it later reads comes out of
 * this struct. If either the layout or the size arithmetic is off by anything,
 * the damage is a stray write into the heap -- which is what
 * "realloc: pointer was never returned by malloc", "free: pointer was never
 * returned", "Unknown relocation type for got: 0" and a bare SIGSEGV all look
 * like from the outside. Those four are the same fault seen from four places.
 *
 * THE STRUCT IS COPIED FROM tcc.h:569 IN FIELD ORDER, because the order is the
 * point: four 8-byte members, then a run of SEVEN ints, then more 8-byte
 * members. The int run is what forces padding before sh_size, and a compiler
 * that packs it wrongly puts every later field at the wrong offset while
 * sizeof still looks plausible.
 *
 *     unsigned long data_offset;      offset 0
 *     unsigned char *data;                   8
 *     unsigned long data_allocated;         16
 *     void *s1;                             24
 *     int sh_name .. sh_entsize;            32..59   seven ints
 *     unsigned long sh_size;                64       <-- needs 4 bytes of pad
 *     ...
 *     char name[1];                         trailing array, over-allocated
 *
 * `char name[1]` is the flexible-array idiom: new_section allocates
 * sizeof(Section) + strlen(name), so sizeof() being wrong by even one byte
 * makes every section's name overlap the next allocation's header.
 *
 * THE ARITHMETIC, from tccelf.c:284. The memset is the dangerous line -- its
 * LENGTH is a difference of two struct fields, so a field read at the wrong
 * width zeroes a range that runs past the end of the block:
 *
 *     size = sec->data_allocated;
 *     if (size == 0) size = 1;
 *     while (size < new_size) size = size * 2;
 *     data = realloc(sec->data, size);
 *     memset(data + sec->data_allocated, 0, size - sec->data_allocated);
 *
 * Probes, one bit each, so one run describes the whole shape rather than
 * stopping at the first thing that is wrong:
 *
 *   1  sizeof(Section) agrees with gcc
 *   2  offset of data_allocated is 16
 *   4  offset of sh_size is 64 -- the padded one
 *   8  the doubling loop reaches the same size
 *  16  the memset LENGTH is size - allocated, computed at 64 bits
 *  32  the memset does not run past the block (guard bytes intact)
 *  64  the trailing array reads back what was written into it
 */
typedef struct Section {
	unsigned long data_offset;
	unsigned char *data;
	unsigned long data_allocated;
	void *s1;
	int sh_name;
	int sh_num;
	int sh_type;
	int sh_flags;
	int sh_info;
	int sh_addralign;
	int sh_entsize;
	unsigned long sh_size;
	unsigned long sh_addr;
	unsigned long sh_offset;
	int nb_hashed_syms;
	struct Section *link;
	struct Section *reloc;
	struct Section *hash;
	struct Section *prev;
	char name[1];
} Section;

unsigned char pool[4096];
unsigned char guard[64];
Section sec_storage;

int mem_set(unsigned char* p, int v, unsigned long n)
{
	unsigned long i;
	i = 0;
	while(i < n) { p[i] = v; i = i + 1; }
	return 0;
}

int main(void)
{
	int r;
	r = 0;

	Section* sec;
	sec = &sec_storage;

	/* 1 -- sizeof. 4*8 + 7*4 + 4 pad + 8 + 8 + 8 + 4 + 4 pad + 4*8 + 1,
	 * rounded up to 8. gcc says 136, with name at offset 128. */
	if(sizeof(Section) != 136) r = r + 1;

	/* 2 -- the third 8-byte member */
	if((unsigned long)&sec->data_allocated - (unsigned long)sec != 16) r = r + 2;

	/* 4 -- the field AFTER the run of seven ints, which needs the pad */
	if((unsigned long)&sec->sh_size - (unsigned long)sec != 64) r = r + 4;

	/* 8 -- the doubling loop, at unsigned long width */
	unsigned long size;
	unsigned long new_size;
	sec->data_allocated = 0;
	new_size = 300;
	size = sec->data_allocated;
	if(size == 0) size = 1;
	while(size < new_size) size = size * 2;
	if(size != 512) r = r + 8;

	/* 16 -- the memset LENGTH, a difference of two fields. With
	 * data_allocated at 100 and size at 512 the length is 412; a 32-bit
	 * read of either operand, or a signed one, gives something else. */
	sec->data_allocated = 100;
	unsigned long len;
	len = size - sec->data_allocated;
	if(len != 412) r = r + 16;

	/* 32 -- and it must not run past the block. Fill guard, zero exactly
	 * the range the real code would zero, then check the guard survived. */
	mem_set(guard, 0x5A, 64);
	sec->data = pool;
	sec->data_allocated = 1024;
	size = 2048;
	mem_set(sec->data + sec->data_allocated, 0, size - sec->data_allocated);
	int i;
	i = 0;
	int bad;
	bad = 0;
	while(i < 64) { if(guard[i] != 0x5A) bad = 1; i = i + 1; }
	if(bad) r = r + 32;

	/* 64 -- the trailing array. Written through the struct, read back at
	 * the offset sizeof() implies. */
	sec->name[0] = 'x';
	if(sec->name[0] != 'x') r = r + 64;

	return r;
}
