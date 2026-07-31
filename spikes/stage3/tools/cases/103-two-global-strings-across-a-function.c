/* TWO GLOBAL STRING INITIALISERS WITH A FUNCTION DECLARATION BETWEEN THEM.
 *
 * micro-c names a global string initialiser's storage
 * `create_unique_id("STR_", "g", n)` where n comes from current_count -- and
 * declare_function RESETS current_count to 0. That reset is correct for every
 * other user of the counter, because they all build
 * `create_unique_id("", function->s, n)` and the function name disambiguates.
 * A global has no function to name, so it uses the literal "g" and the numbers
 * restart underneath it.
 *
 * hex2's AddHash inserts at the head of the bucket and GetTarget returns the
 * first match, so the LAST definition wins and every earlier global with the
 * same number silently reads the later one's bytes.
 *
 * In libtcc.c this produced 41 colliding labels -- STR_g_0_contents was
 * defined as both "alm.?" and "%s/lib%s.so". No existing case could see it:
 * a collision needs two global string initialisers with a function
 * declaration between them, and every case here is smaller than that.
 *
 * Each pair below straddles one function, which is the minimum that triggers
 * it. The last pair straddles two, because the counter resets per function
 * and the third global would otherwise collide with the second rather than
 * the first. */
char* alpha = "alpha";
int f1(int x) { return x + 1; }
char* beta = "beta";
int f2(int x) { return x + 2; }
char* gamma = "gamma";

int streq(char* a, char* b)
{
	int i;
	i = 0;
	while(a[i] != 0)
	{
		if(a[i] != b[i]) return 0;
		i = i + 1;
	}
	if(b[i] != 0) return 0;
	return 1;
}

int main(void)
{
	int r;
	r = 0;

	if(!streq(alpha, "alpha")) r = r + 1;
	if(!streq(beta, "beta")) r = r + 2;
	if(!streq(gamma, "gamma")) r = r + 4;

	/* and that they are three DISTINCT addresses, not one label three
	 * references resolved onto */
	if(alpha == beta) r = r + 8;
	if(beta == gamma) r = r + 16;
	if(alpha == gamma) r = r + 32;

	/* the functions still work -- the counter is shared, so a change here
	 * must not disturb what it was originally for */
	if(f1(1) != 2) r = r + 64;
	if(f2(1) != 3) r = r + 128;

	return r;
}
