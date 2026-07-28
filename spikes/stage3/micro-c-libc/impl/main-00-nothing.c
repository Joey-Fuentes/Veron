/* The smallest possible program. Used with several different LINK SETS, so
 * that what varies between probes is what is linked -- not what main does.
 *
 * The first probe series varied main and linked everything every time, so all
 * three faulted identically and it proved nothing. `int main(){return 0;}`
 * faulting is the whole finding: the fault is not in tcc's code. */
int main(int argc, char** argv) { return 0; }
