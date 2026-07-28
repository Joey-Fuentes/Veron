/* Global string data must be padded so the code that follows stays
 * instruction-aligned. Unpadded, every call landed on an odd address. */
char msg[] = "hello";
char msg2[] = "abc";
int after = 99;
static int f(void) { return 7; }
int main(void)
{
    if (msg[0] != 'h' || msg[4] != 'o') return 1;
    if (msg2[0] != 'a') return 2;
    if (after != 99) return 3;
    if (f() != 7) return 4;
    return 0;
}
