/* micro-c: minimal float.h.
 *
 * WHY THIS EXISTS, AND WHAT BROKE WITHOUT IT. tcc-arm64-asm patch 0006
 * ("convert long double constants when cross compiling") adds two lines to the
 * top of tccgen.c:
 *
 *     #include <math.h>
 *     #include <float.h>
 *
 * math.h was already here. float.h was not, so the moment that patch landed,
 * micro-c stopped being able to compile tcc at all:
 *
 *     tccgen.c:25:Unable to find include file: float.h
 *     micro-c could not compile libtcc.c (rc=1)
 *     stage 3 end to end: no
 *
 * Nothing else noticed, because every OTHER job that applies that series
 * builds tcc with the HOST compiler, and the host has a float.h. Only the two
 * jobs where micro-c is the compiler -- stage3-hermetic-arm64 and
 * micro-c-builds-tcc -- reach this include with micro-c's own include set
 * behind it. See MICRO-C.md.
 *
 * WHY NOT tcc's OWN include/float.h. The pinned tree ships one, and it selects
 * its long double block on __i386__ / __x86_64__ / __aarch64__. micro-c
 * defines none of those, so it would fall through to the generic block -- the
 * right answer, reached by accident. It also carries literals like
 * 1.18973149535723176508575932662800702e+4932L, which describe a type micro-c
 * does not have. A header that says what micro-c IS beats one that happens to
 * guess right.
 *
 * WHAT micro-c'S FLOAT MODEL ACTUALLY IS. One word-sized type. float, double
 * and long double are all the same eight bytes -- the same statement math.h
 * makes, and the same one tcc-microc patch 0001 makes when it sets
 * LDOUBLE_SIZE to 8. So all three families of macros below carry the IEEE
 * double values. That is not a rounding of the truth; it is the truth, and it
 * is what makes patch 0006's guard
 *
 *     #if defined LDBL_MANT_DIG && LDBL_MANT_DIG == 64
 *
 * evaluate FALSE and compile its x87-to-binary128 conversion out. That block
 * exists for an x86_64 host cross-compiling to arm64. micro-c is neither.
 *
 * INTEGER MACROS ONLY -- MEASURED, NOT GUESSED, like the rest of this
 * directory. The whole pinned tcc tree references exactly one name from
 * float.h, FLT_ROUNDS, and patch 0006 adds one more, LDBL_MANT_DIG. Neither
 * is a value macro. FLT_EPSILON, DBL_MIN, LDBL_MAX and their siblings are
 * deliberately absent: they would be floating-point literals that nothing on
 * this path reads, tokenized by a compiler whose float support is the
 * unsoundness this rung is still carrying. Add one when something measurably
 * needs it, with the count, as README.txt requires. */
#ifndef _MICROC_FLOAT_H
#define _MICROC_FLOAT_H

#define FLT_RADIX 2
#define FLT_ROUNDS 1

/* float -- eight bytes here, see above */
#define FLT_MANT_DIG 53
#define FLT_DIG 15
#define FLT_MIN_EXP (-1021)
#define FLT_MIN_10_EXP (-307)
#define FLT_MAX_EXP 1024
#define FLT_MAX_10_EXP 308

/* double */
#define DBL_MANT_DIG 53
#define DBL_DIG 15
#define DBL_MIN_EXP (-1021)
#define DBL_MIN_10_EXP (-307)
#define DBL_MAX_EXP 1024
#define DBL_MAX_10_EXP 308

/* long double -- the same double, said out loud */
#define LDBL_MANT_DIG 53
#define LDBL_DIG 15
#define LDBL_MIN_EXP (-1021)
#define LDBL_MIN_10_EXP (-307)
#define LDBL_MAX_EXP 1024
#define LDBL_MAX_10_EXP 308

#define DECIMAL_DIG 17

#endif
