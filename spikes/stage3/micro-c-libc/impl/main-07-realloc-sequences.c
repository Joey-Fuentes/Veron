/* WHICH realloc SEQUENCE BREAKS?
 *
 * main-06-realloc.c proves malloc -> realloc in isolation, and it PASSES. So
 * the failure tcc hits -- "realloc: pointer was never returned by malloc" --
 * needs something main-06 does not do. M2libc keeps two lists and moves nodes
 * between them, so the suspects are all about reuse:
 *
 *   free() puts a node on _free_list; malloc() may hand that block back via
 *   _malloc_find_free, which moves the node to _allocated_list. realloc then
 *   walks _allocated_list looking for i->block == ptr.
 *
 * Each step exits with its own number, so the exit code names the sequence.
 * 42 means every one of them survived.
 */
void* malloc(unsigned long n);
void* realloc(void* p, unsigned long n);
void free(void* p);
int write(int fd, char* buf, int count);
static void mark(char* s) { write(2, s, 3); }

static void die(int n)
{
	if(1 == n) { asm("mov_x0,1" "mov_x8,93" "svc_0"); }
	if(2 == n) { asm("mov_x0,2" "mov_x8,93" "svc_0"); }
	if(3 == n) { asm("mov_x0,3" "mov_x8,93" "svc_0"); }
	if(4 == n) { asm("mov_x0,4" "mov_x8,93" "svc_0"); }
	if(5 == n) { asm("mov_x0,5" "mov_x8,93" "svc_0"); }
	if(6 == n) { asm("mov_x0,6" "mov_x8,93" "svc_0"); }
	if(7 == n) { asm("mov_x0,7" "mov_x8,93" "svc_0"); }
}

int main(int argc, char** argv)
{
	char* a;
	char* b;
	char* c;
	int i;

	/* 1. a block that came back from the FREE LIST, then grown.
	 *    _malloc_find_free moved the node between lists first. */
	mark("S1\n");
	a = malloc(64);
	if(0 == a) die(1);
	free(a);
	a = malloc(64);              /* very likely the same node, reused */
	if(0 == a) die(1);
	a = realloc(a, 4096);
	if(0 == a) die(1);

	/* 2. realloc CHAINED -- the result of a realloc reallocated again.
	 *    tcc grows a section repeatedly; this is its normal shape. */
	mark("S2\n");
	b = malloc(32);
	if(0 == b) die(2);
	b = realloc(b, 512);
	if(0 == b) die(2);
	b = realloc(b, 8192);
	if(0 == b) die(2);
	b = realloc(b, 65536);
	if(0 == b) die(2);

	/* 3. realloc with another live block freed in between */
	mark("S3\n");
	a = malloc(128);
	b = malloc(128);
	if(0 == a) die(3);
	if(0 == b) die(3);
	free(a);
	b = realloc(b, 4096);
	if(0 == b) die(3);

	/* 4. SHRINK. size < old size takes the same lookup path. */
	mark("S4\n");
	c = malloc(4096);
	if(0 == c) die(4);
	c = realloc(c, 64);
	if(0 == c) die(4);

	/* 5. CHURN, then grow the block allocated FIRST -- it is deepest in
	 *    _allocated_list, so this is the walk at its longest. */
	mark("S5\n");
	a = malloc(96);
	if(0 == a) die(5);
	i = 0;
	while(i < 64)
	{
		b = malloc(96);
		if(0 == b) die(5);
		if(0 == (i % 3)) free(b);
		i = i + 1;
	}
	a = realloc(a, 8192);
	if(0 == a) die(5);

	/* 6. many reallocs of the same pointer, interleaved with mallocs --
	 *    the shape cstr_cat and section_realloc produce together */
	mark("S6\n");
	c = malloc(16);
	if(0 == c) die(6);
	i = 0;
	while(i < 24)
	{
		c = realloc(c, 32 + (i * 512));
		if(0 == c) die(6);
		b = malloc(48);
		if(0 == b) die(6);
		i = i + 1;
	}

	/* 7. contents survive a grow after all that */
	mark("S7\n");
	a = malloc(32);
	if(0 == a) die(7);
	i = 0;
	while(i < 32) { a[i] = i + 1; i = i + 1; }
	a = realloc(a, 16384);
	if(0 == a) die(7);
	i = 0;
	while(i < 32)
	{
		if(a[i] != i + 1) die(7);
		i = i + 1;
	}

	mark("OK\n");
	asm("mov_x0,42" "mov_x8,93" "svc_0");
	return 0;
}
