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

/* FILE IS A FILE DESCRIPTOR AND THREE FLAGS, AND THAT IS ENOUGH HERE.
 *
 * Two tests failed for the want of this type alone. 40_stdio opens a file and
 * reads it back four ways. 42_function_pointer never opens anything -- it
 * writes
 *     int (*fprintfptr)(FILE *, const char *, ...) = &fprintf;
 * and with FILE undeclared that parses as the identifier FILE followed by a
 * star, which is why the error read
 *     42_function_pointer.c:13: error: ',' expected (got '*')
 * and was logged as a parser defect for one round. It is a missing typedef.
 *
 * NO BUFFERING ON THE READ SIDE. Each fgetc is one read(2). These programs
 * read a twelve-byte file; a buffer layer would be more code than the thing
 * being tested and one more place for the shim to be wrong about. */
struct _shim_file {
    int fd;
    int eof;
    int err;
    int used;
};
typedef struct _shim_file FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

int printf(const char *fmt, ...);
int sprintf(char *out, const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);
int puts(const char *s);
int putchar(int c);

FILE *fopen(const char *path, const char *mode);
int fclose(FILE *f);
unsigned long fread(void *p, unsigned long sz, unsigned long n, FILE *f);
unsigned long fwrite(const void *p, unsigned long sz, unsigned long n, FILE *f);
int fgetc(FILE *f);
int getc(FILE *f);
char *fgets(char *s, int n, FILE *f);
int fputc(int c, FILE *f);
int fputs(const char *s, FILE *f);
int feof(FILE *f);
int ferror(FILE *f);
int fflush(FILE *f);
int remove(const char *path);
#endif
