/* Copyright (C) 2016 Jeremiah Orians
 * Copyright (C) 2018 Jan (janneke) Nieuwenhuizen <janneke@gnu.org>
 * Copyright (C) 2020 deesix <deesix@tuta.io>
 * Copyright (C) 2021 Andrius Štikonas <andrius@stikonas.eu>
 * Copyright (C) 2025 Gtker
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

#include "cc_emit.h"
#include "gcc_req.h"
#include <stdint.h>

/* Global lists */
struct token_list* global_symbol_list;
struct token_list* global_function_list;

/* Core lists for this file */
struct token_list* function;

/* A PENDING `*`, PARKED BETWEEN THE STARS AND THE POSTFIX WALK.
 * Defined here rather than beside primary_expr_variable because function_call
 * -- which is earlier in the file -- has to clear it across an argument list.
 * See the note there. */
int num_dereference_after_postfix;

/* THE FUNCTION DESIGNATOR OF A CALL THAT IS ABOUT TO HAPPEN, when the call
 * could not go through primary_expr's direct fast path. Consumed and cleared
 * by function_call. See the notes at both ends. */
struct token_list* pending_function_designator;

/* THE REGISTER HOLDS A CALL'S RESULT -- a VALUE, not the address of a storage
 * slot. Set by function_call, consumed and cleared by postfix_expr. */
int last_expr_was_call;

/* What we are currently working on */
struct type* current_target;
char* break_target_head;
char* break_target_func;
char* break_target_num;
char* continue_target_head;
/* CONTINUE NEEDS ITS OWN func/num. It used to borrow break's, which is why a
 * `continue` inside a `switch` had to be banned outright: the switch overwrites
 * break_target_func/num with its own id, so the label would have pointed at the
 * switch rather than the enclosing loop. C sends continue to the LOOP. */
char* continue_target_func;
char* continue_target_num;
struct token_list* break_frame;
int current_count;
/* A SEPARATE COUNTER FOR GLOBAL-SCOPE GENERATED LABELS.
 *
 * current_count is reset by declare_function, which is correct for every other
 * user of it: they all build `create_unique_id("", function->s, n)`, so the
 * FUNCTION NAME disambiguates and restarting the numbers per function is what
 * keeps them short. A global string initialiser has no function to name -- it
 * uses the literal "g" -- so sharing that counter meant two globals separated
 * by any function declaration both got STR_g_0.
 *
 * hex2's AddHash inserts at the head of the bucket and GetTarget returns the
 * first match, so the LAST definition wins and the FIRST global silently reads
 * the other's bytes. In libtcc.c alone that produced 41 colliding STR_g labels
 * -- e.g. STR_g_0_contents defined as both "alm.?" and "%s/lib%s.so".
 *
 * Invisible to every test here: the case suite and the twelve end-to-end
 * programs are each a single small unit, and a collision needs two global
 * string initialisers with a function declaration between them. */
int current_count_global;
int Address_of;

/* A PREFIX ++/-- WHOSE TARGET IS REACHED THROUGH `->`.
 *
 * prefix_lvalue tells primary_expr "do not load this variable, the caller wants
 * its address". That is right when the variable IS the target -- `--n` -- and
 * wrong the moment anything stands between it and the target. In `--p->n` the
 * address wanted is `p + offset`, which needs p's VALUE; suppressing the load
 * makes the compiler add the member offset to `&p` and decrement a neighbouring
 * stack slot.
 *
 * The flag has to move from the FIRST node of the chain to the LAST. This
 * carries it there, is set and cleared inside one statement, and is read only
 * by the arrow site -- the file's own lesson from Address_of, which became
 * unreliable precisely by outliving the statement that set it. */
int prefix_lvalue_target;

/* DID THE EXPRESSION JUST PARSED END AT AN `&`?
 *
 * `&x` leaves REGISTER_ZERO holding an address but reports x's OWN type, one
 * level short of what it is -- there is no `T*` handed back. Nothing noticed
 * while the only consumer was a store, and `*(&x)` is where it shows: the
 * dereference steps the type down from a level that was never stepped up, and
 * lands one below where it started.
 *
 * Set by the Address_of path in primary_expr_variable, read by the
 * parenthesised dereference immediately after, and cleared on entry to every
 * primary_expr_variable so it can only ever describe the parse that just
 * finished. */
int last_expr_was_address_of;

/* Imported functions */
char* int2str(int x, int base, int signed_p);
int strtoint(char *a);
long long strtolong(char* a);
long long constant_expression(void);
long long constant_unary_expression(void);
char* long2str(long long x, int base, int signed_p);
char* parse_string(char* string);
int escape_lookup(char* c);
void require(int bool, char* error);
struct token_list* reverse_list(struct token_list* head);
struct type *mirror_type(struct type *source);
struct type* new_function_pointer_typedef(char* name);
struct type* add_primitive(struct type* a);

int global_static_array(struct type*, char*);
void declare_global_variable(struct type* type_size, struct token_list* variable);

struct type* fallible_type_name(void);
struct type* type_name(void);

char* parse_function_pointer(void);
/* The bitfield READ path is above the definitions of these, and an implicit
 * declaration makes them return int. */
char* bitwise_and_instruction(void);
char* bitwise_or_instruction(void);
char* shift_left_instruction(void);
char* shift_right_logical_instruction(void);

void flush_output_buffer(FILE* destination_file)
{
	if (output_file_index == 0)
	{
		return;
	}

	fwrite(output_file_buffer, 1, output_file_index, destination_file);
	output_file_index = 0;
}

void write_to_out_buffer(char* s, FILE* destination_file)
{
	int size = string_length(s);

	if (output_file_index + size >= OUTPUT_FILE_BUFFER_SIZE)
	{
		flush_output_buffer(destination_file);
	}

	if (size >= OUTPUT_FILE_BUFFER_SIZE)
	{
		fwrite(s, 1, size, destination_file);
	}

	output_file_index = output_file_index + copy_string(
		output_file_buffer + output_file_index, s,
		OUTPUT_FILE_BUFFER_SIZE - output_file_index);
}

int type_is_pointer(struct type* type_size)
{
	return type_size->type != type_size || (type_size->options & TO_FUNCTION_POINTER);
}

int type_is_struct_or_union(struct type* type_size)
{
	return type_size->members != NULL;
}

char* create_unique_id(char* prefix, char* s, char* num)
{
	return concat_strings4(prefix, s, "_", num);
}

struct token_list* sym_declare(char *s, struct type* t, struct token_list* list, int options)
{
	struct token_list* a = calloc(1, sizeof(struct token_list));
	require(NULL != a, "Exhausted memory while attempting to declare a symbol\n");
	a->next = list;
	a->s = s;
	a->type = t;
	a->array_modifier = 1;
	a->options = options;
	return a;
}

struct token_list* sym_lookup(char *s, struct token_list* symbol_list)
{
	struct token_list* i;
	for(i = symbol_list; NULL != i; i = i->next)
	{
		if(match(i->s, s)) return i;
	}
	return NULL;
}

struct token_list* static_variable_lookup(char* s)
{
	struct static_variable_list* statics = function_static_variables_list;
	while(statics != NULL)
	{
		if(match(s, statics->local_variable_name))
		{
			return statics->global_variable;
		}
		statics = statics->next;
	}

	return NULL;
}

void line_error_token(struct token_list *token)
{
	if(NULL == token)
	{
		fputs("EOF reached inside of line_error\n", stderr);
		fputs("problem at end of file\n", stderr);
		return;
	}
	if(NULL == token->filename)
	{
		fputs("<unknown>", stderr);
	}
	else
	{
		fputs(token->filename, stderr);
	}
	fputs(":", stderr);
	fputs(int2str(token->linenumber, 10, TRUE), stderr);
	fputs(":", stderr);
}

void line_error(void)
{
	line_error_token(global_token);
}

/* Checks if current global_token is NULL and exits if it is. */
void require_token(void)
{
	if(NULL == global_token)
	{
		line_error_token(global_token);
		exit(EXIT_FAILURE);
	}
}

/* Advances token and checks for NULL. */
void require_extra_token(void)
{
	global_token = global_token->next;
	require_token();
}

void require_match(char* message, char* required)
{
	if(NULL == global_token)
	{
		line_error();
		fputs("EOF reached inside of require match\n", stderr);
		fputs("problem at end of file\n", stderr);
		fputs(message, stderr);
		exit(EXIT_FAILURE);
	}
	if(!match(global_token->s, required))
	{
		line_error();
		fputs(message, stderr);
		exit(EXIT_FAILURE);
	}
	global_token = global_token->next;
}

void maybe_bootstrap_error(char* feature)
{
	if (BOOTSTRAP_MODE)
	{
		line_error();
		fputs(feature, stderr);
		fputs(" is not supported in --bootstrap-mode\n", stderr);
		exit(EXIT_FAILURE);
	}
}

int string_size(char* string);
int unary_expr_sizeof(void);
struct type* lookup_member(struct type* parent, char* name);

long long constant_unary_expression(void)
{
	if('-' == global_token->s[0])
	{
		require_extra_token();
		return -constant_unary_expression();
	}
	else if('+' == global_token->s[0])
	{
		require_extra_token();
		return constant_unary_expression();
	}
	else if(match("sizeof", global_token->s))
	{
		return unary_expr_sizeof();
	}
	else if(global_token->s[0] == '\'')
	{
		int val = escape_lookup(global_token->s + 1);
		global_token = global_token->next;
		return val;
	}
	else if(in_set(global_token->s[0], "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"))
	{
		struct token_list* lookup = sym_lookup(global_token->s, global_constant_list);
		if(lookup != NULL)
		{
			if(lookup->arguments == NULL || lookup->arguments->s == NULL)
			{
				line_error();
				fputs("Unable to use incomplete enum constant '", stderr);
				fputs(global_token->s, stderr);
				fputs("' in constant expression.\n", stderr);
				exit(EXIT_FAILURE);
			}

			require_extra_token();
			return strtolong(lookup->arguments->s);
		}
		else
		{
			line_error();
			fputs("Unable to find symbol '", stderr);
			fputs(global_token->s, stderr);
			fputs("' for use in constant expression.\n", stderr);
			exit(EXIT_FAILURE);
		}
	}
	else if(in_set(global_token->s[0], "0123456789"))
	{
		require_extra_token();
		return strtolong(global_token->prev->s);
	}
	else if(global_token->s[0] == '&')
	{
		/* `&((T *)0)->field` -- THE ADDRESS-OF HALF OF offsetof.
		 *     #define offsetof(type, field) ((size_t) &((type *)0)->field)
		 *                                          tcc.h:102
		 * Taken relative to a null pointer, that address IS the member's byte
		 * offset, which is the whole point of the idiom. Folding it emits no
		 * code -- it just reads the offset out of the type. */
		require_extra_token();
		require_match("ERROR in offsetof\nMissing ( before the cast\n", "(");
		require_match("ERROR in offsetof\nMissing ( around the cast type\n", "(");
		struct type* ot = type_name();
		require_match("ERROR in offsetof\nMissing ) after the cast type\n", ")");
		constant_expression();   /* the base, conventionally 0 */
		require_match("ERROR in offsetof\nMissing ) after the cast\n", ")");

		int total = 0;
		while(NULL != global_token)
		{
			if(match("->", global_token->s) || match(".", global_token->s))
			{
				if(match("->", global_token->s)) ot = ot->type;
				require_extra_token();
				require(NULL != global_token, "Incomplete offsetof member access\n");
				struct type* om = lookup_member(ot, global_token->s);
				total = total + om->offset;
				ot = om->type;
				require_extra_token();
			}
			else break;
		}
		return total;
	}
	else if(global_token->s[0] == '(')
	{
		/* A CAST IN A CONSTANT EXPRESSION. offsetof wraps its result in
		 * `(size_t)`, and a cast does not change a compile-time value -- so
		 * take the type and fold the operand. Distinguished from grouping
		 * parens by trying fallible_type_name and rewinding when it is not
		 * one, the same way primary_expr does. */
		struct token_list* before_ce = global_token;
		require_extra_token();
		struct type* ct = fallible_type_name();
		if(NULL != ct)
		{
			require_match("Missing ) after a cast in a constant expression\n", ")");
			return constant_unary_expression();
		}
		global_token = before_ce;

		/* EXPERIMENT: a PARENTHESISED constant expression. elf.h writes
		 *     #define EI_NIDENT (16)
		 * and then `unsigned char e_ident[EI_NIDENT];`, which reaches here as
		 * `[ ( 16 ) ]`. Grouping parens are ordinary C and cost one recursion. */
		require_extra_token();
		long long val = constant_expression();
		require_match("Missing ) in constant expression\n", ")");
		return val;
	}

	line_error();
	fputs("Invalid token '", stderr);
	fputs(global_token->s, stderr);
	fputs("' used in constant_expression_term.\n", stderr);
	exit(EXIT_FAILURE);
}

/* global_token should start on the first part of the expression
 * and it will end one token past the end of the expression. */
long long constant_expression(void)
{
	/* We go from the highest precedence operators down to the lowest */
	long long lhs = constant_unary_expression();

	if(global_token->s[0] == '+')
	{
		require_extra_token();
		return lhs + constant_expression();
	}
	else if(global_token->s[0] == '-')
	{
		require_extra_token();
		return lhs - constant_expression();
	}
	/* EXPERIMENT: the rest of the integer operators. tcc.h:483 writes
	 *     int tab[LDOUBLE_SIZE/4];
	 * and only + and - were handled.
	 *
	 * PRECEDENCE IS WRONG HERE, and was already: this is right-recursive with
	 * no levels, so `2 * 3 + 1` evaluates as 2 * (3 + 1). The existing + and -
	 * have the same flaw (`3 - 1 + 1` gives 1). Adding operators extends that
	 * defect rather than introducing it, which is fine for measuring how far
	 * tcc parses and NOT fine to ship -- a real fix needs precedence levels,
	 * the way the expression parser proper has them. */
	else if(global_token->s[0] == '*')
	{
		require_extra_token();
		return lhs * constant_expression();
	}
	else if(global_token->s[0] == '/')
	{
		require_extra_token();
		return lhs / constant_expression();
	}
	else if(global_token->s[0] == '%')
	{
		require_extra_token();
		return lhs % constant_expression();
	}
	/* THE BITWISE OPERATORS, which entry 10 left out when it added * / %.
	 *     { VT_LLONG | VT_LONG, 8, DW_ATE_signed, ... }    tccdbg.c:36
	 * constant_expression is a second, much smaller expression parser than the
	 * real one, and it shipped knowing only + and -. Everything added to it
	 * since has been in response to a wall; this completes the integer set so
	 * the remaining ones do not arrive one at a time.
	 *
	 * PRECEDENCE IS STILL ABSENT -- see the note in entry 2. `a | b & c`
	 * evaluates right to left here, which is wrong, and matters more now that
	 * there are operators of genuinely different precedence in the set. */
	else if(match("|", global_token->s))
	{
		require_extra_token();
		return lhs | constant_expression();
	}
	else if(match("&", global_token->s))
	{
		require_extra_token();
		return lhs & constant_expression();
	}
	else if(match("^", global_token->s))
	{
		require_extra_token();
		return lhs ^ constant_expression();
	}
	else if(match("<<", global_token->s))
	{
		require_extra_token();
		return lhs << constant_expression();
	}
	else if(match(">>", global_token->s))
	{
		require_extra_token();
		return lhs >> constant_expression();
	}
	else if(global_token->s[0] == '*')
	{
		require_extra_token();
		return lhs * constant_expression();
	}
	else if(global_token->s[0] == ',' || global_token->s[0] == ']' || global_token->s[0] == ';' || global_token->s[0] == '}' || global_token->s[0] == ':' || global_token->s[0] == ')')
	{
		/* ')' joins the terminator set for the grouping parens added to
		 * constant_expression_term: the inner expression has to be able to
		 * stop at its own closing paren. */
		return lhs;
	}

	line_error();
	fputs("Invalid token '", stderr);
	fputs(global_token->s, stderr);
	fputs("' used in constant expression.\n", stderr);
	exit(EXIT_FAILURE);
}

void expression(void);
void comma_expression(void);
void function_call(struct token_list* s, int is_function_pointer)
{
	require_match("ERROR in process_expression_list\nNo ( was found\n", "(");
	require(NULL != global_token, "Improper function call\n");

	emit_push(REGISTER_TEMP, "Protect temp register we are going to use");
	if((AARCH64 == Architecture) || (RISCV64 == Architecture) || (RISCV32 == Architecture))
	{
		emit_push(REGISTER_RETURN, "Protect the old return pointer (link)");
	}
	emit_push(REGISTER_BASE, "Protect the old base pointer");
	emit_push(REGISTER_LOCALS, "Protect the old locals pointer");

	/* Spill the function pointer to the stack instead of a register.
	 * On x86 REGISTER_TEMP2 is EDX, which is implicitly written by mul
	 * (used to scale array subscripts) when evaluating arguments. */
	if(is_function_pointer)
	{
		emit_push(REGISTER_ZERO, "Save function pointer on stack");
	}

	emit_move(REGISTER_TEMP, REGISTER_STACK, "Copy new base pointer");

	/* AN ARGUMENT LIST IS A SEPARATE EXPRESSION CONTEXT.
	 *
	 * A pending `*` is parked in num_dereference_after_postfix when the stars
	 * are eaten, for the postfix walk to apply once the chain is resolved. The
	 * argument list is parsed BETWEEN those two points, and every argument is
	 * a full expression that reads the same global -- so in `*give(8)` the
	 * star landed on the literal 8:
	 *
	 *     mov_rax, %8                  # primary expr number
	 *     movsx_rax,DWORD_PTR_[rax]    # dereferencing 8 as an address
	 *     push_rax                     # function argument
	 *
	 * and the call's result was never dereferenced at all. tcc writes every
	 * byte of .eh_frame through this shape -- tccdbg.c:550,
	 * `*(uint8_t*)section_ptr_add((s), 1) = (data)`. In a small program the
	 * bogus address is unmapped and it segfaults; inside tcc it is usually
	 * MAPPED, so the write silently lands on the wrong memory, an allocator
	 * node's `next` is overwritten, and the damage surfaces much later as
	 * "realloc: pointer was never returned by malloc".
	 *
	 * The count belongs to the expression that parked it, never to a
	 * sub-expression, so it is held here and the global is cleared for the
	 * duration of the list. Saving the CURRENT value rather than restoring a
	 * constant is what makes this safe on the paths that deliberately consume
	 * the count before reaching a call -- see the `CONSUMED HERE` note in
	 * primary_expr_variable. Those arrive with 0 and leave with 0.
	 *
	 * EXPERIMENT-zzzg restored it around the whole call instead and regressed
	 * mc-tcc from 12/12 to 0/12; the boundary that works is the argument list
	 * alone, which is the only region that must not see the count. */
	int pending_deref = num_dereference_after_postfix;
	num_dereference_after_postfix = 0;

	/* AND Address_of IS THE SAME HAZARD, THROUGH THE SAME DOOR.
	 *
	 * unary_expr sets Address_of when it sees a leading `&` and clears it
	 * when it does not -- so an ARGUMENT that begins with `&` leaves the
	 * flag TRUE, and nothing between here and the postfix walk clears it.
	 * postfix_expr_arrow then reads it:
	 *
	 *     ... && (TRUE != Address_of || chain_continues)
	 *
	 * and SKIPS THE LOAD, because a `&` at the end of a chain wants the
	 * address rather than the value. Measured, and the two lines differ
	 * only in the argument:
	 *
	 *     give(sp)->t     42          correct
	 *     give(&sym)->t   <address>   the offset is added, the load is not
	 *
	 * WHAT IT COST. tcc writes
	 *
	 *     #define pointed_type(t) (&(t)->ref->type)
	 *     ... (pointed_type(&p->type)->t & VT_BTYPE) == VT_VOID ...
	 *                                               tccgen.c:2807
	 *
	 * -- an argument that starts with `&`, then `->t` on the result. That
	 * expression is the THIRD clause of is_null_pointer, the one that
	 * recognises `(void*)0`, and it was reading an address where VT_VOID
	 * belongs. So mc-tcc accepted `(c ? 0 : s)->i` and rejected
	 * `(c ? (void*)0 : s)->i` -- which is tests2/33_ternary_op.c:37 and
	 * tcctest.c:4082, the file test1, test2 and test3 all begin with.
	 *
	 * It never faults. pointed_type is used throughout tccgen for every
	 * pointer comparison and every type merge, and each use quietly answers
	 * with a pointer value instead of a type flag.
	 *
	 * SAME BOUNDARY AS THE COUNT ABOVE, and for the same reason: the
	 * argument list is a separate expression context, and it is the only
	 * region that must not see the caller's flag. Saving the current value
	 * rather than restoring a constant keeps `&f(x)->m` working, where the
	 * caller really did ask for an address. */
	int pending_address_of = Address_of;
	Address_of = FALSE;

	/* TAKEN INTO A LOCAL BEFORE THE ARGUMENTS ARE PARSED. An argument may be
	 * `*other(3)`, which parks its own designator through the same global, so
	 * reading it after the list would take the innermost call's return type
	 * for the outermost call's result. */
	struct token_list* designator = pending_function_designator;
	pending_function_designator = NULL;

	int passed = 0;
	while(global_token->s[0] != ')')
	{
		expression();
		require(NULL != global_token, "incomplete function call, received EOF instead of )\n");
		emit_push(REGISTER_ZERO, "function argument");
		passed = passed + 1;

		if(global_token->s[0] == ',')
		{
			require_extra_token();
		}
	}

	num_dereference_after_postfix = pending_deref;
	Address_of = pending_address_of;

	require_match("ERROR in process_expression_list\nNo ) was found\n", ")");

	if(ARMV7L == Architecture)
	{
		emit_push(REGISTER_RETURN, "Protect the old link register");
	}

	emit_move(REGISTER_BASE, REGISTER_TEMP, "Set new base pointer");

	if(TRUE == is_function_pointer)
	{
		emit_load_relative_to_register(REGISTER_ZERO, REGISTER_TEMP, 0, "Address of saved function pointer");
		emit_dereference(REGISTER_ZERO, "Restore function pointer from stack");

		if(Architecture & ARCH_FAMILY_KNIGHT)
		{
			emit_out("CALL R0 R15\n");
		}
		else if(X86 == Architecture)
		{
			emit_out("call_eax\n");
		}
		else if(AMD64 == Architecture)
		{
			emit_out("call_rax\n");
		}
		else if(ARMV7L == Architecture)
		{
			emit_out("'3' R0 CALL_REG_ALWAYS\n");
			emit_pop(REGISTER_RETURN, "Prevent overwrite");
		}
		else if(AARCH64 == Architecture)
		{
			emit_move(REGISTER_TEMP, REGISTER_ZERO, "function pointer call");
			emit_out("blr_x16\n");
		}
		else if(Architecture & ARCH_FAMILY_RISCV)
		{
			emit_out("rd_ra rs1_a0 jalr\n");
		}
	}
	else
	{
		if(Architecture & ARCH_FAMILY_KNIGHT)
		{
			emit_load_named_immediate(REGISTER_ZERO, "FUNCTION_", s->s, "function call");
			emit_out("CALL R0 R15\n");
		}
		else if(Architecture & ARCH_FAMILY_X86)
		{
			emit_out("call %FUNCTION_");
			emit_out(s->s);
			emit_out("\n");
		}
		else if(ARMV7L == Architecture)
		{
			emit_out("^~FUNCTION_");
			emit_out(s->s);
			emit_out(" CALL_ALWAYS\n");
			emit_pop(REGISTER_RETURN, "Restore the old link register");
		}
		else if(AARCH64 == Architecture)
		{
			emit_load_named_immediate(REGISTER_TEMP, "FUNCTION_", s->s, "function call");
			emit_out("blr_x16\n");
		}
		else if(Architecture & ARCH_FAMILY_RISCV)
		{
			emit_out("rd_ra $FUNCTION_");
			emit_out(s->s);
			emit_out(" jal\n");
		}
	}

	if(passed > 0)
	{
		emit_move(REGISTER_STACK, REGISTER_BASE, "Clean up function arguments");
	}

	if(is_function_pointer)
	{
		emit_pop(REGISTER_ONE, "Discard saved function pointer slot");
	}

	emit_pop(REGISTER_LOCALS, "Restore old locals pointer");
	emit_pop(REGISTER_BASE, "Restore old base pointer");
	if((AARCH64 == Architecture) || (RISCV64 == Architecture) || (RISCV32 == Architecture))
	{
		emit_pop(REGISTER_RETURN, "Restore old return pointer (link)");
	}
	emit_pop(REGISTER_TEMP, "Restore temp register");

	/* THE RESULT HAS THE FUNCTION'S RETURN TYPE. Without this current_target
	 * kept whatever the last argument left behind, so a member access on a
	 * call's result looked the member up in the wrong type:
	 *     tok_alloc(str, strlen(str))->tok            tccpp.c:523
	 *     ERROR in lookup_member char*->tok does not exist
	 * -- `char*` being the type of `str`, the last thing evaluated. */
	if(NULL != s)
	{
		if(NULL != s->type)
		{
			current_target = s->type;
		}
	}
	else if(NULL != designator)
	{
		/* THE SAME RULE FOR THE INDIRECT PATH. Reached when a leading `*` sent
		 * the call through primary_expr_variable rather than primary_expr's
		 * direct fast path, so there was no symbol to pass. */
		if(NULL != designator->type)
		{
			current_target = designator->type;
		}
	}

	last_expr_was_call = TRUE;
}

char* load_value_signed(unsigned size)
{
	if(size == 1)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "LOAD8 R0 R0 0\n";
		else if(X86 == Architecture) return "movsx_eax,BYTE_PTR_[eax]\n";
		else if(AMD64 == Architecture) return "movsx_rax,BYTE_PTR_[rax]\n";
		else if(ARMV7L == Architecture) return "LOADS8 R0 LOAD R0 HALF_MEMORY\n";
		else if(AARCH64 == Architecture) return "ldrsb_x0,[x0]\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) return "rd_a0 rs1_a0 lb\n";
	}
	else if(size == 2)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "LOAD16 R0 R0 0\n";
		else if(X86 == Architecture) return "movsx_eax,WORD_PTR_[eax]\n";
		else if(AMD64 == Architecture) return "movsx_rax,WORD_PTR_[rax]\n";
		else if(ARMV7L == Architecture) return "LOADS16 R0 LOAD R0 HALF_MEMORY\n";
		else if(AARCH64 == Architecture) return "ldrsh_x0,[x0]\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) return "rd_a0 rs1_a0 lh\n";
	}
	else if(size == 4)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "LOAD R0 R0 0\n";
		else if(X86 == Architecture) return "mov_eax,[eax]\n";
		else if(AMD64 == Architecture) return "movsx_rax,DWORD_PTR_[rax]\n";
		else if(ARMV7L == Architecture) return "!0 R0 LOAD32 R0 MEMORY\n";
		/* A SIGNED FOUR-BYTE LOAD MUST SIGN-EXTEND, and `ldr w0` does not:
		 * it loads 32 bits and ZEROES the top half of x0. The three lines
		 * above already get this right -- amd64 uses movsx, riscv's lw
		 * sign-extends on rv64, armv7l is 32-bit throughout -- so aarch64
		 * was the one target where a negative int read back positive.
		 *
		 * It never showed while `int` was eight bytes: this branch was
		 * reachable only through int32_t, and micro-c-libc uses int32_t for
		 * struct fields it stores and loads and never COMPARES. A field
		 * written and read back keeps its bits either way; only a
		 * comparison notices the sign is gone. */
		else if(AARCH64 == Architecture) return "ldrsw_x0,[x0]\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) return "rd_a0 rs1_a0 lw\n";
	}
	else if(size == 8)
	{
		if(AMD64 == Architecture) return "mov_rax,[rax]\n";
		else if(AARCH64 == Architecture) return "ldr_x0,[x0]\n";
		else if(RISCV64 == Architecture) return "rd_a0 rs1_a0 ld\n";
	}
	line_error();
	fputs(" Got unsupported size ", stderr);
	fputs(int2str(size, 10, TRUE), stderr);
	fputs(" when trying to load value", stderr);
	fputs("\n  context: ", stderr);
	struct token_list* lctx = global_token;
	int lb = 0;
	while(lb < 8 && NULL != lctx->prev) { lctx = lctx->prev; lb = lb + 1; }
	while(lb > -6 && NULL != lctx) { fputs(lctx->s, stderr); fputs(" ", stderr); lctx = lctx->next; lb = lb - 1; }
	fputs("\n ", stderr);
	if(NULL != current_target)
	{
		fputs(" of type '", stderr);
		if(NULL != current_target->name) fputs(current_target->name, stderr);
		fputs("'", stderr);
	}
	if(NULL != global_token)
	{
		fputs(" at token '", stderr);
		fputs(global_token->s, stderr);
		fputs("'", stderr);
	}
	fputs(".\n", stderr);
	exit(EXIT_FAILURE);
}

char* load_value_unsigned(unsigned size)
{
	if(size == 1)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "LOADU8 R0 R0 0\n";
		else if(X86 == Architecture) return "movzx_eax,BYTE_PTR_[eax]\n";
		else if(AMD64 == Architecture) return "movzx_rax,BYTE_PTR_[rax]\n";
		else if(ARMV7L == Architecture) return "!0 R0 LOAD R0 MEMORY\n";
		else if(AARCH64 == Architecture) return "ldrb_w0,[x0]\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) return "rd_a0 rs1_a0 lbu\n";
	}
	else if(size == 2)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "LOADU16 R0 R0 0\n";
		else if(X86 == Architecture) return "movzx_eax,WORD_PTR_[eax]\n";
		else if(AMD64 == Architecture) return "movzx_rax,WORD_PTR_[rax]\n";
		else if(ARMV7L == Architecture) return "NO_OFFSET R0 LOAD R0 HALF_MEMORY\n";
		else if(AARCH64 == Architecture) return "ldrh_w0,[x0]\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) return "rd_a0 rs1_a0 lhu\n";
	}
	else if(size == 4)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "LOAD R0 R0 0\n";
		else if(X86 == Architecture) return "mov_eax,[eax]\n";
		else if(AMD64 == Architecture) return "mov_eax,[rax]\n";
		else if(ARMV7L == Architecture) return "!0 R0 LOAD32 R0 MEMORY\n";
		else if(AARCH64 == Architecture) return "ldr_w0,[x0]\n";
		else if(RISCV32 == Architecture) return "rd_a0 rs1_a0 lw\n";
		else if(RISCV64 == Architecture) return "rd_a0 rs1_a0 lwu\n";
	}
	else if(size == 8)
	{
		if(AMD64 == Architecture) return "mov_rax,[rax]\n";
		else if(AARCH64 == Architecture) return "ldr_x0,[x0]\n";
		else if(RISCV64 == Architecture) return "rd_a0 rs1_a0 ld\n";
	}
	line_error();
	fputs(" Got unsupported size ", stderr);
	fputs(int2str(size, 10, TRUE), stderr);
	fputs(" when trying to load value", stderr);
	if(NULL != current_target)
	{
		fputs(" of type '", stderr);
		if(NULL != current_target->name) fputs(current_target->name, stderr);
		fputs("'", stderr);
	}
	if(NULL != global_token)
	{
		fputs(" near token '", stderr);
		fputs(global_token->s, stderr);
		fputs("'", stderr);
	}
	fputs(".\n", stderr);
	exit(EXIT_FAILURE);
}

char* load_value(unsigned size, int is_signed)
{
	if(is_signed) return load_value_signed(size);
	return load_value_unsigned(size);
}

/* A CAST TO A NARROWER INTEGER DISCARDS THE HIGH BITS.
 *
 * micro-c treated a cast as a statement about TYPE alone: primary_expr set
 * current_target and emitted nothing. While `int` was eight bytes that was
 * correct by accident -- every integer cast was register-width to
 * register-width, so there was nothing to discard. EXPERIMENT-zzw made `int`
 * four bytes and the accident ended.
 *
 * tcc depends on it directly. arm64-gen.c:494 sign-extends a 32-bit local
 * offset by hand:
 *
 *     uint64_t svcul = (uint32_t)sv->c.i;
 *     svcul = svcul >> 31 & 1 ? svcul - ((uint64_t)1 << 32) : svcul;
 *
 * With the cast a no-op, `svcul` keeps all 64 bits of a negative offset, the
 * sign test still fires, and 2^32 is subtracted from a value that was never
 * truncated -- so every local offset comes out 2^32 too small.
 *
 * That is survivable in load()'s scalar path, which reaches arm64_ldrx and is
 * masked to nine bits by `(off & 511)`, and fatal in the `svr == VT_LOCAL`
 * path at :572, which puts the value straight into an instruction word with no
 * mask. Hence the exact split observed: scalars work, the address of a local
 * segfaults.
 *
 * ONLY INTEGERS. A pointer is register-width and needs nothing; a struct is
 * not held in a register at all; a function pointer is an address. Each is
 * excluded by name rather than left to fall out of the size test, because a
 * four-byte struct would otherwise be truncated as though it were an int. */
void emit_narrowing_cast(struct type* t)
{
	if(NULL == t) return;
	if(NULL != t->members) return;
	if(t->options & TO_FUNCTION_POINTER) return;
	if(0 == t->size) return;
	if(t->size >= register_size) return;

	if(AARCH64 == Architecture)
	{
		if(t->is_signed)
		{
			if(1 == t->size) emit_out("sxtb_x0,w0\n");
			else if(2 == t->size) emit_out("sxth_x0,w0\n");
			else if(4 == t->size) emit_out("sxtw_x0,w0\n");
		}
		else
		{
			if(1 == t->size) emit_out("uxtb_w0,w0\n");
			else if(2 == t->size) emit_out("uxth_w0,w0\n");
			else if(4 == t->size) emit_out("mov_w0,w0\n");
		}
	}
	else if(AMD64 == Architecture)
	{
		if(t->is_signed)
		{
			if(1 == t->size) emit_out("movsx_rax,al\n");
			else if(2 == t->size) emit_out("movsx_rax,ax\n");
			else if(4 == t->size) emit_out("movsx_rax,eax\n");
		}
		else
		{
			if(1 == t->size) emit_out("movzx_rax,al\n");
			else if(2 == t->size) emit_out("movzx_rax,ax\n");
			else if(4 == t->size) emit_out("mov_eax,eax\n");
		}
	}
}

char* store_value(unsigned size)
{
	if(size == 1)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "STORE8 R0 R1 0\n";
		else if(X86 == Architecture) return "mov_[ebx],al\n";
		else if(AMD64 == Architecture) return "mov_[rbx],al\n";
		else if(ARMV7L == Architecture) return "!0 R0 STORE8 R1 MEMORY\n";
		else if(AARCH64 == Architecture) return "strb_w0,[x1]\n";
		else if(RISCV32 == Architecture || RISCV64 == Architecture) return "rs1_a1 rs2_a0 sb\n";
	}
	else if(size == 2)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "STORE16 R0 R1 0\n";
		else if(X86 == Architecture) return "mov_[ebx],ax\n";
		else if(AMD64 == Architecture) return "mov_[rbx],ax\n";
		else if(ARMV7L == Architecture) return "NO_OFFSET R0 STORE16 R1 HALF_MEMORY\n";
		else if(AARCH64 == Architecture) return "strh_w0,[x1]\n";
		else if(RISCV32 == Architecture || RISCV64 == Architecture) return "rs1_a1 rs2_a0 sh\n";
	}
	else if(size == 4)
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "STORE R0 R1 0\n";
		else if(X86 == Architecture) return "mov_[ebx],eax\n";
		else if(AMD64 == Architecture) return "mov_[rbx],eax\n";
		else if(ARMV7L == Architecture) return "!0 R0 STORE32 R1 MEMORY\n";
		else if(AARCH64 == Architecture) return "str_w0,[x1]\n";
		else if(RISCV32 == Architecture || RISCV64 == Architecture) return "rs1_a1 rs2_a0 sw\n";
	}
	else if(size == 8)
	{
		if(AMD64 == Architecture) return "mov_[rbx],rax\n";
		else if(AARCH64 == Architecture) return "str_x0,[x1]\n";
		else if(RISCV64 == Architecture) return "rs1_a1 rs2_a0 sd\n";
	}
	/* Should not happen but print error message. */
	fputs("Got unsupported size ", stderr);
	fputs(int2str(size, 10, TRUE), stderr);
	fputs(" when storing number in register.\n", stderr);
	line_error();
	exit(EXIT_FAILURE);
}

int is_compound_assignment(char* token)
{
	if(match("+=", token)) return TRUE;
	else if(match("-=", token)) return TRUE;
	else if(match("*=", token)) return TRUE;
	else if(match("/=", token)) return TRUE;
	else if(match("%=", token)) return TRUE;
	else if(match("<<=", token)) return TRUE;
	else if(match(">>=", token)) return TRUE;
	else if(match("&=", token)) return TRUE;
	else if(match("^=", token)) return TRUE;
	else if(match("|=", token)) return TRUE;
	return FALSE;
}

void postfix_expr_stub(void);

/*
 * primary-expr:
 * FAILURE
 * "String"
 * 'Char'
 * [0-9]*
 * [a-z,A-Z]*
 * ( expression )
 */

void primary_expr_failure(void)
{
	require(NULL != global_token, "hit EOF when expecting primary expression\n");
	line_error();
	fputs("Received ", stderr);
	fputs(global_token->s, stderr);
	fputs(" in primary_expr\n", stderr);
	exit(EXIT_FAILURE);
}

struct string_list* strings;
char* add_string_to_string_list(char* str)
{
	struct string_list* s = strings;

	while (s != NULL)
	{
		if (match(str, s->string))
		{
			return s->name;
		}

		s = s->next;
	}

	s = calloc(1, sizeof(struct string_list));
	char* number_string = int2str(current_count, 10, TRUE);
	current_count = current_count + 1;
	s->name = create_unique_id("STRING_", function->s, number_string);
	s->string = str;
	s->next = strings;
	strings = s;

	strings_list = emit("\n", emit(s->name, emit(":", strings_list)));
	strings_list = emit(parse_string(str), strings_list);

	return s->name;
}

void primary_expr_string(void)
{
	/* catch case of just "foo" from segfaulting */
	require(NULL != global_token->next, "a string by itself is not valid C\n");

	char* s;

	/* Parse the string */
	if('"' != global_token->next->s[0])
	{
		s = global_token->s;
		require_extra_token();
	}
	else
	{
		s = calloc(MAX_STRING, sizeof(char));

		/* prefix leading string */
		s[0] = '"';
		int i = 1;

		int used_string_concatenation = FALSE;
		int j;
		while('"' == global_token->s[0])
		{
			if(used_string_concatenation) maybe_bootstrap_error("string literal concatenation");

			/* Step past the leading '"' */
			j = 1;

			/* Copy the rest of the string as is */
			while(0 != global_token->s[j])
			{
				require(i < MAX_STRING, "concat string exceeded max string length\n");
				s[i] = global_token->s[j];
				i = i + 1;
				j = j + 1;
			}

			/* Move on to the next token */
			require_extra_token();
			used_string_concatenation = TRUE;
		}
	}

	char* unique_id = add_string_to_string_list(s);

	emit_load_named_immediate(REGISTER_ZERO, "", unique_id, "primary expr string");

	/* A STRING LITERAL HAS A TYPE, AND IT IS `char*`.
	 *
	 * This left current_target alone, exactly as the integer literal did
	 * before the note below was written, so a literal inherited whatever type
	 * the previous expression happened to leave. Indexing one therefore used
	 * the DEFAULT element size -- eight -- and emitted
	 *
	 *     "abc"[1]     mov_x14,8 / mul_x0,x14,x0 / ldr_x0,[x0]
	 *     g[1]         add_x0,x1,x0             / ldrsb_x0,[x0]
	 *
	 * for the same access through a char* variable: the index scaled by eight
	 * and eight bytes loaded instead of one.
	 *
	 * tcc walks its path lists with
	 *
	 *     for (p = in; c = *p, c != '\0' && c != PATHSEP[0]; ++p)
	 *
	 * where PATHSEP is ":". PATHSEP[0] read eight bytes of the wrong place, so
	 * the separator was never recognised and tcc_split_path returned the whole
	 * colon-separated list as ONE path:
	 *
	 *     tried: /usr/lib/aarch64-linux-gnu:/usr/lib:/lib:...:/usr/local/lib/c
	 *
	 * The crt search survived only because CRTPREFIX is a single path with no
	 * separator in it. */
	current_target = character->indirect;
}

void primary_expr_char(void)
{
	emit_load_immediate(REGISTER_ZERO, escape_lookup(global_token->s + 1), "primary expr char");
	require_extra_token();
}

/* AN INTEGER LITERAL HAS A TYPE, AND IT IS `int`.
 *
 * This left current_target alone, so a literal inherited whatever type the
 * expression was carrying when it arrived. Harmless while nothing asked --
 * promote_type folds the two operands together anyway -- and fatal the moment
 * something does: in `q + 1` the literal reported itself as `long*`, so the
 * pointer-arithmetic rule below saw a pointer on BOTH sides, read the
 * expression as a pointer difference, and scaled nothing.
 *
 * Setting it is what C says and it is also the smaller lie: a leftover type is
 * wrong in a way that varies with context, which is the class of bug this
 * compiler keeps producing. */
/* A CONSTANT GETS THE FIRST TYPE IT FITS, AND THE BASE AND SUFFIX CHOOSE THE
 * LIST IT FITS INTO. C89 3.1.3.2:
 *
 *     decimal, no suffix     int, long, unsigned long
 *     hex/octal, no suffix   int, unsigned int, long, unsigned long
 *     u/U                    unsigned int, unsigned long
 *     l/L                    long, unsigned long
 *     u and l                unsigned long
 *
 * unsigned int is on two of those lists and absent from two, which is the
 * whole subtlety: 0x87654321 is unsigned int, 2271560481 is long, and
 * 0x87654321L is long. Everything used to be typed `integer` regardless, so an
 * int compared against any of them gave C's answer only by luck.
 *
 * The first version of this returned a yes/no for "is it unsigned int" and
 * checked only u/U, so it typed 0x87654321L as unsigned int and got the
 * OPPOSITE answer from C. uac-sweep.sh found that, and then found that UL was
 * wrong too. Returning the type rather than a flag is what makes the four
 * lists expressible at all. */
struct type* literal_type(char* s, long long v)
{
	int has_u = FALSE;
	int has_l = FALSE;
	int is_hex_or_octal = FALSE;
	int i = 0;

	while(0 != s[i])
	{
		if('u' == s[i]) has_u = TRUE;
		if('U' == s[i]) has_u = TRUE;
		if('l' == s[i]) has_l = TRUE;
		if('L' == s[i]) has_l = TRUE;
		i = i + 1;
	}

	if('0' == s[0])
	{
		if('x' == s[1]) is_hex_or_octal = TRUE;
		else if('X' == s[1]) is_hex_or_octal = TRUE;
		else if(0 != s[1]) is_hex_or_octal = TRUE;   /* octal */
	}

	/* A NEGATIVE VALUE HERE IS A LITERAL TOO BIG FOR long long, or the unary
	 * minus applied elsewhere; either way it is not an unsigned int. */
	if(v < 0) return signed_long;

	if(has_u && has_l) return unsigned_long;
	if(has_u)
	{
		if(v <= 4294967295) return unsigned_integer;
		return unsigned_long;
	}
	if(has_l) return signed_long;

	if(v <= 2147483647) return integer;
	if(is_hex_or_octal)
	{
		if(v <= 4294967295) return unsigned_integer;
	}
	return signed_long;
}

void primary_expr_number(char* s)
{
	long long v = strtolong(s);
	emit_load_immediate(REGISTER_ZERO, v, "primary expr number");
	current_target = literal_type(s, v);
}

/* IS THIS NAME A VARIABLE? Asked WITHOUT emitting anything.
 *
 * A DECLARATION SHADOWS AN ENUM CONSTANT, and this compiler did not know it:
 *
 *     enum { V = 7 };
 *     int main(void) { int V; V = 2; return V; }
 *
 * The constant list was consulted before any variable list, so `V` resolved to
 * the literal 7 -- and `V = 2` then STORED THROUGH THE CONSTANT 7 as if it
 * were an address. SIGSEGV, on eight lines of legal C that pico-c compiles.
 *
 * The lookups below are the same ones, in the same order, that
 * load_address_of_variable_into_register performs; this one only reports
 * whether they would find anything, so the decision can be made before either
 * path emits. `function` is NULL at file scope, which is exactly where an enum
 * constant SHOULD win, and is checked rather than assumed. */
int name_is_a_variable(char* s)
{
	if(NULL != static_variable_lookup(s)) return TRUE;
	if(NULL != function)
	{
		if(NULL != sym_lookup(s, function->locals)) return TRUE;
		if(NULL != sym_lookup(s, function->arguments)) return TRUE;
	}
	if(NULL != sym_lookup(s, global_symbol_list)) return TRUE;
	return FALSE;
}

struct token_list* load_address_of_variable_into_register(int reg, char* s)
{
	struct token_list* variable = static_variable_lookup(s);
	if(NULL != variable)
	{
		current_target = variable->type;
		emit_load_named_immediate(reg, "GLOBAL_", variable->s, "global load");
		return variable;
	}

	variable = sym_lookup(s, function->locals);
	if(NULL != variable)
	{
		current_target = variable->type;
		emit_load_relative_to_register(reg, REGISTER_LOCALS, variable->depth, "local variable load");

		return variable;
	}

	variable = sym_lookup(s, function->arguments);
	if(NULL != variable)
	{
		current_target = variable->type;
		emit_load_relative_to_register(reg, REGISTER_BASE, variable->depth, "function argument load");

		return variable;
	}

	variable = sym_lookup(s, global_function_list);
	if(NULL != variable)
	{
		/* REMEMBER THE DESIGNATOR IF A CALL FOLLOWS, so the result can carry
		 * the RETURN type.
		 *
		 * primary_expr has a fast path that calls function_call(variable,
		 * FALSE) with the symbol in hand, and function_call uses it to set
		 * current_target at the end. Under a leading `*` that path does not
		 * match -- it tests global_token->s, which is `*` -- so the call
		 * arrives here instead and goes out through function_call(NULL, TRUE)
		 * with no symbol at all. The result then kept the generic
		 * function_pointer type set below, and the dereference that follows
		 * read at the WRONG WIDTH:
		 *
		 *     unsigned char* give(int);
		 *     *give(8)      ->  movsx_rax,DWORD_PTR_[rax]    four bytes, signed
		 *                       wanted movzx_rax,BYTE_PTR_[rax]
		 *
		 * That is a silent wrong VALUE, not a fault, and it hides: the four
		 * bytes after a correct one are usually zero, so the wrong load
		 * returns the right answer and a case built from that form certifies
		 * a broken compiler.
		 *
		 * ONLY WHEN A '(' FOLLOWS. The name has already been consumed, so
		 * global_token is the token after it. Without this guard a designator
		 * used as a VALUE -- `p = give;` -- would leave a symbol parked here
		 * for whatever indirect call came next to pick up. */
		if(NULL != global_token)
		{
			if(global_token->s[0] == '(') pending_function_designator = variable;
		}
		emit_load_named_immediate(REGISTER_ZERO, "FUNCTION_", variable->s, "function load");
		/* A FUNCTION DESIGNATOR USED AS A VALUE IS A FUNCTION POINTER. The
		 * address was already being loaded here, but current_target was left
		 * alone -- unlike the global branch below -- so the result carried
		 * whatever type happened to be current. Calling through it then failed:
		 *     tcc_warning_c(warn_all)("#pragma %s ignored", ...)   tccpp.c:1781
		 *     Attempted to use operator ( on non-function pointer -- type 'int'
		 * because tcc_warning_c expands to `(..., _tcc_warning)` and the call
		 * applies to that result. */
		current_target = function_pointer;
		return variable;
	}

	variable = sym_lookup(s, global_symbol_list);
	if(NULL != variable)
	{
		current_target = variable->type;
		emit_load_named_immediate(reg, "GLOBAL_", variable->s, "global load");
		return variable;
	}

	/* AN UNKNOWN NAME FOLLOWED BY '(' IS AN IMPLICIT FUNCTION DECLARATION.
	 *
	 * C89 6.3.2.2: a call to an undeclared identifier declares it as a
	 * function returning int with external linkage. micro-c rejected it, so
	 * mutual recursion could not be written in its natural order --
	 *
	 *     int ev(int n){ if(n) return od(n-1); return 1; }
	 *     int od(int n){ if(n) return ev(n-1); return 0; }
	 *
	 * -- failed with "od is not a defined symbol" at the first function,
	 * because od is not seen until the second. That is stage 2 corpus row 118.
	 *
	 * ONLY WHEN A '(' FOLLOWS, which is the same guard the function-designator
	 * branch above uses and for the same reason: a bare unknown NAME is still
	 * a typo and must still be an error here, where it is cheap to say so.
	 * With the guard, the only thing this accepts is a call, and a call to a
	 * name that genuinely does not exist still fails -- at link time, from
	 * hex2, as "Target label FUNCTION_od is not valid". Later and less
	 * precise, which is the trade C makes too.
	 *
	 * The symbol is minted rather than looked up, so the call path downstream
	 * finds it exactly as it would a real forward declaration. */
	if(NULL != global_token)
	{
		if(global_token->s[0] == '(')
		{
			struct token_list* implicit = sym_declare(s, integer, global_function_list, TLO_FUNCTION);
			global_function_list = implicit;
			pending_function_designator = implicit;
			emit_load_named_immediate(REGISTER_ZERO, "FUNCTION_", s, "implicit function load");
			current_target = function_pointer;
			return implicit;
		}
	}

	line_error();
	fputs(s ,stderr);
	fputs(" is not a defined symbol\n", stderr);
	exit(EXIT_FAILURE);
}

void emit_va_start_intrinsic(void)
{
	emit_out("# __va_start intrinsic\n");
	require_match("Invalid token after __va_start, expected '('", "(");

	require_token();
	char* ap_name = global_token->s;

	require_extra_token();

	require_match("Invalid token in __va_start, expected ','", ",");

	require_token();
	char* variable_name = global_token->s;
	require_extra_token();

	require_match("Invalid token at end of __va_start, expected ')'", ")");

	struct token_list* loaded = load_address_of_variable_into_register(REGISTER_ZERO, variable_name);
	if(stack_direction == STACK_DIRECTION_PLUS)
	{
		emit_add_immediate(REGISTER_ZERO, loaded->type->size, "Add size of variable");
	}
	else
	{
		emit_sub_immediate(REGISTER_ZERO, loaded->type->size, "Subtract size of variable");
	}

	load_address_of_variable_into_register(REGISTER_ONE, ap_name);

	/* Store REGISTER_ZERO in REGISTER_ONE deref */
	emit_out(store_value(register_size));
	emit_out("# __va_start intrinsic end\n");
}

void emit_va_arg_intrinsic(void)
{
	emit_out("# __va_arg intrinsic\n");
	require_match("Invalid token after __va_arg, expected '('", "(");

	require_token();
	char* ap_name = global_token->s;

	require_extra_token();

	require_match("Invalid token in __va_arg, expected ','", ",");

	require_token();
	struct type* type_size = type_name();

	require_match("Invalid token at end of __va_start, expected ')'", ")");

	emit_out("# REGISTER_ZERO = *ap\n");
	load_address_of_variable_into_register(REGISTER_ZERO, ap_name);
	emit_dereference(REGISTER_ZERO, "Deref ap");
	emit_dereference(REGISTER_ZERO, "Deref ap");
	emit_push(REGISTER_ZERO, "Dereffed va_arg");

	/* A VARARG SLOT IS A REGISTER, NOT A sizeof.
	 *
	 * The READ above is at the type's width and that is right. The STRIDE is
	 * not: every variadic argument occupies a full register-width slot on
	 * this ABI, whatever its declared type, so advancing by sizeof(ty) lands
	 * mid-slot for anything narrower.
	 *
	 * While `int` was eight bytes this was invisible -- int, long and every
	 * pointer were all register-width, and the only narrower types anyone
	 * passed variadically were promoted anyway. At four bytes the first %d
	 * desynchronises everything after it:
	 *
	 *     snprintf(b, 64, "%d %d", 1, 2)     returns 12, glibc returns 3
	 *     snprintf(b, 64, "%s%d%s", ...)     SIGSEGV -- third arg is garbage
	 *     snprintf(b, 64, "%s%s%s", ...)     correct, char* is register-width
	 *
	 * tcc's pp_error formats "%s:%d: ..." and every diagnostic it tried to
	 * print came out corrupt, which is what sent cstr_vprintf into a loop and
	 * hung the compiler.
	 *
	 * A type WIDER than a register keeps its own size, so a struct passed by
	 * value still advances by its own width. */
	int slot_size = type_size->size;
	if(slot_size < register_size)
	{
		slot_size = register_size;
	}
	emit_out("# ap = ap - slot\n");
	load_address_of_variable_into_register(REGISTER_ZERO, ap_name);
	emit_push(REGISTER_ZERO, "Push ap address");
	emit_dereference(REGISTER_ZERO, "Deref ap for pointer to va_arg");
	if(stack_direction == STACK_DIRECTION_PLUS)
	{
		emit_add_immediate(REGISTER_ZERO, slot_size, "Add slot size");
	}
	else
	{
		emit_sub_immediate(REGISTER_ZERO, slot_size, "Subtract slot size");
	}

	emit_pop(REGISTER_ONE, "Pop AP address");
	/* Store REGISTER_ZERO in REGISTER_ONE deref */
	emit_out(store_value(type_size->size));

	emit_pop(REGISTER_ZERO, "Dereffed va_arg");

	emit_out("# __va_arg intrinsic end\n");
}

void emit_va_end_intrinsic(void)
{
	/* va_end is a noop for our impl */
	require_match("Invalid token after __va_arg, expected '('", "(");
	require_extra_token();
	require_match("Invalid token at end of __va_start, expected ')'", ")");
}

void primary_expr_variable(void)
{
	/* THE TOKEN THIS UNARY EXPRESSION STARTS AT, remembered before the stars
	 * are eaten. Everything below that wants to know what OPERATOR this
	 * expression is the operand of has to look here: once the loop has run,
	 * the tokens behind the identifier are the stars, not the operator. */
	struct token_list* unary_start = global_token;
	last_expr_was_address_of = FALSE;

	int num_dereference = 0;
	while(global_token->s[0] == '*') {
		require_extra_token();
		num_dereference = num_dereference + 1;
	}
	num_dereference_after_postfix = num_dereference;


	/* IS THIS THE OPERAND OF A PREFIX ++ / -- ?
	 *
	 * `++*p` is `++(*p)`: an LVALUE. The increment wants the address the
	 * pointer holds, so the dereference chain must stop one load short --
	 * which is exactly the rule the assignment paths already carry, under the
	 * name `assigning`.
	 *
	 * The existing test for this looks two tokens back from the IDENTIFIER.
	 * That is the `++` for `++p` and the `*` for `++*p`, so the entire
	 * through-a-dereference class was invisible: the compiler took the
	 * ordinary rvalue path, loaded one level too far, and then incremented the
	 * pointed-AT object instead of the pointer. It is the same mistake in both
	 * directions -- `(*p)++` reads the `++` correctly because it sits after
	 * the expression, where nothing has been consumed.
	 *
	 * tcc's TOK_GET macro (tccpp.c:1245) is `++*(p)` and runs for every token
	 * tcc reads. */
	int prefix_lvalue = FALSE;
	if(NULL != unary_start->prev)
	{
		prefix_lvalue = match("++", unary_start->prev->s) || match("--", unary_start->prev->s);
	}

	/* A PREFIX ++/-- UNDER A DEREFERENCE: `*++file->buf_ptr`, tccpp.c:673,
	 * which is `*(++(file->buf_ptr))`. The stars are consumed above and this
	 * function then expects an identifier, so it died on "++ is not a defined
	 * symbol". primary_expr already has the prefix handler and it already
	 * calls postfix_expr, so delegate and apply the dereference after --
	 * the same shape used for a parenthesised operand. */
	if(NULL != global_token)
	{
		if(match("++", global_token->s) || match("--", global_token->s))
		{
			primary_expr();
			int fp_pd;
			int assigning_pd = match("=", global_token->s) || is_compound_assignment(global_token->s);
			while(num_dereference > 0)
			{
				fp_pd = current_target->type == current_target->type->type && (current_target->type->options & TO_FUNCTION_POINTER);
				if(!fp_pd)
				{
					if(!assigning_pd)
					{
						current_target = current_target->type;
						/* A STRUCT IS NEVER LOADED INTO A REGISTER. Dereferencing a
						 * struct pointer yields its ADDRESS, which is what every
						 * other struct path already assumes -- member access has
						 * had this guard all along. Without it `x = *p` for a
						 * struct tried load_value(16):
						 *     unsupported size 16 of type 'CType'   tccgen.c:895 */
						if(register_size >= current_target->size) emit_out(load_value(current_target->size, current_target->is_signed));
					}
					else
					{
						/* THE LAST DEREFERENCE OF AN ASSIGNMENT TARGET IS NOT A
						 * LOAD -- and this branch emitted one anyway.
						 *
						 * The comment above says the chain "must stop one load
						 * short" when assigning. It did not: both branches
						 * loaded and differed only in whether current_target
						 * was stepped before or after. So `*--p = v` computed
						 * the address, LOADED the byte at it, and stored
						 * through that byte as if it were a pointer.
						 *
						 *     return *--file->buf_ptr = '\\';   tccpp.c
						 *
						 * That line runs only when the lexer meets a stray
						 * backslash, so every string literal containing an
						 * ESCAPE crashed and every string without one was
						 * fine. tcctest.c reaches it at line 156, the first
						 * "...\n..." in the file; the 155 lines before it
						 * compile clean.
						 *
						 * Only the LAST dereference is spared: `**pp = v`
						 * still has to load once to reach the inner pointer.
						 * Same rule as EXPERIMENT-zzc, zzg and zzm -- an
						 * address applies to the last step of a chain, never
						 * to a step that still has to be followed. */
						if(num_dereference > 1)
						{
							if(register_size >= current_target->size) emit_out(load_value(current_target->size, current_target->is_signed));
						}
						current_target = current_target->type;
					}
				}
				num_dereference = num_dereference - 1;
			}
			num_dereference_after_postfix = 0;
			return;
		}
	}

	struct type* cast_type = NULL;
	if(global_token->s[0] == '(')
	{
		/* IS THIS A CAST, OR JUST PARENTHESES? `*(p)++` is a dereference of a
		 * parenthesised expression, not a cast -- but this called type_name(),
		 * which HARD-ERRORS on a non-type, so `*(p)++` died as
		 * "Unknown type p". tcc reaches it through dwarf_read_1:
		 *     #define dwarf_read_1(ln,end) ((ln) < (end) ? *(ln)++ : 0)
		 *
		 * fallible_type_name() exists for exactly this and returns NULL rather
		 * than exiting. Save the cursor, try, and put it back when it is not a
		 * type -- then the ordinary expression path handles the parens. */
		struct token_list* before_paren = global_token;
		require_extra_token();

		cast_type = fallible_type_name();

		if(NULL == cast_type)
		{
			/* Not a cast -- a parenthesised expression under a dereference,
			 * `*(p)++`. primary_expr already handles that case correctly
			 * (fallible_type_name, then expression()); this path simply never
			 * reached it. Rewind and hand it over, keeping the dereference
			 * count we already consumed. */
			/* Not a cast: a parenthesised expression under a dereference,
			 * `*(p)++`, which tcc reaches through
			 *     #define dwarf_read_1(ln,end) ((ln) < (end) ? *(ln)++ : 0)
			 *
			 * primary_expr parses the parens; the dereference must then use the
			 * SAME sequence the ordinary path uses -- step current_target DOWN
			 * first, then load at that type's width. Loading before stepping is
			 * what made `*(p)` on a char* emit an 8-byte read where `*p`
			 * correctly emits ldrsb. */
			global_token = before_paren;
			primary_expr();
			/* AND IT MAY BE AN LVALUE, in which case the LAST dereference
			 * yields an address and must not load.
			 *
			 *     ++*(p)     tcc's TOK_GET, tccpp.c:1245
			 *     (*p)++     the same thing written the other way round
			 *
			 * prefix_lvalue was read from the token in front of the stars; a
			 * postfix ++/-- is read from the token in front of us right now,
			 * because primary_expr has just consumed the parenthesised part
			 * and left the cursor exactly there.
			 *
			 * The type still steps down for that level -- it is the LOAD that
			 * is skipped, not the dereference. Getting that half wrong is what
			 * made the increment scale by the pointer's own width instead of
			 * its element's. */
			/* A POSTFIX ++/-- OWNS THE PARENTHESES, AND THE STAR COMES AFTER IT.
			 *
			 * `*(p)++` is `*((p)++)` -- postfix binds tighter than unary `*` --
			 * so the increment applies to p and the dereference applies to the
			 * value the increment RETURNED. That is precisely what `*p++` does,
			 * and the postfix handler already does it: it increments, then
			 * applies whatever num_dereference_after_postfix is still carrying.
			 *
			 * This branch was doing neither half. It walked the dereference
			 * HERE, before the increment, and then cleared the count -- so the
			 * postfix handler received p's VALUE where it expects an address,
			 * incremented the byte at it, and never dereferenced anything:
			 *
			 *     c = *(p)++;   c == 8 correct, p unmoved, buf[8] == 9
			 *
			 * which is `(*p)++` -- a different program. So hand the star on
			 * rather than spending it: return with the count intact and let the
			 * one handler that knows the right order do both. primary_expr has
			 * already left p's ADDRESS, because assign_after_parens now treats a
			 * following postfix as a target regardless of pending stars.
			 *
			 * paren_lvalue below is untouched and still covers the OTHER
			 * spelling, `(*p)++`, where the parentheses are around the
			 * dereference and the increment really does apply to it. */
			if(NULL != global_token)
			{
				if(match("++", global_token->s) || match("--", global_token->s))
				{
					return;
				}
			}

			int paren_lvalue = prefix_lvalue;
			if(NULL != global_token)
			{
				/* AND AN ASSIGNMENT TARGET, which is the same rule again and
				 * the eighth place in this file to carry its own copy of it.
				 * `*(t) = 7` loaded through the pointer and stored at the
				 * VALUE it found; `*t = 7`, four characters shorter, has been
				 * correct all along. tcc writes the parenthesised form because
				 * TOK_GET is a macro and `*(t)` is how you write it safely. */
				if(match("=", global_token->s) || is_compound_assignment(global_token->s)) paren_lvalue = TRUE;
			}
			/* `*(&x)` IS `x`, AND THE TYPE HAS TO SAY SO.
			 *
			 * `&x` reports x's own type rather than a pointer to it -- see
			 * last_expr_was_address_of. So this dereference must NOT step the
			 * type down: there is no level to give back. It still loads, or
			 * not, exactly as it would otherwise; only the type is left where
			 * it was.
			 *
			 * That one level is the whole of tcc's remaining fault. TOK_GET
			 * is `++*(p)` and is reached as `TOK_GET(&t, &macro_str, &cval)`,
			 * so after substitution the expression is literally `++*(&x)`.
			 * The address was right all along; the increment was adding ONE
			 * because the type had fallen from `int*` to `int`. */
			int cancels_address_of = last_expr_was_address_of;
			/* THE FIRST APPLICATION IS THE ONE THAT CANCELS THE `&`, not the
			 * last. `**(&x)` steps twice: the first turns the address back
			 * into x, the second is a real dereference. Keying this off
			 * `1 == num_dereference` -- the loop's LAST iteration -- is right
			 * only when there is exactly one star, which is why `++*(&x)` came
			 * out correct and tcc, which writes `**(p)` in the same macro, did
			 * not move at all. */
			int outermost = num_dereference;
			int fp_no_deref;
			while(num_dereference > 0)
			{
				fp_no_deref = current_target->type == current_target->type->type && (current_target->type->options & TO_FUNCTION_POINTER);
				if(!fp_no_deref)
				{
					if(!(cancels_address_of && (outermost == num_dereference)))
					{
						current_target = current_target->type;
					}
					/* A STRUCT IS NEVER LOADED INTO A REGISTER. Dereferencing a
						 * struct pointer yields its ADDRESS, which is what every
						 * other struct path already assumes -- member access has
						 * had this guard all along. Without it `x = *p` for a
						 * struct tried load_value(16):
						 *     unsupported size 16 of type 'CType'   tccgen.c:895 */
						if(!(paren_lvalue && (1 == num_dereference)))
						{
							if(register_size >= current_target->size) emit_out(load_value(current_target->size, current_target->is_signed));
						}
				}
				num_dereference = num_dereference - 1;
			}
			num_dereference_after_postfix = 0;
			return;
		}
		require_match("Expected token ')' in type cast.\n", ")");

		/* A CAST WHOSE OPERAND IS PARENTHESISED, under a dereference:
		 *     *(nwchar_t *)(cstr->data + size - sizeof(nwchar_t)) = ch;
		 * tccpp.c:390. After the cast the code below expects an identifier and
		 * found '(' -- "( is not a defined symbol". Same delegation the
		 * no-cast branch above uses, with the cast type applied to the result
		 * before the dereference walk, because that is what the cast means. */
		if(NULL != global_token)
		{
			if(global_token->s[0] == '(')
			{
				primary_expr();
				current_target = cast_type;

				/* AN ASSIGNMENT TARGET MUST NOT BE LOADED -- the tenth copy of
				 * one rule, and the one that kept every wide literal broken.
				 *
				 * This loop loaded unconditionally, so
				 *
				 *     *(int*)(p + 4) = 7;
				 *
				 * computed the address, LOADED the int sitting there, and then
				 * stored through that value as if it were an address. The read
				 * form `x = *(int*)(p + 4)` was correct, and so was
				 * `*(int*)p = 7` without the parentheses -- only this branch,
				 * only when assigning.
				 *
				 * tcc writes EVERY WIDE CHARACTER through exactly this shape:
				 *
				 *     *(nwchar_t *)(cstr->data + size - sizeof(nwchar_t)) = ch;
				 *                                              tccpp.c:390
				 *
				 * so mc-tcc segfaulted on L'a', L'\x1234' and L"abc" -- which
				 * is where tcctest.c's string_test() stops, and tcctest.c is
				 * the first thing tcc's own test1, test2 and test3 compile.
				 *
				 * ONLY THE LAST LEVEL IS SPARED. `**(p) = v` still has to load
				 * once to reach the inner pointer. Same rule as zzc, zzg, zzm,
				 * zzo and zzzh: an address applies to the last step of a chain,
				 * never to a step that still has to be followed. The type is
				 * stepped either way, because the STORE takes its width from
				 * it. */
				int assigning_cast = match("=", global_token->s)
				                     || is_compound_assignment(global_token->s);
				int fp_nd;
				while(num_dereference > 0)
				{
					fp_nd = current_target->type == current_target->type->type && (current_target->type->options & TO_FUNCTION_POINTER);
					if(!fp_nd)
					{
						current_target = current_target->type;
						/* A STRUCT IS NEVER LOADED INTO A REGISTER. Dereferencing a
						 * struct pointer yields its ADDRESS, which is what every
						 * other struct path already assumes -- member access has
						 * had this guard all along. Without it `x = *p` for a
						 * struct tried load_value(16):
						 *     unsupported size 16 of type 'CType'   tccgen.c:895 */
						if(!(assigning_cast && (1 == num_dereference)))
						{
							if(register_size >= current_target->size) emit_out(load_value(current_target->size, current_target->is_signed));
						}
					}
					num_dereference = num_dereference - 1;
				}
				num_dereference_after_postfix = 0;
				return;
			}
		}
	}

	char* s = global_token->s;
	require_extra_token();

	if(match("__va_start", s))
	{
		emit_va_start_intrinsic();
		return;
	}
	else if(match("__va_arg", s))
	{
		emit_va_arg_intrinsic();
		return;
	}
	else if(match("__va_end", s))
	{
		emit_va_end_intrinsic();
		return;
	}
	else if(match("__va_copy", s))
	{
		emit_va_end_intrinsic();
		return;
	}

	/* A VARIABLE OF THE SAME NAME WINS -- see name_is_a_variable above. */
	struct token_list* a = sym_lookup(s, global_constant_list);
	if(NULL != a && !name_is_a_variable(s))
	{
		emit_load_immediate(REGISTER_ZERO, strtolong(a->arguments->s), "constant load");
		return;
	}

	struct token_list* type = load_address_of_variable_into_register(REGISTER_ZERO, s);

	/* A CAST APPLIES AFTER THE POSTFIX, HERE TOO. primary_expr's cast branch
	 * learned this at tccgen.c:281; this is the same rule in the dereference
	 * path, which kept its own copy:
	 *     #define dwarf_data1(s,data) \
	 *         (*(uint8_t*)section_ptr_add((s), 1) = (data))   tccdbg.c:551
	 * Applying the cast before the '(' made postfix_expr_stub see a call on
	 * `uint8_t*` and refuse it as a non-function-pointer. Defer whenever a
	 * postfix operator follows. */
	int cast_deferred = 0;
	if(cast_type != NULL)
	{
		if(match("(", global_token->s) || match("->", global_token->s) ||
		   match(".", global_token->s) || match("[", global_token->s))
		{
			cast_deferred = 1;
		}
		else
		{
			current_target = cast_type;
		}
	}

	/* WHICH KIND OF THING IS BEING INDEXED, DECIDED BEFORE ANYONE RETURNS.
	 *
	 * These four lines used to sit BELOW the Address_of branch, among the
	 * is_* declarations. Address_of returns before reaching them, so `&a[i]`
	 * left indexing_an_array unset and postfix_expr_array fell through to its
	 * default: scale by current_target->type->size, the size of what a
	 * POINTER points at, rather than ->size, the size of an ARRAY element.
	 *
	 * For `TokenSym *hash_ident[16384]` those are sizeof(TokenSym) against
	 * sizeof(TokenSym*) -- about eight to one. With h masked to 16383,
	 * &hash_ident[h] landed roughly a megabyte past a 128 KB array and
	 * `ts = *pts` read unmapped memory. That is the tok_alloc fault.
	 *
	 * A SECOND COPY INSIDE THE BRANCH WOULD ALSO HAVE WORKED, and would have
	 * been the fourth place in this file carrying one rule. Moving the single
	 * copy above the branch means both paths run it and there is still only
	 * one. It also reaches the deferred-cast path below, which calls
	 * postfix_expr_stub -- and so possibly postfix_expr_array -- at a point
	 * where the flag had not been set at all.
	 *
	 * type->options rather than options: the local is declared after the
	 * branch, and this now runs before it. */
	if(match("[", global_token->s))
	{
		indexing_an_array = (type->options & TLO_LOCAL_ARRAY) != 0;
		if(type->array_modifier > 1) indexing_an_array = TRUE;
	}

	if(TRUE == Address_of)
	{
		/* `&s->member` STILL HAS TO LOAD s.
		 *
		 * Returning here leaves REGISTER_ZERO holding the address of the SLOT
		 * that stores s, and postfix_expr_arrow then adds the member offset to
		 * THAT -- addressing a place on the stack rather than inside the
		 * struct. tcc reaches it through
		 *     tcc_set_lib_path -> tcc_set_str(&s->tcc_lib_path, path)
		 * and the garbage pointer segfaults on the first *pp.
		 *
		 * `&s.member` is different and was always right: a struct variable's
		 * slot IS its address, so no load belongs there. Only the arrow form
		 * needs one.
		 *
		 * The member's own value must still not be loaded -- that is what the
		 * caller asked to take the address OF -- and postfix_expr_arrow
		 * already skips it while Address_of is set. */
		if(match("->", global_token->s))
		{
			emit_out(load_value(register_size, FALSE));
		}

		/* AND THE BASE ITSELF. A global array's symbol is a POINTER CELL, not
		 * the storage: `static long g[4]` emits a cell holding the address of
		 * the data, so every access dereferences it first. The ordinary path
		 * does that at the bottom of this function, guarded by !is_local_array;
		 * returning here skipped it, and &g[i] added the index to the address
		 * of the CELL.
		 *
		 * A LOCAL array is the opposite -- its storage is inline on the stack,
		 * the slot IS the data, no load belongs there -- which is why the two
		 * difftest cases disagreed. A pointer VARIABLE needs the load for the
		 * same reason a global array does, so the test is not "is it global"
		 * but the one the ordinary path already uses. */
		if(match("[", global_token->s) && !(type->options & TLO_LOCAL_ARRAY))
		{
			emit_out(load_value(register_size, FALSE));
		}
		last_expr_was_address_of = TRUE;
		return;
	}

	int options = type->options;

	if(match(".", global_token->s) || match("->", global_token->s) ||
	   match("[", global_token->s) || match("(", global_token->s))
	{
		if(cast_deferred)
		{
			postfix_expr_stub();
			current_target = cast_type;
			return;
		}
	}

	if(match(".", global_token->s))
	{
		postfix_expr_stub();
		return;
	}

	/* `++` AND `--` ON A GLOBAL OR STATIC.
	 *
	 * Upstream excludes them here, and the exclusion is not a guard against
	 * anything -- it makes the variable fall through to the ordinary path,
	 * which LOADS its value. The ++ handling then treats that value as an
	 * address and stores through it. `tok_ident++` at tccpp.c:480 segfaults,
	 * and so does a bare `n++` on any global.
	 *
	 * A local works because is_postfix_operator returns the ADDRESS without
	 * loading, which is what ++ needs. A global scalar's symbol is already the
	 * address of its value -- `lea_rax,[rip] %GLOBAL_n` -- so the same
	 * treatment is correct for it.
	 *
	 * M2-Planet's own sources never increment a global, which is why this
	 * could sit here. tcc does it constantly. */
	int is_prefix_operator = prefix_lvalue;
	int is_postfix_operator = match("++", global_token->s) || match("--", global_token->s);

	/* `->` IS THE ONE THAT NEEDS THE VALUE. `--s.n` on a struct variable is
	 * fine returning the address unloaded, because `&s + offset` IS the
	 * member; `--p->n` is not, because `&p + offset` is the stack slot after
	 * p. Only the pointer form is redirected, so the dot and index paths --
	 * both of which have cases behind them -- are untouched. */
	if(is_prefix_operator && match("->", global_token->s))
	{
		/* THE ARROW FORM NEEDS THE VARIABLE LOADED, and that is the only thing
		 * decided here now. `&s + offset` IS the member for a dot; `&p +
		 * offset` is the stack slot after p for an arrow, so the pointer has
		 * to be fetched first.
		 *
		 * Telling the chain's last step that it is the lvalue is NOT done
		 * here -- see the prefix handler in primary_expr. It was, and a struct
		 * variable returns from this function before ever reaching this line,
		 * which is why the dot form went unfixed for a round. */
		is_prefix_operator = FALSE;
	}
	int is_indexed_local_array = match("[", global_token->s) && (options & TLO_LOCAL_ARRAY);
	int is_local_array = (options & TLO_LOCAL_ARRAY) != 0;
	int is_function = options & TLO_FUNCTION;

	if(is_prefix_operator || is_postfix_operator || is_indexed_local_array || is_function)
	{
		return;
	}

	int is_assignment = match("=", global_token->s);
	int is_compound_operator = is_compound_assignment(global_token->s);

	/* AND A PARENTHESISED TARGET IS ONE TOO. `(*p)++` is an lvalue: the
	 * parentheses are around the DEREFERENCE, so the increment applies to what
	 * p points at and the last dereference must yield an ADDRESS.
	 *
	 * Both flags above read the NEXT TOKEN, which here is `)`, so this took
	 * the rvalue branch, loaded the byte, and the postfix handler then
	 * dereferenced that value as if it were an address:
	 *
	 *     mov_rax,[rax]              p
	 *     movzx_rax,BYTE_PTR_[rax]   the byte -- 0
	 *     # postfix inc/dec
	 *     movzx_rax,BYTE_PTR_[rax]   dereference 0        SIGSEGV
	 *
	 * assign_through_parens is already set by primary_expr's paren branch when
	 * an assignment or a postfix ++/-- follows the closing paren; it had not
	 * reached this decision.
	 *
	 * ONLY WHEN `)` IS NEXT, because the flag belongs to the whole
	 * parenthesised expression rather than to every dereference inside it. In
	 * `(a[*p]) = v` the `*p` is a sub-expression that must still load, and the
	 * token after it is `]`. Same rule as everywhere else here: an lvalue
	 * applies to the last step of a chain, never to one still to be followed.
	 *
	 * The comment at the paren_lvalue site names `(*p)++` as a spelling it
	 * handles. It does not; that site is the `*(...)` path, where the star is
	 * OUTSIDE the parentheses. */
	if(assign_through_parens)
	{
		if(match(")", global_token->s)) is_assignment = TRUE;
	}

	/* AND `(x) = v` IS STILL AN ASSIGNMENT. is_assignment and
	 * is_compound_operator look at the NEXT TOKEN, which for a parenthesised
	 * target is the closing paren, so this loaded the variable and the store
	 * then wrote through its VALUE. See primary_expr's paren branch for the
	 * measurement and for why tcc writes the parenthesised spelling. */
	if(!is_assignment && !is_compound_operator && !is_local_array
	   && !assign_through_parens)
	{
		/* A GLOBAL SCALAR IS ITS OWN STORAGE, SO IT LOADS AT ITS OWN WIDTH.
		 *
		 * register_size is right for a global ARRAY, whose symbol is a
		 * pointer CELL -- this load does double duty fetching it, as the note
		 * below describes. It is wrong for a global scalar, whose symbol IS
		 * the value, and the STORE already used the type's width:
		 *
		 *     str_w0,[x1]      g = -3   four bytes
		 *     ldr_x0,[x0]      read g   EIGHT bytes
		 *
		 * The eight-byte read takes g and the four bytes after it. A positive
		 * value survives because the neighbours are zero -- which is why every
		 * global test written with positive values passed, twice -- and a
		 * negative one does not: -3 stores as 0xFFFFFFFD and reads back as
		 * 0x????????FFFFFFFD.
		 *
		 * tcc compares `tok != TOK_EOF` and TOK_EOF is (-1), so the
		 * comparison failed, tcc_error("...") fired, pp_expr was left set, and
		 * pp_error's `while (next(), tok != TOK_EOF)` ran 5,316,311 times. */
		int size = register_size;
		if(options == TLO_LOCAL || options == TLO_ARGUMENT)
		{
			size = current_target->size;
		}
		else if(0 == type->array_modifier)
		{
			size = current_target->size;
		}
		/* A STRUCT IS NOT LOADED EITHER. Same rule as the dereference sites
		 * and member access: a struct is used by ADDRESS. Without this,
		 * `vtop[0] = tmp` with a local struct tmp tried load_value(16) --
		 * tccgen.c:909, where tcc swaps two SValues through a local.
		 *
		 * AND THE GUARD HAS TO ASK THE TYPE, NOT `size`. size only becomes the
		 * type's real width for TLO_LOCAL and TLO_ARGUMENT above; for a GLOBAL
		 * or STATIC it stays at register_size, so the test could not see that
		 * the thing was a struct at all and loaded its first eight bytes as if
		 * they were the value. tcc hits it immediately:
		 *     char_pointer_type = char_type;          tccgen.c:392
		 * both file-scope, so the source of the copy became char_type.t -- the
		 * integer 3 -- used as an address.
		 *
		 * The local form was fixed and the global form is the same rule in the
		 * other storage class, which is the fourth time that sentence appears
		 * in this file.
		 *
		 * AND NOT FOR AN ARRAY. This load does double duty: for a scalar it
		 * fetches the value, and for a GLOBAL ARRAY it dereferences the
		 * pointer cell the symbol actually holds. Suppressing it on element
		 * size alone killed the second job -- `static struct Big items[4]`
		 * has current_target->size 48 and still needs the load. array_modifier
		 * separates them.
		 */
		int suppress_struct_load = (register_size < current_target->size)
		                           && (type->array_modifier <= 1);
		if(register_size >= size && !suppress_struct_load)
		{
			emit_out(load_value(size, current_target->is_signed));
		}
	}

	/* AN ARRAY NAME USED AS A VALUE IS A POINTER TO ITS FIRST ELEMENT.
	 *
	 * This compiler's type model cannot say that: an array's current_target IS
	 * the element type -- `long lbuf[4]` carries `long`, with the array-ness
	 * held on the SYMBOL (TLO_LOCAL_ARRAY, array_modifier) rather than in the
	 * type. Every path that needed to know has therefore carried the answer
	 * out of band; indexing_an_array is the existing example.
	 *
	 * That was survivable while nothing asked the type. Pointer arithmetic
	 * asks: `lbuf + 1` must advance eight bytes, and the register at that
	 * point genuinely holds a `long*` -- the load above has already turned the
	 * symbol into the address of element zero. Saying `long` is not a
	 * simplification, it is false, and it is false about the exact value in
	 * the register.
	 *
	 * NOT WHEN A '[' FOLLOWS, and that guard is what makes this safe rather
	 * than a rewrite: postfix_expr_array takes its element width from
	 * current_target->size when indexing_an_array is set, so decaying first
	 * would make `char s[10]; s[i]` stride by eight. A local array indexed
	 * never reaches here at all (is_indexed_local_array returns above); a
	 * GLOBAL one does, which is why the test is on the token and not on the
	 * storage class.
	 *
	 * Nor under an assignment, a compound assignment, an `&`, or a leading
	 * `*` -- those want the address or a width, not a decayed value. */
	if(!is_assignment && !is_compound_operator && (TRUE != Address_of)
	   && (0 == num_dereference) && !match("[", global_token->s))
	{
		if(is_local_array || (1 < type->array_modifier))
		{
			current_target = current_target->indirect;
		}
	}

	/* A COMPOUND ASSIGNMENT IS AN ASSIGNMENT, and this is the copy of that
	 * rule that did not know it. `is_assignment` above is `match("=")` only,
	 * so `*p += v` fell through to the rvalue branch below -- which steps the
	 * type DOWN and then loads at the pointed-at width. For `int *p` that
	 * loaded the eight-byte pointer as a four-byte signed int:
	 *
	 *     *p = 5     lea_rax,[rbp-8] / mov_rax,[rax]                8 bytes
	 *     *p += 5    lea_rax,[rbp-8] / movsx_rax,DWORD_PTR_[rax]    4, SIGNED
	 *
	 * The truncated pointer is then stored through, so any address above 2GB
	 * or with bit 31 set becomes a wild write. tcc's find_field does exactly
	 * this -- `*cumofs += s->c` -- which is why a designated initializer
	 * naming a member of an ANONYMOUS struct segfaulted mc-tcc while the same
	 * initializer written with braces was fine.
	 *
	 * The load-before-step order in this branch is what makes it right: an
	 * lvalue wants the POINTER at the pointer's width; only an rvalue read
	 * wants the pointed-at type. Same rule as zz8, and the copies still
	 * disagree. */
	if(is_assignment || is_compound_operator)
	{
		while (num_dereference > 0)
		{
			if(!is_local_array)
			{
				/* A STRUCT IS NEVER LOADED INTO A REGISTER. Dereferencing a
						 * struct pointer yields its ADDRESS, which is what every
						 * other struct path already assumes -- member access has
						 * had this guard all along. Without it `x = *p` for a
						 * struct tried load_value(16):
						 *     unsupported size 16 of type 'CType'   tccgen.c:895 */
						if(register_size >= current_target->size) emit_out(load_value(current_target->size, current_target->is_signed));
			}
			is_local_array = FALSE;
			current_target = current_target->type;
			num_dereference = num_dereference - 1;
		}
		/* CONSUMED HERE. This branch applies the dereference itself, so the
		 * deferred count added for `*bf->buf_end` must be cleared or
		 * postfix_expr applies it a SECOND time -- which is exactly what broke
		 * `*pal = al` and sent tcc backwards from line 660 to 177. */
		num_dereference_after_postfix = 0;
	}
	else
	{
		/* A UNARY `*` BINDS LOOSER THAN A POSTFIX ACCESS. `*bf->buf_end` means
		 * `*(bf->buf_end)`, so dereferencing HERE applies the star to `bf` and
		 * loads the whole struct:
		 *     *bf->buf_end = CH_EOB;                  tccpp.c:660
		 *     unsupported size 1125 of type 'BufferedFile' near '->'
		 *
		 * Leave it for postfix_expr to apply once the chain is resolved.
		 * num_dereference_after_postfix already carries the count, set when the
		 * stars were consumed. */
		/* POSTFIX ++/-- BINDS TIGHTER THAN UNARY '*' TOO.
		 *     sw->sv = *vtop--;                       tccgen.c:7335
		 * is `*(vtop--)`: the pointer is decremented, not the struct it points
		 * at. Applying the dereference first made the decrement operate on the
		 * dereferenced value and store 16 bytes through it.
		 *
		 * Same list as -> . and [ -- this one was simply missed when the
		 * deferral was added. */
		if(match("->", global_token->s) || match(".", global_token->s) ||
		   match("[", global_token->s) ||
		   match("++", global_token->s) || match("--", global_token->s))
		{
			return;
		}

		int should_not_deref;
		while (num_dereference > 0)
		{
			/* Function pointers are special in C.
			 * They can be dereferenced an infinite amount of times but still just be the actual pointer. */
			should_not_deref = current_target->type == current_target->type->type && (current_target->type->options & TO_FUNCTION_POINTER);

			if(!should_not_deref)
			{
				current_target = current_target->type;
				/* A STRUCT IS NEVER LOADED INTO A REGISTER. Dereferencing a
						 * struct pointer yields its ADDRESS, which is what every
						 * other struct path already assumes -- member access has
						 * had this guard all along. Without it `x = *p` for a
						 * struct tried load_value(16):
						 *     unsupported size 16 of type 'CType'   tccgen.c:895 */
						if(register_size >= current_target->size) emit_out(load_value(current_target->size, current_target->is_signed));
			}
			num_dereference = num_dereference - 1;
		}
		num_dereference_after_postfix = 0;
	}
}

void primary_expr(void);
struct type* promote_type(struct type* a, struct type* b)
{
	require(NULL != b, "impossible case 1 in promote_type\n");
	require(NULL != a, "impossible case 2 in promote_type\n");

	if(a == b) return a;

	/* PICK BY RANK, NOT BY POSITION IN global_types.
	 *
	 * This used to walk global_types and return the FIRST entry whose name
	 * matched EITHER operand, so which type won was decided by DECLARATION
	 * ORDER rather than by the types. That is right whenever the wider type
	 * happens to be registered first. `int` is registered early, so anything
	 * that met an `int` and was declared later simply lost -- and every
	 * typedef is declared later:
	 *
	 *     unsigned long x;   x >> 43     shr_rax,cl    logical, correct
	 *     u64           x;   x >> 43     sar_rax,cl    arithmetic, WRONG
	 *
	 * Same width, same signedness, different answer, because `u64` is a
	 * typedef. The promoted type came back as `int` carrying is_signed =
	 * TRUE, so EVERY UNSIGNED TYPEDEF IN THE PROGRAM was signed as far as
	 * codegen was concerned. Division and comparison went the same way.
	 *
	 * WHAT IT COST. tcc's elf.h:34 says
	 *     typedef unsigned long long int  uint64_t;
	 * so this was every uint64_t in tcc. arm64_movi encodes a value whose
	 * only set bit is bit 63 with
	 *     if (!(x & ~(m << 48)))
	 *         return 0xd2e00000 | r | x >> 43;        arm64-gen.c:184
	 * and an arithmetic shift turns 0x100000 into 0xfff00000, so the emitted
	 * word was 0xfff00001 -- not an aarch64 encoding at all.
	 * tests2/118_switch died with SIGILL, on the one case range in the file
	 * whose low bound is exactly LONG_MIN. `LONG_MIN+1 ... -1` was fine,
	 * which is what made it look like a switch bug for two rounds.
	 *
	 * THE RULE. Wider wins; at equal width the unsigned one wins, which is
	 * C's rule for equal rank. A pointer is wider than an int and still wins,
	 * which is what the old walk produced for pointer arithmetic. Case 110
	 * stays a declared KNOWN GAP: this is not the full usual arithmetic
	 * conversions, it is the selection rule those conversions need under
	 * them. */
	/* THE INTEGER PROMOTIONS COME FIRST, AND THEY ERASE SIGNEDNESS.
	 *
	 * C89 3.2.1.1: any operand whose rank is below `int` is converted to
	 * `int` before anything else happens, because every value of a char or a
	 * short fits one. So when BOTH operands are narrower than int there is no
	 * unsigned type left for the rule below to pick:
	 *
	 *     short s = -1; unsigned short t = 0;    s < t   is TRUE in C
	 *
	 * -- both become int, and -1 < 0. This returned `unsigned short`, the
	 * comparison went unsigned, and -1 became 65535. Same for every mixed-sign
	 * pair of narrow types.
	 *
	 * Found by uac-sweep.sh's second phase, which pairs two VARIABLES; the
	 * first phase pairs a variable with a literal, and a literal is never
	 * narrower than int, so this was outside the space it could reach. 31 of
	 * its 396 programs disagreed with gcc on exactly this, and the fault is
	 * older than the sweep -- it reproduces identically on the compiler from
	 * before any of the conversion work.
	 *
	 * ONLY SCALARS. A struct can be smaller than four bytes and is not an
	 * integer; a pointer is register-width and never reaches this. */
	if(NULL == a->members)
	{
		if(NULL == b->members)
		{
			if(0 == (a->options & TO_FUNCTION_POINTER))
			{
				if(0 == (b->options & TO_FUNCTION_POINTER))
				{
					if(a->size < 4)
					{
						if(b->size < 4) return integer;
					}
				}
			}
		}
	}

	if(a->size > b->size) return a;
	if(b->size > a->size) return b;
	if(!a->is_signed) return a;
	if(!b->is_signed) return b;
	return a;
}

/* ADVANCE A TEMP REGISTER BY AN IMMEDIATE.
 *
 * x15 and x16 have a DELIBERATELY NARROW vocabulary in M2libc's
 * aarch64_defs.M1: mov from x0, ldr/str, br, and use as the first source of an
 * add whose destination is x0/x1/x18. There is no `add_x16,x14,x16`, so
 * emit_add_immediate cannot be pointed at them.
 *
 * The round trip through x0 is what IS defined:
 *     mov_x0,N ; add_x0,x16,x0 ; mov_x16,x0
 *
 * This exists because M1 rejected `add_x16,x14,x16` -- the emitted output
 * parsed and looked plausible for eighty walls and had never been assembled. */
void emit_advance_temp(int reg, int amount, char* note)
{
	emit_load_immediate(REGISTER_ZERO, amount, note);
	emit_add(REGISTER_ZERO, reg, TRUE, note);
	emit_move(reg, REGISTER_ZERO, note);
}

/* SHORT-CIRCUIT && AND ||.
 *
 * C requires the right operand not to be evaluated when the left settles the
 * answer, and tcc relies on it in forty-eight places shaped like
 *     if (esym && esym->st_shndx == SHN_UNDEF)
 * where evaluating the right with a null left is a null dereference.
 *
 * Modelled on the ternary above, which is the only other place this compiler
 * branches INSIDE an expression and which works: same id scheme (the function
 * name, so labels cannot collide across functions), same helpers, no attempt
 * to save REGISTER_TEMP. An earlier version used a literal for the function
 * name and pushed and popped x16 around the sequence; it broke tcc_new and
 * exhausted memory on a large file, and neither symptom was ever traced to
 * those two differences -- so this version simply does not differ.
 *
 *     &&                        ||
 *     <left in R0>              <left in R0>
 *     if zero    -> FALSE       if not zero -> TRUE
 *     <right in R0>             <right in R0>
 *     if zero    -> FALSE       if not zero -> TRUE
 *     R0 = 1                    R0 = 0
 *     jump       -> END         jump        -> END
 *     FALSE: R0 = 0             TRUE:  R0 = 1
 *     END:                      END:
 */
void logical_recursion(FUNCTION f, int is_and, char* name, FUNCTION iterate)
{
	require(NULL != global_token, "Received EOF in logical_recursion\n");
	if(!match(name, global_token->s)) return;

	char* number_string = int2str(current_count, 10, TRUE);
	current_count = current_count + 1;
	char* unique_id = create_unique_id("", function->s, number_string);

	/* THE SAME REGISTER_TEMP HAZARD AS THE TERNARY, for the same reason: these
	 * branch inside an expression, and on aarch64 that goes through x16. */
	emit_push(REGISTER_TEMP, "protect the temp register across &&/||");

	if(is_and) emit_jump_if_zero(REGISTER_ZERO, "SC_SETTLED_", unique_id, "&& left settles it");
	else emit_jump_if_not_zero(REGISTER_ZERO, "SC_SETTLED_", unique_id, "|| left settles it");

	require_extra_token();
	f();

	if(is_and)
	{
		emit_jump_if_zero(REGISTER_ZERO, "SC_SETTLED_", unique_id, "&& right is false");
		emit_load_immediate(REGISTER_ZERO, TRUE, "both true");
	}
	else
	{
		emit_jump_if_not_zero(REGISTER_ZERO, "SC_SETTLED_", unique_id, "|| right is true");
		emit_load_immediate(REGISTER_ZERO, FALSE, "neither true");
	}
	emit_unconditional_jump("_SC_END_", unique_id, "skip the settled value");

	emit_label("SC_SETTLED_", unique_id);
	if(is_and) emit_load_immediate(REGISTER_ZERO, FALSE, "&& settled false");
	else emit_load_immediate(REGISTER_ZERO, TRUE, "|| settled true");

	emit_label("_SC_END_", unique_id);
	emit_pop(REGISTER_TEMP, "restore the temp register after &&/||");
	iterate();
}

/* THE TWO OPERAND TYPES, RECORDED BEFORE promote_type FOLDS THEM TOGETHER.
 *
 * promote_type answers "what type is the RESULT", and it answers it by NAME
 * lookup against global_types -- so `long* + int` comes back as plain `long`,
 * with both the indirection and the knowledge of which side carried it gone.
 * That is the information loss behind the shelved scale_pointer_operand: by
 * the time an operator is handled there is nothing left to tell `p + n` from
 * `n + p` from `p - q`, and those three lower to three different things.
 *
 * These are read by the caller IMMEDIATELY after common_recursion returns.
 * Nesting is safe for that reason and only for that reason: f() may recurse
 * through common_recursion any number of times, but every one of those
 * completes before f() returns, and these two lines run after it. Anything
 * that wants them later must copy them into a local first. */
struct type* operand_left_type;
struct type* operand_right_type;

/* AN INTEGER STORED INTO A FLOAT IS CONVERTED, NOT COPIED.
 *
 * micro-c gives float, double and long double one word-sized representation,
 * and every operation on them is an integer operation on float bits -- which
 * the type table says plainly. This is the ONE place that is not good enough,
 * because tcc folds its floating-point constants at compile time:
 *
 *     vtop->c.ld = (uint32_t)vtop->c.i;      tccgen.c:3303
 *     vtop->c.d  = (double)vtop->c.ld;
 *
 * As integer moves those leave the INTEGER in the double's slot, and
 * init_putv then writes it into .data.ro as if it were an IEEE value. That is
 * the whole of the gen2 != gen3 difference: tcc.c has exactly two
 * floating-point constants, both `(double)<int literal>` from
 * tcc_print_stats, and both came out as the integer 1000 instead of 1000.0.
 *
 * ONLY THE STORE, AND ONLY THIS DIRECTION. No arithmetic, no double-to-int,
 * no float literals -- micro-c's scanner still cannot read "1.5" and that is
 * unchanged. What this buys is the conversion tcc's constant folder needs,
 * which is the only float path tcc.c's own constants take.
 *
 * TWO ARCHITECTURES, because those are the two the vocabulary has
 * instructions for (m2libc patch 0013) and the two difftest runs. Anywhere
 * else this does nothing, which is what it did before.
 */
int type_is_float(struct type* t)
{
	if(NULL == t) return FALSE;
	return t->options & TO_FLOAT;
}

void emit_int_to_double(void)
{
	if(AARCH64 == Architecture)
	{
		emit_out("scvtf_d0,x0\t# integer -> double\n");
		emit_out("fmov_x0,d0\t# and back into the value register\n");
	}
	else if(AMD64 == Architecture)
	{
		emit_out("cvtsi2sd_xmm0,rax\t# integer -> double\n");
		emit_out("movq_rax,xmm0\t# and back into the value register\n");
	}
}

/* THE CONVERSION promote_type ONLY SELECTS.
 *
 * promote_type answers "which type wins" -- wider first, unsigned at equal
 * width -- and its own note says that is "not the full usual arithmetic
 * conversions, it is the selection rule those conversions need under them".
 * This is the part that was under them: having chosen the type, both operands
 * have to BE that type before the operator runs.
 *
 * Only the equal-rank int / unsigned int case is emitted, because that is the
 * only one where micro-c's registers disagree with C. Everything narrower is
 * already promoted to int by the load; everything wider is register-width and
 * needs nothing. When both operands are the same width and the same
 * signedness there is nothing to do either.
 *
 *     int      -> unsigned int    keep the low 32 bits
 *     unsigned -> unsigned int    already so, and the move is harmless
 *
 * A 32-bit register write zeroes the top half on both targets, so the
 * zero-extending move IS `mov w,w` / `mov e,e` -- the same reasoning that
 * gave the unsigned four-byte entry in emit_narrowing_cast its odd name.
 *
 * REGISTER_ONE IS THE LEFT OPERAND, and needed vocabulary that did not exist:
 * `mov_ebx,ebx` and `mov_w1,w1` are added by the m2libc series alongside this.
 * Which side is signed is not fixed -- `got != LIT` and `LIT != got` are both
 * legal -- so both registers are converted rather than guessing.
 *
 * CALLED FROM general_recursion AND arithmetic_recursion ONLY, never from
 * common_recursion itself. Ten sites call common_recursion, and in most of
 * them REGISTER_ONE does not hold a VALUE at all: assignment leaves the
 * destination ADDRESS there, and so do array indexing and the additive paths
 * that do pointer scaling. Putting this in common_recursion truncated a stack
 * address to 32 bits, and `local.n = 5` on a struct segfaulted. The two
 * helpers here are the ones whose contract is "two values in, one value out".
 *
 * SILENT ON THE OTHER ARCHITECTURES, deliberately. micro-c targets amd64 and
 * aarch64 here; x86, armv7l and riscv keep exactly the behaviour they had
 * rather than being given an encoding nobody has assembled. */
void emit_usual_arithmetic_conversion(struct type* left, struct type* right)
{
	if(NULL == left) return;
	if(NULL == right) return;
	if(NULL == current_target) return;

	/* the chosen type must be a four-byte unsigned integer */
	if(4 != current_target->size) return;
	if(current_target->is_signed) return;
	if(NULL != current_target->members) return;
	if(current_target->options & TO_FUNCTION_POINTER) return;

	/* THE INTEGER PROMOTIONS HAPPEN FIRST, so an operand NARROWER than int is
	 * already an int by the time the usual conversions look at it and must be
	 * converted with everything else. Requiring size 4 exactly missed all of
	 * them, and uac-sweep found 22 points saying so -- every one a char
	 * against UINT_MAX:
	 *
	 *     char x = -1;   x == 0xFFFFFFFF     gcc 1, micro-c 0
	 *
	 * because x promotes to int -1, the literal is unsigned int, and the int
	 * then converts to 0xFFFFFFFF. Size 8 is still excluded: pointers are
	 * register-width and need nothing, and a long is wider than the chosen
	 * type so it could not have been chosen. */
	if(left->size > 4) return;
	if(right->size > 4) return;
	if(0 == left->size) return;
	if(0 == right->size) return;
	if(NULL != left->members) return;
	if(NULL != right->members) return;
	if(left->options & TO_FUNCTION_POINTER) return;
	if(right->options & TO_FUNCTION_POINTER) return;

	/* and at least one of them must actually be changing */
	if(!left->is_signed && !right->is_signed) return;

	if(AARCH64 == Architecture)
	{
		emit_out("mov_w0,w0\n");
		emit_out("mov_w1,w1\n");
	}
	else if(AMD64 == Architecture)
	{
		emit_out("mov_eax,eax\n");
		emit_out("mov_ebx,ebx\n");
	}
}

/* THE RESULT IS MODULO THE CHOSEN TYPE, NOT THE REGISTER.
 *
 * Converting the operands is only half of it. `unsigned int` arithmetic in C
 * is modulo 2^32, and micro-c multiplies in a 64-bit register, so the product
 * kept bits the type does not have:
 *
 *     char x = -1431655766;  x * 0x80000000    gcc 0, micro-c non-zero
 *
 * emit_narrowing_cast already knows how to reduce REGISTER_ZERO to a type and
 * returns early for anything register-width, so a pointer result -- which the
 * additive paths set deliberately -- passes through untouched. Comparisons
 * yield 0 or 1 and are unaffected by being narrowed, so this does not need to
 * know which operator it follows. */
void emit_result_in_chosen_type(void)
{
	if(NULL == current_target) return;
	if(current_target->is_signed) return;

	/* FOUR BYTES ONLY. THE INTEGER PROMOTIONS RUN FIRST, so there is no such
	 * thing as `unsigned char` arithmetic in C: both operands become `int` and
	 * the RESULT is an int.
	 *
	 *     unsigned char a = 200, b = 100;       a + b  is 300, not 44
	 *     unsigned short s = 60000, t = 10000;  s + t  is 70000, not 4464
	 *
	 * promote_type picks BETWEEN the operands and has no notion of promoting
	 * past both, so for two narrow operands it returns the narrow type. Without
	 * this guard the result was narrowed with `uxtb_w0,w0` and every bit above
	 * the eighth was lost.
	 *
	 * WHAT IT COST, because this shipped for one CI round. mc-tcc SEGFAULTED
	 * assembling musl's aarch64 memset.S and memcpy.S -- tcc's ARM64 assembler
	 * builds instruction words out of narrow unsigned fields -- so libc.a came
	 * out with no memset and no memcpy, every hosted link failed on `undefined
	 * symbol`, and the stage-4 ladder stopped at rung 3 having previously
	 * reached rung 6.
	 *
	 * emit_usual_arithmetic_conversion has always had this guard; this function
	 * was written from it and the one line did not carry over. */
	if(4 != current_target->size) return;

	emit_narrowing_cast(current_target);
}

void common_recursion(FUNCTION f)
{
	emit_push(REGISTER_ZERO, "_common_recursion");

	struct type* last_type = current_target;
	require_extra_token();
	f();
	operand_left_type = last_type;
	operand_right_type = current_target;
	current_target = promote_type(current_target, last_type);

	emit_pop(REGISTER_ONE, "_common_recursion");
}

void general_recursion(FUNCTION f, char* s, char* name, FUNCTION iterate)
{
	require(NULL != global_token, "Received EOF in general_recursion\n");
	if(match(name, global_token->s))
	{
		common_recursion(f);
		emit_usual_arithmetic_conversion(operand_left_type, operand_right_type);
		emit_out(s);
		emit_result_in_chosen_type();
		iterate();
	}
}

void multiply_by_object_size(int object_size)
{
	/* bootstrap mode can't depend upon on pointer arithmetic */
	if(BOOTSTRAP_MODE) return;

	if(object_size == 1)
	{
		/* No reason to multiply by one */
		return;
	}

	/* THE PARAMETER, NOT THE GLOBAL.
	 *
	 * This tested `object_size` and then emitted current_target->type->size,
	 * which is a different number: the caller reassigns current_target via
	 * promote_type between capturing the size and calling this. The caller
	 * even says so --
	 *
	 *     /* We need this before it's changed by the following expression  *\/
	 *     int object_size = current_target->type->size;
	 *
	 * -- so the hazard was seen, the value was captured to dodge it, and then
	 * the capture was ignored here.
	 *
	 * For `struct X *p; p -= 2;` the promoted type still happened to yield the
	 * struct's size, so it looked right. For a pointer to a TYPEDEF'd struct
	 * it yields 8 -- the pointer's own width -- and the pointer moves by two
	 * WORDS instead of two elements.
	 *
	 * tcc's value stack is exactly that shape:
	 *
	 *     ST_DATA SValue *vtop;      arm64_gen_opil:  vtop -= 2; ... ++vtop;
	 *
	 * so the pop after a binary operator moved one entry instead of two, and
	 * every operator with two variable operands leaked a vstack slot:
	 *
	 *     int m(void){ int a; int b; return a+b; }
	 *     error: internal compiler error: vstack leak (1)
	 *
	 * `a+1` and `1+2` escape it because they constant-fold and never reach
	 * the two-operand path. */
	emit_mul_register_zero_with_immediate(object_size, "pointer arithmetic");
}

void arithmetic_recursion(FUNCTION f, char* s1, char* s2, char* name, FUNCTION iterate)
{
	require(NULL != global_token, "Received EOF in arithmetic_recursion\n");
	if(match(name, global_token->s))
	{
		common_recursion(f);
		emit_usual_arithmetic_conversion(operand_left_type, operand_right_type);
		if(NULL == current_target)
		{
			emit_out(s1);
		}
		else if(current_target->is_signed)
		{
			emit_out(s1);
		}
		else
		{
			emit_out(s2);
		}
		emit_result_in_chosen_type();
		iterate();
	}
}


/*
 * postfix-expr:
 *         primary-expr
 *         postfix-expr [ expression ]
 *         postfix-expr ( expression-list-opt )
 *         postfix-expr -> member
 *         postfix-expr . member
 */
struct type* lookup_member(struct type* parent, char* name);
void postfix_expr_arrow(void)
{
	emit_out("# looking up offset\n");
	require_extra_token();

	struct type* i = lookup_member(current_target, global_token->s);
	current_target = i->type;
	require_extra_token();

	if(0 != i->bit_width)
	{
		/* BITFIELD ACCESS. Layout was implemented long before this; the error
		 * that used to stand here was deliberate, so that a read returning the
		 * whole storage unit could never pass silently.
		 *
		 * READ is `(unit >> bit_offset) & ((1 << bit_width) - 1)`. The macros
		 * take dest x0, first source x1, so each step moves the running value
		 * into ONE and the operand into ZERO.
		 *
		 * The WRITE side is handled in expression()'s '=' branch, which is the
		 * only place that has both the address and the new value; these
		 * globals carry the field description to it. */
		pending_bitfield_offset = i->bit_offset;
		pending_bitfield_width = i->bit_width;
		/* THE UNIT WIDTH IS i->type->size, NOT i->size. The layout work made
		 * only the field that OPENS a storage unit carry its size, so a packed
		 * field reports 0 -- and load_value(0) is not a load. The declared
		 * type is the unit. */
		pending_bitfield_size = i->type->size;

		if(!match("=", global_token->s) && !is_compound_assignment(global_token->s))
		{
			emit_out(load_value(i->type->size, FALSE));
			if(0 != i->bit_offset)
			{
				emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: value");
				emit_load_immediate(REGISTER_ZERO, i->bit_offset, "bitfield: shift");
				emit_out(shift_right_logical_instruction());
			}
			emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: value");
			emit_load_immediate(REGISTER_ZERO, (1 << i->bit_width) - 1, "bitfield: mask");
			emit_out(bitwise_and_instruction());
			pending_bitfield_width = 0;
			current_target = integer;
			return;
		}
	}
	else
	{
		pending_bitfield_width = 0;
	}

	if(0 != i->offset)
	{
		emit_add_immediate(REGISTER_ZERO, i->offset, "-> offset calculation");
	}

	if(global_token->s[0] == '.') return;

	int is_postfix_operator = match("++", global_token->s) || match("--", global_token->s);

	/* AN ARRAY MEMBER DECAYS TO ITS ADDRESS -- IT IS NOT LOADED.
	 *
	 *     s->include_stack_ptr = s->include_stack;      tcc_new, libtcc.c
	 *
	 * `include_stack` is `char *include_stack[32]`. Loading it fetched
	 * include_stack[0] -- zero, straight after the memset in tcc_mallocz --
	 * and stored THAT into the pointer. The next dereference of
	 * include_stack_ptr was a null pointer, and tcc_new segfaulted.
	 *
	 * The existing guard only asks whether the member FITS in a register. An
	 * array's element size fits, so the guard let it through; what matters is
	 * that it is an array at all. Same rule as a plain array variable, which
	 * micro-c has always got right -- it was only member access that did not
	 * know.
	 *
	 * Found by reading emitted code, after five probes had each ruled out one
	 * thing without finding it. */
	int member_is_array = i->is_array;

	/* THE LAST STEP OF THE CHAIN IS THE LVALUE, AND ONLY THE LAST.
	 *
	 * A prefix ++/-- wants the ADDRESS of its target. is_postfix_operator
	 * already says so for `p->n++`, because there the operator sits after the
	 * member and a lookahead can see it; a PREFIX operator was consumed
	 * before the chain was parsed and no lookahead here can. prefix_lvalue
	 * _target carries it, and it applies only where the chain stops -- an
	 * intermediate `->` or `[` still has to load the pointer to follow it. */
	int chain_continues = match("->", global_token->s) || match("[", global_token->s);
	int is_prefix_target = prefix_lvalue_target && !chain_continues;
	if(is_prefix_target) prefix_lvalue_target = FALSE;

	/* AND Address_of OBEYS THE SAME RULE, which it did not.
	 *
	 * chain_continues was computed right above for prefix_lvalue_target and
	 * then not applied to Address_of, so `&` suppressed the load at EVERY
	 * arrow rather than only the last:
	 *
	 *     &p->ref->type      ldr [p]  add 8  add 8
	 *      p->ref->type.t    ldr [p]  add 8  ldr  add 8  ldr
	 *
	 * The middle load is how you follow `->ref`. Without it the second offset
	 * is added to the ADDRESS of ref instead of to what ref points at.
	 *
	 * tcc reaches it through
	 *
	 *     #define pointed_type(t) (&(t)->ref->type)
	 *
	 * used by compare_types for every pointer comparison, so any assignment
	 * of a pointer-valued expression walked into a wild address:
	 *
	 *     char *p = g();          crash
	 *     int   n = g();          fine
	 *
	 * The call path was vstore -> verify_assign_cast -> compare_types ->
	 * is_compatible_unqualified_types -> compare_types, and it died in the
	 * innermost one.
	 *
	 * Fourth function to learn this rule -- zzc taught it to the prefix
	 * operators here, zzg to the dot site, zzm to the array site. Here the
	 * rule was WRITTEN in the comment above and applied to one of the two
	 * flags beneath it. */
	if((!match("=", global_token->s) && !is_compound_assignment(global_token->s) && !is_postfix_operator && !is_prefix_target && (register_size >= i->size) && !member_is_array && (TRUE != Address_of || chain_continues)))
	{
		emit_out(load_value(i->size, i->is_signed));
	}
}

void postfix_expr_inc_or_dec(void)
{
	int is_subtract = global_token->s[0] == '-';
	require_extra_token();

	emit_out("# postfix inc/dec\n");
	emit_push(REGISTER_ONE, "Old register one value");

	emit_push(REGISTER_ZERO, "Address of variable");
	/* AT THE VARIABLE'S WIDTH, NOT THE REGISTER'S.
	 *
	 * emit_dereference always loads a full register. While `int` was eight
	 * bytes that was the same thing; at four it reads the variable AND the
	 * four bytes after it. In dynarray_add,
	 *
	 *     pp[nb++] = data;
	 *
	 * nb is 1 and the next slot holds the high half of a stack pointer, so
	 * the postfix read produced
	 *
	 *     X00=0000400000000001
	 *
	 * -- the right value with an address welded to its top -- and the
	 * store that followed went through a wild pointer. tcc segfaulted
	 * before it had parsed anything; even --version died.
	 *
	 * load_value is what every other read already uses, and it takes the
	 * width and the signedness from the type. */
	if(NULL != current_target && register_size >= current_target->size)
	{
		emit_out(load_value(current_target->size, current_target->is_signed));
	}
	else
	{
		emit_dereference(REGISTER_ZERO, "Get value");
	}

	/* We need the address to be at the top of the stack and the value to be below it */
	emit_pop(REGISTER_ONE, "Address of variable");
	emit_push(REGISTER_ZERO, "Value before postfix operator");
	emit_push(REGISTER_ONE, "Address of variable");

	int value = 1;
	if(type_is_pointer(current_target))
	{
		value = current_target->type->size;
	}

	if(is_subtract)
	{
		emit_sub_immediate(REGISTER_ZERO, value, "Subtract offset");
	}
	else
	{
		emit_add_immediate(REGISTER_ZERO, value, "Add offset");
	}

	emit_pop(REGISTER_ONE, "Address of variable");

	/* Store REGISTER_ZERO in REGISTER_ONE deref */
	emit_out(store_value(current_target->size));

	emit_pop(REGISTER_ZERO, "Value before postfix operator");
	emit_pop(REGISTER_ONE, "Previous value");

	/* `*p++ = x` IS AN ASSIGNMENT TARGET, SO THE LAST DEREFERENCE MUST NOT
	 * LOAD.
	 *
	 * `*p++` yields the ADDRESS old p pointed at; the assignment then stores
	 * there. Loading it produced
	 *
	 *     movsx_rax,BYTE_PTR_[rax]     load *old_p
	 *     mov_[rbx],al                 store through the loaded VALUE
	 *
	 * so the byte was written to whatever happened to be sitting at *p. tcc
	 * uses this idiom constantly -- `*s->include_stack_ptr++ = file` is one --
	 * and it would corrupt an arbitrary address every time.
	 *
	 * postfix_expr's own deferred loop has had this check all along under the
	 * name `assigning`; this loop is a separate copy that never got it. That
	 * is the fourth place in this file carrying its own version of one rule. */
	int assigning_through = match("=", global_token->s) || is_compound_assignment(global_token->s);

	while (num_dereference_after_postfix > 0)
	{
		if(assigning_through)
		{
			if(1 == num_dereference_after_postfix)
			{
				/* the final level is the destination, not a value to read */
				current_target = current_target->type;
				num_dereference_after_postfix = num_dereference_after_postfix - 1;
				continue;
			}
		}

		/* A STRUCT IS NOT LOADED. This is the THIRD deferred-dereference loop
		 * in the file with its own copy of that rule -- the other two are in
		 * primary_expr_variable and postfix_expr. `sw->sv = *vtop--` at
		 * tccgen.c:7335 is the one that reaches this one. */
		if(register_size >= current_target->type->size)
		{
			emit_out(load_value(current_target->type->size, current_target->type->is_signed));
		}
		current_target = current_target->type;
		num_dereference_after_postfix = num_dereference_after_postfix - 1;
	}

	emit_out("# postfix inc/dec end\n");
}

void postfix_expr_dot(void)
{
	maybe_bootstrap_error("Member access using .");
	emit_out("# looking up offset\n");
	require_extra_token();

	struct type* i = lookup_member(current_target, global_token->s);
	current_target = i->type;
	require_extra_token();

	if(0 != i->bit_width)
	{
		/* BITFIELD ACCESS. Layout was implemented long before this; the error
		 * that used to stand here was deliberate, so that a read returning the
		 * whole storage unit could never pass silently.
		 *
		 * READ is `(unit >> bit_offset) & ((1 << bit_width) - 1)`. The macros
		 * take dest x0, first source x1, so each step moves the running value
		 * into ONE and the operand into ZERO.
		 *
		 * The WRITE side is handled in expression()'s '=' branch, which is the
		 * only place that has both the address and the new value; these
		 * globals carry the field description to it. */
		pending_bitfield_offset = i->bit_offset;
		pending_bitfield_width = i->bit_width;
		/* THE UNIT WIDTH IS i->type->size, NOT i->size. The layout work made
		 * only the field that OPENS a storage unit carry its size, so a packed
		 * field reports 0 -- and load_value(0) is not a load. The declared
		 * type is the unit. */
		pending_bitfield_size = i->type->size;

		if(!match("=", global_token->s) && !is_compound_assignment(global_token->s))
		{
			emit_out(load_value(i->type->size, FALSE));
			if(0 != i->bit_offset)
			{
				emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: value");
				emit_load_immediate(REGISTER_ZERO, i->bit_offset, "bitfield: shift");
				emit_out(shift_right_logical_instruction());
			}
			emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: value");
			emit_load_immediate(REGISTER_ZERO, (1 << i->bit_width) - 1, "bitfield: mask");
			emit_out(bitwise_and_instruction());
			pending_bitfield_width = 0;
			current_target = integer;
			return;
		}
	}
	else
	{
		pending_bitfield_width = 0;
	}

	if(0 != i->offset)
	{
		emit_add_immediate(REGISTER_ZERO, i->offset, ". offset calculation");
	}
	/* A PREFIX ++/-- SITS WHERE NO LOOKAHEAD CAN SEE IT.
	 *
	 * is_postfix_operator below reads the token in front of the member, which
	 * is where a POSTFIX operator is. A PREFIX one was consumed before the
	 * chain was parsed, so prefix_lvalue_target carries it -- the same
	 * mechanism EXPERIMENT-zzc built for the arrow half, and this is the other
	 * half of that rule in the other function. Ninth and tenth instance of
	 * one-rule-two-implementations in this file.
	 *
	 * It applies only where the chain STOPS: an intermediate `.` or `[` still
	 * has to load, and both return below on their own. */
	int is_postfix_operator = match("++", global_token->s) || match("--", global_token->s);
	int is_prefix_target = prefix_lvalue_target
	                       && !match(".", global_token->s) && !match("[", global_token->s);
	if(is_prefix_target) prefix_lvalue_target = FALSE;
	if(match("=", global_token->s) || is_compound_assignment(global_token->s)
	   || is_postfix_operator || is_prefix_target) return;
	int member_is_array = i->is_array;

	/* INDEXING A MEMBER: AN ARRAY IS ITS ADDRESS, A POINTER MUST BE LOADED.
	 *
	 *     struct { char *p; char arr[8]; } m;
	 *     m.arr[0]     the array IS at &m.arr -- index straight off it
	 *     m.p[0]       p's VALUE is the base -- it has to be loaded first
	 *
	 * Returning early for a following '[' is right for the array and wrong
	 * for the pointer, and micro-c did it for both: m.p[0] indexed off the
	 * ADDRESS of p and read the pointer's own bytes rather than what it points
	 * at. `s->member[i]` is everywhere in tcc.
	 *
	 * The two are only distinguishable because struct members now carry
	 * is_array; the same distinction is still missing for locals and globals,
	 * which is the known gap behind case 01. */
	if(match(".", global_token->s)) return;
	if(match("[", global_token->s))
	{
		/* Tell the index code WHICH it is. `char *arr[8]` and `char *p` both
		 * leave current_target as `char *`; only this flag separates them,
		 * and without it the element width is wrong for one or the other. */
		indexing_an_array = member_is_array;
		if(member_is_array) return;
		if(register_size >= i->size)
		{
			emit_out(load_value(i->size, i->is_signed));
		}
		return;
	}

	/* AN ARRAY MEMBER DECAYS TO ITS ADDRESS, AND SO DOES `s.arr`.
	 *
	 * postfix_expr_arrow learned this; postfix_expr_dot is a SEPARATE function
	 * and did not. `s.ptr = s.arr` therefore loaded arr[0] instead of taking
	 * the array's address -- the same bug as the arrow case, in the other half
	 * of member access, sitting there unnoticed because the tcc code that
	 * exposed it used `->`.
	 *
	 * Found by the differential tester in its first run. Two of these have now
	 * been found by compiling twelve lines of C and comparing an exit code
	 * against gcc, after the first cost three CI rounds.
	 *
	 * Taking the address of it must not load either. */
	if(member_is_array) return;
	/* AND THE SAME chain_continues RULE THE ARROW SITE ALREADY HAS.
	 *
	 * `.` and `[` returned above, so the only continuation that reaches here
	 * is `->`, and an intermediate `->` still has to LOAD the pointer to
	 * follow it. This returned unconditionally, so `&a.b->c` added c's offset
	 * to the ADDRESS of b instead of to what b points at. */
	if(TRUE == Address_of && !match("->", global_token->s)) return;

	/* A STRUCT IS NEVER LOADED INTO A REGISTER -- dereferencing a struct
	 * pointer yields its ADDRESS, which every other struct path assumes. */
	if(register_size >= current_target->size)
	{
		emit_out(load_value(current_target->size, current_target->is_signed));
	}
}

void postfix_expr_array(void)
{
	char* prefix_operator = global_token->prev->prev->s;
	int was_address_of = Address_of;

	struct type* array = current_target;
	common_recursion(expression);
	current_target = array;

	/* AND RESTORE Address_of, WHICH THE INDEX PARSE JUST DESTROYED.
	 *
	 * common_recursion parses the index through primary_expr, whose first act
	 * is to clear Address_of unless it sees a `&`. This function saved the
	 * flag into was_address_of and is therefore fine itself -- but anything
	 * that runs AFTER it reads the global, and by then it is FALSE:
	 *
	 *     pp = &pool[0].next;
	 *
	 * postfix_expr_dot handles `.next` and takes the address-of branch on the
	 * global, so it emitted the member LOAD and pp got pool[0].next instead
	 * of its address. `&head->next`, with no index in front, was always right.
	 *
	 * current_target is restored one line up for exactly the same reason.
	 * This is the same restore, for the other piece of state the index parse
	 * walks over. */
	Address_of = was_address_of;

	require(NULL != current_target, "Arrays only apply to variables\n");

	/* THE LOAD WIDTH IS THE ELEMENT'S, WHICH IS WHAT THE TYPE POINTS AT.
	 *
	 * This matched the literal NAME "char*" and used one byte for it,
	 * otherwise a whole register. So `char msg[] = "hello"; msg[0]` -- whose
	 * type is named `char`, not `char*` -- loaded EIGHT bytes and compared
	 * the first six characters of the string against 'h'.
	 *
	 * A name comparison cannot answer a question about width. The element
	 * size can, and it is the same expression the stride below already uses,
	 * so the two now agree by construction instead of by coincidence.
	 *
	 * The array-of-pointers case (`char *arr[8]`, element width 8) is still
	 * wrong here for the same reason it is wrong in the store: micro-c cannot
	 * tell that from `char *p`. That is the known gap behind case 01, and it
	 * is left visible. */
	/* AND A STRUCT ELEMENT IS NOT LOADED AT ALL -- the same rule as everywhere
	 * else in this compiler. An array of 57-byte structs has no load width;
	 * indexing one yields its ADDRESS. tccpp.c indexes an array of TokenSym
	 * and that is what asked for load_value(57). */
	/* THREE CASES, and the old code collapsed them into a name comparison:
	 *
	 *   size 0            an OPAQUE element -- FILE, or any struct declared
	 *                     but not defined. Nothing is known about its width,
	 *                     and what is being indexed is almost always an array
	 *                     of POINTERS to it, so load a register.
	 *   size > register   a STRUCT element. It has no load width; indexing
	 *                     yields its ADDRESS, as everywhere else here.
	 *   otherwise         the element's own width, which is what the stride
	 *                     below already uses -- so the two agree by
	 *                     construction rather than by coincidence.
	 *
	 * tccpp.c supplied both awkward cases: an array of 57-byte TokenSym, and
	 * an array involving FILE. */
	/* AN ARRAY'S ELEMENT IS current_target ITSELF; A POINTER'S IS WHAT IT
	 * POINTS AT.
	 *
	 *     char *p;        p[i]      element is char    -> ->type->size
	 *     char *arr[8];   arr[i]    element is char*   -> ->size
	 *
	 * Both leave current_target as `char *`, so nothing in the type
	 * distinguishes them; indexing_an_array carries the answer from whoever
	 * knew -- member access via is_array, locals and globals via
	 * TLO_LOCAL_ARRAY and array_modifier.
	 *
	 * Getting this wrong either way is severe. Using ->size for a pointer made
	 * every char-buffer write eight bytes wide and corrupted the stack; using
	 * ->type->size for an array of pointers stored one byte of each and left
	 * seven of garbage. Both were live in this tree in the last two rounds. */
	int element_size = current_target->type->size;
	if(indexing_an_array) element_size = current_target->size;
	indexing_an_array = FALSE;   /* one index, one answer */
	indexed_element_size = element_size;

	char* assign = "";
	if(0 == element_size)
	{
		assign = load_value(register_size, current_target->is_signed);
	}
	else if(register_size >= element_size)
	{
		assign = load_value(element_size, current_target->is_signed);
	}

	/* THE NAME COMPARISON, ACTUALLY REMOVED THIS TIME.
	 *
	 * The comment above says a name cannot answer a question about width, and
	 * then this asked one anyway -- and it decided TWO things: a one-byte load
	 * AND no stride multiply at all. Both are right for `char *p; p[i]`, where
	 * the element is a char. Both are wrong for `char *arr[8]`, where the
	 * element is a char POINTER: the index went unscaled and one signed byte
	 * of an eight-byte pointer was loaded. `current_target` is `char *` in
	 * BOTH cases, which is exactly why a name cannot separate them.
	 *
	 * element_size already separates them, six lines up, via
	 * indexing_an_array. Using it means the load width and the stride agree by
	 * construction rather than by coincidence -- which is what the comment
	 * above claimed and the code below did not do.
	 *
	 * `assign` is left as the earlier branch set it, so an `unsigned char`
	 * array keeps its unsigned load; the old override forced TRUE and would
	 * have sign-extended it.
	 *
	 * FOUND BY BORROWING STAGE 2's CONFORMANCE CORPUS. Nine of its 426
	 * programs fail on this -- 394, 396, 397, 398, 400, 401, 402, 403, 404 --
	 * and the stage-3 case suite has been green over it every round, because
	 * every array-of-pointers case in it used `long*`, where the element width
	 * and the pointed-at width are both 8. */
	if(1 != element_size)
	{
		emit_mul_register_zero_with_immediate(element_size, "primary expr array");
	}

	emit_add(REGISTER_ZERO, REGISTER_ONE, TRUE, "primary expr array");

	require_match("ERROR in postfix_expr\nMissing ]\n", "]");
	require(NULL != global_token, "truncated array expression\n");

	int is_prefix_operator = match("++", prefix_operator) || match("--", prefix_operator);
	int is_postfix_operator = match("++", global_token->s) || match("--", global_token->s);

	/* `->` NEEDS THE ELEMENT'S VALUE, WHATEVER THE CONTEXT WANTS.
	 *
	 * Every other entry in this condition is an lvalue context, where the
	 * ADDRESS of the element is the answer and loading it would be one step
	 * too far. An arrow is different: the element is a POINTER and the thing
	 * being addressed lives at the other end of it, so the load is not
	 * optional -- it is how you get there.
	 *
	 *     ps = &table_ident[v - TOK_IDENT]->sym_identifier;    tccgen.c
	 *
	 * `&` set was_address_of, the load was blanked, and the member offset was
	 * added to the address of the ARRAY SLOT instead of to the TokenSym. For
	 * `alloca` that is index 195 plus 32 bytes = slot 199, and
	 * global_identifier_push then stored a Sym* there -- over a live entry of
	 * the token table. tcc's own symbol table, corrupted two slots at a time,
	 * on every declaration carrying an asm rename.
	 *
	 * That is the SIGSEGV this spike has been chasing: the overwritten entries
	 * reach tal_free as pointers belonging to no allocator buffer, and
	 * tal_free_impl walks its list off the end with no NULL check.
	 *
	 * Same rule as EXPERIMENT-zzc and zzg for prefix ++/--: a request for an
	 * address applies to the LAST step of a chain, never to a step that still
	 * has to be followed. This is the third function to learn it separately;
	 * MICRO-C.md counts the class. */
	int arrow_follows = match("->", global_token->s);
	if(!arrow_follows)
	{
		if(match("=", global_token->s) || is_compound_assignment(global_token->s) || match(".", global_token->s) || is_prefix_operator || is_postfix_operator || was_address_of || assign_through_parens)
		{
			assign = "";
		}
	}
	/* INDEXING YIELDS THE ELEMENT TYPE, whatever follows.
	 *     case_cmp(p[0]->v2, p[1]->v2)               tccgen.c around 3300
	 * Only a following '[' stepped current_target down, so `p[0]->v2` on a
	 * `struct case_t **p` left it at the double pointer and the member lookup
	 * ran against a level with no members.
	 *
	 * The comma-declarator members were a red herring here -- p[0]->v1 failed
	 * identically. Two rounds went into the wrong hypothesis before testing
	 * the FIRST member proved the declarators innocent.
	 *
	 * AND IT YIELDS IT WHEN A VALUE WAS ACTUALLY LOADED, not only in front of
	 * the three operators that were noticed first. `assign` is the load: it is
	 * emitted for an rvalue and blanked above for every lvalue context (`=`, a
	 * compound assignment, `&`, `++`/`--`). So a non-empty `assign` means the
	 * register now holds an ELEMENT, and saying otherwise is simply false.
	 *
	 * It went unnoticed for the same reason the pointer-arithmetic gap did --
	 * nothing asked. Once `p + n` scales, `pn[0] + 1` on an `int*` reports a
	 * pointer on the left, scales the 1 by eight, and case 10 goes red. The
	 * lvalue paths still need the pointer type, because the store width is
	 * taken from it, which is why this is keyed on the load and not made
	 * unconditional. */
	if(match("[", global_token->s) || match("->", global_token->s) || match(".", global_token->s)
	   || !match("", assign))
	{
		current_target = current_target->type;
	}

	emit_out(assign);
}

/*
 * unary-expr:
 *         &postfix-expr
 *         - postfix-expr
 *         !postfix-expr
 *         sizeof ( type )
 */
int unary_expr_sizeof(void)
{
	require_extra_token();
	/* `sizeof x` WITHOUT PARENTHESES. C requires them only for a TYPE operand;
	 * for an expression `sizeof x` is legal, and tccpp.c:104 writes
	 *     pstrcpy(tmp, sizeof tmp, ...)
	 * The body below already resolves a variable and computes its size, so
	 * only the mandatory '(' was in the way. Remember whether we consumed one,
	 * and require the matching ')' only if we did. */
	int sizeof_parens = 0;
	if(global_token->s[0] == '(')
	{
		sizeof_parens = 1;
		require_extra_token();
	}
	require(NULL != global_token, "Incomplete sizeof expression.\n");

	/* `sizeof ((T*)0)->member` -- the idiom for the size of a member without
	 * an instance:
	 *     stab_section->sh_addralign = sizeof ((Stab_Sym*)0)->n_value;
	 *                                              tccdbg.c:497
	 *
	 * The '(' consumed above was NOT sizeof's delimiter; it opened a CAST
	 * expression, and the member walk continues after the closing paren. So:
	 * take the cast type, discard the operand (its value is irrelevant --
	 * sizeof asks about types), close the paren we opened, and let the member
	 * walk below run against the cast type. */
	if(sizeof_parens)
	{
		if(global_token->s[0] == '(')
		{
			struct token_list* before_cast = global_token;
			require_extra_token();
			struct type* cast_t = fallible_type_name();
			if(NULL != cast_t)
			{
				require_match("ERROR in sizeof\nMissing ) after cast\n", ")");
				/* the operand -- a constant, conventionally 0 */
				constant_expression();
				require_match("ERROR in sizeof\nMissing ) after cast operand\n", ")");
				sizeof_parens = 0;   /* that paren is now accounted for */

				struct type* ca = cast_t;
				int csize = ca->size;
				while(NULL != global_token)
				{
					if(match("->", global_token->s) || match(".", global_token->s))
					{
						if(match("->", global_token->s)) ca = ca->type;
						require_extra_token();
						require(NULL != global_token, "Incomplete sizeof member access\n");
						struct type* cm = lookup_member(ca, global_token->s);
						ca = cm->type;
						csize = cm->size;
						require_extra_token();
					}
					else break;
				}
				return csize;
			}
			global_token = before_cast;
		}
	}

	struct token_list* t = NULL;

	int num_dereferences = 0;
	if(!BOOTSTRAP_MODE)
	{
		if(global_token->s[0] == '\"')
		{
			/* string_length (strlen) doesn't include the null terminator but the
			 * token starts with a quotation mark so the count will be correct. */
			int length = string_size(global_token->s);

			require_extra_token();

			if(sizeof_parens) require_match("ERROR in unary_expr\nMissing )\n", ")");

			return length;
		}

		while(global_token->s[0] == '*')
		{
			num_dereferences = num_dereferences + 1;
			require_extra_token();
		}

		t = static_variable_lookup(global_token->s);
		if(NULL == t)
		{
			t = sym_lookup(global_token->s, global_constant_list);
			if(NULL == t && NULL != function)
			{
				t = sym_lookup(global_token->s, function->locals);
				if(NULL == t)
				{
					t = sym_lookup(global_token->s, function->arguments);
				}
			}
		}

		if(NULL == t)
		{
			t = sym_lookup(global_token->s, global_symbol_list);
		}
	}

	int size = 0;
	if(t != NULL)
	{
		require_extra_token();

		struct type* a = t->type;
		/* THE DEREFERENCE IS APPLIED AFTER THE MEMBER CHAIN, NOT BEFORE.
		 * See the note at the bottom of this block -- `sizeof(*s->tab)` is
		 * `sizeof(*(s->tab))`, so the star belongs to the MEMBER. */

		/* `sizeof x->y` and `sizeof x.y`. tccpp.c:1809 writes
		 *     pstrcpy(file->filename, sizeof file->filename, buf);
		 * and this only resolved the base variable, then tried to look
		 * `filename` up in whatever type followed -- "lookup_member
		 * char->filename does not exist". Walk the member chain here; sizeof
		 * is a compile-time query, so nothing is emitted. */
		int member_array = 0;
		int indexed = 0;
		while(NULL != global_token)
		{
			/* `sizeof (x[0])` -- INDEXING inside sizeof.
			 *     #define N_DEFAULT_DEBUG \
			 *         (sizeof (default_debug) / sizeof (default_debug[0]))
			 *                                              tccdbg.c:82
			 * That idiom is how C code counts array elements, so it turns up
			 * wherever a table is declared. The index is a constant expression
			 * and its VALUE is irrelevant -- sizeof asks about the type -- so
			 * it is parsed and discarded, and the type steps down one level. */
			if(match("[", global_token->s))
			{
				require_extra_token();
				constant_expression();
				require_match("ERROR in sizeof\nMissing ]\n", "]");
				/* INDEXING DROPS THE ARRAY COUNT, it does not step the type.
				 * For `struct D tbl[8]` the element type IS D -- the array-ness
				 * lives in array_modifier, not in a level of the type chain.
				 * Stepping a->type gave sizeof(tbl[0]) == sizeof(tbl) == 128
				 * instead of 16. */
				indexed = 1;
				member_array = 0;
				continue;
			}
			if(match("->", global_token->s) || match(".", global_token->s))
			{
				if(match("->", global_token->s))
				{
					a = a->type;
				}
				require_extra_token();
				require(NULL != global_token, "Incomplete sizeof member access\n");
				struct type* m = lookup_member(a, global_token->s);
				a = m->type;
				member_array = m->size;
				require_extra_token();
			}
			else break;
		}
		/* A UNARY `*` BINDS LOOSER THAN A POSTFIX ACCESS -- IN sizeof TOO.
		 *
		 * The stars were applied to the BASE VARIABLE's type before the member
		 * chain was walked, so `sizeof(*s->tab)` measured `(*s).tab` instead
		 * of `*(s->tab)`: it stepped State* down to State, looked `tab` up in
		 * it, and reported the POINTER's width. Eight instead of sixteen.
		 *
		 * `sizeof(*p)` on a plain pointer was correct and always had been,
		 * which is why this survived -- the two forms disagree only when a
		 * member sits between the star and the name. Entry 20 fixed exactly
		 * this precedence for the ordinary expression path, in
		 * postfix_expr; sizeof kept its own copy and never learned it.
		 *
		 * WHAT IT COST. tccelf.c:815 sizes the sym_attr table with
		 *     tcc_realloc(s1->sym_attrs, n * sizeof(*s1->sym_attrs))
		 * so the table was allocated at HALF the space its own indexing
		 * strides through. The first entries are inside it and the later ones
		 * read whatever follows on the heap -- a got_offset came back as
		 * 0x65007374, printable ASCII from a string -- which put one GOT
		 * relocation at a wild address and segfaulted every linked binary.
		 *
		 * A dereference yields the pointed-to type, so it overrides the
		 * member and array rules below rather than being combined with them. */
		if(num_dereferences > 0)
		{
			/* AN ARRAY NAME IS ALREADY ITS ELEMENT TYPE, so the first star
			 * has nothing to step.
			 *
			 *     static const char * const libs[] = { ... };
			 *     sizeof(*libs)      8, a char*      -- micro-c said 1
			 *     sizeof(libs[0])    8               -- always right
			 *     sizeof(*arr)       8, a long       -- right by ACCIDENT:
			 *                        long->type is long, so the extra step
			 *                        lands back where it started
			 *
			 * A declaration `T name[N]` records T in the symbol's type and N
			 * in array_modifier, so `a` is the ELEMENT before any star is
			 * applied. Stepping once more gave what the element points at --
			 * char, for an array of char* -- and only an array whose element
			 * is self-referential hid it.
			 *
			 * WHAT IT COST. tcc picks its library-search format with
			 *     pp += sizeof(libs) / sizeof(*libs) - 2;   libtcc.c:1130
			 * and 24/1 - 2 is 22, so `pp` landed far past the array and *pp
			 * was a pointer into unrelated data. The format string came out
			 * as "P" and every -l search built a path of one character:
			 *     LIB fmt=P path=/usr/lib name=c   ->  [P]
			 * so mc-tcc segfaulted on any link that resolved a library by
			 * name. That is rung 3 of the stage-4 ladder -- the first HOSTED
			 * link, where -static takes exactly that branch.
			 *
			 * NOT WHEN THE ARRAY WAS INDEXED. `sizeof(*arr[0])` has already
			 * decayed through the subscript, so the star there is a real
			 * dereference and must step.
			 *
			 * GREATER THAN ONE, NOT NON-ZERO. array_modifier defaults to 1
			 * for every symbol (cc_core.c:186) and only an actual array sets
			 * it higher -- which is why the sites at 1765 and 1940 test `> 1`
			 * and `<= 1`. Testing `!= 0` here was true for every pointer as
			 * well, and `sizeof(*p)` on a plain struct pointer came back 8
			 * instead of 16. Case 108 caught it. */
			if((t->array_modifier > 1) && (0 == indexed))
			{
				num_dereferences = num_dereferences - 1;
			}
			while(num_dereferences > 0)
			{
				a = a->type;
				num_dereferences = num_dereferences - 1;
			}
			size = a->size;
		}
		else if(0 != member_array)
		{
			size = member_array;
		}
		else if(indexed)
		{
			size = a->size;
		}
		else if(t->array_modifier != 0)
		{
			size = a->size * t->array_modifier;
		}
		else size = a->size;
	}
	else
	{
		if(num_dereferences != 0)
		{
			line_error();
			fputs("Unable to dereference type for sizeof.\n", stderr);
			exit(EXIT_FAILURE);
		}

		struct type* a = type_name();
		size = a->size;
	}

	if(sizeof_parens) require_match("ERROR in unary_expr\nMissing )\n", ")");

	return size;
}

void postfix_expr_stub(void)
{
	require(NULL != global_token, "Unexpected EOF, improperly terminated primary expression\n");
	if(match("[", global_token->s))
	{
		postfix_expr_array();
		postfix_expr_stub();
	}

	if(match("->", global_token->s))
	{
		postfix_expr_arrow();
		postfix_expr_stub();
	}

	if(match(".", global_token->s))
	{
		postfix_expr_dot();
		postfix_expr_stub();
	}

	if(match("++", global_token->s) || match("--", global_token->s))
	{
		postfix_expr_inc_or_dec();
		postfix_expr_stub();
	}

	if(global_token->s[0] == '(')
	{
		if((current_target->options & TO_FUNCTION_POINTER))
		{
			function_call(NULL, TRUE);
		}
		else
		{
			line_error();
			fputs("Attempted to use operator ( on non-function pointer", stderr);
			fputs(" -- type '", stderr);
			if(NULL != current_target->name) fputs(current_target->name, stderr);
			fputs("' options=", stderr);
			fputs(int2str(current_target->options, 10, FALSE), stderr);
			exit(EXIT_FAILURE);
		}
	}
}

void postfix_expr(void)
{
	primary_expr();
	postfix_expr_stub();

	/* Apply any dereference deferred past the postfix chain -- see the note in
	 * primary_expr_variable. postfix_expr_stub recurses, so this has to happen
	 * here rather than inside it, or it would fire at every level.
	 *
	 * AN ASSIGNMENT TARGET MUST NOT BE LOADED. `*bf->buf_end = 7` wants the
	 * pointer's VALUE as the destination address; the ordinary dereference
	 * path guards this with is_assignment and leaves the address in the
	 * register. Loading anyway emitted ldrb -- one byte of an eight-byte
	 * pointer -- and stored through the truncated result. Step the type down
	 * either way, because the store width comes from it. */
	/* A PREFIX ++/-- TARGET IS AN ASSIGNMENT TARGET.
	 *
	 * The two branches below differ only in whether current_target is stepped
	 * before or after the load, which decides whether the load reads the
	 * POINTER or the object it points at. `*p = v` takes the second, correct
	 * one -- its comment says so -- and `--*p` took the first, because the
	 * test only looked for an `=`.
	 *
	 * While every type was register-width both widths were eight and the
	 * branches were interchangeable. At four bytes `--*p` loaded an
	 * eight-byte pointer with a four-byte ldrsw and incremented through the
	 * truncated address. dynarray_reset's `--*n` is that line, so tcc
	 * segfaulted before it had parsed anything -- even --version died.
	 *
	 * prefix_lvalue_target is already set by the prefix handler for exactly
	 * this purpose and is still standing here: the member sites at 2051 and
	 * 2270 consume it, and `--*p` reaches neither. */
	int assigning = match("=", global_token->s) || is_compound_assignment(global_token->s)
	                || prefix_lvalue_target;

	/* A CALL'S RESULT IS ALREADY THE POINTER; A VARIABLE'S SLOT IS NOT.
	 *
	 * The assigning branch below loads once to turn an lvalue into the address
	 * being stored through. That is right for a variable, where the register
	 * holds the address of the SLOT:
	 *
	 *     lea_rax,[r13-8]      address of the slot holding p
	 *     mov_rax,[rax]        p's VALUE -- the destination
	 *
	 * and one step too far for a call, where `call` has already left the
	 * returned pointer in the register:
	 *
	 *     call_rax             rax = &buf[16]
	 *     mov_rax,[rax]        <-- loads buf[16..23] and stores through THAT
	 *
	 * so `*give(16) = 99` wrote 99 to whatever eight bytes happened to be at
	 * buf[16]. tcc writes every byte of .eh_frame through exactly this shape,
	 * `*(uint8_t*)section_ptr_add((s), 1) = (data)` at tccdbg.c:550.
	 *
	 * ONLY THE FIRST LEVEL IS SPARED. `**f() = v` still has to load once to
	 * reach the inner pointer -- a call result starts the chain one step
	 * further along, it does not shorten every step. Same rule as zzc, zzg,
	 * zzm and zzo: an address applies to the last step of a chain, never to a
	 * step that still has to be followed. */
	int result_is_call = last_expr_was_call;
	int outermost_deref = num_dereference_after_postfix;
	last_expr_was_call = FALSE;

	int fp_nd;
	while(num_dereference_after_postfix > 0)
	{
		fp_nd = current_target->type == current_target->type->type && (current_target->type->options & TO_FUNCTION_POINTER);
		if(!fp_nd)
		{
			if(!assigning)
			{
				current_target = current_target->type;
				/* A STRUCT IS NEVER LOADED INTO A REGISTER. Dereferencing a
						 * struct pointer yields its ADDRESS, which is what every
						 * other struct path already assumes -- member access has
						 * had this guard all along. Without it `x = *p` for a
						 * struct tried load_value(16):
						 *     unsupported size 16 of type 'CType'   tccgen.c:895 */
						if(register_size >= current_target->size) emit_out(load_value(current_target->size, current_target->is_signed));
			}
			else
			{
				/* Load the POINTER (this level's width), then the value being
				 * stored is written at the pointed-to type's width. */
				/* A STRUCT IS NEVER LOADED INTO A REGISTER. Dereferencing a
						 * struct pointer yields its ADDRESS, which is what every
						 * other struct path already assumes -- member access has
						 * had this guard all along. Without it `x = *p` for a
						 * struct tried load_value(16):
						 *     unsupported size 16 of type 'CType'   tccgen.c:895 */
						if(!(result_is_call && (outermost_deref == num_dereference_after_postfix)))
						{
							if(register_size >= current_target->size) emit_out(load_value(current_target->size, current_target->is_signed));
						}
				current_target = current_target->type;
			}
		}
		num_dereference_after_postfix = num_dereference_after_postfix - 1;
	}
}

/*
 * additive-expr:
 *         postfix-expr
 *         additive-expr * postfix-expr
 *         additive-expr / postfix-expr
 *         additive-expr % postfix-expr
 *         additive-expr + postfix-expr
 *         additive-expr - postfix-expr
 *         additive-expr << postfix-expr
 *         additive-expr >> postfix-expr
 */
void additive_expr_stub_a(void)
{
	if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture))
	{
		arithmetic_recursion(postfix_expr, "MUL R0 R1 R0\n", "MULU R0 R1 R0\n", "*", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "DIV R0 R1 R0\n", "DIVU R0 R1 R0\n", "/", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "MOD R0 R1 R0\n", "MODU R0 R1 R0\n", "%", additive_expr_stub_a);
	}
	else if(X86 == Architecture)
	{
		arithmetic_recursion(postfix_expr, "imul_ebx\n", "mul_ebx\n", "*", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "xchg_ebx,eax\ncdq\nidiv_ebx\n", "xchg_ebx,eax\nxor_edx,edx\ndiv_ebx\n", "/", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "xchg_ebx,eax\ncdq\nidiv_ebx\nmov_eax,edx\n", "xchg_ebx,eax\nxor_edx,edx\ndiv_ebx\nmov_eax,edx\n", "%", additive_expr_stub_a);
	}
	else if(AMD64 == Architecture)
	{
		arithmetic_recursion(postfix_expr, "imul_rbx\n", "mul_rbx\n", "*", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "xchg_rbx,rax\ncqo\nidiv_rbx\n", "xchg_rbx,rax\nxor_edx,edx\ndiv_rbx\n", "/", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "xchg_rbx,rax\ncqo\nidiv_rbx\nmov_rax,rdx\n", "xchg_rbx,rax\nxor_edx,edx\ndiv_rbx\nmov_rax,rdx\n", "%", additive_expr_stub_a);
	}
	else if(ARMV7L == Architecture)
	{
		arithmetic_recursion(postfix_expr, "'9' R0 '0' R1 MULS R0 ARITH2_ALWAYS\n", "'9' R0 '0' R1 MUL R0 ARITH2_ALWAYS\n", "*", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "{LR} PUSH_ALWAYS\n^~divides CALL_ALWAYS\n{LR} POP_ALWAYS\n", "{LR} PUSH_ALWAYS\n^~divide CALL_ALWAYS\n{LR} POP_ALWAYS\n", "/", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "{LR} PUSH_ALWAYS\n^~moduluss CALL_ALWAYS\n{LR} POP_ALWAYS\n", "{LR} PUSH_ALWAYS\n^~modulus CALL_ALWAYS\n{LR} POP_ALWAYS\n", "%", additive_expr_stub_a);
	}
	else if(AARCH64 == Architecture)
	{
		general_recursion(postfix_expr, "mul_x0,x1,x0\n", "*", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "sdiv_x0,x1,x0\n", "udiv_x0,x1,x0\n", "/", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "sdiv_x2,x1,x0\nmsub_x0,x0,x2,x1\n", "udiv_x2,x1,x0\nmsub_x0,x0,x2,x1\n", "%", additive_expr_stub_a);
	}
	else if((RISCV32 == Architecture) || (RISCV64 == Architecture))
	{
		general_recursion(postfix_expr, "rd_a0 rs1_a1 rs2_a0 mul\n", "*", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "rd_a0 rs1_a1 rs2_a0 div\n", "rd_a0 rs1_a1 rs2_a0 divu\n", "/", additive_expr_stub_a);
		arithmetic_recursion(postfix_expr, "rd_a0 rs1_a1 rs2_a0 rem\n", "rd_a0 rs1_a1 rs2_a0 remu\n", "%", additive_expr_stub_a);
	}
}


void additive_expr_a(void)
{
	postfix_expr();
	additive_expr_stub_a();
}

/* THE ELEMENT SIZE THIS OPERAND'S ARITHMETIC SCALES BY, or 0 if it is not a
 * pointer that scales at all.
 *
 * type_is_pointer() alone is not the question. Two of the things it says yes
 * to have no element to measure:
 *
 *   a FUNCTION pointer   ->type is itself, so ->type->size is the pointer's
 *                        own width and scaling by it would be nonsense
 *   an OPAQUE struct     size 0 (NO_STRUCT_DEFINITION) -- `struct FILE*` with
 *                        no definition in scope. Multiplying by 0 would zero
 *                        the offset silently, which is worse than not scaling
 *
 * A size of 1 IS a scaling pointer -- `char*` -- and the caller must treat it
 * as one, because `p - q` on char* still yields a count and its result type is
 * an integer. It simply needs no multiply emitted. So this returns the size
 * and the caller decides; "is it a pointer" and "must I emit a multiply" are
 * different questions and conflating them is what the earlier version did. */
int pointer_element_size(struct type* t)
{
	if(NULL == t) return 0;
	if(!type_is_pointer(t)) return 0;
	if(t->options & TO_FUNCTION_POINTER) return 0;
	if(NULL == t->type) return 0;
	if(t->type == t) return 0;
	if(0 >= t->type->size) return 0;
	return t->type->size;
}

/* R0 = R0 / <immediate>, for the pointer-difference case.
 *
 * The instruction sequences are the SAME ones the `/` operator lowers to in
 * additive_expr_stub_a, deliberately: every one of them is already proven
 * against the M1 vocabulary for its architecture, so this adds no new macro on
 * any target. They all compute R0 = R1 / R0, so the value is moved into R1 and
 * the divisor loaded into R0 first.
 *
 * The signed forms are used because a pointer difference is signed -- `p - q`
 * is negative when q is further along. */
void emit_divide_register_zero_by_immediate(int value, char* note)
{
	emit_move(REGISTER_ONE, REGISTER_ZERO, note);
	emit_load_immediate(REGISTER_ZERO, value, note);

	if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) emit_out("DIV R0 R1 R0\n");
	else if(X86 == Architecture) emit_out("xchg_ebx,eax\ncdq\nidiv_ebx\n");
	else if(AMD64 == Architecture) emit_out("xchg_rbx,rax\ncqo\nidiv_rbx\n");
	else if(ARMV7L == Architecture) emit_out("{LR} PUSH_ALWAYS\n^~divides CALL_ALWAYS\n{LR} POP_ALWAYS\n");
	else if(AARCH64 == Architecture) emit_out("sdiv_x0,x1,x0\n");
	else if(Architecture & ARCH_FAMILY_RISCV) emit_out("rd_a0 rs1_a1 rs2_a0 div\n");
}

/* SWAP THE TWO OPERANDS. `n + p` needs the scale applied to the LEFT operand,
 * which sits in R1, and the multiply helper only knows how to scale R0.
 * Addition is commutative, so exchanging them is exact rather than a
 * workaround -- and it is done through the stack rather than through a scratch
 * register because on aarch64 the temps have a deliberately narrow M1
 * vocabulary (see emit_advance_temp) and this is not on their list. */
void emit_swap_operands(char* note)
{
	emit_push(REGISTER_ZERO, note);
	emit_move(REGISTER_ZERO, REGISTER_ONE, note);
	emit_pop(REGISTER_ONE, note);
}

void additive_expr_stub_b(void)
{
	require(NULL != global_token, "Received EOF in additive_expr_stub_a\n");

	/* POINTER ARITHMETIC SCALES BY THE POINTED-AT SIZE.
	 *
	 *     long lbuf[4];  lbuf + 1     must be eight bytes on, not one
	 *     long *q;       q + 1        the same
	 *     int **p;       *p + 1       the same, and this one is tcc's TOK_GET
	 *
	 * micro-c emitted a plain add, so `p + n` advanced n BYTES whatever p
	 * pointed at. Indexing was right -- p[n] scales, postfix_expr_array does
	 * it, and so do `p++` and `p += n` -- which is why this survived: this
	 * was the ONE arithmetic path that did not, and M2-Planet's own sources
	 * index rather than add.
	 *
	 * ALL FOUR SHAPES ARE HANDLED, because the previous attempt handled one
	 * and the other three were not merely unhandled but actively wrong:
	 *
	 *     p + n   scale the right operand by sizeof(*p)     result: pointer
	 *     n + p   scale the LEFT operand, so swap first     result: pointer
	 *     p - n   scale the right operand                   result: pointer
	 *     p - q   subtract, then DIVIDE by the element size  result: integer
	 *
	 * What made this possible is operand_left_type/operand_right_type above.
	 * The shelved version could only inspect the promoted type, which is why
	 * it could not tell those four apart -- and why wiring it in fixed `p + n`
	 * and broke `pn[0] = pn[0] + 1`, where the left operand is an indexed
	 * pointer whose promoted type still looks like one.
	 *
	 * THE RESULT TYPE IS SET EXPLICITLY, and that is half the fix rather than
	 * a tidy-up. promote_type is a name lookup: for `long* + int` it returns
	 * plain `long`, so after `q = q + 1` the expression no longer knew it held
	 * a pointer and the NEXT operator in a chain -- `p + 1 + 1`, `*(p + 1)`,
	 * `(p + 1)->m` -- had nothing to scale by. */
	if(match("+", global_token->s))
	{
		common_recursion(additive_expr_a);
		/* + AND - HAVE THEIR OWN PATH, for the pointer scaling below, and so
		 * they never reached general_recursion's conversion. uac-sweep found
		 * it as `char - 0xFFFFFFFF`: gcc 0, micro-c non-zero. The guard in
		 * the conversion excludes anything register-width, so the pointer
		 * cases here -- whose operand IS eight bytes -- are untouched. */
		emit_usual_arithmetic_conversion(operand_left_type, operand_right_type);
		struct type* lhs = operand_left_type;
		struct type* rhs = operand_right_type;
		int left_element = pointer_element_size(lhs);
		int right_element = pointer_element_size(rhs);
		int is_signed = current_target->is_signed;

		if(0 != left_element && 0 == right_element)
		{
			if(1 < left_element) emit_mul_register_zero_with_immediate(left_element, "pointer arithmetic");
			emit_add(REGISTER_ZERO, REGISTER_ONE, is_signed, NULL);
			current_target = lhs;
		}
		else if(0 == left_element && 0 != right_element)
		{
			if(1 < right_element)
			{
				emit_swap_operands("int + pointer");
				emit_mul_register_zero_with_immediate(right_element, "pointer arithmetic");
			}
			emit_add(REGISTER_ZERO, REGISTER_ONE, is_signed, NULL);
			current_target = rhs;
		}
		else
		{
			/* Two pointers added together is not C, and two non-pointers
			 * need nothing. Both keep the promoted type. */
			emit_add(REGISTER_ZERO, REGISTER_ONE, is_signed, NULL);
		}
		/* AND THE SUM IS MODULO THE CHOSEN TYPE. `char x = 1; x + 0xFFFFFFFF`
		 * is 4294967296, which is 0 in unsigned int and non-zero in a 64-bit
		 * register. The pointer branches above set current_target to a
		 * pointer, which is register-width, so this is a no-op for them. */
		emit_result_in_chosen_type();
		additive_expr_stub_b();
	}
	else if(match("-", global_token->s))
	{
		common_recursion(additive_expr_a);
		/* + AND - HAVE THEIR OWN PATH, for the pointer scaling below, and so
		 * they never reached general_recursion's conversion. uac-sweep found
		 * it as `char - 0xFFFFFFFF`: gcc 0, micro-c non-zero. The guard in
		 * the conversion excludes anything register-width, so the pointer
		 * cases here -- whose operand IS eight bytes -- are untouched. */
		emit_usual_arithmetic_conversion(operand_left_type, operand_right_type);
		struct type* lhs = operand_left_type;
		struct type* rhs = operand_right_type;
		int left_element = pointer_element_size(lhs);
		int right_element = pointer_element_size(rhs);
		int is_signed = current_target->is_signed;

		if(0 != left_element && 0 == right_element)
		{
			if(1 < left_element) emit_mul_register_zero_with_immediate(left_element, "pointer arithmetic");
			emit_rsub(REGISTER_ZERO, REGISTER_ONE, is_signed, NULL);
			current_target = lhs;
		}
		else if(0 != left_element && 0 != right_element)
		{
			/* A DIFFERENCE OF POINTERS IS A COUNT OF ELEMENTS, not of bytes,
			 * so the divide comes AFTER the subtraction. The result is an
			 * integer -- leaving it a pointer would make the next operator in
			 * a chain scale a count, which is how `r - p - 1` would go wrong
			 * on anything wider than a char. */
			emit_rsub(REGISTER_ZERO, REGISTER_ONE, is_signed, NULL);
			if(1 < left_element) emit_divide_register_zero_by_immediate(left_element, "pointer difference");
			current_target = integer;
		}
		else
		{
			emit_rsub(REGISTER_ZERO, REGISTER_ONE, is_signed, NULL);
		}
		additive_expr_stub_b();
	}
}


void additive_expr_b(void)
{
	additive_expr_a();
	additive_expr_stub_b();
}

void additive_expr_stub_c(void)
{
	if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture))
	{
		arithmetic_recursion(additive_expr_b, "SAL R0 R1 R0\n", "SL0 R0 R1 R0\n", "<<", additive_expr_stub_c);
		arithmetic_recursion(additive_expr_b, "SAR R0 R1 R0\n", "SR0 R0 R1 R0\n", ">>", additive_expr_stub_c);
	}
	else if(X86 == Architecture)
	{
		arithmetic_recursion(additive_expr_b, "mov_ecx,eax\nmov_eax,ebx\nsal_eax,cl\n", "mov_ecx,eax\nmov_eax,ebx\nshl_eax,cl\n", "<<", additive_expr_stub_c);
		arithmetic_recursion(additive_expr_b, "mov_ecx,eax\nmov_eax,ebx\nsar_eax,cl\n", "mov_ecx,eax\nmov_eax,ebx\nshr_eax,cl\n", ">>", additive_expr_stub_c);
	}
	else if(AMD64 == Architecture)
	{
		arithmetic_recursion(additive_expr_b, "mov_rcx,rax\nmov_rax,rbx\nsal_rax,cl\n", "mov_rcx,rax\nmov_rax,rbx\nshl_rax,cl\n", "<<", additive_expr_stub_c);
		arithmetic_recursion(additive_expr_b, "mov_rcx,rax\nmov_rax,rbx\nsar_rax,cl\n", "mov_rcx,rax\nmov_rax,rbx\nshr_rax,cl\n", ">>", additive_expr_stub_c);
	}
	else if(ARMV7L == Architecture)
	{
		arithmetic_recursion(additive_expr_b, "LEFT R1 R0 R0 SHIFT AUX_ALWAYS\n", "LEFT R1 R0 R0 SHIFT AUX_ALWAYS\n", "<<", additive_expr_stub_c);
		arithmetic_recursion(additive_expr_b, "ARITH_RIGHT R1 R0 R0 SHIFT AUX_ALWAYS\n", "RIGHT R1 R0 R0 SHIFT AUX_ALWAYS\n", ">>", additive_expr_stub_c);
	}
	else if(AARCH64 == Architecture)
	{
		general_recursion(additive_expr_b, "lsl_x0,x1,x0\n", "<<", additive_expr_stub_c);
		arithmetic_recursion(additive_expr_b, "asr_x0,x1,x0\n", "lsr_x0,x1,x0\n", ">>", additive_expr_stub_c);
	}
	else if((RISCV32 == Architecture) || (RISCV64 == Architecture))
	{
		general_recursion(additive_expr_b, "rd_a0 rs1_a1 rs2_a0 sll\n", "<<", additive_expr_stub_c);
		arithmetic_recursion(additive_expr_b, "rd_a0 rs1_a1 rs2_a0 sra\n", "rd_a0 rs1_a1 rs2_a0 srl\n", ">>", additive_expr_stub_c);
	}
}


void additive_expr_c(void)
{
	additive_expr_b();
	additive_expr_stub_c();
}


/*
 * relational-expr:
 *         additive_expr
 *         relational-expr < additive_expr
 *         relational-expr <= additive_expr
 *         relational-expr >= additive_expr
 *         relational-expr > additive_expr
 */

void relational_expr_stub(void)
{
	if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture))
	{
		arithmetic_recursion(additive_expr_c, "CMP R0 R1 R0\nSET.L R0 R0 1\n", "CMPU R0 R1 R0\nSET.L R0 R0 1\n", "<", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "CMP R0 R1 R0\nSET.LE R0 R0 1\n", "CMPU R0 R1 R0\nSET.LE R0 R0 1\n", "<=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "CMP R0 R1 R0\nSET.GE R0 R0 1\n", "CMPU R0 R1 R0\nSET.GE R0 R0 1\n", ">=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "CMP R0 R1 R0\nSET.G R0 R0 1\n", "CMPU R0 R1 R0\nSET.G R0 R0 1\n", ">", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "CMP R0 R1 R0\nSET.E R0 R0 1\n", "CMPU R0 R1 R0\nSET.E R0 R0 1\n", "==", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "CMP R0 R1 R0\nSET.NE R0 R0 1\n", "CMPU R0 R1 R0\nSET.NE R0 R0 1\n", "!=", relational_expr_stub);
	}
	else if(X86 == Architecture)
	{
		arithmetic_recursion(additive_expr_c, "cmp_ebx,eax\nsetl_al\nmovzx_eax,al\n", "cmp_ebx,eax\nsetb_al\nmovzx_eax,al\n", "<", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_ebx,eax\nsetle_al\nmovzx_eax,al\n", "cmp_ebx,eax\nsetbe_al\nmovzx_eax,al\n", "<=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_ebx,eax\nsetge_al\nmovzx_eax,al\n", "cmp_ebx,eax\nsetae_al\nmovzx_eax,al\n", ">=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_ebx,eax\nsetg_al\nmovzx_eax,al\n", "cmp_ebx,eax\nseta_al\nmovzx_eax,al\n", ">", relational_expr_stub);
		general_recursion(additive_expr_c, "cmp_ebx,eax\nsete_al\nmovzx_eax,al\n", "==", relational_expr_stub);
		general_recursion(additive_expr_c, "cmp_ebx,eax\nsetne_al\nmovzx_eax,al\n", "!=", relational_expr_stub);
	}
	else if(AMD64 == Architecture)
	{
		arithmetic_recursion(additive_expr_c, "cmp_rbx,rax\nsetl_al\nmovzx_rax,al\n", "cmp_rbx,rax\nsetb_al\nmovzx_rax,al\n", "<", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_rbx,rax\nsetle_al\nmovzx_rax,al\n", "cmp_rbx,rax\nsetbe_al\nmovzx_rax,al\n", "<=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_rbx,rax\nsetge_al\nmovzx_rax,al\n", "cmp_rbx,rax\nsetae_al\nmovzx_rax,al\n", ">=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_rbx,rax\nsetg_al\nmovzx_rax,al\n", "cmp_rbx,rax\nseta_al\nmovzx_rax,al\n", ">", relational_expr_stub);
		general_recursion(additive_expr_c, "cmp_rbx,rax\nsete_al\nmovzx_rax,al\n", "==", relational_expr_stub);
		general_recursion(additive_expr_c, "cmp_rbx,rax\nsetne_al\nmovzx_rax,al\n", "!=", relational_expr_stub);
	}
	else if(ARMV7L == Architecture)
	{
		arithmetic_recursion(additive_expr_c, "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_L\n", "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_LO\n", "<", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_LE\n", "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_LS\n", "<=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_GE\n", "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_HS\n", ">=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_G\n", "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_HI\n", ">", relational_expr_stub);
		general_recursion(additive_expr_c, "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_EQUAL\n", "==", relational_expr_stub);
		general_recursion(additive_expr_c, "'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_NE\n", "!=", relational_expr_stub);
	}
	else if(AARCH64 == Architecture)
	{
		arithmetic_recursion(additive_expr_c, "cmp_x1,x0\ncset_w0,lt\n", "cmp_x1,x0\ncset_w0,cc\n", "<", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_x1,x0\ncset_w0,le\n", "cmp_x1,x0\ncset_w0,ls\n", "<=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_x1,x0\ncset_w0,ge\n", "cmp_x1,x0\ncset_w0,cs\n", ">=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "cmp_x1,x0\ncset_w0,gt\n", "cmp_x1,x0\ncset_w0,hi\n", ">", relational_expr_stub);
		general_recursion(additive_expr_c, "cmp_x1,x0\ncset_w0,eq\n", "==", relational_expr_stub);
		general_recursion(additive_expr_c, "cmp_x1,x0\ncset_w0,ne\n", "!=", relational_expr_stub);
	}
	else if((RISCV32 == Architecture) || (RISCV64 == Architecture))
	{
		arithmetic_recursion(additive_expr_c, "rd_a0 rs1_a1 rs2_a0 slt\n", "rd_a0 rs1_a1 rs2_a0 sltu\n", "<", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "rd_a0 rs1_a0 rs2_a1 slt\nrd_a0 rs1_a0 !1 xori\n", "rd_a0 rs1_a0 rs2_a1 sltu\nrd_a0 rs1_a0 !1 xori\n", "<=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "rd_a0 rs1_a1 rs2_a0 slt\nrd_a0 rs1_a0 !1 xori\n", "rd_a0 rs1_a1 rs2_a0 sltu\nrd_a0 rs1_a0 !1 xori\n", ">=", relational_expr_stub);
		arithmetic_recursion(additive_expr_c, "rd_a0 rs1_a0 rs2_a1 slt\n", "rd_a0 rs1_a0 rs2_a1 sltu\n", ">", relational_expr_stub);
		general_recursion(additive_expr_c, "rd_a0 rs1_a0 rs2_a1 sub\nrd_a0 rs1_a0 !1 sltiu\n", "==", relational_expr_stub);
		general_recursion(additive_expr_c, "rd_a0 rs1_a0 rs2_a1 sub\nrd_a0 rs2_a0 sltu\n", "!=", relational_expr_stub);
	}
}

void relational_expr(void)
{
	additive_expr_c();
	relational_expr_stub();
}

/*
 * bitwise-expr:
 *         relational-expr
 *         bitwise-expr & bitwise-expr
 *         bitwise-expr && bitwise-expr
 *         bitwise-expr | bitwise-expr
 *         bitwise-expr || bitwise-expr
 *         bitwise-expr ^ bitwise-expr
 */
/* THE FIVE BITWISE AND LOGICAL OPERATORS, EACH AT ITS OWN PRECEDENCE.
 *
 * WHAT WAS HERE. One function tried all five -- & && | || ^ -- at a SINGLE
 * level and recursed into itself, so they were parsed flat, left to right:
 *
 *     1 | 2 ^ 3     read as (1|2)^3 = 0        C says 1|(2^3) = 1
 *     6 ^ 3 & 1     read as (6^3)&1 = 1        C says 6^(3&1) = 7
 *     1 || 0 && 0   read as (1||0)&&0 = 0      C says 1||(0&&0) = 1
 *
 * MICRO-C.md recorded this as `constant_expression` folding "right-to-left".
 * Both halves of that sentence are wrong and it is worth correcting rather
 * than quietly fixing: it is not confined to the constant parser -- these are
 * ordinary runtime expressions -- and it is not right-to-left. It is
 * left-to-right with no precedence at all, which is a different bug and would
 * have been diagnosed differently. The measurement that settled it was three
 * lines of C and their exit codes; the note had never been checked.
 *
 * C's order, tightest first, is  &  ^  |  &&  ||  -- and all five are looser
 * than == and !=, which relational_expr already handles, so this chain sits on
 * top of it exactly as C's grammar does.
 *
 * ARITHMETIC PRECEDENCE WAS ALWAYS RIGHT (`1+2*3` is 7), which is why this
 * survived: additive_expr_a/b/c is already a tiered chain. This is the same
 * shape, for the tier nobody had written.
 *
 * Found by borrowing stage 2's conformance corpus -- rows 193, 196 and 197.
 * tcc itself parenthesises almost everything and is unaffected, which is
 * exactly why no amount of staring at tcc would have found it. */
char* bitwise_and_instruction(void)
{
	if(Architecture & ARCH_FAMILY_KNIGHT) return "AND R0 R0 R1\n";
	else if(X86 == Architecture) return "and_eax,ebx\n";
	else if(AMD64 == Architecture) return "and_rax,rbx\n";
	else if(ARMV7L == Architecture) return "NO_SHIFT R0 R0 AND R1 ARITH2_ALWAYS\n";
	else if(AARCH64 == Architecture) return "and_x0,x1,x0\n";
	else if(Architecture & ARCH_FAMILY_RISCV) return "rd_a0 rs1_a1 rs2_a0 and\n";
	return "";
}

char* bitwise_xor_instruction(void)
{
	if(Architecture & ARCH_FAMILY_KNIGHT) return "XOR R0 R0 R1\n";
	else if(X86 == Architecture) return "xor_eax,ebx\n";
	else if(AMD64 == Architecture) return "xor_rax,rbx\n";
	else if(ARMV7L == Architecture) return "'0' R0 R0 XOR R1 ARITH2_ALWAYS\n";
	else if(AARCH64 == Architecture) return "eor_x0,x0,x1\n";
	else if(Architecture & ARCH_FAMILY_RISCV) return "rd_a0 rs1_a1 rs2_a0 xor\n";
	return "";
}

/* THE BITFIELD PATHS NEEDED THESE, and there were none. Both the plain and the
 * compound bitfield store emitted `lsl_x0,x1,x0` and `lsr_x0,x1,x0` literally,
 * so a bitfield WRITE emitted aarch64 mnemonics on every architecture. Nothing
 * in the corpus wrote a bitfield, so amd64 never noticed. The strings are the
 * same ones compound_operation already selects for `<<` and unsigned `>>`. */
char* shift_left_instruction(void)
{
	if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "SAL R0 R1 R0\n";
	else if(X86 == Architecture) return "mov_ecx,eax\nmov_eax,ebx\nshl_eax,cl\n";
	else if(AMD64 == Architecture) return "mov_rcx,rax\nmov_rax,rbx\nshl_rax,cl\n";
	else if(ARMV7L == Architecture) return "LEFT R1 R0 R0 SHIFT AUX_ALWAYS\n";
	else if(AARCH64 == Architecture) return "lsl_x0,x1,x0\n";
	else if(Architecture & ARCH_FAMILY_RISCV) return "rd_a0 rs1_a1 rs2_a0 sll\n";
	return "";
}

char* shift_right_logical_instruction(void)
{
	if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) return "SR0 R0 R1 R0\n";
	else if(X86 == Architecture) return "mov_ecx,eax\nmov_eax,ebx\nshr_eax,cl\n";
	else if(AMD64 == Architecture) return "mov_rcx,rax\nmov_rax,rbx\nshr_rax,cl\n";
	else if(ARMV7L == Architecture) return "RIGHT R1 R0 R0 SHIFT AUX_ALWAYS\n";
	else if(AARCH64 == Architecture) return "lsr_x0,x1,x0\n";
	else if(Architecture & ARCH_FAMILY_RISCV) return "rd_a0 rs1_a1 rs2_a0 srl\n";
	return "";
}

char* bitwise_or_instruction(void)
{
	if(Architecture & ARCH_FAMILY_KNIGHT) return "OR R0 R0 R1\n";
	else if(X86 == Architecture) return "or_eax,ebx\n";
	else if(AMD64 == Architecture) return "or_rax,rbx\n";
	else if(ARMV7L == Architecture) return "NO_SHIFT R0 R0 OR R1 AUX_ALWAYS\n";
	else if(AARCH64 == Architecture) return "orr_x0,x1,x0\n";
	else if(Architecture & ARCH_FAMILY_RISCV) return "rd_a0 rs1_a1 rs2_a0 or\n";
	return "";
}

void bitwise_and_stub(void)
{
	general_recursion(relational_expr, bitwise_and_instruction(), "&", bitwise_and_stub);
}

void bitwise_and_expr(void)
{
	relational_expr();
	bitwise_and_stub();
}

void bitwise_xor_stub(void)
{
	general_recursion(bitwise_and_expr, bitwise_xor_instruction(), "^", bitwise_xor_stub);
}

void bitwise_xor_expr(void)
{
	bitwise_and_expr();
	bitwise_xor_stub();
}

void bitwise_or_stub(void)
{
	general_recursion(bitwise_xor_expr, bitwise_or_instruction(), "|", bitwise_or_stub);
}

void bitwise_or_expr(void)
{
	bitwise_xor_expr();
	bitwise_or_stub();
}

void logical_and_stub(void)
{
	logical_recursion(bitwise_or_expr, TRUE, "&&", logical_and_stub);
}

void logical_and_expr(void)
{
	bitwise_or_expr();
	logical_and_stub();
}

void logical_or_stub(void)
{
	logical_recursion(logical_and_expr, FALSE, "||", logical_or_stub);
}

void bitwise_expr(void)
{
	logical_and_expr();
	logical_or_stub();
}

/*
 * expression:
 *         bitwise-or-expr
 *         bitwise-or-expr = expression
 */

void primary_expr(void)
{
	require(NULL != global_token, "Received EOF where primary expression expected\n");
	/* GROUPING PARENS ARE TRANSPARENT TO `&`.
	 *
	 *     pts = &(ts->hash_next);        tccpp.c:516
	 *
	 * takes the `(` branch below, which calls comma_expression and comes back
	 * round to primary_expr for `ts`. With no `&` in front of it, the `else`
	 * here reset the flag its own caller had set two frames up, so `&(p->m)`
	 * LOADED the member instead of taking its address. `&p->m` -- the same
	 * expression without parens -- was always right, because it never
	 * re-enters this function.
	 *
	 * Clearing on the way OUT instead was tried and is worse: 22 cases pass
	 * against 38. The head clear is load-bearing -- `&a[i]` parses its index
	 * through here and must start with the flag down.
	 *
	 * So the grouping branch says explicitly that it is handing the flag
	 * down, and this is the only place that reads it. It is consumed
	 * immediately, so a nested expression inside the parens still starts
	 * clean. */
	int inherited = address_of_through_parens;
	address_of_through_parens = FALSE;

	if(match("&", global_token->s))
	{
		Address_of = TRUE;
		require_extra_token();
	}
	else if(!inherited)
	{
		Address_of = FALSE;
	}

	if(match("sizeof", global_token->s))
	{
		/* SIZEOF YIELDS AN INTEGER, AND HAD NO TYPE OF ITS OWN.
		 *
		 * Third instance of the rule primary_expr_number and the string
		 * literal above already learned: a leaf that emits a value must SAY
		 * what it is, or it inherits whatever the previous expression left in
		 * current_target. Here the previous expression is often an assignment
		 * target, so
		 *
		 *     BufferedFile *bf;
		 *     bf = tcc_mallocz(sizeof(BufferedFile) + buflen);
		 *
		 * left `sizeof(BufferedFile)` typed as BufferedFile*, additive_expr
		 * read a pointer on the left and an integer on the right, and scaled
		 * buflen by 1128. The request became 1128 * (8192 + 1) = 9,241,704
		 * bytes instead of 9,320 -- and tcc_mallocz then ZEROES it.
		 *
		 * It never faults. Compiling an empty file, a tcc built by this
		 * compiler zeroed 23 MB where the gcc-built control zeroed 0.23 MB,
		 * with the SAME 800 memset calls -- identical control flow, every
		 * allocation a thousand times too large. Case 100 pins it; 97, 98 and
		 * 99 bound it, because the same expression is correct when assigned
		 * to an integer, when passed as an argument, and through a typedef. */
		emit_load_immediate(REGISTER_ZERO, unary_expr_sizeof(), "load sizeof");
		current_target = integer;
	}
	else if(match("-", global_token->s))
	{
		if((KNIGHT_POSIX != Architecture) && (KNIGHT_NATIVE != Architecture))
		{
			emit_load_immediate(REGISTER_ZERO, 0, "primary expr");
		}

		/* UNARY MINUS MUST NOT PROMOTE AGAINST THE PREVIOUS TYPE.
		 * common_recursion ends with
		 *     current_target = promote_type(current_target, last_type)
		 * which is right for a BINARY operator and wrong here: last_type is
		 * whatever happened to be current before the operator. In
		 *     vtop->c.ld = -(long double)-vtop->c.i;      tccgen.c:3300
		 * that is `double` from the left-hand side, so the operand came back
		 * promoted to double and the following `->c` was looked up in it.
		 *
		 * Setting current_target to integer first only MOVED the problem --
		 * promote_type(SValue*, integer) picks integer. A unary operator must
		 * not promote at ALL: the result has the operand's type. So this does
		 * common_recursion's push/parse/pop without its final promotion.
		 *
		 * postfix_expr, NOT primary_expr, AND THE `!` BRANCH TWENTY LINES
		 * BELOW ALREADY SAYS SO. A unary operator applies to the whole unary
		 * expression that follows, so `-p->v` is `-(p->v)`. Calling
		 * primary_expr consumed only `p` and left `->v` to the caller, and
		 * the result was a segfault rather than a diagnostic:
		 *
		 *     g.v = -g.v;     fine        -- a member of a plain variable
		 *     p->v = -(p->v); fine        -- the parentheses do it by hand
		 *     t   = -p->v;    SIGSEGV
		 *
		 * The cast branch carries this same correction already, in the same
		 * words, for the same reason.
		 *
		 * WHERE IT BIT. tcc's assembler negates an immediate with
		 *     if (op == '-') pe->v = -pe->v;          tccasm.c:178
		 * so mc-tcc segfaulted on EVERY negative immediate in assembly --
		 *     stp x29,x30,[sp,-16]!      mov x0,-16      ldr x0,[sp,-8]
		 * -- while the positive forms assembled. That is musl's crti.s,
		 * memcpy.S and memset.S, and it is nine of the nine files that would
		 * not compile at rung 2 of the stage-4 ladder. */
		emit_push(REGISTER_ZERO, "_common_recursion");
		require_extra_token();
		postfix_expr();
		emit_pop(REGISTER_ONE, "_common_recursion");

		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) emit_out("NEG R0 R0\n");
		else if(X86 == Architecture) emit_out("sub_ebx,eax\nmov_eax,ebx\n");
		else if(AMD64 == Architecture) emit_out("sub_rbx,rax\nmov_rax,rbx\n");
		else if(ARMV7L == Architecture) emit_out("'0' R0 R0 SUB R1 ARITH2_ALWAYS\n");
		else if(AARCH64 == Architecture) emit_out("sub_x0,x1,x0\n");
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) emit_out("rd_a0 rs1_a1 rs2_a0 sub\n");
	}
	else if('!' == global_token->s[0])
	{
		if((RISCV32 != Architecture) && (RISCV64 != Architecture))
		{
			emit_load_immediate(REGISTER_ZERO, 1, "primary expr");
		}

		/* Same reason as unary minus above: no promotion for a unary operator. */
		emit_push(REGISTER_ZERO, "_common_recursion");
		require_extra_token();
		postfix_expr();
		emit_pop(REGISTER_ONE, "_common_recursion");

		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) emit_out("CMPU R0 R1 R0\nSET.G R0 R0 1\n");
		else if(X86 == Architecture) emit_out("cmp_ebx,eax\nseta_al\nmovzx_eax,al\n");
		else if(AMD64 == Architecture) emit_out("cmp_rbx,rax\nseta_al\nmovzx_rax,al\n");
		else if(ARMV7L == Architecture) emit_out("'0' R0 CMP R1 AUX_ALWAYS\n!0 R0 LOADI8_ALWAYS\n!1 R0 LOADI8_HI\n");
		else if(AARCH64 == Architecture) emit_out("cmp_x1,x0\nmov_x0,1\nb.hi_8\nmov_x0,0\n");
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) emit_out("rd_a0 rs1_a0 !1 sltiu\n");
	}
	else if('~' == global_token->s[0])
	{
		common_recursion(postfix_expr);

		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) emit_out("NOT R0 R0\n");
		else if(X86 == Architecture) emit_out("not_eax\n");
		else if(AMD64 == Architecture) emit_out("not_rax\n");
		else if(ARMV7L == Architecture) emit_out("'0' R0 R0 MVN_ALWAYS\n");
		else if(AARCH64 == Architecture) emit_out("mvn_x0,x0\n");
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) emit_out("rd_a0 rs1_a0 not\n");
	}
	else if(match("--", global_token->s) || match("++", global_token->s))
	{
		int is_subtract = global_token->s[0] == '-';
		maybe_bootstrap_error("prefix operators --/++");

		emit_out("# prefix inc/dec\n");

		emit_push(REGISTER_ZERO, "Previous value");
		require_extra_token();
		/* SET HERE, NOT IN primary_expr_variable, AND THE DIFFERENCE IS NOT
		 * cosmetic. EXPERIMENT-zzc set it down there, beside the code that
		 * decides whether to load the variable -- which works for `--p->n`
		 * and never runs for `--s.n`, because a STRUCT variable returns from
		 * that function long before reaching it. The arrow half passed its
		 * case and the dot half was recorded as "a different cause".
		 *
		 * It was the same cause. The flag simply never arrived. This is the
		 * one point every prefix ++/-- passes through, so it is where the
		 * instruction belongs; the arrow site still needs its own line down
		 * there, because it must also force the POINTER to be loaded, and
		 * that is a genuinely different question. */
		prefix_lvalue_target = TRUE;
		postfix_expr();
		/* BOUNDED TO THIS STATEMENT. If the chain never reached an arrow site
		 * -- `--n`, `--s.n`, `--a[i]` -- the flag was never consumed, and a
		 * flag left standing is how Address_of earned its section in
		 * MICRO-C.md. */
		prefix_lvalue_target = FALSE;
		emit_pop(REGISTER_ONE, "Restore previous value");

		emit_push(REGISTER_ONE, "Previous value");
		emit_push(REGISTER_ZERO, "Address of variable");

		/* Same as the postfix site above: the prefix operators read the
		 * variable at its own width, not at the register's. */
		if(NULL != current_target && register_size >= current_target->size)
		{
			emit_out(load_value(current_target->size, current_target->is_signed));
		}
		else
		{
			emit_dereference(REGISTER_ZERO, "Deref to get value");
		}

		int value = 1;
		if(type_is_pointer(current_target))
		{
			value = current_target->type->size;
		}

		if(is_subtract)
		{
			emit_sub_immediate(REGISTER_ZERO, value, "Sub prefix from deref value");
		}
		else
		{
			emit_add_immediate(REGISTER_ZERO, value, "Add prefix to deref value");
		}

		emit_pop(REGISTER_ONE, "Address of variable");

		/* Store REGISTER_ZERO in REGISTER_ONE deref */
		emit_out(store_value(current_target->size));

		emit_pop(REGISTER_ONE, "Previous value");

		emit_out("# prefix inc/dec end\n");
	}
	else if(global_token->s[0] == '(')
	{
		require_extra_token();
		struct type* type_size = fallible_type_name();
		if(type_size != NULL)
		{
			if(global_token->s[0] == '(')
			{
				parse_function_pointer();
				type_size = function_pointer;
			}
			require_match("Invalid character received in cast. Expected ')'.\n", ")");
			/* postfix_expr, NOT primary_expr. A cast applies to the whole unary
			 * expression that follows, so `(T*)al->p` is `(T*)(al->p)`. Calling
			 * primary_expr consumed only `al`, set current_target to the cast
			 * type, and left `->p` for the caller -- which then looked the
			 * member up in the CAST type and failed:
			 *     ERROR in lookup_member tal_header_t->p does not exist
			 * at tccpp.c:281, `memcpy((tal_header_t*)al->p + 1, ...)`. */
			postfix_expr();
			current_target = type_size;
			emit_narrowing_cast(type_size);
		}
		else
		{
			/* A PARENTHESISED EXPRESSION MAY CONTAIN COMMAS. tcc.h:1996:
			 *     #define tcc_warning_c(sw) TCC_SET_STATE((
			 *         tcc_state->warn_num = offsetof(TCCState, sw)
			 *         - offsetof(TCCState, warn_none), _tcc_warning))
			 * The reported line is where the macro is DEFINED; the use is
			 * elsewhere. This is the third and last position where a full
			 * expression is grammatically expected -- statement, controlling
			 * expression, and inside grouping parens. */
			/* A CHAIN AFTER THE CLOSING PAREN MAKES THE INSIDE AN RVALUE.
			 *
			 * Handing Address_of down is right for `&(x)`, where the
			 * parenthesised thing IS the target. It is wrong for
			 *
			 *     &(p)->ref->type
			 *
			 * because there `p` must be LOADED to be followed; only the last
			 * step of the chain yields the address. With the flag handed down,
			 * `p` was not loaded and the offsets were added to the address of
			 * the variable instead of to its value:
			 *
			 *     &p->ref->type      ldr [p]  add 8  ldr  add 8
			 *     &(p)->ref->type             add 8  ldr  add 8
			 *
			 * tcc writes the parenthesised spelling because pointed_type is a
			 * macro:
			 *
			 *     #define pointed_type(t) (&(t)->ref->type)
			 *
			 * and compare_types calls it for every pointer comparison, so any
			 * assignment of a pointer-valued expression walked a wild address.
			 *
			 * The lookahead scans to the MATCHING paren rather than the next
			 * one, because the inside may contain calls and casts of its own.
			 * Address_of is restored afterwards so the chain still ends in an
			 * address; it is the inside that must be an ordinary value. */
			int paren_depth = 1;
			struct token_list* scan = global_token;
			int chain_after_parens = FALSE;
			while(NULL != scan && 0 != paren_depth)
			{
				if('(' == scan->s[0] && 0 == scan->s[1]) paren_depth = paren_depth + 1;
				else if(')' == scan->s[0] && 0 == scan->s[1]) paren_depth = paren_depth - 1;
				if(0 == paren_depth) break;
				scan = scan->next;
			}
			int assign_after_parens = FALSE;
			if(NULL != scan && NULL != scan->next)
			{
				chain_after_parens = match("->", scan->next->s)
				                  || match(".", scan->next->s)
				                  || match("[", scan->next->s);
				/* AN ASSIGNMENT TARGET MUST NOT BE LOADED, and the
				 * parentheses hid that from the only place that checks.
				 *
				 * postfix_expr_variable blanks the load when the NEXT token
				 * is `=` or a compound assignment. For `(ln) += 4` the next
				 * token is `)`, so it loaded ln and the store then wrote
				 * through the VALUE as if it were an address.
				 *
				 *     ln += 4       correct
				 *     (ln) += 4     wrong, and SIGSEGV through a pointer
				 *
				 * tcc reaches it through a macro, which is why the spelling
				 * is parenthesised at all:
				 *
				 *     #define dwarf_read_4(ln,end) \
				 *         ((ln) + 3 < (end) ? read32le(((ln)+=4) - 4) : 0)
				 *                                            tcc.h:1863
				 *
				 * tcc_eh_frame_hdr walks .eh_frame with that macro, and it
				 * is called for every DYNAMIC output -- so mc-tcc segfaulted
				 * on any link that was not -static, which is the whole
				 * libc-facing surface stage 4 needs. -static never reaches
				 * it, which is why the hermetic job is green.
				 *
				 * Same rule as zzc, zzg, zzm, zzo, zzzh and zzzk: an address
				 * applies to the last step of a chain. This is the paren
				 * spelling of it.
				 *
				 * NOT ++/-- HERE. dwarf_read_1 is `*(ln)++`, which parses as
				 * `*((ln)++)` and is wrong under micro-c in its own way --
				 * the value, not the advance. Suppressing the load fixes the
				 * advance and leaves the value wrong, so it is a different
				 * defect wearing the same parentheses and it is left named
				 * rather than half-moved. Case 118 carries it. */
				/* A DEREFERENCE OUTSIDE THE PARENS CANCELS IT. In
				 *     *(t) = v
				 * `t` is NOT the target -- what it points at is -- so t must
				 * be LOADED to be followed, and case 49 has said so since
				 * before this flag existed. num_dereference_after_postfix is
				 * the count of stars the enclosing unary expression ate, so
				 * zero means these parentheses are the whole target. Same
				 * rule as everywhere else here: an address applies to the
				 * last step of a chain, never to one still to be followed. */
				/* AND A POSTFIX ++/-- IS AN ASSIGNMENT TOO. `(p)++` reaches
				 * this the same way `(p) += 1` does -- the token after the
				 * closing paren is what decides, and postfix_expr_variable's
				 * own is_postfix_operator check sees `)` and not `++`. So the
				 * variable was loaded, the increment was applied to the VALUE,
				 * and p did not move at all.
				 *
				 * The num_dereference_after_postfix guard above carries over
				 * unchanged and is what keeps this off `*(p)++`, which is a
				 * different defect: there the ++ belongs to `(p)` but micro-c
				 * reads the whole thing as `(*p)++`. Case 119 holds it. */
				/* A POSTFIX ++/-- BINDS TIGHTER THAN THE OUTER STAR, so it is
				 * NOT subject to the num_dereference_after_postfix guard above.
				 * C reads `*(p)++` as `*((p)++)`: the increment applies to p,
				 * which therefore needs its ADDRESS, exactly as in `*p++`.
				 * `*(t) = v` is the opposite -- there the star is outside the
				 * assignment, so t is loaded and followed -- which is why the
				 * two are separated here rather than sharing one condition. */
				int postfix_after_parens = match("++", scan->next->s)
				                        || match("--", scan->next->s);
				assign_after_parens = postfix_after_parens
				                   || ((0 == num_dereference_after_postfix)
				                       && (match("=", scan->next->s)
				                           || is_compound_assignment(scan->next->s)));
			}

			if(chain_after_parens)
			{
				int want_address = Address_of;
				address_of_through_parens = FALSE;
				comma_expression();
				require_match("Error in Primary expression\nDidn't get )\n", ")");
				Address_of = want_address;
			}
			else
			{
				address_of_through_parens = Address_of;
				/* INHERITED, NOT OVERWRITTEN. `((k)) += 2` enters this
				 * branch twice: the outer parenthesis sees the `+=` and sets
				 * the flag, and the inner one sees only a `)` after itself
				 * and would clear it again -- leaving the variable loaded and
				 * the store writing through its value. Saving and restoring
				 * is the same shape Address_of uses four lines up. */
				int saved_atp = assign_through_parens;
				assign_through_parens = assign_after_parens || saved_atp;
				/* AND A PENDING `*` BELONGS TO US, NOT TO WHAT IS INSIDE.
				 *
				 * num_dereference_after_postfix parks a star that has been
				 * eaten but not yet applied. Everything parsed in here is a
				 * sub-expression that reads the same global, so in
				 *     v = *(1 ? p1 : p2)
				 * the star landed on the CONDITION and loaded address 1.
				 *
				 * Identical to the argument-list hazard function_call
				 * documents at the top of this file -- `*give(8)`, the same
				 * two lines of M1, a different pair of brackets. The ternary
				 * is the loudest way in because its condition is parsed
				 * before `?` is seen, so no edit to the ternary handler can
				 * reach it.
				 *
				 * comma_expression() ALONE, deliberately: zzzg widened this
				 * same restore to a whole call and cost 12/12 -> 0/12. */
				int paren_pending_deref = num_dereference_after_postfix;
				num_dereference_after_postfix = 0;
				comma_expression();
				num_dereference_after_postfix = paren_pending_deref;
				assign_through_parens = saved_atp;
				require_match("Error in Primary expression\nDidn't get )\n", ")");
			}
		}
	}
	else if(global_token->s[0] == '\'') primary_expr_char();
	else if(global_token->s[0] == '"') primary_expr_string();
	else if(in_set(global_token->s[0], "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"))
	{
		/* __FUNCTION__ IS NOT A PREPROCESSOR MACRO. __LINE__ and __FILE__ are
		 * handled in lookup_macro because their values are known while
		 * preprocessing; the enclosing function's name is not known until
		 * parsing, so it belongs here.
		 *
		 * tcc reaches it through
		 *     #define tcc_internal_error(msg) tcc_error(
		 *         "internal compiler error in %s:%d: %s",
		 *         __FUNCTION__, __LINE__, msg)      tcc.h:1250
		 *
		 * The string carries only its LEADING quote, which is how the
		 * tokenizer represents one -- parse_string supplies the terminator.
		 * __FILE__ above does the same. */
		if(match("__FUNCTION__", global_token->s) || match("__func__", global_token->s))
		{
			char* fname = "";
			if(NULL != function) fname = function->s;
			char* unique_id = add_string_to_string_list(concat_strings2("\"", fname));
			emit_load_named_immediate(REGISTER_ZERO, "", unique_id, "__FUNCTION__");
			current_target = lookup_type("char*", global_types);
			require_extra_token();
			return;
		}

		struct token_list* variable = sym_lookup(global_token->s, global_function_list);
		if (variable != NULL && global_token->next != NULL && global_token->next->s[0] == '(')
		{
			/* Call function directly without loading into register optimization */
			require_extra_token();
			function_call(variable, FALSE);
		}
		else
		{
			primary_expr_variable();
		}
	}
	else if(global_token->s[0] == '*') primary_expr_variable();
	else if(in_set(global_token->s[0], "0123456789"))
	{
		primary_expr_number(global_token->s);
		require_extra_token();
	}
	else primary_expr_failure();
}

char* compound_operation(char* operator, int is_signed)
{
	char* operation = "";
	if(match("+=", operator))
	{
		emit_add(REGISTER_ZERO, REGISTER_ONE, is_signed, "compound operation");
	}
	else if(match("-=", operator))
	{
		emit_rsub(REGISTER_ZERO, REGISTER_ONE, is_signed, "compound operation");
	}
	else if(match("*=", operator))
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture))
		{
			if(is_signed) operation = "MUL R0 R1 R0\n";
			else operation =  "MULU R0 R1 R0\n";
		}
		else if(X86 == Architecture)
		{
			if(is_signed) operation = "imul_ebx\n";
			else operation = "mul_ebx\n";
		}
		else if(AMD64 == Architecture)
		{
			if(is_signed) operation = "imul_rbx\n";
			else operation = "mul_rbx\n";
		}
		else if(ARMV7L == Architecture) operation = "'9' R0 '0' R1 MULS R0 ARITH2_ALWAYS\n";
		else if(AARCH64 == Architecture) operation = "mul_x0,x1,x0\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) operation = "rd_a0 rs1_a1 rs2_a0 mul\n";
	}
	else if(match("/=", operator))
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture))
		{
			if(is_signed) operation = "DIV R0 R1 R0\n";
			else operation =  "DIVU R0 R1 R0\n";
		}
		else if(X86 == Architecture)
		{
			if (is_signed) operation = "xchg_ebx,eax\ncdq\nidiv_ebx\n";
			else operation = "xchg_ebx,eax\nxor_edx,edx\ndiv_ebx\n";
		}
		else if(AMD64 == Architecture)
		{
			if(is_signed) operation = "xchg_rbx,rax\ncqo\nidiv_rbx\n";
			else operation = "xchg_rbx,rax\nxor_edx,edx\ndiv_rbx\n";
		}
		else if(ARMV7L == Architecture)
		{
			if(is_signed) operation = "{LR} PUSH_ALWAYS\n^~divides CALL_ALWAYS\n{LR} POP_ALWAYS\n";
			else operation = "{LR} PUSH_ALWAYS\n^~divide CALL_ALWAYS\n{LR} POP_ALWAYS\n";
		}
		else if(AARCH64 == Architecture)
		{
			if(is_signed) operation = "sdiv_x0,x1,x0\n";
			else operation = "udiv_x0,x1,x0\n";
		}
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture))
		{
			if(is_signed) operation = "rd_a0 rs1_a1 rs2_a0 div\n";
			else operation = "rd_a0 rs1_a1 rs2_a0 divu\n";
		}
	}
	else if(match("%=", operator))
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture))
		{
			if(is_signed) operation = "MOD R0 R1 R0\n";
			else operation = "MODU R0 R1 R0\n";
		}
		else if(X86 == Architecture)
		{
			if(is_signed) operation = "xchg_ebx,eax\ncdq\nidiv_ebx\nmov_eax,edx\n";
			else operation = "xchg_ebx,eax\nxor_edx,edx\ndiv_ebx\nmov_eax,edx\n";
		}
		else if(AMD64 == Architecture)
		{
			if(is_signed) operation = "xchg_rbx,rax\ncqo\nidiv_rbx\nmov_rax,rdx\n";
			else operation = "xchg_rbx,rax\nxor_edx,edx\ndiv_rbx\nmov_rax,rdx\n";
		}
		else if(ARMV7L == Architecture)
		{
			if(is_signed) operation = "{LR} PUSH_ALWAYS\n^~moduluss CALL_ALWAYS\n{LR} POP_ALWAYS\n";
			else operation = "{LR} PUSH_ALWAYS\n^~modulus CALL_ALWAYS\n{LR} POP_ALWAYS\n";
		}
		else if(AARCH64 == Architecture)
		{
			if(is_signed) operation = "sdiv_x2,x1,x0\nmsub_x0,x0,x2,x1\n";
			else operation = "udiv_x2,x1,x0\nmsub_x0,x0,x2,x1\n";
		}
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture))
		{
			if(is_signed) operation = "rd_a0 rs1_a1 rs2_a0 rem\n";
			else operation = "rd_a0 rs1_a1 rs2_a0 remu\n";
		}
	}
	else if(match("<<=", operator))
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture))
		{
			if(is_signed) operation = "SAL R0 R1 R0\n";
			else operation = "SL0 R0 R1 R0\n";
		}
		else if(X86 == Architecture)
		{
			if(is_signed) operation = "mov_ecx,eax\nmov_eax,ebx\nsal_eax,cl\n";
			else operation = "mov_ecx,eax\nmov_eax,ebx\nshl_eax,cl\n";
		}
		else if(AMD64 == Architecture)
		{
			if(is_signed) operation = "mov_rcx,rax\nmov_rax,rbx\nsal_rax,cl\n";
			else operation = "mov_rcx,rax\nmov_rax,rbx\nshl_rax,cl\n";
		}
		else if(ARMV7L == Architecture) operation = "LEFT R1 R0 R0 SHIFT AUX_ALWAYS\n";
		else if(AARCH64 == Architecture) operation = "lsl_x0,x1,x0\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) operation = "rd_a0 rs1_a1 rs2_a0 sll\n";
	}
	else if(match(">>=", operator))
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture))
		{
			if(is_signed) operation = "SAR R0 R1 R0\n";
			else operation = "SR0 R0 R1 R0\n";
		}
		else if(X86 == Architecture)
		{
			if(is_signed) operation = "mov_ecx,eax\nmov_eax,ebx\nsar_eax,cl\n";
			else operation = "mov_ecx,eax\nmov_eax,ebx\nshr_eax,cl\n";
		}
		else if(AMD64 == Architecture)
		{
			if(is_signed) operation = "mov_rcx,rax\nmov_rax,rbx\nsar_rax,cl\n";
			else operation = "mov_rcx,rax\nmov_rax,rbx\nshr_rax,cl\n";
		}
		else if(ARMV7L == Architecture)
		{
			if(is_signed) operation = "ARITH_RIGHT R1 R0 R0 SHIFT AUX_ALWAYS\n";
			else operation = "RIGHT R1 R0 R0 SHIFT AUX_ALWAYS\n";
		}
		else if(AARCH64 == Architecture)
		{
			if(is_signed) operation = "asr_x0,x1,x0\n";
			else operation = "lsr_x0,x1,x0\n";
		}
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture))
		{
			if(is_signed) operation = "rd_a0 rs1_a1 rs2_a0 sra\n";
			else operation = "rd_a0 rs1_a1 rs2_a0 srl\n";
		}
	}
	else if(match("&=", operator))
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) operation = "AND R0 R0 R1\n";
		else if(X86 == Architecture) operation = "and_eax,ebx\n";
		else if(AMD64 == Architecture) operation = "and_rax,rbx\n";
		else if(ARMV7L == Architecture) operation = "NO_SHIFT R0 R0 AND R1 ARITH2_ALWAYS\n";
		else if(AARCH64 == Architecture) operation = "and_x0,x1,x0\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) operation = "rd_a0 rs1_a1 rs2_a0 and\n";
	}
	else if(match("^=", operator))
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) operation = "XOR R0 R0 R1\n";
		else if(X86 == Architecture) operation = "xor_eax,ebx\n";
		else if(AMD64 == Architecture) operation = "xor_rax,rbx\n";
		else if(ARMV7L == Architecture) operation = "'0' R0 R0 XOR R1 ARITH2_ALWAYS\n";
		else if(AARCH64 == Architecture) operation = "eor_x0,x0,x1\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) operation = "rd_a0 rs1_a1 rs2_a0 xor\n";
	}
	else if(match("|=", operator))
	{
		if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) operation = "OR R0 R0 R1\n";
		else if(X86 == Architecture) operation = "or_eax,ebx\n";
		else if(AMD64 == Architecture) operation = "or_rax,rbx\n";
		else if(ARMV7L == Architecture) operation = "NO_SHIFT R0 R0 OR R1 AUX_ALWAYS\n";
		else if(AARCH64 == Architecture) operation = "orr_x0,x1,x0\n";
		else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) operation = "rd_a0 rs1_a1 rs2_a0 or\n";
	}
	else
	{
		fputs("Found illegal compound assignment operator: ", stderr);
		fputs(operator, stderr);
		fputc('\n', stderr);
		exit(EXIT_FAILURE);
	}
	return operation;
}


/* A FULL EXPRESSION, COMMAS INCLUDED.
 *
 * The comma operator is C's lowest-precedence operator, but the same character
 * separates function arguments, struct declarators and initialiser lists, where
 * it is punctuation. So it cannot live inside expression() -- `f(a, b)` would
 * become one argument -- and instead belongs at each position where a FULL
 * expression is grammatically expected: a statement, and a controlling
 * expression such as a while or if condition.
 *
 * Entry 10 of the README put it at statement level only, and recorded that the
 * parenthesised form looked unused by tcc. That was wrong:
 *     while (next(), tok != TOK_EOF)              tccpp.c:1536
 * The earlier check looked for `(x = ..., ...)` shapes and missed the comma in
 * a controlling expression, which is a different shape.
 *
 * Nothing is emitted to discard the left value: each expression leaves its
 * result in the return register and the next overwrites it. */
void comma_expression(void)
{
	expression();
	while(match(",", global_token->s))
	{
		require_extra_token();
		expression();
	}
}

void expression(void)
{
	bitwise_expr();

	/* TERNARY `c ? a : b`. 405 uses in the pinned tcc tree -- the largest
	 * single item in ROADMAP.md's static census, and the first of its four to
	 * turn out to be exactly what it predicted.
	 *
	 * Placed here because C puts conditional-expression directly above
	 * assignment: `x = c ? a : b` parses the ternary first, and the '=' branch
	 * below still sees a complete left side. Codegen is the same shape
	 * process_if uses -- evaluate the condition, jump to the else arm when
	 * zero, evaluate one arm, jump past the other -- so both arms leave their
	 * result in the same register and the join needs nothing. */
	if(match("?", global_token->s))
	{
		char* number_string = int2str(current_count, 10, TRUE);
		current_count = current_count + 1;
		char* unique_id = create_unique_id("", function->s, number_string);

		emit_out("# TERNARY_");
		emit_out(unique_id);
		emit_out("\n");

		/* PROTECT REGISTER_TEMP ACROSS THE BRANCHES.
		 *
		 * On aarch64 a far jump is reached by loading the target into x16 and
		 * doing br_x16 -- and x16 is REGISTER_TEMP, which micro-c's CALL
		 * SEQUENCE uses to hold the callee's new base pointer between
		 *
		 *     mov_x16,x18    # Copy new base pointer
		 *     ...evaluate the arguments...
		 *     mov_x17,x16    # Set new base pointer
		 *
		 * So a ternary INSIDE AN ARGUMENT LIST overwrote the base pointer with
		 * a CODE ADDRESS, and every argument after it was read relative to
		 * that. tcc does exactly this:
		 *
		 *     tcc_open_bf(s1, filename ? filename : "<string>", len);
		 *
		 * and the third argument arrived as 0xF9400000D100A688 -- which is not
		 * a number, it is `ldr x0,[x0]` followed by another instruction. Eight
		 * bytes of machine code, loaded as data, passed as an allocation size.
		 *
		 * amd64 does not have this problem: its far jump is a plain jmp to a
		 * label and touches no register. That is why every local test passed.
		 *
		 * Both paths reach the end label, so one push and one pop cover them,
		 * and the pair nests entirely inside the ternary -- so the argument
		 * stack around it is undisturbed. */
		emit_push(REGISTER_TEMP, "protect the temp register across ?:");

		require_extra_token();
		emit_jump_if_zero(REGISTER_ZERO, "TERNARY_ELSE_", unique_id, "ternary: false arm");

		expression();
		struct type* ternary_true_type = current_target;
		emit_unconditional_jump("_END_TERNARY_", unique_id, "ternary: skip false arm");

		require_match("ERROR in ternary\nMISSING :\n", ":");
		emit_label("TERNARY_ELSE_", unique_id);
		expression();
		emit_label("_END_TERNARY_", unique_id);

		/* THE RESULT TYPE IS NOT THE SECOND ARM'S JUST BECAUSE IT PARSED
		 * LAST.
		 *
		 * Both arms call expression(), each leaves its own type in
		 * current_target, and nothing put them back together -- so whatever
		 * the FALSE arm happened to leave became the type of the whole
		 * conditional. Measured:
		 *
		 *     (c ? 0 : s)->i     accepted      the pointer parsed last
		 *     (c ? s : 0)->i     ERROR in lookup_member int->i does not exist
		 *
		 * from the same struct pointer, differing only in arm order. tcc's
		 * own tests2/33_ternary_op and tests/tcctest.c both write all four
		 * orders on consecutive lines, which is why both stop there.
		 *
		 * C 6.5.15p6: when one arm is a NULL POINTER CONSTANT, the type of
		 * the conditional is the OTHER arm's. micro-c cannot see whether an
		 * expression is a constant, but a null pointer constant has only two
		 * spellings -- an integer 0, and that cast to void* -- and each is
		 * handled here by what it leaves in current_target rather than by
		 * proving it was constant:
		 *
		 *   integer 0    promote_type already decides this correctly. Its
		 *                rule is that the wider type wins, and a pointer is
		 *                wider than an int on every architecture here.
		 *
		 *   (void*)0     ties with a struct pointer on width, so promote_type
		 *                falls through to its signedness tie-break and
		 *                returns whichever came first. `void*` is compared by
		 *                IDENTITY against the type object initialize_types
		 *                built, not by name, so a user typedef cannot collide
		 *                with it.
		 *
		 * WHAT THIS IS PERMISSIVE ABOUT, SAID PLAINLY. A conditional between
		 * a genuine void* VALUE and an object pointer has type void* in C,
		 * and gets the object pointer's type here -- there is no constant
		 * information to tell that apart from (void*)0. The effect is that
		 * micro-c ACCEPTS `(c ? vp : s)->i`, which C rejects. It cannot
		 * miscompile anything: both are eight-byte addresses and the type
		 * only decides which member offsets apply, which C would not let you
		 * ask for in the first place. Accepting slightly too much is the
		 * right direction for a bootstrap compiler; rejecting valid C is
		 * what stopped tcc. */
		if(NULL == current_target) current_target = ternary_true_type;
		else if(NULL != ternary_true_type)
		{
			if(void_pointer == current_target) current_target = ternary_true_type;
			else if(void_pointer == ternary_true_type)
			{
				/* keep the false arm's type */
			}
			else current_target = promote_type(current_target, ternary_true_type);
		}

		emit_pop(REGISTER_TEMP, "restore the temp register after ?:");
		return;
	}

	if(match("=", global_token->s))
	{
		/* STRUCT ASSIGNMENT IS A COPY, NOT A STORE.
		 *     char_pointer_type = char_type;               tccgen.c:392
		 * Every other assignment micro-c emits is value-in-register then
		 * store; a struct does not fit in a register, which is where
		 * store_value(16) failed. Both sides are ADDRESSES here -- a struct
		 * variable never gets loaded, for exactly this reason -- so the work
		 * is a word-by-word copy.
		 *
		 * REGISTER_TEMP and TEMP2 make it a straight loop: TEMP holds the
		 * source, TEMP2 the destination, and REGISTER_ZERO carries each word.
		 * Using ZERO and ONE alone would not work, because the load clobbers
		 * the source pointer it was loaded through. */
		/* BITFIELD WRITE IS A READ-MODIFY-WRITE. This is the only place with
		 * both the destination address and the new value, which is why the
		 * field description is carried here from the member access.
		 *
		 *     unit = (unit & ~(mask << off)) | ((value & mask) << off)
		 *
		 * Captured into locals FIRST: the right-hand side is evaluated below
		 * and may itself touch a bitfield, overwriting the globals. */
		int bf_off = pending_bitfield_offset;
		int bf_width = pending_bitfield_width;
		int bf_size = pending_bitfield_size;
		pending_bitfield_width = 0;

		if(0 != bf_width)
		{
			int bf_mask = (1 << bf_width) - 1;
			int unit_bits = bf_size * 8;

			/* `1 << unit_bits` IS NOT ALL-ONES WHEN unit_bits IS 64.
			 *
			 * The shift count is taken modulo the register width, so
			 * `1 << 64` is 1, `(1 << 64) - 1` is 0, and the clear mask came
			 * out ZERO -- which made the store
			 *
			 *     mov_x0,0        # bitfield: clear mask
			 *     and_x0,x1,x0    # the whole unit, gone
			 *
			 * so writing ONE bitfield wiped every other field sharing the
			 * unit. micro-c makes `int` and `unsigned` eight bytes, so the
			 * unit is eight bytes and unit_bits is 64 for essentially every
			 * bitfield in existence: the bug fired always, not in a corner.
			 *
			 * tcc keeps its function attributes in exactly that shape --
			 *
			 *     struct FuncAttr { unsigned func_call:3, func_type:2,
			 *                       func_noreturn:1, func_ctor:1, ... };
			 *
			 * -- so setting the calling convention cleared func_ctor and the
			 * rest, and gen_function then read whatever survived:
			 *
			 *     if (sym->type.ref->f.func_ctor)
			 *         add_array(tcc_state, ".init_array", sym->c);
			 *
			 * A garbage func_ctor sends it into work it must never do.
			 *
			 * A full-width unit needs no masking at all: ~(mask << off) is
			 * already exactly the bits to keep. */
			/* AND THE WIDTH THAT OVERFLOWS IS THE COMPILER'S, NOT THE
			 * TARGET'S. The guard above compared unit_bits against the
			 * TARGET's register width, but `1 << unit_bits` overflows
			 * according to the width of the int in THIS source, in
			 * whichever compiler built micro-c. gcc gives that int four
			 * bytes and stage 2 gives it eight, so the same line produced
			 * different masks depending on who compiled the compiler --
			 * and once `int` became four bytes in the LANGUAGE, unit_bits
			 * became 32, the else branch was taken, `1 << 32` overflowed a
			 * 32-bit int, and the clear mask came out zero again. Exactly
			 * the defect this block already documents, one width down.
			 *
			 * A long is eight bytes under both, so the shift can never
			 * reach its own width: unit_bits is at most 64, and 64 takes
			 * the branch that does not shift at all. */
			long bf_all;
			long bf_clear;
			if(unit_bits >= 64)
			{
				bf_clear = ~(bf_mask << bf_off);
			}
			else
			{
				bf_all = 1;
				bf_all = (bf_all << unit_bits) - 1;
				bf_clear = (~(bf_mask << bf_off)) & bf_all;
			}

			common_recursion(expression);
			/* REGISTER_ONE = address of the unit, REGISTER_ZERO = new value.
			 *
			 * NEITHER mov_x16,x1 NOR mov_x15,x1 EXISTS in M2libc's
			 * aarch64_defs.M1 -- only x0 feeds the temps. So the value is
			 * parked in TEMP2 first, the address travels through x0 into TEMP,
			 * and the value comes back into x1. */
			emit_move(REGISTER_TEMP2, REGISTER_ZERO, "bitfield: park the new value");
			emit_move(REGISTER_ZERO, REGISTER_ONE, "bitfield: address via x0");
			emit_move(REGISTER_TEMP, REGISTER_ZERO, "bitfield: address");
			/* VIA REGISTER_ZERO, because REGISTER_ONE <- TEMP2 does not
			 * exist on every architecture. The comment above records that
			 * aarch64 has no mov_x16,x1 or mov_x15,x1; amd64 likewise has no
			 * mov_rbx,r15, and a bitfield WRITE therefore did not assemble
			 * there at all -- M1 stopped with
			 *     Received invalid other; mov_rbx,r15
			 * so the whole construct was untestable on the amd64 column and
			 * the clear-mask bug below could never have been caught by it.
			 * The address is already parked in TEMP by this point, so x0 is
			 * free to carry the value across. */
			emit_move(REGISTER_ZERO, REGISTER_TEMP2, "bitfield: new value via x0");
			emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: new value");
			emit_load_immediate(REGISTER_ZERO, bf_mask, "bitfield: mask");
			emit_out(bitwise_and_instruction());
			if(0 != bf_off)
			{
				emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: new value");
				emit_load_immediate(REGISTER_ZERO, bf_off, "bitfield: shift");
				emit_out(shift_left_instruction());
			}
			emit_move(REGISTER_TEMP2, REGISTER_ZERO, "bitfield: new bits in place");

			emit_move(REGISTER_ZERO, REGISTER_TEMP, "bitfield: address");
			emit_out(load_value(bf_size, FALSE));
			emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: old unit");
			emit_load_immediate(REGISTER_ZERO, bf_clear, "bitfield: clear mask");
			emit_out(bitwise_and_instruction());

			emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: cleared unit");
			emit_move(REGISTER_ZERO, REGISTER_TEMP2, "bitfield: new bits");
			emit_out(bitwise_or_instruction());

			emit_move(REGISTER_ONE, REGISTER_TEMP, "bitfield: address");
			emit_out(store_value(bf_size));
			current_target = integer;
			return;
		}

		/* An ARRAY ELEMENT can be a struct too:
		 *     tmp = vtop[0]; vtop[0] = vtop[-1];          tccgen.c:907
		 * The size then comes from current_target->type, the same place the
		 * ordinary store for an indexed assignment reads it. */
		int struct_copy = 0;
		if(match("]", global_token->prev->s))
		{
			if(indexed_element_size > register_size)
			{
				struct_copy = indexed_element_size;
			}
		}
		else
		{
			if(current_target->size > register_size)
			{
				struct_copy = current_target->size;
			}
		}

		if(0 != struct_copy)
		{
			common_recursion(expression);
			/* REGISTER_ONE = destination address, REGISTER_ZERO = source. */
			emit_move(REGISTER_TEMP, REGISTER_ZERO, "struct copy: source");
			/* THE M1 VOCABULARY HAS NO `mov_x15,x1`. Only x0 can feed x15 or
			 * x16 -- checked against M2libc's aarch64_defs.M1, which defines
			 * mov_x15,x0 and mov_x16,x0 and nothing else into those two. So the
			 * destination goes via x0.
			 *
			 * This emitted and PARSED fine for eighty walls and would have
			 * failed at assembly. Nothing before this point ever ran M1 over
			 * the output. */
			emit_move(REGISTER_ZERO, REGISTER_ONE, "struct copy: destination via x0");
			emit_move(REGISTER_TEMP2, REGISTER_ZERO, "struct copy: destination");

			/* A CHUNK MUST BE A SIZE THE MACHINE CAN LOAD: 8, 4, 2 or 1.
			 * Taking `remaining` directly gave load_value(3) for a 27-byte
			 * struct -- 8+8+8 then a 3-byte tail -- which is not an
			 * instruction. AttributeDef in tcc is exactly that shape, and the
			 * error read "unsupported size 3", which looked like a broken
			 * struct LAYOUT rather than a broken COPY. */
			int copied = 0;
			while(copied < struct_copy)
			{
				int remaining = struct_copy - copied;
				int chunk = register_size;
				if(remaining < 8) chunk = 4;
				if(remaining < 4) chunk = 2;
				if(remaining < 2) chunk = 1;
				if(chunk > remaining) chunk = 1;

				/* DESTINATION FIRST, THEN THE WORD.
				 *
				 * `emit_move(ONE, TEMP2)` is mov_x1,x15 on aarch64 and
				 * mov_rbx,r15 on amd64 -- and only the first of those exists.
				 * Routing TEMP2 through REGISTER_ZERO works on both, but ZERO
				 * holds the loaded word by then, so the order has to change
				 * rather than the route: set the destination while ZERO is
				 * still free, and load afterwards.
				 *
				 * This whole loop was written against aarch64's macro list and
				 * checked against aarch64's, which is why it did not assemble
				 * for amd64 at all. */
				emit_move(REGISTER_ZERO, REGISTER_TEMP2, "struct copy: destination");
				emit_move(REGISTER_ONE, REGISTER_ZERO, "struct copy: destination");
				emit_move(REGISTER_ZERO, REGISTER_TEMP, "struct copy: word");
				emit_out(load_value(chunk, FALSE));
				emit_out(store_value(chunk));

				emit_advance_temp(REGISTER_TEMP, chunk, "struct copy: advance source");
				emit_advance_temp(REGISTER_TEMP2, chunk, "struct copy: advance destination");
				copied = copied + chunk;
			}
			current_target = integer;
			return;
		}

		/* AN INDEXED STORE IS THE WIDTH OF THE ELEMENT, and for `T *a[N]` the
		 * element is a POINTER. Using current_target->type steps down one more
		 * indirection, which is right only when a type's ->type is itself, as
		 * int's is. For an array of pointers it gave the width of the
		 * POINTED-AT type:
		 *
		 *     char *arr[8];  arr[0] = "first";   stored ONE byte, not eight
		 *
		 * Exactly the mistake already fixed for struct member sizes, in a
		 * second place that was not looked at then. Found by the differential
		 * tester in its first run, in about a second, after this same class of
		 * bug had cost three CI rounds to find the first time. */
		char* store = "";
		if(match("]", global_token->prev->s))
		{
			/* THE ELEMENT WIDTH, WHICH FOR A POINTER IS WHAT IT POINTS AT.
			 *
			 * `char *p; p[i] = 0;` stores ONE byte. An earlier attempt here
			 * used current_target->size, on the grounds that `char *arr[8];
			 * arr[0] = x;` should store EIGHT -- and it broke the common case
			 * badly: every char-buffer write became an eight-byte write, so a
			 * loop zeroing a struct through a char* overran it and corrupted
			 * whatever was below.
			 *
			 * Both are right, and micro-c cannot tell them apart: `char *p`
			 * and `char *arr[8]` both leave current_target as `char *`, with
			 * no record of which one was indexed. Distinguishing them needs
			 * array-ness carried on the type, which exists for STRUCT MEMBERS
			 * (is_array) and not for locals or globals.
			 *
			 * So this is the pointer rule, which is the common case and the
			 * one that is dangerous to get wrong. The array-of-pointers case
			 * is a KNOWN GAP with a failing difftest case (01-array-member),
			 * left visible rather than traded for a worse bug. */
			store = store_value(indexed_element_size);
		}
		else
		{
			store = store_value(current_target->size);
		}

		common_recursion(expression);
		/* operand_left_type is the DESTINATION and operand_right_type the
		 * value, both recorded by common_recursion just above. */
		if(type_is_float(operand_left_type) && !type_is_float(operand_right_type))
		{
			emit_int_to_double();
		}
		emit_out(store);
		current_target = integer;
	}
	else if(is_compound_assignment(global_token->s))
	{
		maybe_bootstrap_error("compound operator");
		char* load = "";
		char* operation = "";
		char* store = "";
		struct type* last_type = current_target;
		int is_array_indexed = match("]", global_token->prev->s);

		/* A COMPOUND ASSIGNMENT TO A BITFIELD IS ALSO A READ-MODIFY-WRITE,
		 * and this path did not know that. It loaded the WHOLE unit, applied
		 * the operator to it, and stored the WHOLE unit back:
		 *
		 *     str_x1,[x18,-8]!    # compound operator
		 *     ldr_x1,[x1]         # the whole unit, not the field
		 *     orr_x0,x1,x0
		 *     ldr_x1,[x18],8      # compound operator
		 *     strh_w0,[x1]        # no mask, no shift
		 *
		 * so `field |= x` landed on BIT ZERO of the unit instead of on the
		 * field. The plain `=` path has done the masking and shifting for a
		 * long time; only `|=`, `&=`, `+=` and the rest were missing it, which
		 * is why the emitted code around them looked correct.
		 *
		 * WHAT IT COST. tcc merges symbol attributes with
		 *
		 *     sa->weak |= sa1->weak;                    tccgen.c, merge_symattr
		 *
		 * and `weak` is bit 6 of a sixteen-bit unit, so the bit never arrived
		 * and put_extern_sym2 chose STB_GLOBAL over STB_WEAK. musl declares
		 * __acquire_ptc, __release_ptc and __malloc_atfork hidden in a header
		 * and weak-aliases each in one translation unit while another defines
		 * it for real, so all three collided:
		 *
		 *     libc.a: error: '__acquire_ptc' defined twice
		 *                    '__release_ptc' defined twice
		 *                    '__malloc_atfork' defined twice
		 *
		 * which is where GNU make stopped at rung 3.5 of the stage-4 ladder.
		 * A gcc-built tcc of the same pin emits WEAK for the same source.
		 *
		 * CAPTURED BEFORE THE RIGHT-HAND SIDE IS EVALUATED, for the same
		 * reason the plain assignment captures them: evaluating it may touch
		 * another bitfield and overwrite the globals. */
		int cbf_off = pending_bitfield_offset;
		int cbf_width = pending_bitfield_width;
		int cbf_size = pending_bitfield_size;
		int cbf_mask = 0;
		long cbf_all;
		long cbf_clear = 0;
		pending_bitfield_width = 0;
		if(0 != cbf_width)
		{
			cbf_mask = (1 << cbf_width) - 1;
			/* `1 << 64` is 1, not zero -- see the note in the plain
			 * assignment path. A full-width unit needs no extra masking. */
			if((cbf_size * 8) >= 64)
			{
				cbf_clear = ~(((long)cbf_mask) << cbf_off);
			}
			else
			{
				cbf_all = 1;
				cbf_all = (cbf_all << (cbf_size * 8)) - 1;
				cbf_clear = (~(((long)cbf_mask) << cbf_off)) & cbf_all;
			}
		}

		if(!is_array_indexed || !match("char*", current_target->name))
		{
			if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) load = "LOAD R1 R1 0\n";
			else if(X86 == Architecture) load = "mov_ebx,[ebx]\n";
			else if(AMD64 == Architecture) load = "mov_rbx,[rbx]\n";
			else if(ARMV7L == Architecture) load = "!0 R1 LOAD32 R1 MEMORY\n";
			else if(AARCH64 == Architecture) load = "ldr_x1,[x1]\n";
			else if(RISCV32 == Architecture) load = "rd_a1 rs1_a1 lw\n";
			else if(RISCV64 == Architecture) load = "rd_a1 rs1_a1 ld\n";
		}
		else
		{
			if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) load = "LOAD8 R1 R1 0\n";
			else if(X86 == Architecture) load = "movsx_ebx,BYTE_PTR_[ebx]\n";
			else if(AMD64 == Architecture) load = "movsx_rbx,BYTE_PTR_[rbx]\n";
			else if(ARMV7L == Architecture) load = "LOADU8 R1 LOAD R1 MEMORY\n";
			else if(AARCH64 == Architecture) load = "ldrb_x1,[x1]\n";
			else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) load = "rd_a1 rs1_a1 lbu\n";
		}

		char *operator = global_token->s;

		if(is_array_indexed)
		{
			store = store_value(current_target->type->size);
		}
		else
		{
			store = store_value(current_target->size);
		}

		int should_apply_pointer_arithmetic = type_is_pointer(current_target) && !is_array_indexed;
		/* We need this before it's changed by the following expression  */
		int object_size = current_target->type->size;

		common_recursion(expression);
		current_target = promote_type(current_target, last_type);
		emit_push(REGISTER_ONE, "compound operator");
		emit_out(load);

		if(0 != cbf_width)
		{
			/* REGISTER_ONE holds the whole unit and REGISTER_ZERO the
			 * right-hand side. Extract the FIELD into REGISTER_ONE without
			 * disturbing REGISTER_ZERO, so the operator below sees the same
			 * two operands it would for an ordinary member. */
			emit_move(REGISTER_TEMP2, REGISTER_ZERO, "compound bitfield: park the rhs");
			emit_move(REGISTER_ZERO, REGISTER_ONE, "compound bitfield: unit via x0");
			if(0 != cbf_off)
			{
				emit_move(REGISTER_ONE, REGISTER_ZERO, "compound bitfield: value");
				emit_load_immediate(REGISTER_ZERO, cbf_off, "compound bitfield: shift");
				emit_out(shift_right_logical_instruction());
			}
			emit_move(REGISTER_ONE, REGISTER_ZERO, "compound bitfield: value");
			emit_load_immediate(REGISTER_ZERO, cbf_mask, "compound bitfield: mask");
			emit_out(bitwise_and_instruction());
			emit_move(REGISTER_ONE, REGISTER_ZERO, "compound bitfield: old field");
			emit_move(REGISTER_ZERO, REGISTER_TEMP2, "compound bitfield: rhs back");
		}

		if(should_apply_pointer_arithmetic) {
			multiply_by_object_size(object_size);
		}

		operation = compound_operation(operator, current_target->is_signed);
		emit_out(operation);
		emit_pop(REGISTER_ONE, "compound operator");
		if(0 != cbf_width)
		{
			/* The same read-modify-write the plain assignment does:
			 *     unit = (unit & ~(mask << off)) | ((value & mask) << off)
			 * REGISTER_ZERO holds the new field value, REGISTER_ONE the
			 * address. */
			emit_move(REGISTER_TEMP2, REGISTER_ZERO, "bitfield: park the new value");
			emit_move(REGISTER_ZERO, REGISTER_ONE, "bitfield: address via x0");
			emit_move(REGISTER_TEMP, REGISTER_ZERO, "bitfield: address");
			emit_move(REGISTER_ZERO, REGISTER_TEMP2, "bitfield: new value via x0");
			emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: new value");
			emit_load_immediate(REGISTER_ZERO, cbf_mask, "bitfield: mask");
			emit_out(bitwise_and_instruction());
			if(0 != cbf_off)
			{
				emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: new value");
				emit_load_immediate(REGISTER_ZERO, cbf_off, "bitfield: shift");
				emit_out(shift_left_instruction());
			}
			emit_move(REGISTER_TEMP2, REGISTER_ZERO, "bitfield: new bits in place");
			emit_move(REGISTER_ZERO, REGISTER_TEMP, "bitfield: address");
			emit_out(load_value(cbf_size, FALSE));
			emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: old unit");
			emit_load_immediate(REGISTER_ZERO, cbf_clear, "bitfield: clear mask");
			emit_out(bitwise_and_instruction());
			emit_move(REGISTER_ONE, REGISTER_ZERO, "bitfield: cleared unit");
			emit_move(REGISTER_ZERO, REGISTER_TEMP2, "bitfield: new bits");
			emit_out(bitwise_or_instruction());
			emit_move(REGISTER_ONE, REGISTER_TEMP, "bitfield: address");
			emit_out(store_value(cbf_size));
		}
		else
		{
			emit_out(store);
		}
		current_target = integer;
	}
}


int iskeywordp(char* s)
{
	if(match("auto", s)) return TRUE;
	if(match("_Bool", s)) return TRUE;
	if(match("break", s)) return TRUE;
	if(match("case", s)) return TRUE;
	if(match("char", s)) return TRUE;
	if(match("const", s)) return TRUE;
	if(match("continue", s)) return TRUE;
	if(match("default", s)) return TRUE;
	if(match("do", s)) return TRUE;
	if(match("double", s)) return TRUE;
	if(match("else", s)) return TRUE;
	if(match("enum", s)) return TRUE;
	if(match("extern", s)) return TRUE;
	if(match("float", s)) return TRUE;
	if(match("for", s)) return TRUE;
	if(match("goto", s)) return TRUE;
	if(match("if", s)) return TRUE;
	if(match("int", s)) return TRUE;
	if(match("long", s)) return TRUE;
	if(match("_Noreturn", s)) return TRUE;
	if(match("register", s)) return TRUE;
	if(match("restrict", s)) return TRUE;
	if(match("return", s)) return TRUE;
	if(match("short", s)) return TRUE;
	if(match("signed", s)) return TRUE;
	if(match("sizeof", s)) return TRUE;
	if(match("static", s)) return TRUE;
	if(match("struct", s)) return TRUE;
	if(match("switch", s)) return TRUE;
	if(match("typedef", s)) return TRUE;
	if(match("union", s)) return TRUE;
	if(match("unsigned", s)) return TRUE;
	if(match("void", s)) return TRUE;
	if(match("volatile", s)) return TRUE;
	if(match("while", s)) return TRUE;
	return FALSE;
}

/* Similar to integer division a / b but rounds up */
unsigned ceil_div(unsigned a, unsigned b)
{
	return (a + b - 1) / b;
}

int locals_depth;
/* Process local variable */
void collect_local(void)
{
	if(NULL != break_target_func)
	{
		maybe_bootstrap_error("Variable inside loop");
	}

	struct type* type_size = type_name();
	if(type_size->size == NO_STRUCT_DEFINITION)
	{
		line_error();
		fputs("Usage of struct '", stderr);
		fputs(type_size->name, stderr);
		fputs("' without definition (forward declaration only).\n", stderr);
		exit(EXIT_FAILURE);
	}

	/* Declarations do not have the same pointer level so we'll need to find the actual type */
	struct type* base_type = type_size->type->type;
	struct type* current_type = type_size;

	require(NULL != global_token, "Received EOF while collecting locals\n");

	struct token_list* list_to_append_to = function->locals;
	struct token_list* a;
	unsigned struct_depth_adjustment;
	char* name;
	int function_depth_offset = 0;

	do
	{
		if(global_token->s[0] == '(')
		{
			name = parse_function_pointer();
			current_type = function_pointer;
		}
		else
		{
			name = global_token->s;
			require_extra_token();
		}

		require(NULL != name, "Local function pointer declarations require a name.\n");

		/* A FUNCTION DECLARATION AT BLOCK SCOPE:
		 *     void __clear_cache(void *beginning, void *end);   tccrun.c:476
		 * Legal C, and not a variable at all -- micro-c read the '(' as the
		 * start of a function-pointer declarator. Skip the parameter list and
		 * leave the symbol alone; the definition is elsewhere and the call
		 * site resolves through the global function list. */
		if(match("(", global_token->s))
		{
			/* Register it as a FUNCTION rather than dropping it -- the call is
			 * usually the very next line (tccrun.c:477 calls __clear_cache
			 * declared on 476), and a dropped declaration makes that an
			 * undefined symbol. */
			struct token_list* fdecl = sym_declare(name, current_type, global_function_list, TLO_FUNCTION);
			global_function_list = fdecl;

			int fdepth = 0;
			while(NULL != global_token)
			{
				if(global_token->s[0] == '(') fdepth = fdepth + 1;
				else if(global_token->s[0] == ')')
				{
					fdepth = fdepth - 1;
					if(0 == fdepth) { require_extra_token(); break; }
				}
				require_extra_token();
			}
			if(NULL != global_token)
			{
				if(global_token->s[0] == ';') break;
			}
			continue;
		}

		a = sym_declare(name, current_type, list_to_append_to, TLO_LOCAL);
		list_to_append_to = a;

		require(!in_set(name[0], "[{(<=>)}]|&!^%;:'\""), "forbidden character in local variable name\n");
		require(!iskeywordp(name), "You are not allowed to use a keyword as a local variable name\n");

		emit_out("# Defining local ");
		emit_out(name);
		emit_out("\n");

		a->array_modifier = 1;
		if(match("[", global_token->s))
		{
			maybe_bootstrap_error("array on the stack");

			a->options = a->options | TLO_LOCAL_ARRAY;

			require_extra_token();

			a->array_modifier = constant_expression();
			if(a->array_modifier == 0)
			{
				line_error();
				fputs("Size zero is not supported for arrays on the stack\n", stderr);
				exit(EXIT_FAILURE);
			}
			else if(a->array_modifier < 0)
			{
				line_error();
				fputs("Negative values are not supported for arrays on the stack\n", stderr);
				exit(EXIT_FAILURE);
			}
			else if(a->array_modifier > 0x100000)
			{
				line_error();
				fputs("M2-Planet is very inefficient so you probably don't want to allocate over 1MB onto the stack\n", stderr);
				exit(EXIT_FAILURE);
			}

			require_match("ERROR in collect_local\nMissing ] after local array size\n", "]");

			/* A SECOND DIMENSION: `char m[12][4]`. Build a row type of size
			 * inner*sizeof(element) and make that the element type, so m[i]
			 * strides by the row and m[i][j] by the element. Flattening to
			 * 48 chars would give the right SIZE and the wrong INDEX. */
			if(match("[", global_token->s))
			{
				require_extra_token();
				int inner = constant_expression();
				if(inner < 1)
				{
					line_error();
					fputs("Second array dimension must be at least 1\n", stderr);
					exit(EXIT_FAILURE);
				}
				require_match("ERROR in collect_local\nMissing ] after second dimension\n", "]");
				a->type = new_array_row_type(a->type, inner);
			}
		}

		if(NULL != function->locals)
		{
			function_depth_offset = function->locals->depth;
		}

		struct_depth_adjustment = ceil_div(a->type->size * a->array_modifier, register_size) * register_size;
		if(stack_direction == STACK_DIRECTION_PLUS)
		{
			a->depth = function_depth_offset + struct_depth_adjustment;
		}
		else
		{
			a->depth = function_depth_offset - struct_depth_adjustment;
		}
		locals_depth = locals_depth + struct_depth_adjustment;

		function->locals = a;

		if(match("=", global_token->s))
		{
			if(a->array_modifier != 1)
			{
				line_error();
				fputs("Stack arrays can not be initialized.\n", stderr);
				exit(EXIT_FAILURE);
			}

			require_extra_token();

			/* A LOCAL STRUCT MAY BE BRACE-INITIALISED:
			 *     CType ct = { VT_ASM_FUNC, NULL };        tccgen.c:1167
			 * Walk the members in order and store each initialiser at its own
			 * offset. Members left out are zeroed, which is what C says an
			 * incomplete initialiser does -- and skipping that would leave
			 * stack garbage in the tail of the struct, silently. */
			if(match("{", global_token->s))
			{
				require_extra_token();
				struct type* member = type_size->members;
				while(NULL != member)
				{
					if(match("}", global_token->s))
					{
						/* zero the rest */
						emit_load_immediate(REGISTER_ZERO, 0, "struct init: implicit zero");
					}
					else
					{
						expression();
						if(global_token->s[0] == ',') require_extra_token();
					}

					emit_move(REGISTER_TEMP, REGISTER_ZERO, "struct init: value");
					load_address_of_variable_into_register(REGISTER_ONE, name);
					if(0 != member->offset)
					{
						emit_add_immediate(REGISTER_ONE, member->offset, "struct init: member offset");
					}
					emit_move(REGISTER_ZERO, REGISTER_TEMP, "struct init: value");

					/* A MEMBER MAY ITSELF BE A STRUCT, and then it does not fit
					 * in a register:
					 *     Sym aref = {0};                  tccgen.c:7732
					 * Sym's members include structs. Write it a word at a time.
					 * Only a ZERO initialiser is handled that way -- storing a
					 * non-zero value into an aggregate member would need a copy
					 * from a source address, and there is no source here, so
					 * that stops rather than writing one word and calling it
					 * done. */
					if(register_size >= member->size)
					{
						emit_out(store_value(member->size));
					}
					else
					{
						int wrote = 0;
						while(wrote < member->size)
						{
							/* Same rule as the struct copy: only 8/4/2/1. */
							int rem = member->size - wrote;
							int w = register_size;
							if(rem < 8) w = 4;
							if(rem < 4) w = 2;
							if(rem < 2) w = 1;
							if(w > rem) w = 1;
							emit_out(store_value(w));
							wrote = wrote + w;
							if(wrote < member->size)
							{
								emit_add_immediate(REGISTER_ONE, w, "struct init: next word");
							}
						}
					}

					member = member->members;
				}
				require_match("ERROR in struct initialiser\nMissing }\n", "}");
			}
			else
			{
				expression();

				load_address_of_variable_into_register(REGISTER_ONE, name);

				/* A STRUCT INITIALISER IS A COPY, NOT A STORE:
				 *     CType type = *func_type;         arm64-gen.c:1445
				 * The assignment path learned this at tccgen.c:392; the
				 * DECLARATION path kept its own store and had to learn it
				 * again. Both sides are addresses, so it is the same
				 * word-by-word copy, chunked 8/4/2/1. */
				/* THE DECLARATOR'S TYPE, NOT THE BASE TYPE.
				 *
				 * type_size is what type_name() returned -- the base of the
				 * whole declaration. current_type is THIS declarator's type,
				 * with the stars applied. They are the same for the first
				 * declarator and diverge the moment a second one adds a `*`:
				 *
				 *     uint8_t buf[1000], *p = buf;        tccpp.c:2191
				 *
				 * Here type_size is `uint8_t`, size 1, so the initialiser
				 * stored ONE BYTE of buf's address into an eight-byte pointer.
				 * The declaration below it was already right -- sym_declare
				 * gets current_type -- so `p` had the correct type and the
				 * wrong value, and every later read loaded eight bytes of
				 * which seven were whatever the stack held.
				 *
				 * parse_string then memcpy'd through that pointer on every
				 * short string literal, and eventually handed it to free,
				 * which is where it finally became visible. */
				if(register_size >= current_type->size)
				{
					emit_out(store_value(current_type->size));
				}
				else
				{
					emit_move(REGISTER_TEMP, REGISTER_ZERO, "struct init: source");
					emit_move(REGISTER_ZERO, REGISTER_ONE, "struct init: destination via x0");
					emit_move(REGISTER_TEMP2, REGISTER_ZERO, "struct init: destination");
					int done = 0;
					while(done < current_type->size)
					{
						int rem = current_type->size - done;
						int ch = register_size;
						if(rem < 8) ch = 4;
						if(rem < 4) ch = 2;
						if(rem < 2) ch = 1;
						if(ch > rem) ch = 1;

						emit_move(REGISTER_ZERO, REGISTER_TEMP2, "struct init: destination");
						emit_move(REGISTER_ONE, REGISTER_ZERO, "struct init: destination");
						emit_move(REGISTER_ZERO, REGISTER_TEMP, "struct init: word");
						emit_out(load_value(ch, FALSE));
						emit_out(store_value(ch));

						emit_advance_temp(REGISTER_TEMP, ch, "struct init: advance source");
						emit_advance_temp(REGISTER_TEMP2, ch, "struct init: advance destination");
						done = done + ch;
					}
				}
			}
		}

		if(global_token->s[0] == ',')
		{
			maybe_bootstrap_error("multiple variables per statement");

			require_extra_token();

			current_type = base_type;
			while(global_token->s[0] == '*')
			{
				current_type = current_type->indirect;

				require_extra_token();
			}
		}
	}
	while(global_token->s[0] != ';');

	require_match("ERROR in collect_local\nMissing ;\n", ";");
}

void statement(void);

/* Evaluate if statements */
void process_if(void)
{
	char* number_string = int2str(current_count, 10, TRUE);
	current_count = current_count + 1;

	char* unique_id = create_unique_id("", function->s, number_string);

	emit_out("# IF_");
	emit_out(unique_id);
	emit_out("\n");

	global_token = global_token->next;
	require_match("ERROR in process_if\nMISSING (\n", "(");
	comma_expression();

	emit_jump_if_zero(REGISTER_ZERO, "ELSE_", unique_id, "Jump to else");

	require_match("ERROR in process_if\nMISSING )\n", ")");
	statement();
	require(NULL != global_token, "Reached EOF inside of function\n");

	int has_else = match("else", global_token->s);
	if(has_else)
	{
		emit_unconditional_jump("_END_IF_", unique_id, "Else statement");
	}

	emit_label("ELSE_", unique_id);

	if(has_else)
	{
		require_extra_token();
		statement();
		require_token();
	}
	emit_label("_END_IF_", unique_id);
}

void process_case(void)
{
process_case_iter:
	require(NULL != global_token, "incomplete case statement\n");
	if(match("case", global_token->s)) return;
	if(match("default", global_token->s)) return;
	if(global_token->s[0] == '}') return;

	if(match("break", global_token->s))
	{
		statement();
		require(NULL != global_token, "incomplete case statement\n");
	}
	else
	{
		statement();
		require(NULL != global_token, "incomplete case statement\n");
		goto process_case_iter;
	}
}

/* LOAD A CASE VALUE INTO R0, SIGN INTACT.
 *
 * `case -2:` was loaded as 4294967294. The value is stored in the case list as
 * its LABEL SPELLING, which is rendered unsigned, and the table recovered the
 * constant by strtoint()ing that name back -- so the sign was laundered out
 * through a string. R1 holds the switch value, sign-extended to the full
 * register, so nothing ever matched and the switch fell to default.
 *
 * IT PASSED ON amd64 BY ACCIDENT, which is why it survived: x86-64's
 * `mov_rax,%imm32` SIGN-EXTENDS, so the wrong constant landed on the right
 * value. aarch64 builds its immediates zero-extended and does not. That is the
 * fifth instance of the invisible-on-amd64/fatal-on-aarch64 class MICRO-C.md
 * counts, and it is the one the difftest suite caught by being run on both.
 *
 * NEGATION WITHOUT A NEGATE. There is no general negative-immediate lowering
 * here -- the aarch64 table carries exactly three, `mov_x0,-1`, `-8` and
 * `-100`, the ones M2libc happened to need -- so emitting `mov x0, -2` would
 * need a new macro on every architecture. It is not necessary:
 *
 *     -v  ==  ~(v - 1)
 *
 * so the magnitude minus one is loaded and bitwise-NOT'd. Every one of those
 * NOT forms is already emitted for unary `~` and is therefore already proven
 * against each architecture's M1 vocabulary. No new macro anywhere.
 *
 * `-(value + 1)` rather than `-value - 1` on purpose: the first is exactly
 * |value| - 1 and stays representable at INT_MIN, where negating first would
 * overflow. */
void emit_case_value(long long value)
{
	if(value >= 0)
	{
		emit_load_immediate(REGISTER_ZERO, value, "Load case value");
		return;
	}

	emit_load_immediate(REGISTER_ZERO, -(value + 1), "Load case value (magnitude - 1)");

	if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) emit_out("NOT R0 R0\n");
	else if(X86 == Architecture) emit_out("not_eax\n");
	else if(AMD64 == Architecture) emit_out("not_rax\n");
	else if(ARMV7L == Architecture) emit_out("'0' R0 R0 MVN_ALWAYS\n");
	else if(AARCH64 == Architecture) emit_out("mvn_x0,x0\n");
	else if((RISCV32 == Architecture) || (RISCV64 == Architecture)) emit_out("rd_a0 rs1_a0 not\n");
}

/* A C LABEL IS SCOPED TO ITS FUNCTION. THIS COMPILER EMITTED IT GLOBALLY.
 *
 *     :redo     #C goto label
 *
 * -- five times, in one flat assembler namespace, from the five different
 * functions in tccpp.c that each write `redo:`. Every `goto redo` in the unit
 * therefore resolved to whichever definition the linker kept, and control left
 * for an unrelated function. That is what was killing the micro-c-built tcc:
 * `next()` reached `begin_macro`, returned from it correctly, executed
 * `goto redo`, and never came back.
 *
 * M2-Planet gets away with it because M2-Planet's own source has globally
 * unique labels -- there is a `/* because of how M2-Planet treats labels *``/`
 * comment in its switch code saying as much. tcc's source does not, and has no
 * reason to: C says a label is visible only inside the function that declares
 * it, so five functions may each have a `redo:` and thousands of programs do.
 *
 * Our own stage 2 hit this exactly once and fixed it the same way (see
 * PROGRESS.md m58): qualify the emitted name with the enclosing function, so
 * two functions may each define `redo` and neither can see the other's. The
 * definition and the reference must agree by construction, which is why both
 * go through this one function rather than concatenating in two places. */
char* goto_label_name(char* name)
{
	char* scope = "";
	if(NULL != function) scope = function->s;
	return concat_strings3(name, "_L_", scope);
}

void process_switch(void)
{
	maybe_bootstrap_error("switch/case statements");
	struct token_list* nested_locals = break_frame;
	char* nested_break_head = break_target_head;
	char* nested_break_func = break_target_func;
	char* nested_break_num = break_target_num;
	char* nested_continue_head = continue_target_head;
	char* nested_continue_func = continue_target_func;
	char* nested_continue_num = continue_target_num;

	char* number_string = int2str(current_count, 10, TRUE);
	current_count = current_count + 1;

	break_target_head = "_SWITCH_END_";
	/* continue_target_head is DELIBERATELY LEFT ALONE. tccpp.c:893 has a
	 * `continue` inside a switch inside a while loop, which is ordinary C --
	 * continue targets the enclosing LOOP, break targets the switch. Now that
	 * continue carries its own func/num, passing it through is safe. */
	break_target_num = number_string;
	break_frame = function->locals;
	break_target_func = function->s;

	char* unique_id = create_unique_id("", function->s, number_string);

	emit_out("# switch_");
	emit_out(unique_id);
	emit_out("\n");

	/* get what we are casing on */
	global_token = global_token->next;
	require_match("ERROR in process_switch\nMISSING (\n", "(");
	expression();
	require_match("ERROR in process_switch\nMISSING )\n", ")");

	/* Put the value in R1 as it is currently in R0 */
	emit_move(REGISTER_ONE, REGISTER_ZERO, "process switch");

	emit_unconditional_jump("_SWITCH_TABLE_", unique_id, "Jump to the switch table");

	int has_default = FALSE;

	/* must be switch (exp) {$STATEMENTS}; form */
	require_match("ERROR in process_switch\nMISSING {\n", "{");
	struct case_list* backtrack = NULL;
	long long value;
process_switch_iter:
	require(NULL != global_token, "incomplete switch statement\n");

	/* AN ORDINARY GOTO LABEL MAY SIT BETWEEN CASES. tccpp.c:952 has
	 *     break;
	 * _default:
	 *     default:
	 * -- `_default:` is a goto target, not a case. process_case returns after
	 * a `break`, so the label lands back here, where only case/default/} were
	 * accepted. Emit it and carry on; statement() handles labels the same way
	 * elsewhere, this loop just never saw one. */
	if(NULL != global_token->next)
	{
		if(global_token->next->s[0] == ':')
		{
			if(!match("case", global_token->s) && !match("default", global_token->s))
			{
				emit_out(":");
				emit_out(goto_label_name(global_token->s));
				emit_out("\t#C goto label in switch\n");
				global_token = global_token->next;
				require_extra_token();
				goto process_switch_iter;
			}
		}
	}

	if(match("case", global_token->s))
	{
		require_extra_token();
		value = constant_expression();
		require_token();
		if(':' == global_token->s[0])
		{
			struct case_list* c = calloc(1, sizeof(struct case_list));
			c->next = backtrack;
			c->ivalue = value;
			/* int2str, NOT long2str, and deliberately. This string is a LABEL
			 * NAME -- :_SWITCH_CASE_<value>_<uid> -- so its only job is to be
			 * injective; c->ivalue beside it carries the number. Rendering it
			 * any wider would change every switch label micro-c has ever
			 * emitted, and the guard on this patch is that the .M1 does not
			 * move for any constant that fits 32 bits. */
			c->value = int2str(value, 10, FALSE);
			backtrack = c;
			emit_out(":_SWITCH_CASE_");
			emit_out(c->value);
			emit_out("_");
			emit_out(unique_id);
			emit_out("\n");
			require_extra_token();
			process_case();
			require_token();
		}
		else line_error();
		goto process_switch_iter;
	}
	else if(match("default", global_token->s))
	{ /* because of how M2-Planet treats labels */
		has_default = TRUE;
		require_extra_token();
		require_match("ERROR in process_switch\nMISSING : after default\n", ":");
		emit_label("_SWITCH_DEFAULT_", unique_id);

		/* `default:` NEED NOT COME LAST.
		 *     switch(op) {
		 *     default: l1 = gen_opic_sdiv(l1, l2); break;
		 *     case '%': ...                            tccgen.c:2396
		 *
		 * This used to collect statements straight through to '}', which
		 * assumed nothing followed it, and a `case` after it then reached
		 * statement() as an undefined symbol. Use process_case like the case
		 * branch does -- it stops at case, default or '}' -- and loop back.
		 *
		 * The jump that skips the table moves OUT of here to after the whole
		 * body, which is where it belongs: emitting it at the end of default
		 * would cut the fall-through from default into a following case, and
		 * a switch with NO default previously emitted no such jump at all and
		 * ran its last case's statements straight into the table. */
		process_case();
		goto process_switch_iter;
	}

	/* Switch statements must end with } */
	require_match("ERROR in process_switch\nMISSING }\n", "}");

	emit_unconditional_jump("_SWITCH_END_", unique_id, "jump over the switch table");

	/* create the table */
	emit_label("_SWITCH_TABLE_", unique_id);

	char* buf;
	struct case_list* hold;
	while(NULL != backtrack)
	{
		/* put case value in R0 as the switch (value) is in R1 */
		emit_case_value(backtrack->ivalue);
		hold = backtrack->next;

		buf = concat_strings3(backtrack->value, "_", unique_id);

		emit_jump_if_equal(REGISTER_ZERO, REGISTER_ONE, "_SWITCH_CASE_", buf, "Jump to case if equal");

		free(backtrack);
		backtrack = hold;
	}

	if(has_default)
	{
		emit_unconditional_jump("_SWITCH_DEFAULT_", unique_id, "Default to default:");
	}

	/* put the exit of the switch */
	emit_label("_SWITCH_END_", unique_id);

	break_target_head = nested_break_head;
	break_target_func = nested_break_func;
	break_target_num = nested_break_num;
	continue_target_head = nested_continue_head;
	continue_target_func = nested_continue_func;
	continue_target_num = nested_continue_num;
	break_frame = nested_locals;
}

void process_for(void)
{
	struct token_list* nested_locals = break_frame;
	char* nested_break_head = break_target_head;
	char* nested_break_func = break_target_func;
	char* nested_break_num = break_target_num;
	char* nested_continue_head = continue_target_head;
	char* nested_continue_func = continue_target_func;
	char* nested_continue_num = continue_target_num;

	char* number_string = int2str(current_count, 10, TRUE);
	current_count = current_count + 1;

	break_target_head = "FOR_END_";
	continue_target_head = "FOR_ITER_";
	continue_target_num = number_string;
	continue_target_func = function->s;
	break_target_num = number_string;
	break_frame = function->locals;
	break_target_func = function->s;

	char* unique_id = create_unique_id("", function->s, number_string);

	emit_out("# FOR_initialization_");
	emit_out(unique_id);
	emit_out("\n");

	require_extra_token();

	require_match("ERROR in process_for\nMISSING (\n", "(");
	/* fallible_type_name moves the global token if non-NULL */
	struct token_list* current = global_token;
	if (fallible_type_name() != NULL)
	{
		global_token = current;
		collect_local();
	}
	else if(!match(";", global_token->s))
	{
		/* The init clause is a FULL expression, commas included:
		 *     for (n = 0, q = tokc.str.data; *q; ++q)      tccpp.c:1946 */
		comma_expression();
		require_match("ERROR in process_for\nMISSING ;1\n", ";");
	}
	else
	{
		require_match("ERROR in process_for\nMISSING ;3\n", ";");
	}

	emit_label("FOR_", unique_id);

	/* AN EMPTY CONDITION IS ALWAYS TRUE. `for (;;)` at tccpp.c:415 has all
	 * three clauses empty; the init clause already handled that, the other two
	 * called expression() unconditionally and died on ';' and ')'.
	 *
	 * Skipping the exit jump as well as the expression is the part that
	 * matters: emitting jump-if-zero on whatever happened to be in the
	 * register would end the loop on the previous statement's value. */
	if(match(";", global_token->s))
	{
		emit_out("# FOR condition empty -- always true\n");
	}
	else
	{
		/* The condition is a full expression too:
		 *     for (p = in; c = *p, c != 0 && c != PATHSEP[0]; ++p)
		 *                                          libtcc.c:582
		 * Init and increment already took comma_expression; the middle clause
		 * was the one left. */
		comma_expression();
		emit_jump_if_zero(REGISTER_ZERO, "FOR_END_", unique_id, "Jump to end");
	}

	emit_unconditional_jump("FOR_THEN_", unique_id, "Go to body");

	emit_label("FOR_ITER_", unique_id);

	require_match("ERROR in process_for\nMISSING ;2\n", ";");
	if(!match(")", global_token->s))
	{
		comma_expression();   /* `for (...; ...; i++, j--)` is equally legal */
	}

	emit_unconditional_jump("FOR_", unique_id, "Check conditional");

	emit_label("FOR_THEN_", unique_id);

	require_match("ERROR in process_for\nMISSING )\n", ")");
	statement();
	require(NULL != global_token, "Reached EOF inside of function\n");

	emit_unconditional_jump("FOR_ITER_", unique_id, "Repeat iteration");

	emit_label("FOR_END_", unique_id);

	break_target_head = nested_break_head;
	break_target_func = nested_break_func;
	break_target_num = nested_break_num;
	continue_target_head = nested_continue_head;
	continue_target_func = nested_continue_func;
	continue_target_num = nested_continue_num;
	break_frame = nested_locals;
}

/* Process Assembly statements */
void process_asm(void)
{
	global_token = global_token->next;
	require_match("ERROR in process_asm\nMISSING (\n", "(");
	while('"' == global_token->s[0])
	{
		emit_out((global_token->s + 1));
		emit_out("\n");
		require_extra_token();
	}
	require_match("ERROR in process_asm\nMISSING )\n", ")");
	require_match("ERROR in process_asm\nMISSING ;\n", ";");
}

/* Process do while loops */
void process_do(void)
{
	struct token_list* nested_locals = break_frame;
	char* nested_break_head = break_target_head;
	char* nested_break_func = break_target_func;
	char* nested_break_num = break_target_num;
	char* nested_continue_head = continue_target_head;
	char* nested_continue_func = continue_target_func;
	char* nested_continue_num = continue_target_num;

	char* number_string = int2str(current_count, 10, TRUE);
	current_count = current_count + 1;

	char* unique_id = create_unique_id("", function->s, number_string);

	break_target_head = "DO_END_";
	continue_target_head = "DO_TEST_";
	continue_target_num = number_string;
	continue_target_func = function->s;
	break_target_num = number_string;
	break_frame = function->locals;
	break_target_func = function->s;

	emit_label("DO_", unique_id);

	require_extra_token();
	statement();
	require_token();

	emit_label("DO_TEST_", unique_id);

	require_match("ERROR in process_do\nMISSING while\n", "while");
	require_match("ERROR in process_do\nMISSING (\n", "(");
	/* A do-while condition is a FULL expression too:
	 *     } while (++p, f);                        tccrun.c:296
	 * The sixth position taking comma_expression, and the last controlling
	 * expression that did not have it. */
	comma_expression();
	require_match("ERROR in process_do\nMISSING )\n", ")");
	require_match("ERROR in process_do\nMISSING ;\n", ";");

	emit_jump_if_not_zero(REGISTER_ZERO, "DO_", unique_id, "Rerun loop");

	emit_label("DO_END_", unique_id);

	break_frame = nested_locals;
	break_target_head = nested_break_head;
	break_target_func = nested_break_func;
	break_target_num = nested_break_num;
	continue_target_head = nested_continue_head;
	continue_target_func = nested_continue_func;
	continue_target_num = nested_continue_num;
}


/* Process while loops */
void process_while(void)
{
	struct token_list* nested_locals = break_frame;
	char* nested_break_head = break_target_head;
	char* nested_break_func = break_target_func;
	char* nested_break_num = break_target_num;
	char* nested_continue_head = continue_target_head;
	char* nested_continue_func = continue_target_func;
	char* nested_continue_num = continue_target_num;

	char* number_string = int2str(current_count, 10, TRUE);
	current_count = current_count + 1;

	char* unique_id = create_unique_id("", function->s, number_string);

	break_target_head = "END_WHILE_";
	continue_target_head = "WHILE_";
	continue_target_num = number_string;
	continue_target_func = function->s;
	break_target_num = number_string;
	break_frame = function->locals;
	break_target_func = function->s;

	emit_label("WHILE_", unique_id);

	global_token = global_token->next;
	require_match("ERROR in process_while\nMISSING (\n", "(");
	comma_expression();

	emit_jump_if_zero(REGISTER_ZERO, "END_WHILE_", unique_id, "Jump to end");

	emit_out("# THEN_while_");
	emit_out(unique_id);
	emit_out("\n");

	require_match("ERROR in process_while\nMISSING )\n", ")");
	statement();
	require(NULL != global_token, "Reached EOF inside of function\n");

	emit_unconditional_jump("WHILE_", unique_id, "Repeat loop");

	emit_label("END_WHILE_", unique_id);

	break_target_head = nested_break_head;
	break_target_func = nested_break_func;
	break_target_num = nested_break_num;
	continue_target_head = nested_continue_head;
	continue_target_func = nested_continue_func;
	continue_target_num = nested_continue_num;
	break_frame = nested_locals;
}

char* function_locals_cleanup_string;
/* Ensure that functions return */
void return_result(void)
{
	require_extra_token();
	if(global_token->s[0] != ';') expression();

	require_match("ERROR in return_result\nMISSING ;\n", ";");

	emit_out(function_locals_cleanup_string);
	emit_return();
}

void process_break(void)
{
	if(NULL == break_target_head)
	{
		line_error();
		fputs("Not inside of a loop or case statement\n", stderr);
		exit(EXIT_FAILURE);
	}

	require_extra_token();

	char* break_target = concat_strings4(break_target_head, break_target_func, "_", break_target_num);
	emit_unconditional_jump("", break_target, "Break statement");

	require_match("ERROR in break statement\nMissing ;\n", ";");
}

void process_continue(void)
{
	if(NULL == continue_target_head)
	{
		line_error();
		fputs("Not inside of a loop\n", stderr);
		exit(EXIT_FAILURE);
	}
	require_extra_token();

	char* continue_target = concat_strings4(continue_target_head, continue_target_func, "_", continue_target_num);

	emit_unconditional_jump("", continue_target, "Continue statement");

	require_match("ERROR in continue statement\nMissing ;\n", ";");
}

void recursive_statement(void)
{
	require_extra_token();
	struct token_list* frame = function->locals;

	while(!match("}", global_token->s))
	{
		statement();
		require(NULL != global_token, "Received EOF in recursive statement prior to }\n");
	}
	global_token = global_token->next;

	function->locals = frame;
}

/* Variables inside loops are currently just global variables */
void process_static_variable(void)
{
	maybe_bootstrap_error("static local variable");

	struct type* type_size = type_name();
	char* name = global_token->s;

	struct static_variable_list* variable = calloc(1, sizeof(struct static_variable_list));
	variable->next = function_static_variables_list;
	function_static_variables_list = variable;
	variable->local_variable_name = name;

	char* new_name = concat_strings3(function->s, "_", name);

	variable->global_variable = sym_declare(new_name, type_size, NULL, TLO_STATIC);
	require_extra_token();

	declare_global_variable(type_size, variable->global_variable);

	require_match("Expected ; after static variable declarations\n", ";");
}

/*
 * statement:
 *     { statement-list-opt }
 *     type-name identifier ;
 *     type-name identifier = expression;
 *     if ( expression ) statement
 *     if ( expression ) statement else statement
 *     do statement while ( expression ) ;
 *     while ( expression ) statement
 *     for ( expression ; expression ; expression ) statement
 *     asm ( "assembly" ... "assembly" ) ;
 *     goto label ;
 *     label:
 *     return ;
 *     break ;
 *     expr ;
 * 	   ; (Empty statement)
 */

struct type* lookup_primitive_type(void);
void statement(void)
{
	require(NULL != global_token, "expected a C statement but received EOF\n");
	/* Always an integer until told otherwise */
	current_target = integer;

	struct token_list* current_token = global_token;

	struct token_list* next_token = global_token->next;
	int is_label = FALSE;
	if(next_token != NULL)
	{
		if(next_token->s[0] == ':')
		{
			is_label = TRUE;
		}
	}

	if(global_token->s[0] == '{')
	{
		recursive_statement();
	}
	else if(is_label)
	{
		emit_out(":");
		emit_out(goto_label_name(global_token->s));
		emit_out("\t#C goto label\n");
		global_token = global_token->next;
		require_extra_token();

		/* A LABEL IS A PREFIX, NOT A STATEMENT.
		 *
		 * `lab: stmt;` is ONE labelled statement in C. Returning here made
		 * the label a statement in its own right, which is harmless inside a
		 * block -- the block loop just calls statement() again for the next
		 * line -- and wrong wherever a single statement is expected:
		 *
		 *     if (t0 == TOK_PPJOIN)
		 *     bad_twosharp:
		 *         tcc_error("'##' cannot appear at either end of macro");
		 *                                                    tccpp.c:1621
		 *
		 * The if got the label as its whole body and the tcc_error became the
		 * next statement, unconditional. So every #define tcc preprocessed
		 * raised that error, and the first one reported was <command line>:1
		 * -- its own predefs. It looked like a macro bug and was a parser one.
		 *
		 * The construct is unusual because the label is BOTH a goto target and
		 * the branch body; tcc uses it to reach one error site two ways.
		 *
		 * A `}` cannot follow a label in C89 or C99, but tolerating it costs
		 * nothing and misparsing it would cost a round.
		 *
		 * AND NOT WHEN A case OR default FOLLOWS. tccpp.c:952 writes
		 *
		 *     break;
		 * _default:
		 *     default:
		 *
		 * -- an ordinary goto label immediately in front of a switch label.
		 * Those belong to process_switch, not to statement(), and recursing
		 * into statement() here made it try to parse `default` as an
		 * expression: "case is not a defined symbol", reported against
		 * tcc.h:1116, which has nothing to do with it. process_switch already
		 * has a branch for exactly this shape and its comment says so; this
		 * is the same rule seen from the other side. */
		if(global_token->s[0] != '}' &&
		   !match("case", global_token->s) &&
		   !match("default", global_token->s))
		{
			statement();
		}
	}
	else if((NULL != lookup_primitive_type()) ||
	          match("enum", global_token->s) ||
	          match("struct", global_token->s) ||
	          match("union", global_token->s) ||
	          match("const", global_token->s))
	{
		/* Multi token lookup may move the global_token, but collect_local does a lookup of its own. */
		global_token = current_token;
		collect_local();
	}
	else if(match("if", global_token->s))
	{
		process_if();
	}
	else if(match("switch", global_token->s))
	{
		process_switch();
	}
	else if(match("do", global_token->s))
	{
		process_do();
	}
	else if(match("while", global_token->s))
	{
		process_while();
	}
	else if(match("for", global_token->s))
	{
		process_for();
	}
	else if(match("asm", global_token->s))
	{
		process_asm();
	}
	else if(match("goto", global_token->s))
	{
		require_extra_token();
		emit_unconditional_jump("", goto_label_name(global_token->s), "Goto");
		require_extra_token();
		require_match("ERROR in statement\nMissing ;\n", ";");
	}
	else if(match("return", global_token->s))
	{
		return_result();
	}
	else if(match("break", global_token->s))
	{
		process_break();
	}
	else if(match("continue", global_token->s))
	{
		process_continue();
	}
	else if(match("static", global_token->s))
	{
		require_extra_token();

		process_static_variable();
	} else if (match(";", global_token->s))
	{
		/* empty statement */
		require_extra_token();
	}
	else
	{
		comma_expression();   /* see the note on comma_expression */

		if(!match(";", global_token->s))
		{
			line_error();
			fputs("ERROR in statement: expected ';' but found '", stderr);
			fputs(global_token->s, stderr);
			fputs("'\n", stderr);
			exit(EXIT_FAILURE);
		}
		require_match("ERROR in statement\nMISSING ;\n", ";");
	}
}

/* Collect function arguments */
void collect_arguments(void)
{
	require_extra_token();
	struct type* type_size;
	struct token_list* a;

	while(!match(")", global_token->s))
	{
		if(global_token->s[0] == '.')
		{
			/* Periods can only be in the argument list as a variadic parameter
			 * so if there is a period it's part of a variadic parameter */
			require_match("Invalid token found in variadic arguments token", ".");
			require_match("Invalid token found in variadic arguments token", ".");
			require_match("Invalid token found in variadic arguments token", ".");

			maybe_bootstrap_error("variadic functions");
			break;
		}

		type_size = type_name();
		require(NULL != global_token, "Received EOF when attempting to collect arguments\n");
		require(NULL != type_size, "Must have non-null type\n");

		/* EXPERIMENT: FUNCTION-POINTER PARAMETER, `void (*cb)(int, char*)`.
		 * libtcc.h:99 declares one. The parameter name is wrapped in parens and
		 * followed by its own argument list, so the name check below sees '('
		 * and rejects it. Take the name out of the first paren group, register
		 * it pointer-sized, then skip the trailing argument list. */
		if(global_token->s[0] == '(')
		{
			int d = 0;
			char* fpname = NULL;
			while(NULL != global_token)
			{
				if(global_token->s[0] == '(') d = d + 1;
				else if(global_token->s[0] == ')')
				{
					d = d - 1;
					if(0 == d) { global_token = global_token->next; break; }
				}
				else if(NULL == fpname)
				{
					if(global_token->s[0] != '*') fpname = global_token->s;
				}
				global_token = global_token->next;
			}
			if(NULL != fpname)
			{
				a = sym_declare(fpname, function_pointer, function->arguments, TLO_ARGUMENT);
				/* A FUNCTION-POINTER PARAMETER NEEDS A STACK DEPTH like any
				 * other argument. Registering the name was enough to parse and
				 * enough to reference; without the depth it landed at offset 0
				 * and emitted `sub_x0,x17,0`, which is not in the aarch64
				 * vocabulary at all -- offsets start at 8.
				 *
				 * Three functions in tcc take one: expr_type, list_elf_symbols
				 * and tcc_list_symbols. M2-Planet's own source has none, which
				 * is why nothing caught it until the output was assembled. */
				if(NULL == function->arguments)
				{
					if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) a->depth = 0;
					else if(X86 == Architecture) a->depth = -4;
					else if(AMD64 == Architecture) a->depth = -8;
					else if(ARMV7L == Architecture) a->depth = 4;
					else if(AARCH64 == Architecture) a->depth = register_size;
					else if(RISCV32 == Architecture) a->depth = -4;
					else if(RISCV64 == Architecture) a->depth = -8;
				}
				else
				{
					if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) a->depth = function->arguments->depth + register_size;
					else if(X86 == Architecture) a->depth = function->arguments->depth - register_size;
					else if(AMD64 == Architecture) a->depth = function->arguments->depth - register_size;
					else if(ARMV7L == Architecture) a->depth = function->arguments->depth + register_size;
					else if(AARCH64 == Architecture) a->depth = function->arguments->depth + register_size;
					else if(RISCV32 == Architecture) a->depth = function->arguments->depth - register_size;
					else if(RISCV64 == Architecture) a->depth = function->arguments->depth - register_size;
				}
				function->arguments = a;
			}
			/* now skip the function pointer's own parameter list */
			if(NULL != global_token)
			{
				if(global_token->s[0] == '(')
				{
					d = 0;
					while(NULL != global_token)
					{
						if(global_token->s[0] == '(') d = d + 1;
						else if(global_token->s[0] == ')')
						{
							d = d - 1;
							if(0 == d) { global_token = global_token->next; break; }
						}
						global_token = global_token->next;
					}
				}
			}
			if(NULL != global_token)
			{
				if(global_token->s[0] == ',') global_token = global_token->next;
			}
			continue;
		}

		if(global_token->s[0] == ')')
		{
			/* foo(int,char,void) doesn't need anything done */
			continue;
		}
		else if(global_token->s[0] != ',')
		{
			/* deal with foo(int a, char b) */
			if(in_set(global_token->s[0], "[{(<=>)}]|&!^%;:'\""))
			{
				line_error();
				fputs("forbidden character in argument variable name: '", stderr);
				fputs(global_token->s, stderr);
				fputs("'\n", stderr);
				exit(EXIT_FAILURE);
			}
			require(!iskeywordp(global_token->s), "You are not allowed to use a keyword as a argument variable name\n");
			a = sym_declare(global_token->s, type_size, function->arguments, TLO_ARGUMENT);
			if(NULL == function->arguments)
			{
				if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) a->depth = 0;
				else if(X86 == Architecture) a->depth = -4;
				else if(AMD64 == Architecture) a->depth = -8;
				else if(ARMV7L == Architecture) a->depth = 4;
				else if(AARCH64 == Architecture) a->depth = register_size;
				else if(RISCV32 == Architecture) a->depth = -4;
				else if(RISCV64 == Architecture) a->depth = -8;
			}
			else
			{
				if((KNIGHT_POSIX == Architecture) || (KNIGHT_NATIVE == Architecture)) a->depth = function->arguments->depth + register_size;
				else if(X86 == Architecture) a->depth = function->arguments->depth - register_size;
				else if(AMD64 == Architecture) a->depth = function->arguments->depth - register_size;
				else if(ARMV7L == Architecture) a->depth = function->arguments->depth + register_size;
				else if(AARCH64 == Architecture) a->depth = function->arguments->depth + register_size;
				else if(RISCV32 == Architecture) a->depth = function->arguments->depth - register_size;
				else if(RISCV64 == Architecture) a->depth = function->arguments->depth - register_size;
			}

			require_extra_token();
			function->arguments = a;

			while(global_token->s[0] == '[')
			{
				require_extra_token();

				if(global_token->s[0] != ']')
				{
					/* Throw away the result since we don't use it anyway */
					constant_expression();
				}

				require_match("Invalid token received in argument array, expected ']'.\n", "]");
				a->type = a->type->indirect;
			}
		}

		/* ignore trailing comma (needed for foo(bar(), 1); expressions*/
		if(global_token->s[0] == ',')
		{
			require_extra_token();
		}

		require(NULL != global_token, "Argument list never completed\n");
	}
	require_extra_token();
}

void declare_function(struct type* return_type)
{
	current_count = 0;
	/* RECORD THE RETURN TYPE. It was registered as NULL, so a call's result had
	 * no type and current_target kept whatever the last ARGUMENT left behind --
	 * which is how `tok_alloc(str, strlen(str))->tok` came to look up `tok` in
	 * `char*`, the type of `str`. */
	function = sym_declare(global_token->prev->s, return_type, global_function_list, TLO_FUNCTION);

	/* allow previously defined functions to be looked up */
	global_function_list = function;
	if((KNIGHT_NATIVE == Architecture) && match("main", function->s))
	{
		require_match("Impossible error ( vanished\n", "(");
		require_match("Reality ERROR (USING KNIGHT-NATIVE)\nHardware does not support arguments\nthus neither can main on this architecture\ntry tape_01 and tape_02 instead\n", ")");
	}
	else collect_arguments();

	require(NULL != global_token, "Function definitions either need to be prototypes or full\n");
	/* If just a prototype don't waste time */
	if(global_token->s[0] == ';') require_extra_token();
	else
	{
		emit_out("# Defining function ");
		emit_out(function->s);
		emit_out("\n");
		emit_label("FUNCTION_", function->s);

		locals_depth = 0;

		char* allocate_locals_string = calloc(MAX_STRING, sizeof(char));

		/* Save the current location of the stack pointer. */
		emit_out(allocate_locals_string);

		char* stack_reserve_string = calloc(MAX_STRING, sizeof(char));
		emit_out(stack_reserve_string);

		function_locals_cleanup_string = calloc(MAX_STRING, sizeof(char));

		/* If we add any statics we don't want them globally available */
		function_static_variables_list = NULL;
		statement();
		/* Just to be sure this doesn't escape the function somehow. */
		function_static_variables_list = NULL;

		if(locals_depth != 0)
		{
			reset_emit_string();
			if(stack_direction == STACK_DIRECTION_PLUS)
			{
				write_add_immediate(REGISTER_STACK, locals_depth, "Reserve stack");
			}
			else
			{
				write_sub_immediate(REGISTER_STACK, locals_depth, "Reserve stack");
			}
			copy_string(stack_reserve_string, emit_string, MAX_STRING);

			/* Only write this if there are locals. Otherwise leave empty. */
			reset_emit_string();
			write_move(REGISTER_LOCALS, REGISTER_STACK, "Set locals pointer");
			copy_string(allocate_locals_string, emit_string, MAX_STRING);

			reset_emit_string();
			write_move(REGISTER_STACK, REGISTER_LOCALS, "Undo local variables");
			copy_string(function_locals_cleanup_string, emit_string, MAX_STRING);
		}

		/* C99 5.1.2.2.3 Program termination
		 * [..] reaching the } that terminates the main function returns a value of 0.
		 * */
		int is_main = match(function->s, "main");
		if (!match(return_instruction, output_list->s))
		{
			if(is_main) emit_load_immediate(REGISTER_ZERO, 0, "declare function");
			emit_out(function_locals_cleanup_string);
			emit_return();
		}

		emit_out("\n");
	}
}

struct type* typedef_function_pointer(void)
{
	char* name = parse_function_pointer();

	if(match(name, "FUNCTION"))
	{
		/* Don't create unnecessary duplicates of built-in types */
		return function_pointer;
	}

	return new_function_pointer_typedef(name);
}

struct type* global_typedef(void)
{
	require_extra_token(); /* skip 'typedef' */

	struct type* type_size = type_name();
	require(NULL != global_token, "Received EOF while reading typedef\n");

	if(global_token->s[0] == '(')
	{
		typedef_function_pointer();
	}
	else
	{
		type_size = mirror_type(type_size);
		global_token = global_token->next;

		/* AN ARRAY TYPEDEF, `typedef T name[N];`.
		 *
		 * micro-c had no form of this at all -- the name was consumed, `[`
		 * reached the `;` check, and the whole declaration died with
		 * "ERROR in typedef statement". micro-c-libc/setjmp.h says so in its
		 * own header note and works around it with a plain struct, adding that
		 * the array typedef becomes "a real micro-c gap rather than a
		 * self-inflicted one" the moment something needs it. Something does:
		 * tcc writes
		 *
		 *     jmp_buf main_jb;                       tcc.h
		 *     tcc_setjmp(s1, main_jb, ...)           tccrun.c:250
		 *
		 * and a plain struct does not decay, so the call failed with
		 * "cannot convert 'struct __jmp_buf' to 'void *'".
		 *
		 * THE SIZE IS THE WHOLE IMPLEMENTATION, and that is not a shortcut.
		 * micro-c already treats anything wider than a register as living at
		 * an ADDRESS rather than in one -- that is the same rule that makes
		 * struct arguments, struct assignment and member access work. So a
		 * typedef whose size is N elements wide gets both halves for free: a
		 * declaration reserves N elements, and passing the name yields its
		 * address rather than a load. Nothing else has to know.
		 *
		 * WHAT IT DOES NOT DO. The element type is not recorded, so INDEXING
		 * through such a typedef would stride by the whole array rather than
		 * by one element. Nothing in tcc indexes one -- jmp_buf is passed and
		 * never subscripted -- and a case would be needed before that changed.
		 * Recorded rather than discovered later. */
		if(NULL != global_token)
		{
			if(global_token->s[0] == '[')
			{
				require_extra_token();
				int elements = constant_expression();
				require_match("ERROR in typedef statement\nMissing ]\n", "]");
				require(0 < elements, "An array typedef needs a positive size\n");
				type_size->size = type_size->size * elements;
			}
		}

		/* EXPERIMENT: FUNCTION-TYPE typedef, `typedef T name(args);`.
		 * The branch above handles `typedef T (*name)(args)` -- a function
		 * POINTER -- but not the plain function type, which libtcc.h uses three
		 * times (TCCReallocFunc, TCCErrorFunc, TCCBtFunc) and tcc uses nowhere
		 * in the pointer form. Skip the balanced parameter list; the name is
		 * already registered with a pointer-sized type, which is enough for the
		 * declarations that follow to parse. */
		if(NULL != global_token)
		{
			if(global_token->s[0] == '(')
			{
				int depth = 0;
				while(NULL != global_token)
				{
					if(global_token->s[0] == '(') depth = depth + 1;
					if(global_token->s[0] == ')')
					{
						depth = depth - 1;
						if(0 == depth)
						{
							global_token = global_token->next;
							break;
						}
					}
					global_token = global_token->next;
				}
				/* MARK IT CALLABLE. The typedef names a FUNCTION type, so a
				 * value of that type is called through:
				 *     TCCBtFunc *bt_func;  ...  bt_func(...)   tccrun.c:1140
				 * Without TO_FUNCTION_POINTER, postfix_expr_stub refuses the
				 * '(' as an operator on a non-function-pointer. Registering the
				 * name pointer-sized was enough to PARSE the declaration and
				 * not enough to use it. */
				type_size->options = type_size->options | TO_FUNCTION_POINTER;
				if(NULL != type_size->indirect)
				{
					type_size->indirect->options = type_size->indirect->options | TO_FUNCTION_POINTER;
				}
			}
		}
	}

	require_match("ERROR in typedef statement\nMissing ;\n", ";");

	return type_size;
}

void global_variable_header(char* name)
{
	globals_list = emit(":GLOBAL_", globals_list);
	globals_list = emit(name, globals_list);
	globals_list = emit("\n", globals_list);
}

void global_variable_zero_initialize(int size)
{
	unsigned i = ceil_div(size, register_size);
	while(i != 0)
	{
		/* NULLs are defined in the *_defs.M1 files to be register_size.
		 * This will round objects up to a multiple of register_size, but
		 * it will not have a negative effect.
		 * */
		globals_list = emit("NULL\n", globals_list);
		i = i - 1;
	}
}

void global_value_output(long long value, int size)
{
	if(size == 1)
	{
		globals_list = emit(integer_to_raw_byte_string(value), globals_list);
	}
	else if(size == 2)
	{
		if(value < 0 && Architecture != RISCV64 && Architecture != RISCV32)
		{
			globals_list = emit("@", globals_list);
		}
		else
		{
			globals_list = emit("$", globals_list);
		}
		globals_list = emit(int2str(value, 10, FALSE), globals_list);
		globals_list = emit(" ", globals_list);
	}
	else if(size >= 4)
	{
		globals_list = emit("%", globals_list);
		globals_list = emit(long2str(immediate_low_word(value), 10, FALSE), globals_list);
		globals_list = emit(" ", globals_list);

		if(size == 8)
		{
			/* THE HIGH WORD IS THE VALUE'S HIGH WORD, not a sign guess.
			 * This emitted 0xffffffff for anything negative and 0 for anything
			 * else -- a correct SIGN EXTENSION of a 32-bit number, and silently
			 * wrong for a 64-bit one: an eight-byte global initialised to
			 * 0x100000000 got 0. */
			globals_list = emit("%", globals_list);
			globals_list = emit(long2str(immediate_high_word(value), 10, FALSE), globals_list);
			globals_list = emit(" ", globals_list);
		}
	}

}

void global_pad_to_register_size(int bytes_written)
{
	int remaining = (bytes_written % register_size);
	if(remaining != 0)
	{
		int alignment_size = register_size - remaining;
		while(alignment_size != 0)
		{
			globals_list = emit("'00' ", globals_list);

			alignment_size = alignment_size - 1;
		}
	}

	globals_list = emit("\n", globals_list);
}

void global_struct_initializer_list(struct type* type_size);
void global_value_selection(struct type* type_size)
{
	if(type_is_pointer(type_size))
	{
		if(('"' == global_token->s[0]))
		{
			/* A LABEL MUST NOT BE THE STRING'S CONTENTS.
			 *
			 * This used `global_token->s + 1` -- the text of the string -- as
			 * the symbol name, which works only while every such string is a
			 * plain identifier. tccdbg.c has
			 *     "long int:t3=r3;-9223372036854775808;9223372036854775807;"
			 * and M1 rejected the resulting label outright.
			 *
			 * A generated id is both valid and unique. Found by ASSEMBLING the
			 * output: it parsed and emitted happily for the whole run. */
			char* number_string = int2str(current_count_global, 10, TRUE);
			current_count_global = current_count_global + 1;
			char* name = create_unique_id("STR_", "g", number_string);
			globals_list = emit("&GLOBAL_", globals_list);
			globals_list = emit(name, globals_list);
			globals_list = emit("_contents ", globals_list);

			if(register_size == 8)
			{
				global_value_output(0, 4);
			}

			strings_list = emit(":GLOBAL_", strings_list);
			strings_list = emit(name, strings_list);
			strings_list = emit("_contents\n", strings_list);

			/* ADJACENT LITERALS CONCATENATE HERE TOO.
			 *     static const char * const target_os_defs =
			 *         "__linux__\0"
			 *         "__linux\0"
			 *         ...;                                 tccpp.c:3596
			 * Only the first was consumed, so the next arrived at
			 * constant_expression as a string and failed. Accumulate the whole
			 * run into one literal before emitting it -- the same rule
			 * primary_expr_string and the array initialiser already follow. */
			char* joined = calloc(MAX_STRING, sizeof(char));
			require(NULL != joined, "Exhausted memory joining a global string initialiser\n");
			int ji = 0;
			joined[ji] = '"';
			ji = ji + 1;
			while('"' == global_token->s[0])
			{
				int jj = 1;
				while(0 != global_token->s[jj])
				{
					require(ji < MAX_STRING, "joined global string exceeded MAX_STRING\n");
					joined[ji] = global_token->s[jj];
					ji = ji + 1;
					jj = jj + 1;
				}
				require_extra_token();
			}
			joined[ji] = 0;
			strings_list = emit(parse_string(joined), strings_list);
		}
		else if(match("0", global_token->s))
		{
			global_value_output(0, register_size);
			require_extra_token();
		}
		else if(global_token->s[0] == '&')
		{
			require_extra_token();

			char* name = global_token->s;
			struct token_list* lookup_token = sym_lookup(name, global_function_list);
			if(NULL != lookup_token)
			{
				globals_list = emit("&FUNCTION_", globals_list);
				globals_list = emit(name, globals_list);
				globals_list = emit(" ", globals_list);
			}
			else
			{
				lookup_token = sym_lookup(name, global_symbol_list);
				if(NULL != lookup_token)
				{
					globals_list = emit("&GLOBAL_", globals_list);
					globals_list = emit(name, globals_list);
					globals_list = emit(" ", globals_list);
				}
				else
				{
					line_error();
					fputs("Unable to find address of '", stderr);
					fputs(name, stderr);
					fputs("'.\n", stderr);
					exit(EXIT_FAILURE);
				}
			}
			if(register_size > 4)
			{
				globals_list = emit("%0 ", globals_list);
			}
			require_extra_token();
		}
		else if(in_set(global_token->s[0], "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"))
		{
			/* A GLOBAL FUNCTION POINTER MAY BE INITIALISED WITH A FUNCTION
			 * NAME:
			 *     static void *(*reallocator)(void*, unsigned long)
			 *         = default_reallocator;       libtcc.c:265
			 * The branches above take "string", 0 and &name, but not a bare
			 * function -- which is the ordinary way to fill a function
			 * pointer. A function designator IS its address, so this emits the
			 * same &FUNCTION_ reference the &name form does. */
			struct token_list* fsym = sym_lookup(global_token->s, global_function_list);
			if(NULL == fsym)
			{
				line_error();
				fputs("Invalid initializer for global struct pointer member.\n", stderr);
				exit(EXIT_FAILURE);
			}
			globals_list = emit("&FUNCTION_", globals_list);
			globals_list = emit(fsym->s, globals_list);
			globals_list = emit(" ", globals_list);
			if(register_size == 8)
			{
				globals_list = emit("%0 ", globals_list);
			}
			require_extra_token();
		}
		else
		{
			line_error();
			fputs("Invalid initializer for global struct pointer member.\n", stderr);
			exit(EXIT_FAILURE);
		}
	}
	else if(type_is_struct_or_union(type_size))
	{
		global_struct_initializer_list(type_size);
	}
	else
	{
		long long value = constant_expression();
		global_value_output(value, type_size->size);
	}
}

/* A STRING LITERAL INITIALISING A char ARRAY MEMBER, LAID OUT INLINE.
 *
 * micro-c has a string path for globals, but only `if(type_is_pointer(...))`,
 * where it emits a POINTER to storage elsewhere. A `char[16]` MEMBER cannot be
 * that: the bytes belong at the member's own offset, because the struct is
 * memcpy'd and written to a file and the layout has to be exact.
 *
 *     static const ArHdr arhdr_init = {
 *         "/               ",        char ar_name[16]
 *         "0           ",            char ar_date[12]
 *         ...
 *         ARFMAG                     char ar_fmag[2]   -- "`\n", NO room for NUL
 *     };                                          tcctools.c:60
 *
 * That declaration is the only thing in tcc's whole front end micro-c could
 * not parse, and it is why mc-tcc has a 175-line hand-written driver instead
 * of tcc.c.
 *
 * EXACTLY member->size BYTES, NEVER A NUL BY ASSUMPTION. ar_fmag is two bytes
 * initialised from a two-character string, which C allows precisely because
 * the terminator is dropped when it does not fit. Emitting the string and
 * letting M1 append its own NUL would make the struct one byte too long and
 * every field after it wrong. Short strings pad with zeroes; long ones
 * truncate, which is what C says.
 *
 * ESCAPES ARE DECODED HERE. ARFMAG is a backtick and a newline -- three
 * characters of source, two bytes of data. Emitting the source text would put
 * a backslash and an 'n' in the archive header. escape_lookup and
 * amount_of_escaped_chars_to_skip are the same pair the string collector uses,
 * so there is one answer to "what byte is this" rather than a second copy of
 * the rule -- the class of bug this file has paid for nine times. */
void global_member_string_output(struct type* member)
{
	char* p = global_token->s + 1;   /* past the opening quote */
	int written = 0;
	int ch;

	while(0 != p[0])
	{
		if(written >= member->size) break;
		ch = escape_lookup(p);
		if('\\' == p[0])
		{
			p = p + amount_of_escaped_chars_to_skip(p);
		}
		p = p + 1;
		global_value_output(ch, 1);
		written = written + 1;
	}

	while(written < member->size)
	{
		global_value_output(0, 1);
		written = written + 1;
	}

	require_extra_token();
}

void global_struct_initializer_list(struct type* type_size)
{
	require_match("Struct assignment initialization is invalid for globals.", "{");
	require(NULL != global_token, "EOF in global struct initialization");

	struct type* member = type_size->members;

	/* A GLOBAL STRUCT INITIALISER MUST BE AS WIDE AS THE STRUCT.
	 *
	 * This emitted the members back to back and stopped. Nothing put the
	 * PADDING in -- neither the gaps between members nor the tail that takes
	 * the struct up to its alignment -- so the bytes written were the sum of
	 * the member sizes while every access used the struct's SIZE as its
	 * stride. For one struct that is invisible. For an ARRAY of them the two
	 * disagree by the padding on every element and the drift compounds:
	 *
	 *     struct TCCOption { const char *name; uint16_t index, flags; };
	 *
	 *     emitted   &str %0 $1 $0        8 + 2 + 2 = 12 bytes
	 *     accessed  stride 16, index at 8, flags at 10
	 *
	 * tcc's option table is exactly that. `-B.` made tcc_parse_args walk to
	 * the second entry, read its `name` four bytes early -- 0x100000000, the
	 * tail of entry 0 spliced to the head of entry 1 -- and dereference it.
	 * A single `-B` flag segfaulted a one-line program.
	 *
	 * The cursor pads to each member's own offset rather than assuming the
	 * members are contiguous, because `struct { char c; int i; }` has a gap
	 * before `i` and that gap is the same bug in miniature. */
	int cursor = 0;

	do
	{
		if(member == NULL)
		{
			line_error();
			fputs("Global struct initializer list has too many values.\n", stderr);
			exit(EXIT_FAILURE);
		}

		while(cursor < member->offset)
		{
			global_value_output(0, 1);
			cursor = cursor + 1;
		}

		/* An ARRAY member initialised by a STRING is laid out inline; every
		 * other member goes through the ordinary value path. */
		if(member->is_array && ('"' == global_token->s[0]))
		{
			global_member_string_output(member);
		}
		else
		{
			global_value_selection(member->type);
		}
		cursor = member->offset + member->size;

		member = member->members;

		if(global_token->s[0] == ',')
		{
			require_extra_token();
		}
	}
	while(global_token->s[0] != '}');

	while(member != NULL)
	{
		while(cursor < member->offset)
		{
			global_value_output(0, 1);
			cursor = cursor + 1;
		}
		global_value_output(0, member->size);
		cursor = member->offset + member->size;
		member = member->members;
	}

	/* THE TAIL. sizeof is what the accessor strides by. */
	while(cursor < type_size->size)
	{
		global_value_output(0, 1);
		cursor = cursor + 1;
	}

	globals_list = emit("\n", globals_list);

	require_match("Struct assignment initialization is invalid for globals.", "}");
	require(NULL != global_token, "EOF in global struct initialization");
}

int global_array_initializer_list(struct type* type_size, int array_modifier)
{
	int amount_of_elements = 0;

	do
	{
		if(amount_of_elements >= array_modifier && array_modifier != 0)
		{
			line_error();
			fputs("Too many elements in initializer list.", stderr);
			exit(EXIT_FAILURE);
		}

		/* A STRING ELEMENT IN A 2D CHAR ARRAY INITIALISER:
		 *     static char const ab_month_name[12][4] =
		 *         { "Jan", "Feb", ... };                    tccpp.c:3428
		 * Each element occupies a whole ROW, so the bytes are emitted and then
		 * padded out to the row width. Without the padding the rows would run
		 * together and every index past the first would be wrong -- silently,
		 * since the total size would still look right. */
		if(0 != global_second_dimension && '"' == global_token->s[0])
		{
			int written = 0;
			int j = 1;   /* past the leading quote */
			while(0 != global_token->s[j])
			{
				global_value_output(global_token->s[j], 1);
				written = written + 1;
				j = j + 1;
			}
			require_extra_token();
			/* NUL terminator plus padding to the row width. */
			while(written < global_second_dimension)
			{
				global_value_output(0, 1);
				written = written + 1;
			}
			if(written > global_second_dimension)
			{
				line_error();
				fputs("String initialiser longer than the array row\n", stderr);
				exit(EXIT_FAILURE);
			}
			amount_of_elements = amount_of_elements + global_second_dimension;

			if(global_token->s[0] == ',')
			{
				require_extra_token();
			}
			continue;
		}

		global_value_selection(type_size);

		amount_of_elements = amount_of_elements + 1;

		if(global_token->s[0] == ',')
		{
			require_extra_token();
		}
	}
	while (global_token->s[0] != '}');

	require_extra_token();

	if(array_modifier == 0)
	{
		if(amount_of_elements == 0)
		{
			line_error();
			fputs("Array with initializer list can not have size zero.\n", stderr);
			exit(EXIT_FAILURE);
		}

		array_modifier = amount_of_elements;
	}

	int size;
	while(amount_of_elements < array_modifier)
	{
		size = type_size->size;
		if(size == 1 || size == 4 || size == 8)
		{
			global_value_output(0, size);
		}
		else
		{
			while(size > 0)
			{
				if(size >= 4)
				{
					global_value_output(0, 4);
					size = size - 4;
				}
				else
				{
					global_value_output(0, 1);
					size = size - 1;
				}
			}
			globals_list = emit("\n", globals_list);
		}

		amount_of_elements = amount_of_elements + 1;
	}


	return array_modifier;
}

int global_static_array(struct type* type_size, char* name)
{
	/* AN `extern` DECLARATION EMITS NOTHING. The symbol is already registered
	 * by the caller, so references resolve to `&GLOBAL_<name>` -- which the
	 * unit that DEFINES it supplies. Emitting storage here is what produced
	 * two objects with one name; see the comment in cc_types.c. */
	if(extern_declaration)
	{
		extern_declaration = FALSE;
		/* consume to the end of the declaration without emitting */
		while(NULL != global_token)
		{
			if(global_token->s[0] == ';') break;
			if(global_token->s[0] == ',') break;
			require_extra_token();
		}
		return 0;
	}

	global_variable_header(name);

	if(global_token->s[0] == ';' || global_token->s[0] == ',')
	{
		global_variable_zero_initialize(type_size->size);
		return 0;
	}
	else if(global_token->s[0] == '=')
	{
		require_extra_token();

		global_value_selection(type_size);

		global_pad_to_register_size(type_size->size);
		return 0;
	}

	maybe_bootstrap_error("global array definitions");

	globals_list = emit("&GLOBAL_STORAGE_", globals_list);
	globals_list = emit(name, globals_list);
	if (AARCH64 == Architecture || AMD64 == Architecture || RISCV64 == Architecture)
	{
		globals_list = emit(" %0", globals_list);
	}
	globals_list = emit("\n:GLOBAL_STORAGE_", globals_list);
	globals_list = emit(name, globals_list);
	globals_list = emit("\n", globals_list);

	require_extra_token();

	int array_modifier = 0;
	int size = 0;
	if(global_token->s[0] != ']')
	{
		array_modifier = constant_expression();
		/* Make sure not negative */
		if(array_modifier < 0)
		{
			line_error();
			fputs("Negative values are not supported for allocated arrays\n", stderr);
			exit(EXIT_FAILURE);
		}

		/* length */
		size = array_modifier * type_size->size;

		if(size == 0)
		{
			line_error();
			fputs("Arrays with size of zero are not allowed.\n", stderr);
			exit(EXIT_FAILURE);
		}

		/* Stop bad states */
		if((size < 0) || (size > 0x100000))
		{
			line_error();
			fputs("M2-Planet is very inefficient so you probably don't want to allocate over 1MB into your binary for NULLs\n", stderr);
			exit(EXIT_FAILURE);
		}
	}

	/* Ensure properly closed */
	require_match("missing close bracket\n", "]");
	require(NULL != global_token, "Unterminated global array declaration\n");

	/* A SECOND DIMENSION on a global or static array. Same two-level row type
	 * the local path builds; here it only has to scale the STORAGE, since the
	 * declared type is already recorded on the variable and indexing reads it
	 * from there.
	 *     static char const ab_month_name[12][4] = {"Jan", ...}   tccpp.c:3428 */
	if(match("[", global_token->s))
	{
		require_extra_token();
		int inner2 = constant_expression();
		if(inner2 < 1)
		{
			line_error();
			fputs("Second array dimension must be at least 1\n", stderr);
			exit(EXIT_FAILURE);
		}
		require_match("missing close bracket after second dimension\n", "]");
		array_modifier = array_modifier * inner2;
		global_second_dimension = inner2;
		/* `size` was computed from the FIRST dimension alone, a dozen lines
		 * above, so it has to be recomputed here or the storage comes out at
		 * 12 chars instead of 48. */
		size = array_modifier * type_size->size;
	}
	else
	{
		global_second_dimension = 0;
	}

	if(global_token->s[0] == '=')
	{
		require_extra_token();

		/* A GLOBAL CHAR ARRAY MAY BE INITIALISED WITH A STRING.
		 *     static const char help[] = "usage: ...";          tcc.c:32
		 *     static const char tcc_keywords[] =                tccpp.c:64
		 *         #define DEF(id,str) str "\0"
		 *         #include "tcctok.h"
		 *     ;
		 * The second is 433 lines of adjacent literals produced by macro
		 * expansion, which is why this could not be reached until the
		 * preprocessor work landed.
		 *
		 * Adjacent literals concatenate, so the loop mirrors what
		 * primary_expr_string already does. The bytes go out under the
		 * GLOBAL's own label -- unlike a string EXPRESSION, which gets its own
		 * STRING_ label and is referenced by address. */
		if(global_token->s[0] == '"')
		{
			char* acc = calloc(MAX_STRING, sizeof(char));
			require(NULL != acc, "Exhausted memory on global string initialiser\n");
			int ai = 0;
			acc[ai] = '"';
			ai = ai + 1;
			while('"' == global_token->s[0])
			{
				int j = 1;   /* step past this literal's leading quote */
				while(0 != global_token->s[j])
				{
					require(ai < MAX_STRING, "global string initialiser exceeded MAX_STRING\n");
					acc[ai] = global_token->s[j];
					ai = ai + 1;
					j = j + 1;
				}
				require_extra_token();
			}
			acc[ai] = 0;
			globals_list = emit(parse_string(acc), globals_list);
			/* PAD TO REGISTER SIZE. A string initialiser writes an arbitrary
			 * number of bytes and whatever comes next starts immediately after.
			 * When that next thing is CODE, the function lands on an address
			 * that is not a multiple of four, and on aarch64 every call to it
			 * is SIGBUS -- which is how a binary that ran fine at 248 bytes
			 * died at 14,478.
			 *
			 * Every other global path already pads; the string paths added
			 * later did not. M1 writes the characters plus a NUL, which is
			 * exactly `ai` bytes: one leading quote in acc, replaced by the
			 * terminator M1 appends. */
			global_pad_to_register_size(ai);
			/* AN ARRAY SIZED BY ITS INITIALISER MUST STILL SAY IT IS AN ARRAY.
			 *
			 * `char x[8] = "hi"` keeps its declared 8. `char x[] = "hi"` had
			 * nothing declared, so this returned 0 -- and 0 is what a plain
			 * scalar records too, leaving the symbol unable to say which it
			 * is. Every site that asks `array_modifier` to separate an array
			 * from a scalar therefore got the wrong answer for exactly the
			 * form C sizes from the initialiser.
			 *
			 * The length is already known: ai is the byte count this branch
			 * just padded from, one leading quote in acc standing in for the
			 * terminator M1 appends. That is the C size of the array. */
			if(0 == array_modifier)
			{
				array_modifier = ai / type_size->size;
				if(array_modifier < 1) array_modifier = 1;
			}
			/* The caller consumes the ';'. */
			return array_modifier;
		}

		require_match("Missing { after = in global array", "{");

		array_modifier = global_array_initializer_list(type_size, array_modifier);

		global_pad_to_register_size(array_modifier * type_size->size);
	}
	else
	{
		if(size == 0)
		{
			line_error();
			fputs("Array without size must have initializer list.", stderr);
			exit(EXIT_FAILURE);
		}

		global_variable_zero_initialize(size);
	}

	return array_modifier;
}

void declare_global_variable(struct type* type_size, struct token_list* variable)
{
	variable->array_modifier = global_static_array(type_size, variable->s);
}

/*
 * program:
 *     declaration
 *     declaration program
 *
 * declaration:
 *     CONSTANT identifer value
 *     typedef identifer type;
 *     type-name identifier ;
 *     type-name identifier = value ;
 *     type-name identifier [ value ];
 *     type-name identifier ( parameter-list ) ;
 *     type-name identifier ( parameter-list ) statement
 *
 * parameter-list:
 *     parameter-declaration
 *     parameter-list, parameter-declaration
 *
 * parameter-declaration:
 *     type-name identifier-opt
 */
void program(void)
{
	function = NULL;
	Address_of = FALSE;
	struct type* type_size;
	char* name;
	struct type* base_type;
	struct type* current_type;

new_type:
	/* Deal with garbage input */
	if (NULL == global_token) return;
	require('#' != global_token->s[0], "unhandled macro directive\n");
	require(!match("\n", global_token->s), "unexpected newline token\n");

	/* Handle c typedef statements */
	if(match("typedef", global_token->s))
	{
		type_size = global_typedef();
		goto new_type;
	}

	/* declaration-specifiers can come in any order */
	while(match("inline", global_token->s)
			|| match("static", global_token->s)
			|| match("_Noreturn", global_token->s))
	{
		require_extra_token();
	}

	type_size = type_name();
	/* Deal with case of struct definitions */
	if(global_token->s[0] == ';')
	{
		global_token = global_token->next;
		goto new_type;
	}

	require(NULL != global_token->next, "Unterminated global\n");

	if(global_token->s[0] == '('
				|| global_token->next->s[0] == ','
				|| global_token->next->s[0] == ';'
				|| global_token->next->s[0] == '='
				|| global_token->next->s[0] == '[')
	{
		/* Declarations do not have the same pointer level so we'll need to find the actual type */
		base_type = type_size->type->type;
		current_type = type_size;

		do
		{
			if(global_token->s[0] == '(')
			{
				name = parse_function_pointer();
				current_type = function_pointer;
			}
			else
			{
				name = global_token->s;
				require_extra_token();
			}

			global_symbol_list = sym_declare(name, current_type, global_symbol_list, TLO_GLOBAL);
			declare_global_variable(current_type, global_symbol_list);

			if(global_token->s[0] == ',')
			{
				require_extra_token();

				current_type = base_type;
				while(global_token->s[0] == '*')
				{
					current_type = current_type->indirect;

					require_extra_token();
				}
			}
		}
		while(global_token->s[0] != ';');

		require_match("Expected ; after global declarations", ";");

		goto new_type;
	}

	require_extra_token();

	/* Deal with global functions */
	if(match("(", global_token->s))
	{
		declare_function(type_size);
		goto new_type;
	}

	/* Everything else is just an error */
	line_error();
	fputs("Received ", stderr);
	fputs(global_token->s, stderr);
	fputs(" in program\n", stderr);
	exit(EXIT_FAILURE);
}

void recursive_output(struct token_list* head, FILE* out)
{
	struct token_list* i = reverse_list(head);
	while(NULL != i)
	{
		write_to_out_buffer(i->s, out);
		i = i->next;
	}
}

void output_tokens(struct token_list *i, FILE* out)
{
	while(NULL != i)
	{
		write_to_out_buffer(i->s, out);
		write_to_out_buffer(" ", out);
		i = i->next;
	}
}
