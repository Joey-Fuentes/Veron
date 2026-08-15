/* Copyright (C) 2016 Jeremiah Orians
 * This file is part of M2-Planet.
 *
 * M2-Planet is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * M2-Planet is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with M2-Planet.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdarg.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>

/* Required constants */
/* For file I/O*/
#define EOF 0xFFFFFFFF
#define BUFSIZ 0x1000

/* For lseek */
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

/* Required variables */
FILE* stdin;
FILE* stdout;
FILE* stderr;
FILE* __list;

void __init_io()
{
	__list = NULL;
	stdin = calloc(1, sizeof(FILE));
	stdin->fd = STDIN_FILENO;
	stdin->bufmode = O_RDONLY;
	stdin->buflen = 1;
	stdin->buffer = calloc(2, sizeof(char));

	stdout = calloc(1, sizeof(FILE));
	stdout->fd = STDOUT_FILENO;
	stdout->bufmode = O_WRONLY;
	stdout->buflen = 512;
	stdout->buffer = calloc(514, sizeof(char));

	stderr = calloc(1, sizeof(FILE));
	stderr->fd = STDERR_FILENO;
	stderr->bufmode = O_WRONLY;
	stderr->buflen = 512;
	stderr->buffer = calloc(514, sizeof(char));
}


/* Flush all IO on exit */
int fflush(FILE* stream);
void __kill_io()
{
	fflush(stdout);
	fflush(stderr);
	while(NULL != __list)
	{
		fflush(__list);
		__list = __list->next;
	}
}

/* Standard C functions */
/* Getting */
int read(int fd, char* buf, unsigned count);
int fgetc(FILE* f)
{
	/* Only read on read buffers */
	if(O_WRONLY == f->bufmode) return EOF;

	/* A '+' STREAM IS WRITTEN THROUGH THE BUFFER AND READ THROUGH THE
	 * DESCRIPTOR. Its buffer holds pending output, so reading out of it
	 * would hand back the bytes waiting to be written. Flushing first also
	 * makes the descriptor's position mean what the caller thinks it does. */
	if(O_RDWR == f->bufmode)
	{
		char one;
		fflush(f);
		if(1 != read(f->fd, &one, 1)) return EOF;
		return one & 0xFF;
	}

	/* Deal with stdin */
	if(STDIN_FILENO == f->fd)
	{
		f->bufpos = 0;
		int r = read(f->fd, f->buffer, 1);

		/* Catch special case of STDIN gets nothing (AN EOF) */
		if(0 == r) return EOF;
	}

	/* Catch EOF */
	if(f->buflen <= f->bufpos) return EOF;

	/* Deal with standard case */
	int ret = f->buffer[f->bufpos];
	f->bufpos = f->bufpos + 1;

	/* Ensure 0xFF doesn't return EOF */
	return (ret & 0xFF);
}

size_t fread( void* buffer, size_t size, size_t count, FILE* stream )
{
	if(0 == size) return 0;
	if(0 == count) return 0;

	long n = size * count;
	char* p = buffer;
	long i;
	unsigned c;
	for(i = 0; i < n; i = i + 1)
	{
		c = fgetc(stream);
		if(EOF == c) return (i/size);
		p[i] = c;
	}

	return (i/size);
}

int getchar()
{
	return fgetc(stdin);
}


char* fgets(char* str, int count, FILE* stream)
{
	int i = 0;
	int ch;
	if(count <= 0) return NULL;
	while(i < count - 1)
	{
		ch = fgetc(stream);
		if(EOF == ch) {
			/* Return null if EOF is first char read */
			if (i == 0) return NULL;
			break;
		}

		str[i] = ch;
		i = i + 1;

		if('\n' == ch) break;
	}

	str[i] = 0;
	return str;
}

/* Putting */
void fputc(char s, FILE* f)
{
	/* Only write on write buffers */
	if(O_RDONLY == f->bufmode) return;

	/* Add to buffer */
	f->buffer[f->bufpos] = s;
	f->bufpos = f->bufpos + 1;

	/* Flush if full or '\n' */
	if(f->bufpos == f->buflen) fflush(f);
	else if(('\n' == s) && (2 >= f->fd)) fflush(f);
}

size_t fwrite(void const* buffer, size_t size, size_t count, FILE* stream )
{
	long n = size * count;
	if(0 == n) return 0;

	char* p = buffer;
	int c;
	long i;
	for(i=0; i < n; i = i + 1)
	{
		c = p[i];
		fputc(c, stream);
	}

	return (i/size);
}

void putchar(char s)
{
	fputc(s, stdout);
}


int fputs(char const* str, FILE* stream)
{
	while(0 != str[0])
	{
		fputc(str[0], stream);
		str = str + 1;
	}
	return 0;
}


int puts(char const* str)
{
	fputs(str, stdout);
	fputc('\n', stdout);
	return 0;
}


int lseek(int fd, int offset, int whence);
int close(int fd);
/* File management */
FILE* fopen(char const* filename, char const* mode)
{
	int f;
	int size;

	/* '+' MEANS THE STREAM IS READ AS WELL AS WRITTEN, and ignoring it
	 * opened tcc's archive scratch file WRITE-ONLY:
	 *     fo = fopen(tfile, "wb+");            tcctools.c:184
	 *     ...
	 *     fseek(fo, 0, SEEK_SET); fread(buf, fsize, 1, fo);
	 * fgetc refuses a write-mode stream, so fread returned 0 and left `buf`
	 * holding whatever the allocator last put there -- which, because the
	 * previous block was freed and the sizes fall in the same power-of-two
	 * class, was the OBJECT FILE minus its sixty-byte member header. The
	 * archive came out the right length with the header missing and sixty
	 * stray bytes at the end, and mc-tcc rejected its own output:
	 *     libh.a: error: invalid archive
	 * Nothing reported an error anywhere along that path.
	 *
	 * ONLY 'w+' AND 'a+' ARE HANDLED. A read stream here slurps the whole
	 * file into a buffer at open time, and "r+" would have to write through
	 * that buffer as well -- a different design, and nothing needs it. It
	 * stays exactly as it was. */
	int rw = 0;
	if(0 != mode[1])
	{
		if('+' == mode[1]) rw = 1;
		else if('+' == mode[2]) rw = 1;
	}

	if('w' == mode[0])
	{
		if(rw) f = open(filename, O_RDWR|O_CREAT|O_TRUNC, 00600);
		else f = open(filename, O_WRONLY|O_CREAT|O_TRUNC, 00600);
	}
	else if('a' == mode[0])
	{
		if(rw) f = open(filename, O_RDWR|O_CREAT|O_APPEND, 00600);
		else f = open(filename, O_WRONLY|O_CREAT|O_APPEND, 00600);
	}
	else f = open(filename, 0, 0); /* Everything else is a read */

	/* Negative numbers are error codes */
	if(0 > f)
	{
		return 0;
	}

	FILE* fi = calloc(1, sizeof(FILE));
	if(NULL == fi)
	{
		close(f);
		return 0;
	}

	if('w' == mode[0] || 'a' == mode[0])
	{
		/* Buffer as much as possible */
		fi->buffer = malloc(BUFSIZ * sizeof(char));
		if(NULL == fi->buffer)
		{
			close(f);
			free(fi);
			return 0;
		}
		fi->buflen = BUFSIZ;
		/* O_RDWR marks the buffered-write stream that may also be read.
		 * fputc already writes for anything that is not O_RDONLY; fgetc,
		 * fseek and ftell below each take the descriptor route for it. */
		if(rw) fi->bufmode = O_RDWR;
		else fi->bufmode = O_WRONLY;
	}
	else
	{
		/* Get enough buffer to read it all */
		size = lseek(f, 0, SEEK_END);
		if(size < 0)
		{
			close(f);
			free(fi);
			return 0;
		}
		fi->buffer = malloc((size + 1) * sizeof(char));
		if(NULL == fi->buffer)
		{
			close(f);
			free(fi);
			return 0;
		}
		fi->buflen = size;
		fi->bufmode = O_RDONLY;

		/* Now read it all */
		lseek(f, 0, SEEK_SET);
		read(f, fi->buffer, size);
	}

	fi->next = __list;
	if(NULL != __list) __list->prev = fi;
	__list = fi;
	fi->fd = f;
	return fi;
}

FILE* fdopen(int fd, char* mode)
{
	FILE* fi = calloc(1, sizeof(FILE));
	if(NULL == fi) return 0;
	int size;

	if('w' == mode[0])
	{
		/* Buffer as much as possible */
		fi->buffer = malloc(BUFSIZ * sizeof(char));
		if(NULL == fi->buffer)
		{
			free(fi);
			return 0;
		}
		fi->buflen = BUFSIZ;
		fi->bufmode = O_WRONLY;
	}
	else
	{
		/* Get enough buffer to read it all */
		size = lseek(fd, 0, SEEK_END);
		if(size < 0)
		{
			free(fi);
			return 0;
		}
		fi->buffer = malloc((size + 1) * sizeof(char));
		if(NULL == fi->buffer)
		{
			free(fi);
			return 0;
		}
		fi->buflen = size;
		fi->bufmode = O_RDONLY;

		/* Now read it all */
		lseek(fd, 0, SEEK_SET);
		read(fd, fi->buffer, size);
	}

	fi->next = __list;
	if(NULL != __list) __list->prev = fi;
	__list = fi;
	fi->fd = fd;
	return fi;
}


int write(int fd, char* buf, unsigned count);
int fflush(FILE* stream)
{
	/* We only need to flush on writes */
	if(O_RDONLY == stream->bufmode) return 0;

	/* If nothing to flush */
	if(0 ==stream->bufpos) return 0;

	/* The actual flushing */
	int error = write(stream->fd, stream->buffer, stream->bufpos);

	/* Keep track of position */
	stream->file_pos = stream->file_pos + stream->bufpos;
	stream->bufpos = 0;

	return error;
}


int fclose(FILE* stream)
{
	/* Deal with STDIN, STDOUT and STDERR */
	/* No close for you */
	if(2 >= stream->fd) return 0;

	/* We only need to flush on writes */
	if(O_WRONLY == stream->bufmode)
	{
		fflush(stream);
	}

	/* Need to keep the File Descriptor for a moment */
	int fd = stream->fd;

	/* Remove from __list */
	if(NULL != stream->prev) stream->prev->next = stream->next;
	if(NULL != stream->next) stream->next->prev = stream->prev;
	/* Deal with special case of first node in __list */
	if (__list == stream) __list = __list->next;

	/* Free up the buffer and struct used for FILE */
	free(stream->buffer);
	free(stream);

	/* Do the actual closing */
	return close(fd);
}


int unlink(char* filename);
/* File Removal */
int remove(char *pathname)
{
	return unlink(pathname);
}


/* File Positioning */
int ungetc(int ch, FILE* stream)
{
	/* Deal with STDIN, STDOUT and STDERR */
	/* No ungetc for you */
	if(2 >= stream->fd) return EOF;

	/* You can't unget on a write stream! */
	if(O_WRONLY == stream->bufmode) return EOF;

	/* Don't underflow */
	if(0 == stream->bufpos) return EOF;

	/* Don't let crap be shoved into read stream */
	if(stream->buffer[stream->bufpos - 1] != ch) return EOF;

	stream->bufpos = stream->bufpos - 1;

	return ch;
}


long ftell(FILE* stream)
{
	/* Deal with STDIN, STDOUT and STDERR */
	/* No ftell for you */
	if(2 >= stream->fd) return 0;

	/* A '+' stream's position is the descriptor's, once the pending output
	 * has gone out. file_pos only counts what was written, and this stream
	 * is also being read. */
	if(O_RDWR == stream->bufmode)
	{
		fflush(stream);
		return lseek(stream->fd, 0, SEEK_CUR);
	}

	/* Deal with buffered output */
	if(O_WRONLY == stream->bufmode) return stream->file_pos + stream->bufpos;

	/* Deal with read */
	return stream->bufpos;
}


int fseek(FILE* f, long offset, int whence)
{
	/* Deal with STDIN, STDOUT and STDERR */
	/* No seek and destroy missions */
	if(2 >= f->fd) return 0;

	/* Deal with ugly case */
	if(O_WRONLY == f->bufmode || O_RDWR == f->bufmode)
	{
		fflush(f);
		return lseek(f->fd, offset, whence);
	}

	/* Deal with read mode */
	int pos;

	if(SEEK_SET == whence)
	{
		pos = offset;
	}
	else if(SEEK_CUR == whence)
	{
		pos = f->bufpos + offset;
	}
	else if(SEEK_END == whence)
	{
		pos = f->buflen + offset;
	}
	else return -1;

	if(pos < 0) return -1;
	if(pos > f->buflen) return -1;

	f->bufpos = pos;
	return pos;
}


void rewind(FILE* f)
{
	fseek(f, 0, SEEK_SET);
}

char* __unsigned_integer_to_string(unsigned int value, int base, int uppercase)
{
	static char buf[60];

	char* digits = "0123456789abcdef";
	if(uppercase)
	{
		digits = "0123456789ABCDEF";
	}

	char* ptr = &buf + 59;
	*ptr = '\0';

	do
	{
		--ptr;
		*ptr = digits[value % base];
		value /= base;
	}
	while(value != 0);

	return ptr;
}

char* __integer_to_string(int value)
{
	static char buf[60];

	char* digits = "0123456789abcdef";

	char* ptr = &buf + 59;
	*ptr = '\0';

	do
	{
		--ptr;
		*ptr = digits[value % 10];
		value /= 10;
	}
	while(value != 0);

	return ptr;
}

int __vsnprintf_string_offset;
va_list __vsnprintf_ap;
/* BYTES ACTUALLY WRITTEN by the last vsnprintf call, for vfprintf's chunking
 * loop. The RETURN value reports truncation the way ISO callers read it and is
 * therefore no longer the size of the chunk; this is. Exported rather than
 * recomputed because the function already knows it, and because the obvious
 * alternative -- strlen of the buffer -- adds a symbol stdio.c does not
 * otherwise use, which is exactly what broke 40 corpus rows. */
int __vsnprintf_written;
/* One line since M2-Mesoplanet doesn't support multi line macros */
#define INLINE_STRSCPY str_i = 0; while(str[str_i] != '\0' && output < n - 1) { s[output++] = str[str_i++]; }
/* A CONVERSION SPECIFICATION IS NOT JUST ITS LAST LETTER.
 *
 * This loop read the character after `%` and compared it against the six
 * conversions it knew. Anything else -- a flag, a width, a precision, a length
 * modifier -- matched nothing, so it emitted NOTHING for the `%`, advanced one
 * character, and then copied the rest of the specification out as literal
 * text. `%.2s` became the two characters `2s`, and tcc's
 *
 *     cstr_printf(cs, "#define __TINYC__ 9%.2s\n", &TCC_VERSION[4]);
 *
 * produced `#define __TINYC__ 92s`. Every `#if __TINYC__` in tcc's own test
 * suite then failed with "invalid number", at tcctest.c:337.
 *
 * AND IT DID NOT CONSUME THE ARGUMENT. That is the worse half. An unrecognised
 * specification fell through without calling va_arg, so every conversion after
 * it in the same format string read the WRONG SLOT -- silently, with no
 * diagnostic, producing plausible numbers from the wrong values. tcc uses 41
 * `%lx`, 11 `%08x`, 24 `%p` and 12 `%-2d` among others, none of which this
 * understood, so any diagnostic mixing them was misaligned from the first one
 * onwards.
 *
 * WHAT IS IMPLEMENTED NOW: the full specification shape
 *
 *     %[flags][width][.precision][length]conversion
 *
 * flags `-`, `0`, `+`, ` `, `#`; width and precision as digits or `*`; the
 * length modifiers h/hh/l/ll/z/j/t/L parsed and discarded; and the conversions
 * d i u o x X c s p %%. Every integer is fetched as a long, which is the
 * widest of the modifiers and, where int and long are the same width, also the
 * narrowest -- so discarding them is exact here rather than approximate.
 *
 * WHAT IS NOT: e E f g G a A n. There is no floating point in this compiler to
 * convert from. They emit the specification verbatim AND consume one argument
 * slot, so the conversions after them stay aligned -- a visible wrong output
 * rather than an invisible shift of everything downstream.
 *
 * THE RESUME CONTRACT IS UNCHANGED, AND IS WHY THE ROOM CHECK MOVED.
 * vfprintf calls this in PRINTF_BUFFER_SIZE chunks and restarts from
 * __vsnprintf_string_offset with __vsnprintf_ap. So the check for "does it
 * fit" now happens BEFORE a specification is emitted rather than per
 * character, and on truncation the offset points at the START of that
 * specification with the va_list snapshotted from before its arguments were
 * taken. Previously a `%s` could be cut in half and the remainder dropped: the
 * offset had already advanced past it. A specification too large for an empty
 * buffer is emitted truncated rather than retried, because otherwise vfprintf
 * would ask for it forever.
 */

char __vsnprintf_scratch[80];

int vsnprintf(char* s, size_t n, const char* format, va_list arg)
{
	int i;
	int output;
	int str_i;
	char* str;
	char* digits;
	va_list ap_save;
	int spec_start;
	int flag_minus;
	int flag_zero;
	int flag_plus;
	int flag_space;
	int flag_hash;
	int width;
	int precision;
	int have_precision;
	int base;
	int uppercase;
	int is_negative;
	int nlen;
	int total;
	int pad;
	int k;
	int sign_len;
	char sign_ch;
	int prefix_len;
	int len_long;
	unsigned long uvalue;
	long svalue;
	char conv;

	i = 0;
	output = 0;
	__vsnprintf_string_offset = 0;

	if(0 == n) return 0;

	while(format[i] != '\0')
	{
		if(format[i] != '%')
		{
			if(output >= n - 1)
			{
				__vsnprintf_string_offset = i;
				__vsnprintf_ap = arg;
				__vsnprintf_written = output;
				s[output] = '\0';
				/* TRUNCATED: SAY SO THE WAY ISO CALLERS READ IT. See the note
				 * above vfprintf. Returning the bytes WRITTEN makes
				 *     len = vsnprintf(buf, size, ...);
				 *     if (len >= size) { grow; retry; }
				 * believe every string fit. */
				return n;
			}
			s[output] = format[i];
			output = output + 1;
			i = i + 1;
			continue;
		}

		/* Snapshot BEFORE any va_arg of this specification, so a truncated
		 * chunk can be redone from here by vfprintf. */
		spec_start = i;
		ap_save = arg;
		i = i + 1;

		flag_minus = 0;
		flag_zero = 0;
		flag_plus = 0;
		flag_space = 0;
		flag_hash = 0;
		while(format[i] == '-' || format[i] == '0' || format[i] == '+'
		   || format[i] == ' ' || format[i] == '#')
		{
			if(format[i] == '-') flag_minus = 1;
			if(format[i] == '0') flag_zero = 1;
			if(format[i] == '+') flag_plus = 1;
			if(format[i] == ' ') flag_space = 1;
			if(format[i] == '#') flag_hash = 1;
			i = i + 1;
		}

		width = 0;
		if(format[i] == '*')
		{
			width = va_arg(arg, int);
			if(width < 0)
			{
				flag_minus = 1;
				width = 0 - width;
			}
			i = i + 1;
		}
		else
		{
			while(format[i] >= '0' && format[i] <= '9')
			{
				width = width * 10 + (format[i] - '0');
				i = i + 1;
			}
		}

		have_precision = 0;
		precision = 0;
		if(format[i] == '.')
		{
			have_precision = 1;
			i = i + 1;
			if(format[i] == '*')
			{
				precision = va_arg(arg, int);
				/* A NEGATIVE PRECISION IS AS IF IT WERE OMITTED, not as if it
				 * were zero -- the difference is a whole string or none. */
				if(precision < 0)
				{
					have_precision = 0;
					precision = 0;
				}
				i = i + 1;
			}
			else
			{
				while(format[i] >= '0' && format[i] <= '9')
				{
					precision = precision * 10 + (format[i] - '0');
					i = i + 1;
				}
			}
		}

		/* THE LENGTH MODIFIER IS PARSED AND REMEMBERED, NOT DISCARDED.
		 *
		 * Where int and long are the same width -- which is the case for the
		 * compiler this library is built by -- fetching everything as a long
		 * is exact. Where they are not, it is not: an `int` argument occupies
		 * a slot whose upper half means nothing, so reading it as a long
		 * turns -42 into 4294967254. Keeping the flag costs one variable and
		 * makes the same source correct under both. */
		len_long = 0;
		while(format[i] == 'h' || format[i] == 'l' || format[i] == 'L'
		   || format[i] == 'z' || format[i] == 'j' || format[i] == 't')
		{
			if(format[i] != 'h') len_long = 1;
			i = i + 1;
		}

		conv = format[i];
		if(conv == '\0')
		{
			/* A format ending in a bare `%`. Emit it and stop rather than
			 * reading past the end of the string. */
			if(output < n - 1)
			{
				s[output] = '%';
				output = output + 1;
			}
			break;
		}
		i = i + 1;

		sign_len = 0;
		sign_ch = ' ';
		prefix_len = 0;
		base = 10;
		uppercase = 0;
		is_negative = 0;
		nlen = 0;
		str = __vsnprintf_scratch;

		if(conv == 's')
		{
			str = va_arg(arg, char*);
			if(0 == str) str = "(null)";
			while(str[nlen] != '\0') nlen = nlen + 1;
			if(have_precision && precision < nlen) nlen = precision;
			flag_zero = 0;
		}
		else if(conv == 'c')
		{
			__vsnprintf_scratch[0] = va_arg(arg, int);
			nlen = 1;
			flag_zero = 0;
		}
		else if(conv == '%')
		{
			__vsnprintf_scratch[0] = '%';
			nlen = 1;
			flag_zero = 0;
		}
		else if(conv == 'd' || conv == 'i' || conv == 'u' || conv == 'o'
		     || conv == 'x' || conv == 'X' || conv == 'p')
		{
			if(conv == 'd' || conv == 'i')
			{
				if(len_long) svalue = va_arg(arg, long);
				else svalue = va_arg(arg, int);
				if(svalue < 0)
				{
					is_negative = 1;
					uvalue = 0 - svalue;
				}
				else
				{
					uvalue = svalue;
				}
			}
			else
			{
				/* A pointer is always the full width, whatever the modifier
				 * said. */
				if(len_long || conv == 'p') uvalue = va_arg(arg, unsigned long);
				else uvalue = va_arg(arg, unsigned int);
				if(conv == 'o') base = 8;
				else if(conv == 'u') base = 10;
				else base = 16;
				if(conv == 'X') uppercase = 1;
			}

			digits = "0123456789abcdef";
			if(uppercase) digits = "0123456789ABCDEF";

			/* Built backwards into the tail of the scratch buffer. */
			k = 78;
			__vsnprintf_scratch[79] = '\0';
			if(0 == uvalue && have_precision && 0 == precision)
			{
				/* A zero printed with an explicit precision of zero is the
				 * empty string. */
			}
			else
			{
				do
				{
					__vsnprintf_scratch[k] = digits[uvalue % base];
					uvalue = uvalue / base;
					k = k - 1;
				}
				while(uvalue != 0);
			}
			nlen = 78 - k;

			/* ON AN INTEGER, PRECISION IS A MINIMUM NUMBER OF DIGITS, and it
			 * overrides the `0` flag rather than adding to it. */
			if(have_precision)
			{
				flag_zero = 0;
				while(nlen < precision && k > 0)
				{
					__vsnprintf_scratch[k] = '0';
					k = k - 1;
					nlen = nlen + 1;
				}
			}
			str = &__vsnprintf_scratch[k + 1];

			if(is_negative)
			{
				sign_ch = '-';
				sign_len = 1;
			}
			else if(flag_plus && (conv == 'd' || conv == 'i'))
			{
				sign_ch = '+';
				sign_len = 1;
			}
			else if(flag_space && (conv == 'd' || conv == 'i'))
			{
				sign_ch = ' ';
				sign_len = 1;
			}

			if(conv == 'p') prefix_len = 2;
			else if(flag_hash && 16 == base && nlen != 0) prefix_len = 2;
		}
		else
		{
			/* NOT IMPLEMENTED. Consume one slot so that everything after this
			 * conversion still reads its own argument, and show the
			 * specification rather than a plausible wrong number. */
			va_arg(arg, long);
			k = 0;
			while(spec_start + k < i && k < 78)
			{
				__vsnprintf_scratch[k] = format[spec_start + k];
				k = k + 1;
			}
			nlen = k;
			str = __vsnprintf_scratch;
			width = 0;
			flag_zero = 0;
			flag_minus = 0;
		}

		total = nlen + sign_len + prefix_len;
		pad = 0;
		if(width > total) pad = width - total;

		/* THE ROOM CHECK IS PER SPECIFICATION, NOT PER CHARACTER, so a chunk
		 * boundary never lands inside a conversion. If nothing has been
		 * written yet the specification cannot be deferred to a later chunk,
		 * so it is emitted truncated instead -- otherwise vfprintf asks for
		 * the same specification forever. */
		if(output + total + pad > n - 1 && output > 0)
		{
			__vsnprintf_string_offset = spec_start;
			__vsnprintf_ap = ap_save;
			__vsnprintf_written = output;
			s[output] = '\0';
			/* TRUNCATED -- same reason as the site above. */
			return n;
		}

		if(!flag_minus && !flag_zero)
		{
			while(pad > 0 && output < n - 1)
			{
				s[output] = ' ';
				output = output + 1;
				pad = pad - 1;
			}
		}
		if(sign_len && output < n - 1)
		{
			s[output] = sign_ch;
			output = output + 1;
		}
		if(prefix_len)
		{
			if(output < n - 1)
			{
				s[output] = '0';
				output = output + 1;
			}
			if(output < n - 1)
			{
				if(uppercase) s[output] = 'X';
				else s[output] = 'x';
				output = output + 1;
			}
		}
		if(!flag_minus && flag_zero)
		{
			while(pad > 0 && output < n - 1)
			{
				s[output] = '0';
				output = output + 1;
				pad = pad - 1;
			}
		}
		str_i = 0;
		while(str_i < nlen && output < n - 1)
		{
			s[output] = str[str_i];
			output = output + 1;
			str_i = str_i + 1;
		}
		if(flag_minus)
		{
			while(pad > 0 && output < n - 1)
			{
				s[output] = ' ';
				output = output + 1;
				pad = pad - 1;
			}
		}
	}

	__vsnprintf_string_offset = i;
	__vsnprintf_ap = arg;
	__vsnprintf_written = output;
	if(format[i] == '\0') __vsnprintf_string_offset = 0;

	if(output < n)
	{
		/* Null terminator doesn't count */
		s[output] = '\0';
	}
	else
	{
		s[n - 1] = '\0';
	}

	return output;
}
#undef INLINE_STRSCPY

#define PRINTF_BUFFER_SIZE 4096
/* Add one to always have a null terminator */
char printf_buf[PRINTF_BUFFER_SIZE + 1];
int vfprintf(FILE* stream, char* format, va_list arg)
{
	int output = 0;
	va_list ap = arg;

	do
	{
		/* WHAT WAS WRITTEN, NOT WHAT WAS RETURNED.
		 *
		 * vsnprintf's return now reports TRUNCATION for ISO callers, so it is
		 * no longer the size of this chunk. This loop wants the bytes it is
		 * about to hand to fputs, which is exactly strlen of the buffer. */
		vsnprintf(printf_buf, PRINTF_BUFFER_SIZE, format, ap);
		output += __vsnprintf_written;
		format += __vsnprintf_string_offset;
		ap = __vsnprintf_ap;
		fputs(printf_buf, stream);
	}
	while(__vsnprintf_string_offset != 0);

	return output;
}
#undef PRINTF_BUFFER_SIZE

int vsprintf(char* s, const char* format, va_list arg)
{
	/* M2-Planet doesn't handle large literals that well. */
	return vsnprintf(s, 2147483647, format, arg);
}

int sprintf(char* s, char* format, ...)
{
	va_list ap;
	va_start(ap, format);
	return vsprintf(s, format, ap);
}

int fprintf(FILE* stream, char* format, ...)
{
	va_list ap;
	va_start(ap, format);
	return vfprintf(stream, format, ap);
}

int printf(char* format, ...)
{
	va_list ap;
	va_start(ap, format);
	return vfprintf(stdout, format, ap);
}

int vprintf(const char * format, va_list arg)
{
	return vfprintf(stdout, format, arg);
}

int snprintf(char* s, size_t n, const char* format, ...)
{
	va_list ap;
	va_start(ap, format);
	return vsnprintf(s, n, format, ap);
}
