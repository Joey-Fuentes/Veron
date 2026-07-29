/* An initialiser stores the DECLARATOR's width, not the declaration's.
 *
 *     unsigned char a[8], *p = a;
 *
 * `p` is eight bytes wide; the base type of the declaration is `unsigned
 * char`, one byte. The store used the base type, so one byte of a's address
 * went into p and the other seven were whatever the stack held. `p` was
 * DECLARED correctly, so it had the right type and the wrong value.
 *
 * tccpp.c:2191 is exactly this line. parse_string then memcpy'd through the
 * wild pointer on every SHORT string literal -- sizeof buf was right, so the
 * malloc branch was correctly skipped -- and handed it to free on the way out.
 *
 * The four shapes that were always right are probed too, because they are what
 * makes this narrow: the bug needs a LATER declarator whose star widens it past
 * the base type. `int *p = &g, *q = &g;` escapes only because the base type is
 * already eight wide.
 *
 * Sequential returns, not a bitmask: this construct produced a wild pointer,
 * and a case that can segfault must not report through a channel that cannot
 * be told from a signal. */
int g;
int main(void)
{
	unsigned char a[8], *p = a;
	int x = 1, y = 2;
	int m[4], n = 5;
	int *r = &g, *s = &g;
	unsigned char b[8];
	unsigned char *q = b;

	if(p != a) return 1;
	if(x != 1) return 2;
	if(y != 2) return 3;
	if(n != 5) return 4;
	m[0] = 7;
	if(m[0] != 7) return 5;
	if(r != &g) return 6;
	if(s != &g) return 7;
	if(q != b) return 8;

	/* the value has to survive a round trip, not just compare equal */
	a[0] = 42;
	if(p[0] != 42) return 9;
	p[1] = 9;
	if(a[1] != 9) return 10;
	return 0;
}
