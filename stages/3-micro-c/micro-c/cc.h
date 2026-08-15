/* Copyright (C) 2016 Jeremiah Orians
 * Copyright (C) 2020 deesix <deesix@tuta.io>
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

#ifndef CC_H
#define CC_H

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

enum
{
	FALSE = 0,
	TRUE = 1,
};

enum
{
	KNIGHT_NATIVE = 1,
	KNIGHT_POSIX = 2,
	X86 = 4,
	AMD64 = 8,
	ARMV7L = 16,
	AARCH64 = 32,
	RISCV32 = 64,
	RISCV64 = 128,
};

/* These architecture families often behave similarly */
enum
{
	ARCH_FAMILY_KNIGHT = 3,
	ARCH_FAMILY_X86 = 12,
	ARCH_FAMILY_RISCV =  192,
};

enum
{
	/* Stack grows to higher memory addresses */
	STACK_DIRECTION_PLUS = 0,
	/* Stack grows to lower memory addresses */
	STACK_DIRECTION_MINUS = 1,
};

enum
{
	NO_STRUCT_DEFINITION = 0,
};

void write_to_out_buffer(char* s, FILE* destination_file);
void flush_output_buffer(FILE* destination_file);

int copy_string(char* target, char* source, int max);
char* concat_strings2(char* a, char* b);
struct type* new_array_row_type(struct type* element, int inner);
char* concat_strings3(char* a, char* b, char* c);
char* concat_strings4(char* a, char* b, char* c, char* d);
int string_length(char* a);
int in_set(int c, char* s);
int match(char* a, char* b);
void require(int bool, char* error);
void reset_hold_string(void);
char* int2str(int x, int base, int signed_p);

/* M2libc's strtoint() RETURNS int AND SIGN-EXTENDS FROM BIT 31, and int2str()
 * MASKS TO 32 BITS. Built by gcc, where int is four bytes, neither can carry a
 * literal wider than 32 bits at all; `0x100000000` arrives as 0. These two are
 * the same readers with a 64-bit accumulator and no truncation step.
 *
 * `long long` rather than `long` on purpose: M2-Planet maps both to
 * register_size, but a host `long` is 32 bits under LLP64, and the whole point
 * of this pair is that nothing depends on the host's integer width. */
long long strtolong(char* a);
char* long2str(long long x, int base, int signed_p);
long long immediate_low_word(long long value);
long long immediate_high_word(long long value);

void require_extra_token(void);
void require_token(void);

enum {
	FILE_BUFFER_SIZE = 65536,
	OUTPUT_FILE_BUFFER_SIZE = 65536,
};

enum
{
	REGISTER_ZERO = 0,
	REGISTER_ONE = 1,
	REGISTER_TEMP = 2,
	REGISTER_BASE = 3,
	/* AARCH64 and RISCV32/RISCV64 have return pointers. */
	REGISTER_RETURN = 4,
	REGISTER_STACK = 5,
	REGISTER_LOCALS = 6,
	REGISTER_EMIT_TEMP = 7,
	REGISTER_TEMP2 = 8,
};

void emit_push(int, char*);
void emit_pop(int, char*);

/* TO = Type Option */
enum
{
	TO_FUNCTION_POINTER = 1,
	/* A FLOATING-POINT TYPE. micro-c still gives float, double and long
	 * double one word-sized representation; this only records WHICH types
	 * are floating, so that an integer stored into one is converted rather
	 * than copied. See the assignment in cc_core.c. */
	TO_FLOAT = 2,
};

struct type
{
	struct type* next;
	int size;
	int offset;
	int is_signed;
	/* Dereferenced type */
	struct type* indirect;
	struct type* members;
	/* Pointer indirection of type */
	struct type* type;
	char* name;
	int options;
	/* BITFIELDS. bit_width 0 means "not a bitfield" -- every existing member
	 * keeps that by calloc, so nothing outside this feature changes. bit_offset
	 * is the bit position within the storage unit that `offset` addresses. */
	int bit_offset;
	int bit_width;
	/* ARRAY MEMBERS. Non-zero when the member was declared `T name[N]`, so
	 * that member access knows to yield the ADDRESS rather than load the first
	 * element. calloc leaves it zero for every member that is not an array. */
	int is_array;
};

/* TLO = Token List Option */
enum
{
	TLO_NONE = 0,
	TLO_LOCAL_ARRAY = 1,
	TLO_STATIC = 2,
	TLO_GLOBAL = 4,
	TLO_ARGUMENT = 8,
	TLO_LOCAL = 16,
	TLO_FUNCTION = 32,
	TLO_CONSTANT = 64,
};

struct token_list
{
	struct token_list* next;
	struct token_list* locals;
	struct token_list* prev;
	char* s;
	struct type* type;
	char* filename;
	struct token_list* arguments;
	int depth;
	int linenumber;
	int array_modifier;
	int options;
	/* BLUE PAINT. Set on a token that names the macro currently being
	 * expanded, so it is never expanded again. C requires this: a macro name
	 * appearing in its own expansion is not re-expanded. */
	int no_expand;
};

struct case_list
{
	struct case_list* next;
	char* value;
	/* THE VALUE ITSELF, beside its spelling. `value` is a LABEL NAME and is
	 * rendered unsigned, so `case -2:` spells itself 4294967294 -- fine for a
	 * name, and destroyed as a number. The table used to recover the constant
	 * by strtoint()ing that name back, which is where the sign went. */
	int ivalue;
};

struct static_variable_list
{
	struct static_variable_list* next;
	char* local_variable_name;
	struct token_list* global_variable;
};

struct include_path_list
{
	char* path;
	struct include_path_list* next;
};

struct string_list {
  struct string_list* next;
  char* name;
  char* string;
};

struct token_list* sym_declare(char *s, struct type* t, struct token_list* list, int options);
void line_error_token(struct token_list* token);

#include "cc_globals.h"

#endif /* CC_H */

