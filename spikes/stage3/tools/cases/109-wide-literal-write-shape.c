/* BITMASK -- tcc's WIDE-LITERAL PATH, tccpp.c:384 and :2222.
 *
 * CLOSED by EXPERIMENT-zzzk. This case is expected to PASS.
 *
 * REDUCED TO ONE LINE. A cast whose operand is PARENTHESISED, dereferenced,
 * as an ASSIGNMENT TARGET:
 *
 *     *(int*)(p + 4) = 7;      SIGSEGV before the fix
 *     *(int*)p       = 7;      always fine
 *
 * The read form `x = *(int*)(p + 4)` was fine too, so it was the store side of
 * the parenthesised-cast path alone -- the tenth place carrying its own copy
 * of "an assignment target must not be loaded".
 *
 * THE READ PROBE DELIBERATELY USES 0x07654321, NOT 0x87654321. The high-bit
 * form is `unsigned int` in C, so comparing it against an `int` triggers the
 * usual arithmetic conversions -- which micro-c folds at 64-bit signed and
 * gets wrong. That is a real divergence and a DIFFERENT one; leaving it here
 * made this case fail for a reason it does not claim to test. Case 110 holds
 * it separately.
 *
 * Every L-prefixed literal segfaults mc-tcc:
 *
 *     L'a'   L'\x1234'   L"abc"      SIGSEGV during -c
 *     'r'    "\141\142"  "\x41"      fine
 *
 * and tcctest.c's string_test() is the first function in tcc's own test file
 * to use one, which is what stops test1/test2/test3 before they start.
 *
 * The write path is cstr_wccat:
 *
 *     size = cstr->size + sizeof(nwchar_t);
 *     if (size > cstr->size_allocated) cstr_realloc(cstr, size);
 *     *(nwchar_t *)(cstr->data + size - sizeof(nwchar_t)) = ch;
 *     cstr->size = size;
 *
 * That last line is a CAST over PARENTHESISED POINTER ARITHMETIC, dereferenced
 * as an ASSIGNMENT TARGET, with a sizeof inside the arithmetic and the base
 * coming from a struct MEMBER. Four rules meeting on one line, each of which
 * this series has had a separate bug in.
 *
 * The read path is tccpp.c:2222, a cast applied to a member and then INDEXED:
 *
 *     c = ((nwchar_t *)tokcstr.data)[i];
 *
 * Probes, one bit each:
 *
 *   1  sizeof(int) inside pointer arithmetic
 *   2  (T*)(p + n) -- a cast over parenthesised arithmetic, READ
 *   4  *(T*)(p + n - sizeof(T)) = v -- the same as an ASSIGNMENT TARGET
 *   8  the base coming from a struct MEMBER rather than a local
 *  16  ((T*)member)[i] -- cast then index, the read path
 *  32  a 4-byte store through the cast does not disturb its neighbours
 *  64  the whole cstr_wccat loop appends four wide chars in order
 */
typedef struct CString {
	int size;
	int size_allocated;
	unsigned char* data;
} CString;

unsigned char buffer[256];
CString cs_storage;

int main(void)
{
	int r;
	r = 0;

	CString* cstr;
	cstr = &cs_storage;
	cstr->data = buffer;
	cstr->size = 0;
	cstr->size_allocated = 256;

	int i;
	i = 0;
	while(i < 256) { buffer[i] = 0xEE; i = i + 1; }

	/* 1 -- sizeof inside the arithmetic */
	if(sizeof(int) != 4) r = r + 1;

	/* 2 -- a cast over parenthesised arithmetic, as a READ */
	unsigned char* p;
	p = buffer;
	buffer[8] = 0x21; buffer[9] = 0x43; buffer[10] = 0x65; buffer[11] = 0x07;
	int got;
	got = *(int*)(p + 8);
	if(got != 0x07654321) r = r + 2;

	/* 4 -- the same shape as an ASSIGNMENT TARGET, which is the line that
	 * actually writes every wide character */
	int size;
	size = 4 + sizeof(int);
	*(int*)(p + size - sizeof(int)) = 0x11223344;
	if(*(int*)(p + 4) != 0x11223344) r = r + 4;

	/* 8 -- with the base coming from a struct MEMBER, as in cstr->data */
	cstr->size = 16;
	size = cstr->size + sizeof(int);
	*(int*)(cstr->data + size - sizeof(int)) = 0x55667788;
	if(*(int*)(buffer + 16) != 0x55667788) r = r + 8;

	/* 16 -- cast then INDEX, through a member: the read path */
	if(((int*)cstr->data)[4] != 0x55667788) r = r + 16;

	/* 32 -- the store must be four bytes wide and no more. The bytes on
	 * either side were filled with 0xEE above. */
	if(buffer[15] != 0xEE) r = r + 32;
	if(buffer[20] != 0xEE) r = r + 32;

	/* 64 -- the loop, as cstr_wccat runs it: append four wide chars and
	 * read them back in order */
	cstr->size = 64;
	int n;
	n = 0;
	while(n < 4) {
		size = cstr->size + sizeof(int);
		*(int*)(cstr->data + size - sizeof(int)) = 0x100 + n;
		cstr->size = size;
		n = n + 1;
	}
	n = 0;
	int bad;
	bad = 0;
	while(n < 4) {
		if(((int*)(buffer + 64))[n] != 0x100 + n) bad = 1;
		n = n + 1;
	}
	if(bad) r = r + 64;

	return r;
}
