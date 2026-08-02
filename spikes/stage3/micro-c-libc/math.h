/* micro-c: minimal math.h.
 *
 * tcc's number parser converts floating-point literals in the source it
 * compiles, and reaches for a handful of libm entry points to do it. Measured
 * counts in the pinned tree: fabs 5, ldexp 2, ldexpl 1, pow 1. tcc-arm64-asm
 * patch 0006 adds frexpl 1, inside a block guarded on LDBL_MANT_DIG == 64 --
 * see float.h. The guard is false for micro-c, so the call never survives
 * preprocessing; the declaration is here so that the header does not depend on
 * that block staying compiled out.
 *
 * DECLARATIONS ONLY, like everything else here. `long double` is declared as
 * `double`: micro-c maps the two to one type (see the experiments README), so
 * declaring them differently here would be a fiction the compiler cannot keep.
 * A built tcc would compute long-double literals at double precision -- which
 * matters for the values it parses, and is recorded rather than hidden. */
#ifndef _MICROC_MATH_H
#define _MICROC_MATH_H

double fabs(double x);
double ldexp(double x, int exp);
double ldexpl(double x, int exp);
double pow(double x, double y);
double frexp(double x, int* exp);
double frexpl(double x, int* exp);

#endif
