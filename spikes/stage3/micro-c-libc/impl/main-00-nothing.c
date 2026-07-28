/* PROBE 0: does anything run at all?
 *
 * No call into compiled tcc code, no malloc. If THIS faults, the fault is in
 * the ELF header, the startup stub, or micro-c's calling convention -- not in
 * tcc. Everything above it in this series is only meaningful once this passes. */
int main(int argc, char** argv) { return 0; }
