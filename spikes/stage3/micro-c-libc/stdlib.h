/* micro-c: stdlib.h.
 *
 * WHY OURS AND NOT M2libc's. This directory is searched BEFORE M2libc, so a
 * header here shadows rather than extends. M2libc's stdlib.h declares eight
 * functions and none of the ones tcc needs for floating-point conversion
 * (strtod, strtof, strtold) or for realloc/qsort/abort. Shadowing means ours
 * has to be complete.
 *
 * That is NOT a fork of M2libc. These are the C standard's signatures, written
 * out; the implementations still come from whatever supplies the runtime.
 *
 * `long double` is `double` -- micro-c maps them to one type, so strtold here
 * returns double. A built tcc would parse long-double literals at double
 * precision. Recorded in math.h too, because it is the kind of thing that is
 * invisible until it is wrong. */
#ifndef _MICROC_STDLIB_H
#define _MICROC_STDLIB_H

#include <stddef.h>

void exit(int value);
void abort(void);

void* malloc(unsigned long size);
void* calloc(unsigned long count, unsigned long size);
void* realloc(void* ptr, unsigned long size);
void free(void* ptr);
void* memset(void* dest, int c, unsigned long n);

char* getenv(char* name);
int atoi(char* str);

/* THE const AND THE RETURN TYPES ARE LOAD-BEARING, and they were wrong.
 *
 * micro-c ignores both, so this file read `char*` and `double strtold` for as
 * long as micro-c was the only compiler that saw it. mc-tcc is a real tcc and
 * checks: tcc.h:49-50 declares these itself, for exactly the non-ISOC99 case
 * this header is standing in for, and a mismatch is an error rather than a
 * warning --
 *
 *     tcc.h:49: error: incompatible types for redefinition of 'strtof'
 *
 * which stopped self-compilation before any code was generated. `const char*`
 * against `char*` is the strtof half; `long double` against `double` is the
 * strtold half.
 *
 * `long double` STILL IS `double` UNDERNEATH -- micro-c maps them to one
 * type, so a built tcc parses long-double literals at double precision. What
 * changes here is only the SPELLING, so the declaration agrees with tcc's own
 * and with the C standard. The precision note in math.h is unchanged and
 * still applies. */
long strtol(const char* nptr, char** endptr, int base);
unsigned long strtoul(const char* nptr, char** endptr, int base);
long long strtoll(const char* nptr, char** endptr, int base);
unsigned long long strtoull(const char* nptr, char** endptr, int base);
double strtod(const char* nptr, char** endptr);
long double strtold(const char* nptr, char** endptr);
float strtof(const char* nptr, char** endptr);

void qsort(void* base, unsigned long n, unsigned long size, void* compar);

#endif

/* SOFT-FLOAT FOR tcc's CONSTANT FOLDER. Declared here because tccgen.c reaches
 * for them through the ordinary headers; the definitions are in impl/runtime.c
 * and operate on IEEE bit patterns in integer arithmetic. See the note there
 * for why tcc cannot use its own `f1 * f2` when micro-c is the compiler. */
unsigned long sf_add(unsigned long a, unsigned long b);
unsigned long sf_sub(unsigned long a, unsigned long b);
unsigned long sf_mul(unsigned long a, unsigned long b);
unsigned long sf_div(unsigned long a, unsigned long b);
unsigned long sf_neg(unsigned long a);
