/* `extern` declares a global; it does not define one.
 *
 * micro-c used to skip the keyword and let the declaration fall through to the
 * ordinary global path, which EMITS STORAGE -- so `extern char** environ;`
 * produced `:GLOBAL_environ` in that unit as well as in the one that really
 * defines it, and hex2 has no duplicate-label diagnostic.
 *
 * THIS CASE CANNOT SEE THAT BUG, and saying so is the point. Every case in
 * this directory is a SINGLE FILE, and a linkage fault needs two units to
 * show itself: there is no second definition here to disagree with. What this
 * does check is the half that is expressible -- that an extern declaration
 * followed by a definition in the same unit still yields exactly one object
 * that reads and writes consistently.
 *
 * The real regression test is cross-unit and lives in the corpus harness,
 * which links a program against the M2libc runtime. That is where
 * `extern char** environ` actually failed.
 *
 * The blind spot is the same shape as the array-of-pointers one: every probe
 * there used `long*`, so element width and pointed-at width were both 8 and
 * no case could tell a wrong choice between them. A suite only finds bugs in
 * the shapes it can express. */
extern int shared;
int shared;
extern int shared;

int bump(void) { shared = shared + 1; return shared; }

int main(void)
{
	shared = 41;
	if(shared != 41) return 1;
	if(bump() != 42) return 2;
	if(shared != 42) return 3;
	return 0;
}
