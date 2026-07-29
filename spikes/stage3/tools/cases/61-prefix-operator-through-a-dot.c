/* BITMASK. A prefix ++/-- whose target is reached through `.`. CLOSED.
 *
 * `--s.len` emits the member ADDRESS and then LOADS it, so the prefix code
 * treats the member's value as an address and stores through it.
 *
 * This is the dot half of EXPERIMENT-zzc, which fixed the arrow half. tcc uses
 * both:
 *
 *     ++indexsym.c;                              tccgen.c:8086
 *     while (str.str[--str.len] != ',')          tccpp.c:3101
 *
 * The second is on the token path, and it is the shape probed below: the
 * decremented member used immediately as an index. */
struct S { char* str; int len; int c; };
struct S g;
int main(void)
{
	struct S s;
	char buf[4];
	long r;
	r = 0;

	s.len = 3;   --s.len;   if(s.len != 2) r = r + 1;
	s.c = 5;     ++s.c;     if(s.c != 6) r = r + 2;

	buf[0] = 'a'; buf[1] = 'b'; buf[2] = 'c';
	s.str = buf;
	s.len = 3;
	if(s.str[--s.len] != 'c') r = r + 4;
	if(s.len != 2) r = r + 8;

	g.len = 3;   --g.len;   if(g.len != 2) r = r + 16;

	return r;
}
