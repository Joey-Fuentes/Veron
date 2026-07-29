/* A local variable whose name is also an enum constant. CLOSED.
 *
 *     enum{V=7}; int main(){int V; V=2; return V;}
 *
 * The declaration is legal C -- the local shadows the enumerator for the rest
 * of the block -- and micro-c segfaults on it. Row 320 of stage 2's
 * conformance corpus; pico-c handles it. */
enum { V = 7 };
int main(void)
{
	int V;
	V = 2;
	if(V != 2) return 1;
	return 0;
}
