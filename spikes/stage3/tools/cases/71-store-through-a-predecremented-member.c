/* `*--p->m = v` -- the LAST dereference of an assignment target is not a load.
 *
 * primary_expr_variable had two branches for a dereference under a prefix
 * ++/--, and the comment above them says the chain "must stop one load short"
 * when assigning. It did not: BOTH branches emitted the load and differed only
 * in whether current_target was stepped before or after it. So `*--p = v`
 * computed the address, LOADED the byte at it, and then stored through that
 * byte as if it were a pointer.
 *
 *     return *--file->buf_ptr = '\\';        tccpp.c, handle_stray_noerror
 *
 * That line runs only when the lexer meets a stray backslash, so every string
 * literal containing an ESCAPE segfaulted and every string without one was
 * fine. tcctest.c reached it at line 156 -- the first "...\n..." in the file --
 * while the 155 lines before it compiled clean, which is why this looked like
 * a size or complexity limit rather than one construct.
 *
 * Probe 5 is the exact tcc shape: the store is ALSO the returned value, so a
 * fix that produced the right memory but the wrong expression value would
 * still be wrong.
 *
 * Only the last dereference is spared. `**pp = v` must still load once to
 * reach the inner pointer -- the rule is that an address applies to the LAST
 * step of a chain, never to a step that still has to be followed. That is the
 * fifth function to learn it separately (zzc, zzg, zzm, and here). */
struct F { char* bp; int n; };
struct F f;
struct F* fp;
char buf[8];

int give(void) { return *--f.bp = 'z'; }

int main(void)
{
	buf[0]='.'; buf[1]='.'; buf[2]='.'; buf[3]='.'; buf[4]='.';

	f.bp = &buf[4];
	*--f.bp = 'x';
	if (f.bp != &buf[3]) return 1;
	if (buf[3] != 'x') return 2;

	fp = &f;
	*--fp->bp = 'y';
	if (fp->bp != &buf[2]) return 3;
	if (buf[2] != 'y') return 4;

	/* the exact tcc shape: the store is also the returned value */
	f.bp = &buf[2];
	if (give() != 'z') return 5;
	if (f.bp != &buf[1]) return 6;
	if (buf[1] != 'z') return 7;
	return 0;
}
