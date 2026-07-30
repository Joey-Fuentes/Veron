/* A string literal has a type, and it is `char*`.
 *
 * primary_expr_string emitted the address and left current_target alone, so a
 * literal inherited whatever type the previous expression happened to leave.
 * Indexing one then used the DEFAULT element size -- eight:
 *
 *     "abc"[1]     mov_x14,8 / mul_x0,x14,x0 / ldr_x0,[x0]
 *     g[1]         add_x0,x1,x0             / ldrsb_x0,[x0]
 *
 * for the same access through a char* variable. The index scaled by eight and
 * eight bytes came back instead of one.
 *
 * tcc walks every path list with
 *
 *     for (p = in; c = *p, c != 0 && c != PATHSEP[0]; ++p)
 *
 * where PATHSEP is ":". PATHSEP[0] read eight bytes of the wrong place, the
 * separator was never matched, and tcc_split_path returned the whole
 * colon-separated list as ONE path:
 *
 *     tried: /usr/lib/aarch64-linux-gnu:/usr/lib:/lib:...:/usr/local/lib/c
 *
 * The crt search escaped it because CRTPREFIX is a single path with no
 * separator; the library search, six paths long, did not.
 *
 * Probe 1 is the literal indexed directly and probe 2 the same thing through a
 * variable -- the pair that made the difference visible. Probes 3 and 4 are
 * the macro spellings, which is how it reaches tcc.
 *
 * NOT PROBED, and left as a known gap: `*SEP` on a literal is rejected outright
 * ("\": is not a defined symbol"). Dereferencing a literal is a separate hole
 * and tcc does not use it. */
#define SEP ":"
char* g = ":";
int main(void)
{
	if ("xyz"[1] != 'y') return 1;
	if (g[0] != ':') return 2;
	if (SEP[0] != ':') return 3;
	char* p = SEP;
	if (p[0] != ':') return 4;
	return 0;
}
