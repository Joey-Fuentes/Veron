/* KNOWN GAP. A prefix ++/-- on a member of a LOCAL STRUCT, reached by `.`.
 *
 * Found while writing case 55 and deliberately NOT fixed with it. Case 55 is
 * the ARROW form -- `--p->n` added the member offset to the address of the
 * pointer variable instead of to its value. This is the DOT form, it is a
 * different site with a different cause, and the file this sits beside counts
 * nine bugs of the shape "one rule, several implementations, and the copies
 * disagree". Fixing them in one change would have produced one measurement
 * where two are owed.
 *
 * The first attempt at a joint fix -- suppressing the dot site's final load
 * under the same flag -- did NOT close this, which is the evidence that it is
 * a separate cause rather than the same one in another function.
 *
 * `--g.n` on a GLOBAL struct is probed alongside, because the local/global
 * split is exactly where four earlier bugs in this compiler lived. */
struct S { struct S *next; unsigned n; };
struct S g;
int main(void)
{
	struct S local;
	long r;
	r = 0;

	local.n = 5;   --local.n;   if(local.n != 4) r = r + 1;
	g.n = 5;       --g.n;       if(g.n != 4) r = r + 2;

	return r;
}
