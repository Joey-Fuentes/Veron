/* tal_free_impl's list walk, shape for shape -- the site that found case 55.
 *
 * The walk itself (`al = *(pal = &al->next)`, an assignment inside a
 * dereference) is correct and stays here as a control: it was the first
 * suspect and it was innocent, which is worth a case rather than a memory. */
struct TA {
	unsigned char *p;
	unsigned char *bufend;
	struct TA *next;
	unsigned nb_allocs;
	unsigned size;
	union { unsigned char buffer[1]; long _aligner_; };
};
struct TA a1;
struct TA a2;
int main(void)
{
	struct TA *al;
	struct TA **pal;
	struct TA **top;
	struct TA *hold;
	unsigned char *q;

	a1.bufend = a1.buffer;
	a2.bufend = &a2.buffer[0];
	a1.next = &a2;
	a2.next = 0;
	a1.nb_allocs = 1;
	a2.nb_allocs = 2;
	hold = &a1;
	pal = &hold;
	top = pal;
	q = a2.buffer;

	al = *pal;
	while((unsigned char *)q < al->buffer || (unsigned char *)q > al->bufend)
		al = *(pal = &al->next);

	if(al != &a2) return 1;
	if(pal != &a1.next) return 2;
	if(0 == --al->nb_allocs) return 3;
	if(a2.nb_allocs != 1) return 4;
	if(a1.nb_allocs != 1) return 5;
	if(top != &hold) return 6;
	return 0;
}
