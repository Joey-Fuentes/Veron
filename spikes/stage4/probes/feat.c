/* Does a compiler handle the C constructs gcc 4.7's source leans on?
 * gcc <= 4.7 builds with a C compiler; 4.8+ switched to C++, which is why the
 * old-gcc/new-gcc step is load-bearing and cannot be collapsed away.
 * Returns 6 when every feature works. */
#include <stdarg.h>
#include <stdio.h>

struct big { int a[8]; double d; };

static struct big mk(int n) { struct big b; b.a[0] = n; b.d = n * 1.5; return b; }

static int vsum(int n, ...) {
    va_list ap; int s = 0, i;
    va_start(ap, n);
    for (i = 0; i < n; i++) s += va_arg(ap, int);
    va_end(ap);
    return s;
}

typedef int (*fp)(int);
static int inc(int x) { return x + 1; }

int main(void) {
    struct big b = mk(7);          /* struct return by value */
    fp f = inc;                    /* function pointers      */
    long long ll = 1LL << 40;      /* 64-bit integers        */
    double d = b.d * 2.0;          /* floating point         */
    int arr[3] = {1, 2, 3};        /* aggregate initialisers */
    return (b.a[0] == 7) + (vsum(3,1,2,3) == 6) + (f(1) == 2)
         + (ll > 0) + (d > 0) + (arr[2] == 3);
}
