#ifndef _SHIM_STDIO_H
#define _SHIM_STDIO_H
/* NULL BELONGS HERE, AND ITS ABSENCE COST A TEST.
 *
 * 19_pointer_arithmetic includes <stdio.h> and nothing else, then writes
 *     c = NULL;
 * ISO C says stdio.h defines NULL -- it is one of the seven headers that do --
 * and this one did not, so the test failed to compile and was counted in the
 * 29 that "would not compile", which reads as a codegen frontier. It is a
 * missing #define. Pulling stddef.h in is how the real header does it. */
#include <stddef.h>
int printf(const char *fmt, ...);
int sprintf(char *out, const char *fmt, ...);
int puts(const char *s);
int putchar(int c);
#endif
