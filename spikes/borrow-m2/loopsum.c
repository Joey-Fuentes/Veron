/* SPIKE / invariants SUSPENDED — see spikes/borrow-m2/README.md
 *
 * One step past a constant: a while-loop with a local accumulator. This
 * exercises real codegen (locals, comparison, addition, a backward branch)
 * rather than just emitting a literal, while still needing no C library.
 * Sum of 0..9 = 45, so a correct build exits 45.
 */
int main()
{
	int s;
	int i;
	s = 0;
	i = 0;
	while(i < 10)
	{
		s = s + i;
		i = i + 1;
	}
	return s;
}
