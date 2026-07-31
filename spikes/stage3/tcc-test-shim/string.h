#ifndef _SHIM_STRING_H
#define _SHIM_STRING_H
#include <stddef.h>
void *memset(void *d, int c, unsigned long n);
void *memcpy(void *d, const void *s, unsigned long n);
void *memmove(void *d, const void *s, unsigned long n);
int memcmp(const void *a, const void *b, unsigned long n);
unsigned long strlen(const char *s);
char *strcpy(char *d, const char *s);
char *strcat(char *d, const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, unsigned long n);

char *strncpy(char *d, const char *s, unsigned long n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strncpy(char *d, const char *s, unsigned long n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
#endif
