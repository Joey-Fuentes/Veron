/* PROBE MAIN: exits with a DISTINCTIVE CODE using a raw syscall.
 *
 * `return 0` cannot distinguish "main ran and returned" from "the process died
 * before main and something else produced a zero" -- and when the answer is a
 * fault it says nothing at all about WHERE.
 *
 * Exit code 42 through svc directly touches no libc: no exit(), no FILE
 * flush, no atexit. So:
 *
 *     exit 42     main was reached and the fault, if any, is after it
 *     SIGNAL      the fault is BEFORE main -- in the startup or the layout
 *
 * The syscall is aarch64 exit, number 93 in x8, status in x0 -- the same
 * sequence libc-core's own FUNCTION__exit uses. */
int main(int argc, char** argv)
{
    asm("mov_x0,42"
        "mov_x8,93"
        "svc_0");
    return 0;
}
