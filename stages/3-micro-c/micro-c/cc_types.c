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
#include "cc.h"

/* Imported functions */
int strtoint(char *a);
void line_error(void);
void require(int bool, char* error);
struct token_list* sym_lookup(char*, struct token_list*);
int constant_expression(void);

/* enable easy primitive extension */
struct type* add_primitive(struct type* a)
{
	if(NULL == prim_types) return a;
	struct type* i = prim_types;
	while(NULL != i->next)
	{
		i = i->next;
	}
	i->next = a;

	return prim_types;
}

/* enable easy primitive creation */
struct type* new_primitive(char* name0, char* name1, char* name2, int size, int sign)
{
	/* Create type** */
	struct type* a = calloc(1, sizeof(struct type));
	require(NULL != a, "Exhausted memory while declaring new primitive**\n");
	a->name = name2;
	a->size = register_size;
	a->indirect = a;
	a->is_signed = sign;

	/* Create type* */
	struct type* b = calloc(1, sizeof(struct type));
	require(NULL != b, "Exhausted memory while declaring new primitive*\n");
	b->name = name1;
	b->size = register_size;
	b->is_signed = sign;
	b->indirect = a;
	a->type = b;

	struct type* r = calloc(1, sizeof(struct type));
	require(NULL != r, "Exhausted memory while declaring new primitive\n");
	r->name = name0;
	r->size = size;
	r->is_signed = sign;
	r->indirect = b;
	r->type = r;
	b->type = r;

	return r;
}

/* Initialize default types */
void initialize_types(void)
{
	if(AMD64 == Architecture || AARCH64 == Architecture || RISCV64 == Architecture) register_size = 8;
	else register_size = 4;

	/* Define void */
	struct type* hold = new_primitive("void", "void*", "void**", register_size, FALSE);
	prim_types = add_primitive(hold);
	/* new_primitive links base -> indirect -> `void*`, so this is the exact
	 * type object every (void*) cast resolves to. */
	void_pointer = hold->indirect;

	/* Define unsigned LONG */
	hold = new_primitive("SCM","SCM*", "SCM**", register_size, FALSE);
	prim_types = add_primitive(hold);

	/* Define unsigned long long */
	unsigned_long_long = new_primitive("unsigned long long", "unsigned long long*", "unsigned long long**", register_size, FALSE);
	prim_types = add_primitive(unsigned_long_long);

	/* Define signed long long */
	signed_long_long = new_primitive("long long", "long long*", "long long**", register_size, TRUE);
	prim_types = add_primitive(signed_long_long);

	/* Define LONG */
	signed_long = new_primitive("long", "long*", "long**", register_size, TRUE);
	prim_types = add_primitive(signed_long);

	/* Define unsigned long */
	unsigned_long = new_primitive("unsigned long", "unsigned long*", "unsigned long**", register_size, FALSE);
	prim_types = add_primitive(unsigned_long);

	/* Define UNSIGNED */
	/* int IS FOUR BYTES, NOT A REGISTER.
	 *
	 * tcc's source depends on it. tccgen.c carries
	 *     ST_DATA int nocode_wanted;
	 *     #define NODATA_WANTED    (nocode_wanted > 0)
	 *     #define DATA_ONLY_WANTED 0x80000000
	 * and sets DATA_ONLY_WANTED for every file-scope variable. On a 32-bit
	 * int that sets the SIGN BIT, so NODATA_WANTED is false and
	 * put_extern_sym defines the symbol. At eight bytes 0x80000000 stays
	 * positive, put_extern_sym takes its early return, and every global in
	 * every program our tcc compiles is silently dropped.
	 *
	 * int32_t below has been a signed four-byte primitive all along -- it is
	 * what micro-c-libc uses for every struct that has to match the kernel --
	 * so the four-byte path is the tested one, not a new one. */
	unsigned_integer = new_primitive("unsigned", "unsigned*", "unsigned**", 4, FALSE);
	prim_types = add_primitive(unsigned_integer);

	/* Define int */
	integer = new_primitive("int", "int*", "int**", 4, TRUE);
	prim_types = add_primitive(integer);

	/* Define signed short */
	signed_short = new_primitive("short", "short*", "short**", 2, TRUE);
	prim_types = add_primitive(signed_short);

	/* Define unsigned short */
	unsigned_short = new_primitive("unsigned short", "unsigned short*", "unsigned short**", 2, FALSE);
	prim_types = add_primitive(unsigned_short);

	/* Define uint64_t */
	hold = new_primitive("uint64_t", "uint64_t*", "uint64_t**", 8, FALSE);
	prim_types = add_primitive(hold);

	/* Define int64_t */
	hold = new_primitive("int64_t", "int64_t*", "int64_t**", 8, TRUE);
	prim_types = add_primitive(hold);

	/* Define uint32_t */
	hold = new_primitive("uint32_t", "uint32_t*", "uint32_t**", 4, FALSE);
	prim_types = add_primitive(hold);

	/* Define int32_t */
	hold = new_primitive("int32_t", "int32_t*", "int32_t**", 4, TRUE);
	prim_types = add_primitive(hold);

	/* Define uint16_t */
	hold = new_primitive("uint16_t", "uint16_t*", "uint16_t**", 2, FALSE);
	prim_types = add_primitive(hold);

	/* Define int16_t */
	hold = new_primitive("int16_t", "int16_t*", "int16_t**", 2, TRUE);
	prim_types = add_primitive(hold);

	/* Define uint8_t */
	hold = new_primitive("uint8_t", "uint8_t*", "uint8_t**", 1, FALSE);
	prim_types = add_primitive(hold);

	/* Define int8_t */
	hold = new_primitive("int8_t", "int8_t*", "int8_t**", 1, TRUE);
	prim_types = add_primitive(hold);

	/* Define char -- KEPT, because a string literal needs its pointer type.
	 * Every other primitive that anything asks about is held in a global;
	 * `char` was the one built and dropped, so primary_expr_string had
	 * nothing to name and left current_target alone. */
	character = new_primitive("char", "char*", "char**", 1, TRUE);
	prim_types = add_primitive(character);

	/* Define signed char */
	signed_char = new_primitive("signed char", "signed char*", "signed char**", 1, TRUE);
	prim_types = add_primitive(signed_char);

	/* Define unsigned char */
	unsigned_char = new_primitive("unsigned char", "unsigned char*", "unsigned char**", 1, FALSE);
	prim_types = add_primitive(unsigned_char);

	/* Define _Bool */
	hold = new_primitive("_Bool", "_Bool*", "_Bool**", 1, TRUE);
	prim_types = add_primitive(hold);

	/* Define FUNCTION */
	function_pointer = new_primitive("FUNCTION", "FUNCTION*", "FUNCTION**", register_size, FALSE);
	function_pointer->options = TO_FUNCTION_POINTER; /* FUNCTION */
	function_pointer->indirect->options = TO_FUNCTION_POINTER; /* FUNCTION* */
	prim_types = add_primitive(function_pointer);

	/* Define _va_list */
	hold = new_primitive("__va_list", "__va_list*", "__va_list**", register_size, FALSE);
	prim_types = add_primitive(hold);

	/* EXPERIMENT ONLY -- float/double as word-sized primitives so DECLARATIONS
	 * parse. This is not a fix: arithmetic on them would be integer ops on
	 * float bits, silently wrong. Here to measure how far tcc gets. */
	hold = new_primitive("float", "float*", "float**", register_size, FALSE);
	hold->options = hold->options | TO_FLOAT;
	prim_types = add_primitive(hold);
	hold = new_primitive("double", "double*", "double**", register_size, FALSE);
	hold->options = hold->options | TO_FLOAT;
	prim_types = add_primitive(hold);

	if(BOOTSTRAP_MODE)
	{
		/* Define FILE */
		hold = new_primitive("FILE", "FILE*", "FILE**", register_size, TRUE);
		prim_types = add_primitive(hold);

		/* Primitives mes.c wanted */
		hold = new_primitive("size_t", "size_t*", "size_t**", register_size, FALSE);
		prim_types = add_primitive(hold);

		hold = new_primitive("ssize_t", "ssize_t*", "ssize_t**", register_size, FALSE);
		prim_types = add_primitive(hold);
	}

	global_types = prim_types;
}

struct type* lookup_type(char* s, struct type* start)
{
	struct type* i;
	for(i = start; NULL != i; i = i->next)
	{
		if(match(i->name, s))
		{
			return i;
		}
	}
	return NULL;
}

/* A ROW TYPE FOR A TWO-DIMENSIONAL ARRAY.
 *
 * `char m[12][4]` is an array of 12 things each of which is 4 chars. micro-c
 * carries one element count per declarator (array_modifier), so the inner
 * dimension has nowhere to live -- and indexing strides by
 * current_target->type->size, which for a flattened array would be 1 rather
 * than 4. Flattening therefore INDEXES WRONG rather than merely losing
 * information, which is why this synthesises a real type instead.
 *
 * The row type has size inner*sizeof(element) and steps down to the element
 * type, so m[i] strides by 4 and m[i][j] then strides by 1, which is what C
 * means. tcc reaches it at tccpp.c:3428:
 *     static char const ab_month_name[12][4] = {"Jan", "Feb", ...}; */
struct type* new_array_row_type(struct type* element, int inner)
{
	char* rowname = concat_strings4(element->name, "[", int2str(inner, 10, FALSE), "]");
	struct type* existing = lookup_type(concat_strings2(rowname, "#"), global_types);
	if(NULL != existing) return existing;

	/* TWO LEVELS ARE NEEDED, not one. postfix_expr_array takes its stride from
	 * current_target->type->size and only THEN steps current_target down. So
	 * for `m[i][j]` to stride by the row and then by the element:
	 *
	 *     m's type  ->  wrapper (size row)  ->  row (size row)  ->  element
	 *                   stride = wrapper->type->size = row      = 4
	 *                   after [ : current_target = row
	 *                   stride = row->type->size = element      = 1
	 *
	 * A single level cannot do both: a self-referential row gives 4 twice, and
	 * a row pointing straight at the element gives 1 twice. */
	int rowsize = element->size * inner;

	struct type* row = new_primitive(rowname,
	                                 concat_strings2(rowname, "*"),
	                                 concat_strings2(rowname, "**"),
	                                 rowsize, element->is_signed);
	row->type = element;
	row->next = global_types;
	global_types = row;

	struct type* wrapper = new_primitive(concat_strings2(rowname, "#"),
	                                     concat_strings2(rowname, "#*"),
	                                     concat_strings2(rowname, "#**"),
	                                     rowsize, element->is_signed);
	wrapper->type = row;
	wrapper->next = global_types;
	global_types = wrapper;

	return wrapper;
}


struct type* lookup_primitive_type(void)
{
	if(BOOTSTRAP_MODE)
	{
		return lookup_type(global_token->s, prim_types);
	}

	/* Lookup order for multi token types

	 * unsigned
     *	 char
     *	 short
     *	 short int
     *	 long
     *	 long int
     *	 long long
     *	 long long int
     *	 int
     *	 - (unsigned int)

	 * signed
     *	 char
     *	 short
     *	 short int
     *	 long
     *	 long int
     *	 long long
     *	 long long int
     *	 int
	 *	 - (int)

	 * short
     *	 int
     *	 - (short)

	 * long
     *	 int
     *	 long
     *	 long long int
     *	 - (long)
	 */

	if(match("unsigned", global_token->s))
	{
		require(global_token->next != NULL, "NULL token received in multi token type lookup");

		if(match("char", global_token->next->s))
		{
			global_token = global_token->next;
			return unsigned_char;
		}
		else if(match("short", global_token->next->s))
		{
			global_token = global_token->next;
			require(global_token->next != NULL, "NULL token received in multi token type lookup 'unsigned short'");

			if(match("int", global_token->next->s))
			{
				global_token = global_token->next;
				/* fallthrough to unsigned_short */
			}

			return unsigned_short;
		}
		else if(match("long", global_token->next->s))
		{
			global_token = global_token->next;
			require(global_token->next != NULL, "NULL token received in multi token type lookup 'unsigned long'");

			if(match("long", global_token->next->s))
			{
				global_token = global_token->next;
				require(global_token->next != NULL, "NULL token received in multi token type lookup 'unsigned long long'");

				if(match("int", global_token->next->s))
				{
					global_token = global_token->next;
					/* fallthrough to unsigned_long_long */
				}

				return unsigned_long_long;
			}
			else if(match("int", global_token->next->s))
			{
				global_token = global_token->next;
				/* fallthrough to unsigned_long */
			}

			return unsigned_long;
		}
		else if(match("int", global_token->next->s))
		{
			global_token = global_token->next;
			/* fallthrough to unsigned_integer */
		}

		return unsigned_integer;
	}
	else if(match("signed", global_token->s))
	{
		require(global_token->next != NULL, "NULL token received in multi token type lookup");

		if(match("char", global_token->next->s))
		{
			global_token = global_token->next;
			return signed_char;
		}
		else if(match("short", global_token->next->s))
		{
			global_token = global_token->next;
			require(global_token->next != NULL, "NULL token received in multi token type lookup 'signed short'");

			if(match("int", global_token->next->s))
			{
				global_token = global_token->next;
				/* fallthrough to signed_short */
			}

			return signed_short;
		}
		else if(match("long", global_token->next->s))
		{
			global_token = global_token->next;
			require(global_token->next != NULL, "NULL token received in multi token type lookup 'signed long'");

			if(match("long", global_token->next->s))
			{
				global_token = global_token->next;
				require(global_token->next != NULL, "NULL token received in multi token type lookup 'signed long long'");

				if(match("int", global_token->next->s))
				{
					global_token = global_token->next;
					/* fallthrough to signed_long_long */
				}

				return signed_long_long;
			}
			else if(match("int", global_token->next->s))
			{
				global_token = global_token->next;
				/* fallthrough to signed_long */
			}

			return signed_long;
		}
		else if(match("int", global_token->next->s))
		{
			global_token = global_token->next;
			/* fallthrough to integer */
		}

		return integer;
	}
	else if(match("short", global_token->s))
	{
		require(global_token->next != NULL, "NULL token received in multi token type lookup 'short'");

		if(match("int", global_token->next->s))
		{
			global_token = global_token->next;
			/* fallthrough to signed_short */
		}

		return signed_short;
	}
	else if(match("long", global_token->s))
	{
		require(global_token->next != NULL, "NULL token received in multi token type lookup 'long'");

		if(match("double", global_token->next->s))
		{
			/* EXPERIMENT: `long double`, as one token, mapped to double. */
			global_token = global_token->next;
			return lookup_type("double", prim_types);
		}
		else if(match("long", global_token->next->s))
		{
			global_token = global_token->next;
			require(global_token->next != NULL, "NULL token received in multi token type lookup 'long long'");

			if(match("int", global_token->next->s))
			{
				global_token = global_token->next;
				/* fallthrough to signed_long_long */
			}

			return signed_long_long;
		}
		else if(match("int", global_token->next->s))
		{
			global_token = global_token->next;
			/* fallthrough to signed_long */
		}

		return signed_long;
	}

	return lookup_type(global_token->s, prim_types);
}

struct type* lookup_global_type(void)
{
	struct type* a = lookup_primitive_type();
	if(NULL != a) return a;

	return lookup_type(global_token->s, global_types);
}

struct type* lookup_member(struct type* parent, char* name)
{
	int is_anonymous_type = match("", parent->name);
	if(is_anonymous_type)
	{
		/* We need to be able to know if we're in an anonymous type */
		parent = parent->type;
	}

	struct type* i;
	require(NULL != parent, "Not a valid struct type\n");
	struct type* anonymous;
	for(i = parent->members; NULL != i; i = i->members)
	{
		if(match("", i->name))
		{
			/* Anonymous struct/union (C11 extension */
			 anonymous = lookup_member(i, name);
			 if(anonymous != NULL)
			 {
				 return anonymous;
			 }
		}
		else if(match(i->name, name)) return i;
	}

	/* Anonymous types are not guaranteed to have the member in them */
	if(is_anonymous_type)
	{
		return NULL;
	}

	fputs("ERROR in lookup_member ", stderr);
	fputs(parent->name, stderr);
	fputs("->", stderr);
	fputs(name, stderr);
	fputs(" does not exist\n", stderr);
	fputs("  context: ", stderr);
	struct token_list* ctx = global_token;
	int back = 0;
	while(back < 8 && NULL != ctx->prev) { ctx = ctx->prev; back = back + 1; }
	while(back > -6 && NULL != ctx)
	{
		fputs(ctx->s, stderr); fputs(" ", stderr);
		ctx = ctx->next; back = back - 1;
	}
	fputs("\n", stderr);
	line_error();
	fputs("\n", stderr);
	exit(EXIT_FAILURE);
}

struct type* type_name(void);
void require_match(char* message, char* required);

char* parse_function_pointer(void)
{
	require_extra_token(); /* skip '(' */
	require_match("Required '*' after '(' in struct function pointer.", "*");
	require(NULL != global_token, "Incomplete function pointer declarator.\n");

	char* name = NULL;
	if(global_token->s[0] != ')')
	{
		name = global_token->s;
		require_extra_token();
	}

	require_match("Required ')' after name in struct function pointer.", ")");
	require_match("Required '(' after ')' in struct function pointer.", "(");
	require(NULL != global_token, "Incomplete function pointer parameter list.\n");

	while(global_token->s[0] != ')')
	{
		type_name();
		require(NULL != global_token, "Incomplete function pointer parameter list.\n");

		if(global_token->s[0] == '(')
		{
			parse_function_pointer();
		}
		require(NULL != global_token, "Incomplete function pointer parameter list.\n");

		if(global_token->s[0] != ')' && global_token->s[0] != ',')
		{
			/* skip optional name */
			require_extra_token();
		}

		if(global_token->s[0] == ',')
		{
			require_extra_token();
		}
	}
	require_extra_token(); /* skip ')' */

	return name;
}

int member_size;
/* AN ANONYMOUS AGGREGATE CAN CONTAIN ANOTHER ONE, AND ONLY ONE LEVEL WAS BEING
 * FLATTENED.
 *
 * `members` is the sibling chain -- build_member sets i->members = last -- so
 * walking it visits every member of ONE aggregate. A nested anonymous struct
 * appears on that chain as a single entry whose own members hang off
 * entry->type->members, a different list, and those never received the
 * enclosing offset. They kept offsets relative to the inner aggregate.
 *
 * tcc's Sym is exactly this shape:
 *
 *     typedef struct Sym {
 *         int v;
 *         unsigned short r;
 *         struct SymAttr a;
 *         union {
 *             struct { int c; int sym_scope; ... };
 *             ...
 *         };
 *     } Sym;
 *
 * so `c` -- the first member of the inner struct -- resolved to OFFSET 0 and
 * aliased `v`. sym_push2 does
 *
 *     s->v = v;  s->type.t = t;  s->c = c;
 *
 * and c is 0 for a field, so the third store wiped the token the first store
 * had just written. Every symbol tcc created came back with v == 0.
 * check_fields then computed table_ident[0 - TOK_IDENT] -- index -256 -- read
 * NULL out of it and dereferenced that. THAT is the P151 fault: it was never
 * in tccgen at all, it was a member offset.
 *
 * lookup_member already recurses into anonymous members, so the offsets have
 * to be correct at every level for it to agree with itself. */
void offset_anonymous_members(struct type* list, int offset)
{
	struct type* iterator = list;
	struct type* inner;

	while(NULL != iterator)
	{
		iterator->offset = iterator->offset + offset;

		inner = iterator->type;
		if(NULL != inner)
		{
			if(match("anonymous struct", inner->name) || match("anonymous union", inner->name))
			{
				offset_anonymous_members(inner->members, offset);
			}
		}

		iterator = iterator->members;
	}
}

struct type* build_member(struct type* last, int offset)
{
	struct type* i = calloc(1, sizeof(struct type));
	require(NULL != i, "Exhausted memory while building a struct member\n");
	i->members = last;
	i->offset = offset;

	struct type* member_type = type_name();
	require(NULL != member_type, "struct member type can not be invalid\n");
	i->type = member_type;

	if(global_token->s[0] == '(')
	{
		i->name = parse_function_pointer();
		i->type = function_pointer;
	}
	else if(global_token->s[0] != ';')
	{
		i->name = global_token->s;
		require_extra_token();

		/* BITFIELD: `unsigned short aligned : 5`. The width is a constant
		 * expression; the bit POSITION is assigned by the caller, which is the
		 * only place that knows what came before in this storage unit. */
		if(NULL != global_token)
		{
			if(global_token->s[0] == ':')
			{
				require_extra_token();
				i->bit_width = constant_expression();
				if(i->bit_width < 1)
				{
					line_error();
					fputs("bitfield width must be at least 1\n", stderr);
					exit(EXIT_FAILURE);
				}
				if(i->bit_width > (member_type->size * 8))
				{
					line_error();
					fputs("bitfield wider than its type\n", stderr);
					exit(EXIT_FAILURE);
				}
			}
		}
	}
	else
	{
		struct type* iterator = i->type->members;
		if(iterator == NULL)
		{
			line_error();
			fputs("Missing name for non-struct/union type.\n", stderr);
			exit(EXIT_FAILURE);
		}

		if(!match(i->type->name, "anonymous struct") && !match(i->type->name, "anonymous union"))
		{
			line_error();
			fputs("Anonymous members can not have a type name.\n", stderr);
			exit(EXIT_FAILURE);
		}

		/* Anonymous struct/union (C11 extension) */
		i->name = "";

		/* We need to offset all the member so that they're pointing correctly
		 * into the current struct -- at EVERY level, not just this one. */
		offset_anonymous_members(iterator, offset);
	}

	/* Check to see if array */
	if(match( "[", global_token->s))
	{
		require_extra_token();
		/* THE ELEMENT SIZE IS member_type->size, NOT member_type->type->size.
		 * The second steps down one level of indirection, which is right only
		 * when the type is self-referential -- as `int` is, its ->type being
		 * itself. For a POINTER element it is wrong:
		 *     char *include_stack[32]
		 * measured 32 * sizeof(char) = 32 bytes instead of 32 * 8 = 256, so
		 * every member after it in TCCState sat at the wrong offset.
		 *
		 * It also records that this member IS an array, which member access
		 * needs: an array decays to its address and must not be loaded. */
		i->is_array = TRUE;
		i->size = constant_expression() * i->type->size;
		if(0 == i->size)
		{
			fputs("Struct only supports [num] form\n", stderr);
			exit(EXIT_FAILURE);
		}
		require_match("Struct only supports [num] form\n", "]");
	}
	else
	{
		/* THE DECLARATOR'S OWN TYPE, NOT THE TYPE NAME IT STARTED FROM.
		 *
		 * For `int (*add)(int, int);` the branch above already replaced
		 * i->type with function_pointer -- and then this line took the size
		 * from `int`, the RETURN type, giving a member four bytes wide where
		 * the pointer is eight. create_struct reads that for both the running
		 * offset and the alignment, so the members after it overlap:
		 *
		 *     struct Ops { int (*add)(); int (*mul)(); int tag; }
		 *     add@0 mul@4 tag@8            add and mul share four bytes
		 *
		 * The store is eight bytes wide, because THAT width comes from
		 * i->type, so `o.mul = do_mul` overwrites the top half of `o.add` and
		 * the first call through it jumps to a spliced address.
		 *
		 * Invisible while `int` was eight bytes: the return type and the
		 * pointer were the same number. EXPERIMENT-zzw made them differ.
		 * For every other member i->type IS member_type, so this is a no-op
		 * there. */
		i->size = i->type->size;
	}

	/* AND ITS SIGNEDNESS, which nothing here copied.
	 *
	 * build_member callocs the record, so is_signed started 0 and stayed
	 * there: EVERY struct member reported as unsigned, whatever it was
	 * declared. The member read then chose the zero-extending load --
	 *
	 *     emit_out(load_value(i->size, i->is_signed));    ldr_w0, not ldrsw
	 *
	 * -- so a negative value written through `p->c` read back as its unsigned
	 * bit pattern: -1 stored 0xFFFFFFFF and returned 0x00000000FFFFFFFF.
	 *
	 * While `int` was eight bytes an eight-byte load had nothing to extend
	 * and signedness never reached the emitted code. At four bytes it decides
	 * correctness.
	 *
	 * tcc pushes a fresh struct with c = -1 and then asks
	 *
	 *     if (s->c != -1) tcc_error("struct/union/enum already defined");
	 *
	 * so every anonymous struct in tccdefs.h -- beginning with aarch64's
	 * __builtin_va_list at <command line>:56 -- reported as already defined,
	 * and every program our tcc was handed failed to compile.
	 *
	 * An ARRAY member keeps the element's signedness, which is what a read of
	 * one element needs. A function pointer has none to carry. */
	i->is_signed = i->type->is_signed;

	member_size = i->size;

	return i;
}

struct type* reverse_members_type_list(struct type* head)
{
	struct type* root = NULL;
	struct type* next;
	while(NULL != head)
	{
		next = head->members;
		head->members = root;
		root = head;
		head = next;
	}
	return root;
}

struct type* create_forward_declared_struct(char* name, int prepend_to_global_types)
{
	struct type* head = calloc(1, sizeof(struct type));
	require(NULL != head, "Exhausted memory while creating a struct\n");
	struct type* i = calloc(1, sizeof(struct type));
	require(NULL != i, "Exhausted memory while creating a struct indirection\n");
	struct type* ii = calloc(1, sizeof(struct type));
	require(NULL != ii, "Exhausted memory while creating a struct double indirection\n");

	head->name = name;
	head->type = head;
	head->indirect = i;
	head->next = global_types;
	head->size = NO_STRUCT_DEFINITION;
	head->members = NULL;

	i->name = head->name;
	i->type = head;
	i->indirect = ii;
	i->size = register_size;
	i->members = NULL;

	ii->name = head->name;
	ii->type = i;
	ii->indirect = ii;
	ii->size = register_size;

	if(prepend_to_global_types)
	{
		global_types = head;
	}

	return head;
}

struct type* create_struct(int is_union)
{
	int offset = 0;
	member_size = 0;

	struct type* head = NULL;
	struct type* i = NULL;

	char* name = "anonymous struct";
	if(is_union)
	{
		name = "anonymous union";
	}

	int has_name = global_token->s[0] != '{';
	if(has_name)
	{
		name = global_token->s;
		head = lookup_global_type();
		require_extra_token();
	}

	if(NULL == head)
	{
		head = create_forward_declared_struct(name, has_name);
		i = head->indirect;
	}
	else
	{
		if(head->size != NO_STRUCT_DEFINITION)
		{
			line_error();
			fputs("struct '", stderr);
			fputs(head->name, stderr);
			fputs("' already has definition.", stderr);
			exit(EXIT_FAILURE);
		}

		i = head->indirect;
	}

	require(NULL != global_token, "Incomplete struct declaration/definition at end of file\n");

	if(global_token->s[0] != '{')
	{
		/*
		 * When forward declaring the struct will have size == 0 and be an error to use.
		 * Zero-sized types are not allowed in C so this will never happen naturally.
		 */
		return head;
	}

	int largest_member_size = 0;
	require_match("ERROR in create_struct\n Missing {\n", "{");
	struct type* last = NULL;
	/* BITFIELD PACKING STATE. bit_cursor is how many bits of the CURRENT
	 * storage unit are spoken for; unit_offset is that unit's byte offset.
	 * A non-bitfield member, or one that will not fit, closes the unit. */
	int bit_cursor = 0;
	int unit_offset = 0;
	int unit_size = 0;
	require(NULL != global_token, "Incomplete struct definition at end of file\n");
	while('}' != global_token->s[0])
	{
		last = build_member(last, offset);

		/* ALIGN THE MEMBER.
		 *
		 * micro-c placed members end to end with no padding, so
		 *
		 *     struct { unsigned char a; char** p; }
		 *
		 * put p at offset 1. On amd64 an unaligned load merely costs time; on
		 * AARCH64 IT IS A FAULT. TCCState opens with ELEVEN unsigned char
		 * fields followed by pointers, so every pointer in it was misaligned,
		 * which is a very good candidate for the SIGBUS/SIGSEGV that the
		 * micro-c-built tcc dies with as soon as it touches one.
		 *
		 * Measured against gcc on TCCState's own opening fields:
		 *     gcc      tcc_lib_path at offset 16
		 *     micro-c  tcc_lib_path at offset 9
		 *
		 * The rule: a member aligns to its own size, capped at the register
		 * width, rounded down to a power of two. For an ARRAY it is the
		 * ELEMENT that determines alignment, not the whole array. Aligning
		 * more than strictly required would waste space but stay correct;
		 * aligning less is a fault, so the cap is deliberate rather than
		 * clever.
		 *
		 * Bitfields are left alone: their offsets are managed by the unit
		 * logic below, which has already decided where the storage unit sits. */
		if(0 == last->bit_width)
		{
			int align_size = last->size;
			if(last->is_array)
			{
				if(NULL != last->type) align_size = last->type->size;
			}
			if(align_size > register_size) align_size = register_size;

			int align = 1;
			while(align * 2 <= align_size) align = align * 2;

			if(align > 1)
			{
				int slack = offset % align;
				if(0 != slack)
				{
					offset = offset + (align - slack);
					last->offset = offset;
				}
			}
		}

		if(0 != last->bit_width)
		{
			/* Does it fit in the unit we are filling? */
			if(0 != bit_cursor)
			{
				if(last->type->size != unit_size) bit_cursor = 0;
				else if((bit_cursor + last->bit_width) > (unit_size * 8)) bit_cursor = 0;
			}
			if(0 == bit_cursor)
			{
				unit_offset = offset;
				unit_size = last->type->size;
			}
			last->offset = unit_offset;
			last->bit_offset = bit_cursor;
			bit_cursor = bit_cursor + last->bit_width;
			last->size = unit_size;
			/* member_size CANNOT be 0 here: NO_STRUCT_DEFINITION is 0, so a
			 * zero would trip the undefined-type check below. A packed field
			 * adds nothing to the struct, so say so by rewinding the offset
			 * after the caller advances it, rather than by reporting 0. */
			member_size = unit_size;
			if(last->bit_offset != 0) offset = offset - unit_size;
		}
		else
		{
			bit_cursor = 0;
		}

		if(member_size == NO_STRUCT_DEFINITION)
		{
			line_error();
			fputs("Can not use non-defined type in object.\n", stderr);
			exit(EXIT_FAILURE);
		}

		offset = offset + member_size;
		/* AN ARRAY'S ALIGNMENT IS ITS ELEMENT'S, NOT ITS TOTAL SIZE.
		 *
		 * largest_member_size drives the struct's own alignment, and the
		 * struct's SIZE is rounded up to it at the bottom of this function.
		 * Counting `char ar_name[16]` as a 16-byte member therefore rounded
		 * to eight and made a struct of nothing but char arrays a multiple
		 * of eight bytes long:
		 *
		 *     char a[3]   ->  4       char a[10]  ->  16
		 *     ArHdr       ->  64, and C says 60
		 *
		 * ArHdr is tcctools.c's `ar` member header, a BYTE-EXACT file
		 * format. tcc writes it with `fwrite(&arhdr, sizeof(arhdr), 1, fh)`,
		 * so mc-tcc wrote 64 bytes where 60 belong and four stray bytes
		 * landed exactly where the archive's symbol table starts. The
		 * archive it produced, it then rejected itself:
		 *     libh.a: error: invalid archive
		 * `tcc -ar` is on stage 4's critical path -- binutils must be built
		 * by tcc, and that means creating libbfd.a and libiberty.a before
		 * any ar exists.
		 *
		 * The ELEMENT size is what an array is aligned to, and this file
		 * already records it: i->size is count * element for an array, and
		 * i->type->size is the element. Using the element leaves every
		 * non-array member exactly as it was, since for those the two are
		 * the same number. */
		if(last->is_array)
		{
			if(last->type->size > largest_member_size)
			{
				largest_member_size = last->type->size;
			}
		}
		else if(member_size > largest_member_size)
		{
			largest_member_size = member_size;
		}

		if(is_union)
		{
			offset = 0;
		}

		/* EXPERIMENT: MULTIPLE DECLARATORS IN ONE MEMBER, `int jtrue, jfalse;`.
		 * build_member parses one declarator and the loop then demanded ';',
		 * so the comma form was a hard error. tcc.h:493 uses it inside an
		 * anonymous union, which made this look like an anonymous-union gap --
		 * it is not. Plain anonymous unions already worked; splitting the
		 * declarators onto separate lines compiles fine.
		 *
		 * Each extra declarator repeats the PREVIOUS member's type. That is
		 * what `int a, b;` means, and it is why this is a loop over the name
		 * rather than a re-parse of the type. */
		while(',' == global_token->s[0])
		{
			require_extra_token();

			/* POINTER DECLARATORS: `Section *a, *b, *c;`. The '*' binds to the
			 * DECLARATOR, not the type, so each one carries its own. Reusing
			 * the previous member's type is right only when the star counts
			 * match -- `int *a, b;` gives a an int* and b an int, and quietly
			 * treating b as int* would be exactly the silent-wrong-type bug
			 * this project keeps digging out. So count them, and refuse the
			 * mismatch loudly instead of guessing. */
			int stars = 0;
			while('*' == global_token->s[0])
			{
				stars = stars + 1;
				require_extra_token();
			}
			/* Count the previous declarator's stars from its TYPE NAME, which
			 * M2-Planet spells "int", "int*", "int**". The indirect/type
			 * fields are a two-way chain and reading direction off them is how
			 * the first version of this check got it exactly backwards. */
			/* Apply THIS declarator's stars to the shared base type, which is
			 * what C means. tcc needs both: `Section *a, *b` 107 times and
			 * `int *seg2lc, nseg` five times -- and the second is exactly what
			 * reusing the previous member's type gets wrong. */
			struct type* dtype = last_type_base;
			int k = 0;
			while(k < stars)
			{
				dtype = dtype->indirect;
				k = k + 1;
			}

			struct type* extra = calloc(1, sizeof(struct type));
			require(NULL != extra, "Exhausted memory on extra struct member\n");
			extra->members = last;
			extra->offset = offset;
			extra->type = dtype;
			extra->size = dtype->size;
			require(NULL != global_token, "Unterminated struct member list\n");
			extra->name = global_token->s;
			require_extra_token();

			if(NULL != global_token)
			{
				if(global_token->s[0] == ':')
				{
					require_extra_token();
					extra->bit_width = constant_expression();
					if(0 != bit_cursor)
					{
						if(extra->type->size != unit_size) bit_cursor = 0;
						else if((bit_cursor + extra->bit_width) > (unit_size * 8)) bit_cursor = 0;
					}
					if(0 == bit_cursor)
					{
						unit_offset = offset;
						unit_size = extra->type->size;
					}
					extra->offset = unit_offset;
					extra->bit_offset = bit_cursor;
					bit_cursor = bit_cursor + extra->bit_width;
					/* Same rule in the comma path: only the field that opens
					 * the unit contributes its size. */
					if(extra->bit_offset == 0) extra->size = unit_size;
					else extra->size = 0;
					unit_size = unit_size;
				}
			}
			last = extra;

			offset = offset + extra->size;
			/* Same rule for the comma-declarator members. */
			if(extra->is_array)
			{
				if(extra->type->size > largest_member_size)
				{
					largest_member_size = extra->type->size;
				}
			}
			else if(extra->size > largest_member_size)
			{
				largest_member_size = extra->size;
			}
			if(is_union)
			{
				offset = 0;
			}
		}

		require_match("ERROR in create_struct\n Missing ;\n", ";");
		require(NULL != global_token, "Unterminated struct\n");
	}

	/* Members are prepended so the list needs to be reversed. */
	last = reverse_members_type_list(last);

	require_extra_token();

	head->size = offset;
	if(is_union)
	{
		head->size = largest_member_size;
	}

	/* PAD THE STRUCT ITSELF, not just its members.
	 *
	 * Aligning members put each field on a sensible boundary; it did not make
	 * the WHOLE struct a multiple of that boundary, so
	 *
	 *     struct S { long a; long b; int c; char d; };
	 *
	 * measured 25. C requires the total to be a multiple of the largest
	 * member's alignment, and for a good reason: an ARRAY of these puts every
	 * element after the first at a misaligned address, and on aarch64 reading
	 * `a` out of element 1 is a fault rather than a slow load.
	 *
	 * It also made whole-struct assignment copy 25 bytes, ending mid-word.
	 *
	 * The alignment is the largest member's size capped at the register width,
	 * rounded down to a power of two -- the same rule used for placing the
	 * members, so the two cannot disagree. */
	int struct_align = largest_member_size;
	if(struct_align > register_size) struct_align = register_size;

	int pow2 = 1;
	while(pow2 * 2 <= struct_align) pow2 = pow2 * 2;

	if(pow2 > 1)
	{
		int tail = head->size % pow2;
		if(0 != tail) head->size = head->size + (pow2 - tail);
	}

	head->members = last;
	i->members = last;

	return head;
}

struct type* create_enum(void)
{
	struct type* head = calloc(1, sizeof(struct type));
	require(NULL != head, "Exhausted memory while creating an enum\n");
	struct type* i = calloc(1, sizeof(struct type));
	require(NULL != i, "Exhausted memory while creating a enum indirection\n");
	struct type* ii = calloc(1, sizeof(struct type));
	require(NULL != ii, "Exhausted memory while creating a enum double indirection\n");

	head->type = head;
	head->indirect = i;
	head->next = global_types;

	head->size = register_size; /* We treat enums as always being ints. */
	head->is_signed = TRUE;

	i->name = head->name;
	i->type = head;
	i->indirect = ii;
	i->size = register_size;

	ii->name = head->name;
	ii->type = i;
	ii->indirect = ii;
	ii->size = register_size;

	if(match("{", global_token->s))
	{
		head->name = "anonymous enum";
	}
	else
	{
		maybe_bootstrap_error("non-anonymous enum statement");
		head->name = global_token->s;
		require_extra_token();

		/* Anonymous enums should not be able to be looked up
		 * so we only add named enums. */
		global_types = head;
	}

	require_match("ERROR in create_enum\n Missing {\n", "{");
	require(NULL != global_token, "Incomplete enum definition at end of file\n");

	int next_enum_value = 0;
	int expr = 0;
	while('}' != global_token->s[0])
	{
		global_constant_list = sym_declare(global_token->s, NULL, global_constant_list, TLO_CONSTANT);
		global_constant_list->type = integer;

		require_extra_token();

		global_constant_list->arguments = calloc(1, sizeof(struct token_list));
		if(match("=", global_token->s))
		{
			require_extra_token();

			expr = constant_expression();
		}
		else
		{
			maybe_bootstrap_error("enum statement");
		}

		global_constant_list->arguments->s = int2str(expr, 10, TRUE);
		next_enum_value = expr + 1;
		expr = next_enum_value;

		if(match(",", global_token->s))
		{
			require_extra_token();
		}

		require(NULL != global_token, "Unterminated enum\n");
	}

	require_extra_token();

	return head;
}

struct type* fallible_type_name(void)
{
	struct type* ret;

	require(NULL != global_token, "Received EOF instead of type name\n");

	if(match("extern", global_token->s))
	{
		/* `extern` DECLARES; IT DOES NOT DEFINE.
		 *
		 * This skipped the keyword and let the declaration fall through to the
		 * ordinary global path, which EMITS STORAGE. So
		 *
		 *     extern char** environ;          micro-c-libc/impl/runtime.c:214
		 *
		 * produced `:GLOBAL_environ` in that unit as well as in M2libc, and
		 * hex2 has no duplicate-label diagnostic. The unit that reads it and
		 * the unit `_start` initialises were two different objects: getenv saw
		 * NULL and returned NULL for everything.
		 *
		 * The same headers declare `stdin`, `stdout`, `stderr` and `errno`
		 * the same way, and libtcc.c includes them, so tcc's diagnostics were
		 * going through a null FILE* of its own.
		 *
		 * Every case in tools/cases/ is a single file, which is exactly why
		 * this survived: a linkage bug is invisible to a one-unit test. */
		extern_declaration = TRUE;
		require_extra_token();
	}

	if(match("const", global_token->s))
	{
		require_extra_token();
	}

	/* `static` MAY FOLLOW THE TYPE as well as precede it -- C lets storage
	 * class and type specifiers appear in any order. tcc reaches it through
	 *     #define TCC_SEM(s) TCCSem s
	 *     TCC_SEM(static rt_sem);                  tccrun.c:68
	 * which expands to `TCCSem static rt_sem;`. Skipped here and after the
	 * type below; the declaration is already at file scope either way, and
	 * micro-c does not act on internal linkage. */
	if(match("static", global_token->s))
	{
		require_extra_token();
	}

	if(match("struct", global_token->s))
	{
		require_extra_token();
		ret = lookup_global_type();
		if(match(global_token->s, "{") ||
			((NULL != global_token->next) &&
			(match(global_token->next->s, "{") || match(global_token->next->s, ";"))))
		{
			/* A STRUCT DEFINED INLINE MAY STILL CARRY A DECLARATOR:
			 *     struct switch_t {
			 *         struct case_t { int64_t v1, v2; int ind, line; } **p;
			 *     };                                       tccgen.c:94
			 * Returning here skipped the '*' loop at the bottom, so `**p` was
			 * left unconsumed and the member list died on "Missing ;".
			 *
			 * create_struct has already eaten the tag and the body, so fall
			 * through to the star loop WITHOUT the require_extra_token that
			 * the named-struct path needs. */
			struct type* defined = create_struct(FALSE);
			while(global_token->s[0] == '*')
			{
				defined = defined->indirect;
				require_extra_token();
				while(match("const", global_token->s) || match("restrict", global_token->s))
				{
					require_extra_token();
				}
			}
			return defined;
		}
		else if(NULL == ret)
		{
			ret = create_forward_declared_struct(global_token->s, TRUE);
		}
	}
	else if(match("enum", global_token->s))
	{
		require_extra_token();
		ret = lookup_global_type();
		if(NULL == ret)
		{
			return create_enum();
		}
	}
	else if(match("union", global_token->s))
	{
		require_extra_token();
		ret = lookup_global_type();
		if(match(global_token->s, "{") ||
			((NULL != global_token->next) &&
			(match(global_token->next->s, "{") || match(global_token->next->s, ";"))))
		{
			return create_struct(TRUE);
		}
		else if(NULL == ret)
		{
			ret = create_forward_declared_struct(global_token->s, TRUE);
		}
	}
	else
	{
		ret = lookup_global_type();
		if(NULL == ret)
		{
			return NULL;
		}
	}

	require_extra_token();

	if(match("const", global_token->s))
	{
		require_extra_token();
	}

	if(match("static", global_token->s))   /* see the note above */
	{
		require_extra_token();
	}

	/* RECORD THE DECLARATOR'S POINTER DEPTH AND ITS BASE, here where the stars
	 * are actually consumed -- the only place that knows both. A struct member
	 * list shares the BASE type but each declarator carries its own stars:
	 * `int *a, b;` gives a an int* and b an int. Counting stars from the type
	 * NAME works for primitives and silently fails for struct pointers, whose
	 * name is just "T". */
	last_type_base = ret;
	last_type_stars = 0;
	while(global_token->s[0] == '*')
	{
		ret = ret->indirect;
		last_type_stars = last_type_stars + 1;
		require_extra_token();

		while(match("const", global_token->s) || match("restrict", global_token->s))
		{
			require_extra_token();
		}
	}

	return ret;
}

struct type* type_name(void)
{
	struct type* ret = fallible_type_name();
	if(ret != NULL)
	{
		return ret;
	}

	fputs("Unknown type ", stderr);
	fputs(global_token->s, stderr);
	fputs("\n", stderr);
	line_error();
	fputs("\n", stderr);
	exit(EXIT_FAILURE);
}

struct type* new_function_pointer_typedef(char* name)
{
	struct type* first = new_primitive(name, name, name, register_size, FALSE);
	first->options = TO_FUNCTION_POINTER;
	first->indirect->options = TO_FUNCTION_POINTER;

	return add_primitive(first);
}

struct type *mirror_type(struct type *source)
{
	struct type* head = lookup_primitive_type();
	struct type* i;
	struct type* ii;
	if(NULL == head)
	{
		head = calloc(1, sizeof(struct type));
		require(NULL != head, "Exhausted memory while creating a struct\n");

		add_primitive(head);

		i = calloc(1, sizeof(struct type));
		require(NULL != i, "Exhausted memory while creating a struct indirection\n");

		ii = calloc(1, sizeof(struct type));
		require(NULL != ii, "Exhausted memory while creating a struct double indirection\n");
	}
	else
	{
		i = head->indirect;
		ii = i->indirect;
		if(ii == head)
		{
			/* An older two-level chain built by this function. Give it the
			 * third level it should always have had. */
			ii = calloc(1, sizeof(struct type));
			require(NULL != ii, "Exhausted memory while creating a struct double indirection\n");
		}
	}

	head->name = global_token->s;
	i->name = global_token->s;
	head->size = source->size;
	i->size = source->indirect->size;
	head->offset = source->offset;
	i->offset = source->indirect->offset;
	head->is_signed = source->is_signed;
	i->is_signed = source->indirect->is_signed;
	/* THREE LEVELS, NOT TWO. `i->indirect = head` made T** resolve to T
	 * itself, so `*pal` on a T** loaded sizeof(T) instead of sizeof(T*) --
	 * "unsupported size 48" at tccpp.c:177, and only ever for structs reached
	 * through a typedef. create_forward_declared_struct has always built
	 * head / i / ii with ii->indirect = ii; this is the same shape.
	 *
	 * Reproduction, which passes without the typedef and fails with it:
	 *     typedef struct T { struct T* next; int a; } T;
	 *     int f(T** pal) { T* q; q = *pal; return 0; } */
	head->indirect = i;
	i->indirect = ii;
	ii->indirect = ii;
	head->members = source->members;
	i->members =  source->indirect->members;
	head->type = head;
	i->type = head;

	ii->name = head->name;
	ii->size = i->size;
	ii->offset = i->offset;
	ii->is_signed = i->is_signed;
	ii->members = i->members;
	ii->type = i;

	return head;
}
