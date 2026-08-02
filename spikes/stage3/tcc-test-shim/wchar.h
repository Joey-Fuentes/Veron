#ifndef _SHIM_WCHAR_H
#define _SHIM_WCHAR_H
/* DECLARATIONS ONLY, AND ONLY WHAT tests2 REACHES FOR.
 *
 * 97_utf8_string_literal includes this and then uses exactly one thing from
 * it: the type `wchar_t`, for `wchar_t s[] = L"hello$$..."`. It calls no wide
 * function -- it walks the array with a plain printf("%04X"). So this header
 * is a type and a constant, and adding wprintf and its family would be
 * inventing a surface nothing measures.
 *
 * wchar_t itself lives in stddef.h, where ISO C puts it and where tcc's own
 * stdatomic.h expects to find it. This header pulls that in rather than
 * repeating the typedef, because two typedefs of the same name in two headers
 * is a redefinition error waiting for the first program that includes both --
 * and 97 includes stdio.h, which includes stddef.h, immediately above it. */
#include <stddef.h>
#define WEOF ((wint_t)-1)
typedef unsigned int wint_t;
unsigned long wcslen(const wchar_t *s);
#endif
