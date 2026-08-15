/* micro-c: string.h.
 *
 * M2libc's string.h has everything tcc needs EXCEPT strerror. Because this
 * directory is searched first, a header here shadows rather than extends, so
 * ours has to carry the whole set -- the same situation as stdlib.h, and the
 * same answer: these are the C standard's signatures, not M2libc's code.
 *
 * Adding one symbol by putting strerror somewhere it does not belong would
 * have been shorter and wrong; a reader looking for it would not find it, and
 * the next missing string function would face the same choice again. */
#ifndef _MICROC_STRING_H
#define _MICROC_STRING_H

#include <stddef.h>

size_t strlen(char* str);
char* strcpy(char* dest, char* src);
char* strncpy(char* dest, char* src, size_t n);
char* strcat(char* dest, char* src);
char* strncat(char* dest, char* src, size_t n);
int strcmp(char* a, char* b);
int strncmp(char* a, char* b, size_t n);
char* strchr(char* str, int c);
char* strrchr(char* str, int c);
char* strstr(char* haystack, char* needle);
char* strpbrk(char* str, char* accept);
char* strdup(char* str);
size_t strspn(char* str, char* accept);
size_t strcspn(char* str, char* reject);

void* memcpy(void* dest, void* src, size_t n);
void* memmove(void* dest, void* src, size_t n);
void* memset(void* dest, int c, size_t n);
int memcmp(void* a, void* b, size_t n);

/* The one M2libc does not have, and the reason this file exists. */
char* strerror(int errnum);

#endif
