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

long strtol(char* nptr, char** endptr, int base);
unsigned long strtoul(char* nptr, char** endptr, int base);
long long strtoll(char* nptr, char** endptr, int base);
unsigned long long strtoull(char* nptr, char** endptr, int base);
double strtod(char* nptr, char** endptr);
double strtold(char* nptr, char** endptr);
float strtof(char* nptr, char** endptr);

void qsort(void* base, unsigned long n, unsigned long size, void* compar);

#endif
