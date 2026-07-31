/* A STRING LITERAL INITIALISING A char ARRAY MEMBER, LAID OUT INLINE.
 *
 * This is tcctools.c:60 -- the ONE declaration in tcc's entire front end that
 * micro-c could not parse, and therefore the reason mc-tcc carried a 175-line
 * hand-written driver instead of tcc.c:
 *
 *     static const ArHdr arhdr_init = {
 *         "/               ",      char ar_name[16]
 *         "0           ",          char ar_date[12]
 *         ...
 *         ARFMAG                   char ar_fmag[2]  -- "`\n", NO room for NUL
 *     };
 *
 * The bytes belong at the member's own offset: the struct is memcpy'd into an
 * archive header and written to a file, so the layout must be exact. micro-c's
 * other string path emits a POINTER to storage elsewhere, which a member
 * cannot be.
 *
 * ar_fmag is the case that decides the rule. Two bytes from a two-character
 * string, which C allows precisely because the terminator is dropped when it
 * does not fit -- so the emitter must write exactly member->size bytes and
 * never append a NUL by assumption. And ARFMAG is a backtick and a NEWLINE:
 * three characters of source, two bytes of data, so escapes are decoded here
 * or an archive header gets a backslash and an 'n' in it. */
struct ArHdr {
	char ar_name[16];
	char ar_date[12];
	char ar_fmag[2];
};

/* exactly filled, short (padded), and exactly filled with an escape */
static struct ArHdr h = { "/               ", "0", "`\n" };

struct Mixed { char tag[4]; int n; char end[3]; };
static struct Mixed m = { "ab", 42, "xyz" };

int main(void)
{
	int r;
	r = 0;

	/* a string exactly as long as its member: every byte, no terminator */
	if(h.ar_name[0] != '/') r = r + 1;
	if(h.ar_name[1] != ' ') r = r + 2;
	if(h.ar_name[15] != ' ') r = r + 4;

	/* a SHORT string pads the rest of the member with zeroes */
	if(h.ar_date[0] != '0') r = r + 8;
	if(h.ar_date[1] != 0) r = r + 16;
	if(h.ar_date[11] != 0) r = r + 32;

	/* escape decoded, and NO terminator where there is no room */
	if(h.ar_fmag[0] != '`') r = r + 64;
	if(h.ar_fmag[1] != 10) r = r + 128;

	/* the member AFTER a string member is still at its own offset --
	 * an emitter that wrote the wrong number of bytes would shift it */
	if(m.tag[0] != 'a') r = r + 256;
	if(m.tag[1] != 'b') r = r + 512;
	if(m.tag[2] != 0) r = r + 1024;
	if(m.n != 42) r = r + 2048;
	if(m.end[0] != 'x') r = r + 4096;
	if(m.end[2] != 'z') r = r + 8192;

	return r;
}
