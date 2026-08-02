/* `sizeof(*arr)` -- AN ARRAY NAME IS ALREADY ITS ELEMENT TYPE.
 *
 * MEASURED, and only one of the three spellings was wrong:
 *
 *     static char* pa[3];
 *     sizeof(pa)      24        right
 *     sizeof(pa[0])    8        right
 *     sizeof(*pa)      1        WRONG -- should be 8
 *
 * A declaration `T name[N]` records T in the symbol's type and N in
 * array_modifier, so the type is the ELEMENT before any star is applied.
 * Stepping once more gave what the element points AT -- char, for an array of
 * char*.
 *
 * AN ARRAY OF long HID IT FOR AS LONG AS IT EXISTED. `sizeof(*arr)` on
 * `long arr[3]` came out 8 and correct, because long's own ->type is long:
 * the extra step lands back where it started. Only an array whose element is a
 * POINTER shows the fault, and 108-sym-attr-table-growth -- the case written
 * for the sizeof family -- uses a pointer variable rather than an array of
 * them.
 *
 * WHAT IT COST. tcc chooses its library-search format like this:
 *
 *     static const char * const libs[] = { "%s/lib%s.so", "%s/lib%s.a", NULL };
 *     ...
 *     if (s->static_link)
 *         pp += sizeof(libs) / sizeof(*libs) - 2;        libtcc.c:1130
 *
 * 24/1 - 2 is 22, so `pp` landed far past the array and `*pp` was a pointer
 * into unrelated data. Probed from inside mc-tcc, every -l search built a path
 * one character long:
 *
 *     LIB fmt=P path=/usr/lib name=c   ->  [P]
 *
 * so it segfaulted on any link that resolved a library BY NAME. Explicit
 * paths worked, which is why it survived: -nostdlib links pass their objects
 * outright, and only a HOSTED link -- rung 3 of the stage-4 ladder, and the
 * first one that needs `-lc` -- takes that branch. With this fixed, mc-tcc
 * links a hosted static program byte-identical to the gcc-built control's.
 *
 * GREATER THAN ONE, NOT NON-ZERO. array_modifier DEFAULTS to 1 for every
 * symbol, so the first version of the fix tested `!= 0`, fired for plain
 * pointers as well, and made `sizeof(*p)` 8 instead of 16. Case 108 caught it
 * before it left this machine.
 *
 * Probes, one bit each:
 *
 *   1  sizeof of the array, and of an element by subscript -- the controls
 *   2  sizeof(*arr) on an array of POINTERS -- the defect
 *   4  sizeof(*arr) on an array of long -- right by accident, must stay right
 *   8  sizeof(*p) on a plain pointer -- what the first fix broke
 *  16  sizeof(**arr), two stars on an array of pointers
 *  32  libtcc.c:1130 itself, with the pointer it selects
 */

struct A { int a; int b; long c; };

static const char * const libs[] = { "%s/lib%s.so", "%s/lib%s.a", 0 };
static char* pa[3];
static long la[3];
static struct A tab[3];

int main(void)
{
	int r;
	r = 0;

	/* 1 -- the two spellings that were always right */
	if(sizeof(libs) != 24) r = r + 1;
	if(sizeof(libs[0]) != 8) r = r + 1;
	if(sizeof(pa) != 24) r = r + 1;

	/* 2 -- an array of pointers */
	if(sizeof(*pa) != 8) r = r + 2;
	if(sizeof(*libs) != 8) r = r + 2;

	/* 4 -- an array of long: right by accident before, and must stay right */
	if(sizeof(*la) != 8) r = r + 4;
	if(sizeof(*tab) != 16) r = r + 4;

	/* 8 -- a plain pointer, which is NOT an array and must still step */
	struct A* p;
	p = tab;
	if(sizeof(*p) != 16) r = r + 8;
	char** q;
	q = pa;
	if(sizeof(*q) != 8) r = r + 8;

	/* 16 -- two stars: one for the decay, one real */
	if(sizeof(**pa) != 1) r = r + 16;

	/* 32 -- libtcc.c:1130, and the format string it picks */
	const char* const* pp;
	pp = libs;
	pp = pp + (sizeof(libs) / sizeof(*libs) - 2);
	if(pp != libs + 1) r = r + 32;
	if(pp[0][0] != '%') r = r + 32;

	return r;
}
