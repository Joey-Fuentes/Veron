/* Copyright (C) 2016 Jeremiah Orians
 * Copyright (C) 2018 Jan (janneke) Nieuwenhuizen <janneke@gnu.org>
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

#include "cc.h"
#include <stdint.h>

struct token_list* emit(char *s, struct token_list* head);
void require(int bool, char* error);

char upcase(char a)
{
	if(in_set(a, "abcdefghijklmnopqrstuvwxyz"))
	{
		a = a - 32;
	}

	return a;
}


int char2hex(int c)
{
	if (c >= '0' && c <= '9') return (c - 48);
	else if (c >= 'a' && c <= 'f') return (c - 87);
	else if (c >= 'A' && c <= 'F') return (c - 55);
	else return -1;
}

int hexify(int c, int high)
{
	int i = char2hex(c);

	if(0 > i)
	{
		fputs("Tried to print non-hex number\n", stderr);
		exit(EXIT_FAILURE);
	}

	if(high)
	{
		i = i << 4;
	}
	return i;
}

int digit_is_octal(char digit)
{
	return digit >= '0' && digit <= '7';
}

int parse_octal_escape_code(char* digits)
{
	int result = 0;
	int i = 0;
	while(digit_is_octal(digits[i]) && i < 3)
	{
		result = result * 8;
		result = result + (digits[i] - '0');

		i = i + 1;
	}
	/* implementation defined behavior: Octals above 0177 (127) wrap around in 2s complement. Same as GCC. */
	while(result > 127)
	{
		result = result - 256;
	}

	return result;
}

int amount_of_escaped_chars_to_skip(char* string)
{
	if (string[1] == 'x') return 3;
	else if (digit_is_octal(string[1]))
	{
		int i = 2;
		while(digit_is_octal(string[i]) && i < 4)
		{
			i = i + 1;
		}
		return i - 1;
	}

	return 1;
}

/* HOW MANY BYTES A STRING LITERAL OCCUPIES, which is not how many characters
 * were written to spell it.
 *
 * sizeof used string_length on the raw token, and the comment there explains
 * why that worked: the token keeps its OPENING QUOTE and drops the closing
 * one, so the quote stands in for the terminating NUL. That is exact for a
 * literal with no escapes and wrong for every literal with one, because an
 * escape is several source characters and one byte:
 *
 *     sizeof("abc")        4    correct
 *     sizeof("a\nb")       5    should be 4
 *     sizeof("!<arch>\n")  10   should be 9
 *
 * The last one is ARMAG, and tcc starts reading an archive at
 *     file_offset = sizeof ARMAG - 1;              tccelf.c:3540
 * so mc-tcc began one byte into the first member header, read a header whose
 * fmag was 0a00 instead of "`\n", and rejected every archive -- including the
 * ones it had just written itself.
 *
 * amount_of_escaped_chars_to_skip already knows how wide each escape is; this
 * is the same walk the string emitter does, counting instead of emitting. */
int amount_of_escaped_chars_to_skip(char* string);
int string_size(char* string)
{
	int n = 0;
	int i = 1;                 /* skip the opening quote */
	while(0 != string[i])
	{
		if('\\' == string[i]) i = i + amount_of_escaped_chars_to_skip(string + i);
		i = i + 1;
		n = n + 1;
	}
	return n + 1;              /* the terminating NUL */
}

int escape_lookup(char* c);
int weird(char* string)
{
	int c;
	string = string + 1;
weird_reset:
	c = string[0];
	if(0 == c) return FALSE;
	if('\\' == c)
	{
		c = escape_lookup(string);
		string = string + amount_of_escaped_chars_to_skip(string);
	}

	if(!in_set(c, "\t\n !#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")) return TRUE;
	if(in_set(c, " \t\n\r") && (':' == string[1])) return TRUE;
	string = string + 1;
	goto weird_reset;
}

/* Lookup escape values */
int escape_lookup(char* c)
{
	if('\\' != c[0]) return c[0];

	if(c[1] == 'x')
	{
		int t1 = hexify(c[2], TRUE);
		int t2 = hexify(c[3], FALSE);
		return t1 + t2;
	}
	else if(c[1] == 'a') return 7;
	else if(c[1] == 'b') return 8;
	else if(c[1] == 't') return 9;
	else if(c[1] == 'n') return 10;
	else if(c[1] == 'v') return 11;
	else if(c[1] == 'f') return 12;
	else if(c[1] == 'r') return 13;
	else if(c[1] == 'e') return 27;
	else if(c[1] == '"') return 34;
	else if(c[1] == '\'') return 39;
	else if(c[1] == '\\') return 92;
	else if(c[1] == '?') return 63;
	else if(digit_is_octal(c[1])) return parse_octal_escape_code(c + 1);

	fputs("Unknown escape received: ", stderr);
	fputs(c, stderr);
	fputs(" Unable to process\n", stderr);
	exit(EXIT_FAILURE);
}

/* Deal with human strings */
char* collect_regular_string(char* string)
{
	string_index = 0;

collect_regular_string_reset:
	require((MAX_STRING - 3) > string_index, "Attempt at parsing regular string exceeds max length\n");
	if(string[0] == '\\')
	{
		hold_string[string_index] = escape_lookup(string);
		string = string + amount_of_escaped_chars_to_skip(string) + 1;
	}
	else
	{
		hold_string[string_index] = string[0];
		string = string + 1;
	}

	string_index = string_index + 1;
	if(string[0] != 0) goto collect_regular_string_reset;

	hold_string[string_index] = '"';
	hold_string[string_index + 1] = '\n';
	char* message = calloc(string_index + 3, sizeof(char));
	require(NULL != message, "Exhausted memory while storing regular string\n");
	copy_string(message, hold_string, string_index + 2);
	reset_hold_string();
	return message;
}

/* Deal with non-human strings */
char* collect_weird_string(char* string)
{
	string_index = 1;
	int temp;
	char* table = "0123456789ABCDEF";

	hold_string[0] = '\'';
collect_weird_string_reset:
	require((MAX_STRING - 6) > string_index, "Attempt at parsing weird string exceeds max length\n");
	string = string + 1;
	hold_string[string_index] = ' ';
	temp = escape_lookup(string) & 0xFF;
	hold_string[string_index + 1] = table[(temp >> 4)];
	hold_string[string_index + 2] = table[(temp & 15)];

	if(string[0] == '\\')
	{
		string = string + amount_of_escaped_chars_to_skip(string);
	}

	string_index = string_index + 3;
	if(string[1] != 0) goto collect_weird_string_reset;

	hold_string[string_index] = ' ';
	hold_string[string_index + 1] = '0';
	hold_string[string_index + 2] = '0';
	hold_string[string_index + 3] = '\'';
	hold_string[string_index + 4] = '\n';

	char* hold = calloc(string_index + 6, sizeof(char));
	require(NULL != hold, "Exhausted available memory while attempting to collect a weird string\n");
	copy_string(hold, hold_string, string_index + 5);
	reset_hold_string();
	return hold;
}

/* Parse string to deal with hex characters*/
char* parse_string(char* string)
{
	/* the string */
	if(weird(string)) return collect_weird_string(string);
	else return collect_regular_string(string);
}

/* AN INTEGER LITERAL IS SIXTY-FOUR BITS WIDE, AND THIS IS WHERE IT STOPPED
 * BEING ONE.
 *
 * M2libc's strtoint() returns `int` and finishes with
 *
 *     if(0 != (0x80000000 & result)) result = (0xFFFFFFFF << 31) | result;
 *
 * -- a deliberate sign-extension from bit 31, written for a reader whose
 * accumulator is 32 bits. micro-c is built by gcc, where `int` IS 32 bits, so
 * `0x100000000` never even reaches that line intact: it is 0 by the time the
 * function returns. `0x7fffffffffffffff` is 0xffffffff. Nothing warns.
 *
 * The consequence is not a wrong number in a corner. tcc's parse_number tests
 *
 *     if (n >= 0x8000000000000000ULL)                       tccpp.c
 *
 * That literal is 0, so the test reads `n >= 0` -- true for everything -- and
 * the same statement marks the constant UNSIGNED. Every constant the tcc we
 * build reads is therefore mis-typed, and it says so on every one:
 *
 *     <command line>:27: warning: integer constant overflow
 *
 * This is the same reader with a 64-bit accumulator and no truncation step.
 * It is here rather than in M2libc for two reasons. Changing strtoint() would
 * change it for every M2libc consumer, including M2-Planet's own reference
 * build, which is not ours to alter. And local-build.sh compiles micro-c
 * against spikes/reference/m2libc/bootstrappable.c -- the UNPATCHED copy --
 * so a patch to M2libc would have landed in a file nothing on this path reads,
 * which is the fourth time this repository has done exactly that.
 *
 * The digit loop stops at the first character that is not a digit in the
 * current base, which is how an integer suffix is handled without a table:
 * char2hex('U') and char2hex('L') are both -1, so `0x8000000000000000ULL` ends
 * at the U. */
long long strtolong(char* a)
{
	long long result;
	long long base;
	long long digit;
	int i;
	int negative;
	int c;

	if(NULL == a) return 0;
	if(0 == a[0]) return 0;

	result = 0;
	negative = FALSE;
	i = 0;

	if('-' == a[0])
	{
		negative = TRUE;
		i = 1;
	}
	else if('+' == a[0])
	{
		i = 1;
	}

	base = 10;
	if('0' == a[i])
	{
		if(('x' == a[i + 1]) || ('X' == a[i + 1]))
		{
			base = 16;
			i = i + 2;
		}
		else if(('b' == a[i + 1]) || ('B' == a[i + 1]))
		{
			base = 2;
			i = i + 2;
		}
		else
		{
			base = 8;
			i = i + 1;
		}
	}

	while(0 != a[i])
	{
		c = a[i];
		/* M2libc's readers accept _ as a digit separator; keep that. */
		if('_' != c)
		{
			digit = char2hex(c);
			if(0 > digit) break;
			if(digit >= base) break;
			result = (result * base) + digit;
		}
		i = i + 1;
	}

	if(negative) return 0 - result;
	return result;
}

/* THE PRINTING HALF, AND IT IS NOT OPTIONAL.
 *
 * M2libc's int2str() ends its unsigned path with
 *
 *     i = x & (0x7FFFFFFF + 0x80000000);
 *
 * which is a 32-bit mask ONLY IF the compiler that built it reads 0x80000000
 * as a positive number. gcc does. M2-Planet, whose strtoint() sign-extends
 * bit 31, reads it as -2147483648, so that expression is -1 and the mask does
 * nothing. int2str therefore truncates or does not truncate depending on WHICH
 * COMPILER BUILT IT -- and after the fix in this patch, on whether that
 * compiler had the fix. Splitting a 64-bit constant into halves with it would
 * have worked here and quietly stopped working at self-compilation.
 *
 * So the mask is built by arithmetic instead of written as a literal, and the
 * width of the accumulator is stated rather than inherited. */
char* long2str(long long x, int base, int signed_p)
{
	char* p;
	long long i;
	long long digit;
	int sign_p;
	char* table;

	require(1 < base, "long2str doesn\'t support a base less than 2\n");
	require(37 > base, "long2str doesn\'t support a base more than 36\n");

	/* 64 binary digits, a sign and a terminator, rounded up. */
	p = calloc(70, sizeof(char));
	require(NULL != p, "Exhausted memory while converting a number to a string\n");
	p = p + 68;
	table = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

	sign_p = FALSE;
	i = x;

	/* A NEGATIVE NUMBER RENDERED UNSIGNED IS A CALLER ERROR, AND IT USED TO
	 * BE A SILENT ONE. int2str masks to 32 bits first, so it happens to
	 * produce something; without that mask the digit below indexes the
	 * table at a negative offset and reads whatever is in front of it.
	 * Every caller here passes a value it already knows to be non-negative
	 * -- immediate_low_word and immediate_high_word return masked halves --
	 * so this is a programming error and says so rather than printing
	 * garbage that looks like a number. */
	require(signed_p || (0 <= x), "long2str asked to print a negative number as unsigned\\n");

	if(signed_p && (0 > x))
	{
		sign_p = TRUE;
	}

	/* THE DIGITS COME OFF THE NEGATIVE SIDE when the number is negative, so
	 * that LLONG_MIN works: negating it first overflows, and this compiler
	 * has no diagnostic that would tell you it had. C truncates division
	 * toward zero, so -9 % 10 is -9 and the digit is its magnitude. */
	if(sign_p)
	{
		do
		{
			digit = 0 - (i % base);
			p[0] = table[digit];
			p = p - 1;
			i = i / base;
		} while(0 != i);

		p[0] = '-';
		return p;
	}

	do
	{
		digit = i % base;
		p[0] = table[digit];
		p = p - 1;
		i = i / base;
	} while(0 != i);

	return p + 1;
}

/* THE LOW AND HIGH WORDS OF A 64-BIT CONSTANT, as M1 wants them.
 *
 * M1 emits `%` as exactly four little-endian bytes and masks to 0xFFFFFFFF, so
 * `%lo %hi` IS a correct 64-bit little-endian doubleword -- checked by running
 * it, see tools/verify-imm64.sh. Both halves are returned NON-NEGATIVE, since
 * a sign on either one would be a second, contradictory statement about a bit
 * pattern that is already exact. */
long long immediate_low_word(long long value)
{
	long long one;
	one = 1;
	return value & ((one << 32) - one);
}

long long immediate_high_word(long long value)
{
	long long one;
	one = 1;
	return (value >> 32) & ((one << 32) - one);
}
