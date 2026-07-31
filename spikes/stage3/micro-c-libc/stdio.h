/* micro-c: stdio.h.
 *
 * M2libc's stdio.h has the file primitives but none of the printf family --
 * tcc uses fprintf, printf, snprintf, sprintf, vfprintf, vprintf, vsnprintf,
 * perror and freopen, and none of those are there.
 *
 * Shadowing again means this has to be complete; same reasoning as stdlib.h,
 * string.h and unistd.h. FILE stays an OPAQUE struct, exactly as M2libc has
 * it, so nothing here depends on its layout. */
#ifndef _MICROC_STDIO_H
#define _MICROC_STDIO_H

#include <stddef.h>
#include <stdarg.h>

typedef struct __IO_FILE FILE;

extern FILE* stdin;
extern FILE* stdout;
extern FILE* stderr;

#define EOF 0xFFFFFFFF
#define BUFSIZ 4096
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

FILE* fopen(char* filename, char* mode);
FILE* freopen(char* filename, char* mode, FILE* stream);
FILE* fdopen(int fd, char* mode);
int fclose(FILE* stream);
int fflush(FILE* stream);
int setvbuf(FILE* stream, char* buf, int mode, size_t size);

int fgetc(FILE* stream);
int getchar(void);
char* fgets(char* str, int count, FILE* stream);
int ungetc(int ch, FILE* stream);
size_t fread(void* buffer, size_t size, size_t count, FILE* stream);

void fputc(int ch, FILE* stream);
void putchar(int ch);
int fputs(char* str, FILE* stream);
int puts(char* str);
size_t fwrite(void* buffer, size_t size, size_t count, FILE* stream);

long ftell(FILE* stream);
int fseek(FILE* stream, long offset, int origin);
void rewind(FILE* stream);
int remove(char* filename);

/* The printf family -- the reason this file exists.
 *
 * THE ELLIPSIS IS LOAD-BEARING AND WAS MISSING. These were declared with
 * their fixed parameters only, which micro-c accepts because it does not
 * check argument counts against a prototype. mc-tcc is a real tcc and does:
 *
 *     tccpp.c:545: error: too many arguments to function
 *
 * on `sprintf(p, "%llu", cv->i)` -- the first line of tcc's own source that
 * self-compilation reached, once the headers stopped stopping it earlier.
 * Every call in tcc that passes a format argument would have been rejected.
 *
 * micro-c parses `...` (M2-Planet has the __va_start/__va_arg intrinsics
 * behind it), and the emitted .M1 for the whole tcc unit is byte-identical
 * either way -- checked, because a header on the build path is exactly where
 * a silent change would be worst. */
int printf(const char* format, ...);
int fprintf(FILE* stream, const char* format, ...);
int sprintf(char* buffer, const char* format, ...);
int snprintf(char* buffer, size_t count, const char* format, ...);
int vprintf(const char* format, va_list ap);
int vfprintf(FILE* stream, const char* format, va_list ap);
int vsnprintf(char* buffer, size_t count, const char* format, va_list ap);
void perror(char* str);

#endif
