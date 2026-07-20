/* SPIKE / invariants SUSPENDED — see spikes/borrow-m2/README.md
 *
 * Smallest possible end-to-end proof: a bare main() returning a constant.
 * Needs no C library at all — libc-core.M1's _start calls main and turns
 * its return value into the process exit code. If this runs under QEMU and
 * exits 42, the whole fetch -> compile(aarch64) -> assemble -> link -> run
 * pipeline is working on this setup.
 */
int main()
{
	return 42;
}
