#ifndef _SHIM_STDLIB_H
#define _SHIM_STDLIB_H
#include <stddef.h>
void *malloc(unsigned long n);
void *calloc(unsigned long a, unsigned long b);
void *realloc(void *p, unsigned long n);
void free(void *p);
void exit(int code);
void abort(void);
int abs(int v);
#endif
