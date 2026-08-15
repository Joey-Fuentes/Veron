/* Copyright (C) 2021 Sanne Wouda
 * Copyright (C) 2021 Andrius Štikonas <andrius@stikonas.eu>
 * Copyright (C) 2022 Jan (janneke) Nieuwenhuizen <janneke@gnu.org>
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
#include "gcc_req.h"

void require(int bool, char* error);
int strtoint(char* a);
void line_error_token(struct token_list* list);
struct token_list* eat_token(struct token_list* head);
int copy_string(char* target, char* source, int max);
struct token_list* read_all_tokens(FILE* a, struct token_list* current, char* filename);
struct token_list* reverse_list(struct token_list* head);

struct conditional_inclusion
{
	struct conditional_inclusion* prev;
	int previous_condition_matched; /* 1 == all subsequent conditions treated as FALSE */
};

struct macro_argument
{
	char* name;
	struct macro_argument* next;
};

struct macro_list
{
	struct macro_list* next;
	char* symbol;
	struct token_list* expansion;
	struct macro_argument* arguments;
};

struct macro_list* macro_env;
struct conditional_inclusion* conditional_inclusion_top;

void push_conditional_inclusion(int include)
{
	struct conditional_inclusion* t = calloc(1, sizeof(struct conditional_inclusion));

	t->prev = conditional_inclusion_top;
	conditional_inclusion_top = t;

	t->previous_condition_matched = include;
}

void pop_conditional_inclusion(void)
{
	struct conditional_inclusion* t = conditional_inclusion_top;
	conditional_inclusion_top = conditional_inclusion_top->prev;
	free(t);
}


/* point where we are currently modifying the global_token list */
struct token_list* macro_token;

void init_macro_env(char* sym, char* value, char* source, int num)
{
	struct macro_list* hold = macro_env;
	macro_env = calloc(1, sizeof(struct macro_list));
	macro_env->symbol = sym;
	macro_env->next = hold;
	macro_env->expansion = calloc(1, sizeof(struct token_list));
	macro_env->expansion->s = value;
	macro_env->expansion->filename = source;
	macro_env->expansion->linenumber = num;
	macro_env->arguments = NULL;
}

void eat_current_token(void)
{
	int update_global_token = FALSE;
	if (macro_token == global_token)
		update_global_token = TRUE;

	macro_token = eat_token(macro_token);

	if(update_global_token)
		global_token = macro_token;
}

void eat_newline_tokens(void)
{
	macro_token = global_token;

	while(TRUE)
	{
		if(NULL == macro_token) return;

		if(match("\n", macro_token->s))
		{
			eat_current_token();
		}
		else
		{
			macro_token = macro_token->next;
		}
	}
}

/* returns the first token inserted; inserts *before* point */
struct token_list* insert_tokens(struct token_list* point, struct token_list* token, char* at_file, int at_line)
{
	struct token_list* copy;
	struct token_list* first = NULL;

	while (NULL != token)
	{
		copy = calloc(1, sizeof(struct token_list));
		copy->s = token->s;

		/* AN EXPANDED TOKEN IS AT THE INVOCATION, NOT AT THE #define.
		 *
		 * These copies carried the position of the token they were copied
		 * FROM -- a token in the macro's replacement list, whose line is the
		 * line of the `#define`. So __LINE__ inside a macro body expanded to
		 * the line the macro was DEFINED on, the same number at every call
		 * site:
		 *
		 *     #define tcc_free(ptr)  tcc_free_at(ptr, __LINE__)   tcc.h:1229
		 *
		 * Every tcc_free in the program reported 1229. tcc uses __LINE__ in
		 * tcc_error, in MEM_DEBUG and in tcc_strdup_debug(str, __FILE__,
		 * __LINE__), so every line number tcc printed was the line of a macro
		 * definition in a header.
		 *
		 * The position is passed in rather than read from `point`. For a
		 * FUNCTION-LIKE macro the caller's token pointer has already advanced
		 * past the argument list by the time the splice happens -- it can sit
		 * on the next line entirely -- so `point` is not the invocation. The
		 * first attempt at this fix used point->linenumber and reported 8 for
		 * a call on line 7. Captured at entry to maybe_expand instead, before
		 * anything is consumed. This fixes __FILE__ the same way and makes an
		 * error inside an expansion point at the call rather than the
		 * header. */
		copy->filename = at_file;
		copy->linenumber = at_line;
		/* AND HERE TOO. This is the SECOND field-by-field token copy in this
		 * file, and it is the one on the path that actually matters: the paint
		 * was being applied, carried through copy_token, and then dropped
		 * again right here. Two copies enumerating fields independently is why
		 * adding one field took three attempts to land. */
		copy->no_expand = token->no_expand;

		if(NULL == first)
		{
			first = copy;
		}

		copy->next = point;

		if (NULL != point)
		{
			copy->prev = point->prev;

			if(NULL != point->prev)
			{
				point->prev->next = copy;
			}

			point->prev = copy;
		}

		token = token->next;
	}

	return first;
}

struct macro_list* create_replacement_token(char* symbol, struct token_list* token)
{
	struct macro_list* hold = calloc(1, sizeof(struct macro_list));

	hold->next = NULL;
	hold->symbol = symbol;
	hold->expansion = calloc(1, sizeof(struct token_list));

	hold->expansion->prev = NULL;
	hold->expansion->next = NULL;
	hold->expansion->linenumber = token->linenumber;

	/* Make sure this is cleaned up along with the real ones */
	hold->next = macro_env;
	macro_env = hold;

	return hold;
}

struct macro_list* lookup_macro(struct token_list* token)
{
	if(NULL == token)
	{
		line_error_token(macro_token);
		fputs("null token received in lookup_macro\n", stderr);
		exit(EXIT_FAILURE);
	}

	if(match(token->s, "__LINE__"))
	{
		struct macro_list* hold = create_replacement_token("__LINE__", token);

		hold->expansion->s = int2str(token->linenumber, 10, TRUE);

		return hold;
	}
	else if(match(token->s, "__FILE__"))
	{
		struct macro_list* hold = create_replacement_token("__FILE__", token);

		hold->expansion->s = concat_strings2("\"", token->filename);

		return hold;
	}

	struct macro_list* hold = macro_env;

	while (NULL != hold)
	{
		if (match(token->s, hold->symbol))
		{
			/* found! */
			return hold;
		}

		hold = hold->next;
	}

	/* not found! */
	return NULL;
}

void remove_macro(struct token_list* token)
{
	if(NULL == token)
	{
		line_error_token(macro_token);
		fputs("received a null in remove_macro\n", stderr);
		exit(EXIT_FAILURE);
	}

	/* #undef MUST REMOVE EVERY DEFINITION, not just the first.
	 *
	 * A #define does not replace an existing entry -- it PREPENDS a new one --
	 * so a macro re-defined N times has N entries and lookup finds the newest.
	 * Returning after the first removal left the older ones live, and the
	 * symbol stayed defined.
	 *
	 * tcc hits this because every .c file re-includes tcc.h, whose tail does
	 *     #define _tcc_error use_tcc_error_noabort     (the poison)
	 * for files that do NOT set USING_GLOBALS, and
	 *     #undef _tcc_error
	 * for those that do. By the time arm64-gen.c sets USING_GLOBALS there are
	 * several poison entries, and one #undef could not clear them:
	 *     arm64-gen.c:252 use_tcc_error_noabort is not a defined symbol */
	struct macro_list* hold = macro_env;
	struct macro_list* temp;

	/* Leading matches */
	while (NULL != macro_env)
	{
		if (!match(token->s, macro_env->symbol)) break;
		temp = macro_env;
		macro_env = macro_env->next;
		free(temp);
	}

	if (NULL == macro_env) return;

	/* Matches further in */
	hold = macro_env;
	while (NULL != hold->next)
	{
		if (match(token->s, hold->next->symbol))
		{
			temp = hold->next;
			hold->next = hold->next->next;
			free(temp);
		}
		else
		{
			hold = hold->next;
		}
	}

	return;
}

int macro_expression(void);
/* A MACRO IN AN #if EXPANDS UNTIL IT IS A NUMBER, NOT ONCE.
 *
 * This read the expansion token and handed it straight to strtoint, so a macro
 * whose body is ANOTHER MACRO NAME evaluated to zero:
 *
 *     #define SHT_RELA 4
 *     #define SHT_RELX SHT_RELA
 *     #if SHT_RELX == SHT_RELA        -- FALSE, because strtoint("SHT_RELA")
 *
 * One level worked, which is why this survived: `SHT_RELA == 4` was always
 * right, and `SHT_RELY == SHT_RELX` compared two unexpanded names and matched
 * by accident.
 *
 * WHAT IT COST. tcc.h has exactly that pair, and tccelf.c guards the addend
 * store with it:
 *
 *     #if SHT_RELX == SHT_RELA
 *         rel->r_addend = addend;
 *     #endif
 *
 * So mc-tcc compiled OUT the line that writes a relocation's addend. Every
 * static initialiser of the form `pointer = array + N` lost its offset --
 *
 *     static const int32_t *const ptable = table + 128;
 *     control:  R_AARCH64_ABS64  table + 200
 *     mc-tcc:   R_AARCH64_ABS64  table + 0
 *
 * -- and pointed at element 0 instead. The runtime guard on the next line,
 * `if (SHT_RELX != SHT_RELA && addend) tcc_error_noabort(...)`, never fired,
 * because the COMPILER agreed they were equal; only the preprocessor did not.
 *
 * BOUNDED, because a macro may name itself. M2-Planet's blue paint covers
 * expansion in the body of the program; this is a separate evaluator with its
 * own walk, so it carries its own limit rather than borrowing that one. */
int macro_variable(void)
{
	int value = 0;
	struct macro_list* hold = lookup_macro(macro_token);
	int depth = 0;
	while (NULL != hold)
	{
		if(NULL == hold->expansion)
		{
			line_error_token(macro_token);
			fputs("hold->expansion is a null\n", stderr);
			exit(EXIT_FAILURE);
		}

		/* Only an IDENTIFIER can expand further; lookup_macro returns NULL
		 * for a number, which ends the walk on the common case. */
		struct macro_list* next = lookup_macro(hold->expansion);
		if(NULL == next) break;
		if(next == hold) break;
		depth = depth + 1;
		if(depth > 64) break;
		hold = next;
	}

	if (NULL != hold)
	{
		value = strtoint(hold->expansion->s);
	}
	eat_current_token();
	return value;
}

int macro_number(void)
{
	int result = strtoint(macro_token->s);
	eat_current_token();
	return result;
}

int macro_primary_expr(void)
{
	int defined_has_paren = FALSE;
	int hold;
	require(NULL != macro_token, "got an EOF terminated macro primary expression\n");

	if('-' == macro_token->s[0])
	{
		eat_current_token();
		return -macro_primary_expr();
	}
	else if('!' == macro_token->s[0])
	{
		eat_current_token();
		return !macro_primary_expr();
	}
	else if('(' == macro_token->s[0])
	{
		eat_current_token();
		hold = macro_expression();
		require(')' == macro_token->s[0], "missing ) in macro expression\n");
		eat_current_token();
		return hold;
	}
	else if(match("defined", macro_token->s))
	{
		eat_current_token();

		require(NULL != macro_token, "got an EOF terminated macro defined expression\n");

		if('(' == macro_token->s[0])
		{
			defined_has_paren = TRUE;
			eat_current_token();
		}

		if (NULL != lookup_macro(macro_token))
		{
			hold = TRUE;
		}
		else
		{
			hold = FALSE;
		}
		eat_current_token();

		if(TRUE == defined_has_paren)
		{
			if(NULL == macro_token)
			{
				line_error_token(macro_token);
				fputs("unterminated define ( statement\n", stderr);
				exit(EXIT_FAILURE);
			}
			require(')' == macro_token->s[0], "missing close parenthesis for defined()\n");
			eat_current_token();
		}

		return hold;
	}
	else if(in_set(macro_token->s[0], "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"))
	{
		return macro_variable();
	}
	else if(in_set(macro_token->s[0], "0123456789"))
	{
		return macro_number();
	}
	else
	{
		return 0;    /* FIXME: error handling */
	}
}

int macro_additive_expr(void)
{
	int lhs = macro_primary_expr();
	int hold;

	require(NULL != macro_token, "got an EOF terminated macro additive expression\n");
	if(match("+", macro_token->s))
	{
		eat_current_token();
		return lhs + macro_additive_expr();
	}
	else if(match("-", macro_token->s))
	{
		eat_current_token();
		return lhs - macro_additive_expr();
	}
	else if(match("*", macro_token->s))
	{
		eat_current_token();
		return lhs * macro_additive_expr();
	}
	else if(match("/", macro_token->s))
	{
		eat_current_token();
		hold = macro_additive_expr();
		require(0 != hold, "divide by zero not valid even in C macros\n");
		return lhs / hold;
	}
	else if(match("%", macro_token->s))
	{
		eat_current_token();
		hold = macro_additive_expr();
		require(0 != hold, "modulus by zero not valid even in C macros\n");
		return lhs % hold;
	}
	else if(match(">>", macro_token->s))
	{
		eat_current_token();
		return lhs >> macro_additive_expr();
	}
	else if(match("<<", macro_token->s))
	{
		eat_current_token();
		return lhs << macro_additive_expr();
	}
	else
	{
		return lhs;
	}
}

int macro_relational_expr(void)
{
	int lhs = macro_additive_expr();

	if(match("<", macro_token->s))
	{
		eat_current_token();
		return lhs < macro_relational_expr();
	}
	else if(match("<=", macro_token->s))
	{
		eat_current_token();
		return lhs <= macro_relational_expr();
	}
	else if(match(">=", macro_token->s))
	{
		eat_current_token();
		return lhs >= macro_relational_expr();
	}
	else if(match(">", macro_token->s))
	{
		eat_current_token();
		return lhs > macro_relational_expr();
	}
	else if(match("==", macro_token->s))
	{
		eat_current_token();
		return lhs == macro_relational_expr();
	}
	else if(match("!=", macro_token->s))
	{
		eat_current_token();
		return lhs != macro_relational_expr();
	}
	else
	{
		return lhs;
	}
}

int macro_bitwise_expr(void)
{
	int rhs;
	int lhs = macro_relational_expr();

	if(match("&", macro_token->s))
	{
		eat_current_token();
		return lhs & macro_bitwise_expr();
	}
	else if(match("&&", macro_token->s))
	{
		eat_current_token();
		rhs = macro_bitwise_expr();
		return lhs && rhs;
	}
	else if(match("|", macro_token->s))
	{
		eat_current_token();
		rhs = macro_bitwise_expr();
		return lhs | rhs;
	}
	else if(match("||", macro_token->s))
	{
		eat_current_token();
		rhs = macro_bitwise_expr();
		return lhs || rhs;
	}
	else if(match("^", macro_token->s))
	{
		eat_current_token();
		rhs = macro_bitwise_expr();
		return lhs ^ rhs;
	}
	else
	{
		return lhs;
	}
}

int macro_expression(void)
{
	return macro_bitwise_expr();
}

void handle_function_like_macro(struct macro_list* hold)
{

	eat_current_token(); /* Skip '(' */
	struct macro_argument* argument = calloc(1, sizeof(struct macro_argument));
	hold->arguments = argument;

	argument->next = NULL;
	/* A NULL name in the first argument means a function macro without any arguments */
	argument->name = NULL;

	while(macro_token->s[0] != ')')
	{
		/* ... is not tokenized as a single token here */
		if(macro_token->s[0] == '.')
		{
			/* Periods can only be in the macro argument list as a variadic parameter
			 * so if there is a period it's part of a variadic parameter */
			require(macro_token->next != NULL, "EOF in variadic parameter");
			require(macro_token->next->s[0] == '.', "Invalid token '.' in macro parameter list");
			require(macro_token->next->next != NULL, "EOF in second variadic parameter");
			require(macro_token->next->next->s[0] == '.', "Invalid tokens '..' in macro parameter list");

			line_error_token(macro_token);
			fputs("Variadic function-like macros not supported.", stderr);
			exit(EXIT_FAILURE);
		}

		argument->name = macro_token->s;
		eat_current_token(); /* skip past name to comma */

		if(macro_token->s[0] == ',')
		{
			argument->next = calloc(1, sizeof(struct macro_argument));
			argument = argument->next;

			eat_current_token(); /* skip comma */
		}
	}

	eat_current_token(); /* skip past ')' */
}

void handle_define(void)
{
	struct macro_list* hold;
	struct token_list* expansion_end = NULL;

	eat_current_token();

	require(NULL != macro_token, "got an EOF terminated #define\n");
	require('\n' != macro_token->s[0], "unexpected newline after #define\n");

	/* insert new macro */
	hold = calloc(1, sizeof(struct macro_list));
	hold->symbol = macro_token->s;
	hold->next = macro_env;
	hold->arguments = NULL;
	macro_env = hold;

	/* discard the macro name */
	eat_current_token();

	/* This is the only place in which a token can be whitespace
	 * We need this to distinguish between function-like macros
	 * and normal macros with an opening parens as the first token.
	 * #define FUNCTION_MACRO(x)
	 * #define NOT_FUNCTION_MACRO (x)
	 * */
	if(macro_token->s[0] == ' ')
	{
		eat_current_token();
	}
	else if(macro_token->s[0] == '(')
	{
		handle_function_like_macro(hold);
	}

	if (macro_token->s[0] == '\n')
	{
		/* hold->expansion is NULL for macros without expansion */
		return;
	}

	hold->expansion = macro_token;

	while (macro_token->s[0] != '\n')
	{
		expansion_end = macro_token;
		eat_current_token();
	}

	hold->expansion->prev = NULL;
	expansion_end->next = NULL;

	/* Fix up the prev members of the expansion.
	 * Otherwise, they are set to the prev of the very first token. */
	expansion_end = hold->expansion;
	while (expansion_end->next != NULL)
	{
		expansion_end->next->prev = expansion_end;
		expansion_end = expansion_end->next;
	}
}

void handle_undef(void)
{
	eat_current_token();
	remove_macro(macro_token);
	eat_current_token();
}

void handle_error(int warning_p)
{
	eat_current_token();
	line_error_token(macro_token);
	if(warning_p) fputs(" warning: #warning ", stderr);
	else fputs(" error: #error ", stderr);
	while (TRUE)
	{
		require(NULL != macro_token, "\nFailed to properly terminate error message with \\n\n");
		if ('\n' == macro_token->s[0]) break;
		fputs(macro_token->s, stderr);
		macro_token = macro_token->next;
		fputs(" ", stderr);
	}
	fputs("\n", stderr);
	if(!warning_p) exit(EXIT_FAILURE);

	while (TRUE)
	{
		require(NULL != macro_token, "\nFailed to properly terminate error message with \\n\n");
		/* discard the error */
		if ('\n' == macro_token->s[0])
		{
			return;
		}
		eat_current_token();
	}
}

void handle_include(void)
{
	eat_current_token();
	char* buffer = calloc(MAX_STRING, sizeof(char));
	FILE* f = NULL;

	char* include_filename = macro_token->s + 1;

	/* The only difference between " and < includes is that " looks in the directory of the current file. */
	if(macro_token->s[0] == '"')
	{
		int offset = copy_string(buffer, macro_token->filename, MAX_STRING);
		while(buffer[offset] != '/' && offset != 0)
		{
			offset = offset - 1;
		}

		/* We could have no / in filename in which case we just start from 0 */
		if(buffer[offset] == '/')
		{
			offset = offset + 1;
		}

		offset = offset + copy_string(buffer + offset, include_filename, MAX_STRING - offset);
		buffer[offset] = 0;

		f = fopen(buffer, "r");
	}
	else
	{
		/* < includes are not tokenized as a single token, but as a list of tokens in between < and > */
		include_filename = calloc(MAX_STRING, sizeof(char));
		eat_current_token(); /* Skip over '<' */
		int offset = 0;
		while(macro_token->s[0] != '>')
		{
			offset = offset + copy_string(include_filename + offset, macro_token->s, MAX_STRING - offset);
			eat_current_token();
		}
	}

	struct include_path_list* inc = include_paths;
	int offset;
	while(inc != NULL && f == NULL)
	{
		offset = copy_string(buffer, inc->path, MAX_STRING);
		buffer[offset] = '/';
		offset = offset + 1;
		offset = offset + copy_string(buffer + offset, include_filename, MAX_STRING - offset);
		/* TERMINATE IT. copy_string copies and counts; it does not write a NUL.
		 * One buffer is reused for every -I in turn, so without this any path
		 * shorter than a previous attempt inherits that attempt's tail and
		 * fopen is handed garbage. The effect is that only the FIRST -I works:
		 *     -I stubs                  -> found
		 *     -I long/path -I stubs     -> "Unable to find include file"
		 * The quoted-include branch above already terminates; this loop and the
		 * M2libc fallback below did not. */
		buffer[offset] = 0;

		f = fopen(buffer, "r");

		inc = inc->next;
	}

	if(f == NULL)
	{
		/* If all else fails, try to look in M2libc in the CWD */
		offset = copy_string(buffer, "./M2libc/", MAX_STRING);
		offset = offset + copy_string(buffer + offset, include_filename, MAX_STRING - offset);
		buffer[offset] = 0;   /* same reason as above */
		f = fopen(buffer, "r");
	}

	if(f == NULL)
	{
		line_error_token(macro_token);
		fputs("Unable to find include file: ", stderr);
		fputs(include_filename, stderr);
		fputs("\n", stderr);
		exit(EXIT_FAILURE);
	}
	eat_current_token();

	struct token_list* current_macro_token = macro_token;

	struct token_list* new_token_list = read_all_tokens(f, NULL, buffer);
	new_token_list = reverse_list(new_token_list);

	/* AN INCLUDE THAT PRODUCES NO TOKENS IS NOT AN ERROR, AND MUST NOT CRASH.
	 * An empty header -- or one holding nothing but comments -- makes
	 * read_all_tokens return NULL, and the splice below then walks
	 * last_token->next from a null pointer. Two lines of C reproduce it:
	 *     : > empty.h ; printf '#include "empty.h"\nint main(){return 0;}\n'
	 * segfaults. Nothing to splice means nothing to do. */
	if(NULL == new_token_list)
	{
		return;
	}

	struct token_list* last_token = new_token_list;
	while(last_token->next != NULL)
	{
		last_token = last_token->next;
	}

	struct token_list* next_original_token = current_macro_token->next;

	current_macro_token->next = new_token_list;
	new_token_list->prev = current_macro_token;

	last_token->next = next_original_token;
	next_original_token->prev = last_token;

	macro_token = current_macro_token;
}

void eat_block(void);
void macro_directive(void)
{
	int result;

	if(match("#if", macro_token->s))
	{
		eat_current_token();
		/* evaluate constant integer expression */
		result = macro_expression();

		push_conditional_inclusion(result);

		if(FALSE == result)
		{
			eat_block();
		}
	}
	else if(match("#ifdef", macro_token->s))
	{
		eat_current_token();
		require(NULL != macro_token, "got an EOF terminated macro defined expression\n");
		if (NULL != lookup_macro(macro_token))
		{
			result = TRUE;
			eat_current_token();
		}
		else
		{
			result = FALSE;
			eat_block();
		}

		push_conditional_inclusion(result);
	}
	else if(match("#ifndef", macro_token->s))
	{
		eat_current_token();
		require(NULL != macro_token, "got an EOF terminated macro defined expression\n");
		if (NULL != lookup_macro(macro_token))
		{
			result = FALSE;
		}
		else
		{
			result = TRUE;
			eat_current_token();
		}

		push_conditional_inclusion(result);

		if(FALSE == result)
		{
			eat_block();
		}
	}
	else if(match("#elif", macro_token->s))
	{
		require(NULL != macro_token->next, "#elif without leading #if\n");
		eat_current_token();
		result = macro_expression();
		require(NULL != conditional_inclusion_top, "#elif without leading #if\n");

		if(FALSE == result || conditional_inclusion_top->previous_condition_matched)
		{
			eat_block();
		}
		else
		{
			conditional_inclusion_top->previous_condition_matched = TRUE;
		}
	}
	else if(match("#else", macro_token->s))
	{
		require(NULL != macro_token->next, "#else without leading #if\n");
		eat_current_token();
		require(NULL != conditional_inclusion_top, "#else without leading #if\n");

		if(conditional_inclusion_top->previous_condition_matched)
		{
			eat_block();
		}
	}
	else if(match("#endif", macro_token->s))
	{
		if(NULL == conditional_inclusion_top)
		{
			line_error_token(macro_token);
			fputs("unexpected #endif\n", stderr);
			exit(EXIT_FAILURE);
		}

		eat_current_token();

		pop_conditional_inclusion();
	}
	else if(match("#define", macro_token->s))
	{
		handle_define();
	}
	else if(match("#undef", macro_token->s))
	{
		handle_undef();
	}
	else if(match("#error", macro_token->s))
	{
		handle_error(FALSE);
	}
	else if(match("#warning", macro_token->s))
	{
		handle_error(TRUE);
	}
	else
	{
		if(match("#include", macro_token->s))
		{
			if(FOLLOW_INCLUDES)
			{
				handle_include();
			}
		}
		else
		{
			/* Put a big fat warning but see if we can just ignore */
			fputs(">>WARNING<<\n>>WARNING<<\n", stderr);
			line_error_token(macro_token);
			fputs("feature: ", stderr);
			fputs(macro_token->s, stderr);
			fputs(" unsupported in M2-Planet\nIgnoring line, may result in bugs\n>>WARNING<<\n>>WARNING<<\n\n", stderr);
		}

		/* unhandled macro directive; let's eat until a newline; om nom nom */
		while(TRUE)
		{
			if(NULL == macro_token)
			{
				return;
			}

			if('\n' == macro_token->s[0])
			{
				return;
			}

			eat_current_token();
		}
	}
}


void eat_until_endif(void)
{
	/* This #if block is nested inside of an #if block that needs to be dropped, lose EVERYTHING */
	do
	{
		require(NULL != macro_token, "Unterminated #if block\n");
		if(match("#if", macro_token->s) || match("#ifdef", macro_token->s) || match("#ifndef", macro_token->s))
		{
			eat_current_token();
			eat_until_endif();
		}

		eat_current_token();
		require(NULL != macro_token, "Unterminated #if block\n");
	} while(!match("#endif", macro_token->s));
}

void eat_block(void)
{
	/* This conditional #if block is wrong, drop everything until the #elif/#else/#endif */
	do
	{
		if(match("#if", macro_token->s) || match("#ifdef", macro_token->s) || match("#ifndef", macro_token->s))
		{
			eat_current_token();
			eat_until_endif();
		}

		eat_current_token();
		require(NULL != macro_token, "Unterminated #if block\n");
		if(match("#elif", macro_token->s)) break;
		if(match("#else", macro_token->s)) break;
		if(match("#endif", macro_token->s)) break;
	} while(TRUE);

	if(macro_token->prev != NULL)
	{
		/* rewind the newline */
		if(match("\n", macro_token->prev->s)) macro_token = macro_token->prev;
	}
	else
	{
		struct token_list* newline_token = calloc(1, sizeof(struct token_list));
		newline_token->s = "\n";
		newline_token->filename = macro_token->filename;
		newline_token->linenumber = macro_token->linenumber;
		newline_token->next = macro_token;
		macro_token = newline_token;
	}
}

struct token_list* deep_copy_token_list(struct token_list* from)
{
	if(from == NULL)
	{
		return NULL;
	}

	struct token_list* to = calloc(1, sizeof(struct token_list));

	to->next = deep_copy_token_list(from->next);
	if (to->next != NULL)
	{
		/* Ensure the new prev points at this object */
		to->next->prev = to;
	}
	to->locals = from->locals;
	to->prev = from->prev;
	to->s = from->s;
	to->type = from->type;
	to->filename = from->filename;
	to->arguments = from->arguments;
	to->depth = from->depth;
	to->linenumber = from->linenumber;
	/* CARRY THE PAINT. This copy enumerates the fields it moves, so a new one
	 * is silently dropped unless it is added here -- which is exactly what
	 * happened: the paint was applied correctly and then lost on every copy,
	 * so the macro expanded forever anyway. */
	to->no_expand = from->no_expand;

	return to;
}

extern int expand_depth;

struct token_list* maybe_expand(struct token_list* token)
{
	/* CAPTURED BEFORE ANYTHING IS CONSUMED -- see insert_tokens. */
	char* invocation_file;
	int invocation_line;

	if(NULL == token)
	{
		line_error_token(macro_token);
		fputs("maybe_expand passed a null token\n", stderr);
		exit(EXIT_FAILURE);
	}

	/* PAINTED TOKENS ARE NOT MACRO INVOCATIONS. Without this, tcc.h's
	 * thirteen self-referential defines expand forever:
	 *     #define total_bytes TCC_STATE_VAR(total_bytes)
	 * The inner name must stay an identifier. M2-Planet already terminated on
	 * the direct `#define FOO FOO` form, but not when the self-reference sits
	 * inside a function-like macro's argument list, which is the form real
	 * code uses. */
	invocation_file = token->filename;
	invocation_line = token->linenumber;

	if(token->no_expand)
	{
		return token->next;
	}

	struct macro_list* hold = lookup_macro(token);
	if(NULL == token->next)
	{
		line_error_token(macro_token);
		fputs("we can't expand a null token: ", stderr);
		fputs(token->s, stderr);
		fputc('\n', stderr);
		exit(EXIT_FAILURE);
	}

	if (NULL == hold)
	{
		return token->next;
	}

	/* A FUNCTION-LIKE MACRO NAME NOT FOLLOWED BY `(` IS NOT AN INVOCATION.
	 * C says such a name is left as an ordinary identifier -- it is only a
	 * macro call when the next token is an open paren. This used to eat the
	 * name first and then die on the check below, so any bare use of the name
	 * -- passing it somewhere, or reusing the spelling as a declarator -- was
	 * a hard error. tcc trips it at libtcc.c:267. Returning here is the same
	 * thing the `not a macro at all` path above already does. */
	if(NULL != hold->arguments)
	{
		if(token->next->s[0] != '(')
		{
			return token->next;
		}
	}

	token = eat_token(token);

	struct token_list* expansion = hold->expansion;

	if(hold->arguments != NULL)
	{
		if(token->s[0] != '(')
		{
			line_error_token(macro_token);
			fputs("Function-like-macro called without parameter list\n", stderr);
			exit(EXIT_FAILURE);
		}
		token = eat_token(token); /* skip '(' */

		expansion = deep_copy_token_list(hold->expansion);

		struct token_list* token_before_macro = token->prev;

		struct token_list* start_token = token;
		int parens = 1;
		struct macro_argument* argument = hold->arguments;
		struct token_list* expand_list;
		struct token_list* start_token_copy = NULL;
		struct token_list* end_token;
		while (parens != 0)
		{
			if(argument == NULL)
			{
				line_error_token(macro_token);
				fputs("Invalid amount of parameters for function-like macro\n", stderr);
				exit(EXIT_FAILURE);
			}

			if(token->s[0] == '(')
			{
				parens = parens + 1;
			}
			else if (token->s[0] == ')')
			{
				parens = parens - 1;
			}

			if ((token->s[0] == ',' && parens == 1) || (token->s[0] == ')' && parens == 0))
			{
				token->prev->next = NULL;

				expand_list = expansion;

				while(expand_list != NULL)
				{
					/* STRINGIFY, `#x`. The tokenizer already makes `#x` a
					 * single token -- the '#' branch consumes the hash and then
					 * grabs the following alphanumerics -- so this is a name
					 * comparison against "#" + the parameter, not a two-token
					 * pattern.
					 *
					 * tcc uses it 77 times as #x alone, and reaches it first at
					 *     #define DEF_ATOMIC(ID) DEF(TOK_##__##ID, "__"#ID)
					 * where the result is concatenated with an adjacent literal,
					 * which the string handling already does.
					 *
					 * The argument text is joined with single spaces. That is
					 * not what C specifies -- the standard preserves the
					 * original spelling minus leading and trailing whitespace --
					 * but every use in tcc stringifies a single identifier,
					 * where the two agree exactly. Recorded rather than
					 * pretended: a multi-token argument would stringify with
					 * normalised spacing. */
					if('#' == expand_list->s[0] && match(expand_list->s + 1, argument->name))
					{
						char* acc = calloc(MAX_STRING, sizeof(char));
						require(NULL != acc, "Exhausted memory stringifying a macro argument\n");
						int ai = 0;
						acc[ai] = '"';
						ai = ai + 1;
						struct token_list* w = start_token;
						while(NULL != w)
						{
							if(ai > 1)
							{
								acc[ai] = ' ';
								ai = ai + 1;
							}
							int j = 0;
							while(0 != w->s[j])
							{
								require(ai < MAX_STRING, "stringified argument too long\n");
								acc[ai] = w->s[j];
								ai = ai + 1;
								j = j + 1;
							}
							w = w->next;
						}
						/* NO CLOSING QUOTE. A string TOKEN carries only the
						 * leading '"' -- parse_string supplies the terminator
						 * when the bytes are emitted. Adding one here put a
						 * literal 0x22 inside the data, which -E did not show
						 * because it prints raw tokens: the hex dump did.
						 * Compare emitted output, not preprocessed text. */
						acc[ai] = 0;
						expand_list->s = acc;
						expand_list = expand_list->next;
						continue;
					}
					if(match(expand_list->s, argument->name))
					{
						start_token_copy = deep_copy_token_list(start_token);
						end_token = start_token_copy;

						while (end_token->next != NULL)
						{
							end_token = end_token->next;
						}

						if (expand_list->prev != NULL)
						{
							expand_list->prev->next = start_token_copy;
						}
						start_token_copy->prev = expand_list->prev;

						end_token->next = expand_list->next;
						if (expand_list->next != NULL)
						{
							expand_list->next->prev = end_token;
						}
						if (expand_list->prev == NULL)
						{
							/* If we don't have a prev expansion needs to be updated to the new root. */
							expansion = start_token_copy;
						}
						expand_list = end_token;
					}
					expand_list = expand_list->next;
				}

				token->prev->next = token;
				start_token = token->next;
				argument = argument->next;
			}

			require(token->next != NULL, "NULL token found in function-like macro arguments\n");
			token = token->next;
		}

		token_before_macro->next = token;
		token->prev = token_before_macro;
	}
	else
	{
		if(hold->arguments != NULL)
		{
			line_error_token(macro_token);
			fputs("Function-like macro '", stderr);
			fputs(hold->symbol, stderr);
			fputs("' was called like normal macro\n", stderr);
			exit(EXIT_FAILURE);
		}
	}

	if (NULL == hold->expansion)
	{
		/* AN EMPTY MACRO MUST NOT SWALLOW THE NEXT TOKEN. `token` already
		 * points PAST the macro name (eat_token above), so returning
		 * token->next skips whatever followed it:
		 *     #define PUB_FUNC
		 *     #define NORETURN __attribute__((noreturn))
		 *     PUB_FUNC NORETURN void die(char*);
		 * left NORETURN unexpanded, because PUB_FUNC's empty expansion jumped
		 * over it. Consistent with rescanning from the head elsewhere: resume
		 * AT the next token, never past it. */
		return token;
	}

	/* PASTE: fold `X ## Y` into a single token XY, after argument substitution
	 * has run so the operands are the substituted text. Applied to the
	 * expansion list about to be spliced, walking left to right so a chain like
	 * `Elf##64##_##type` folds progressively: Elf64, Elf64_, Elf64_type.
	 *
	 * The result is re-looked-up as an ordinary identifier by the normal
	 * rescan, which is what makes `ElfW(Sym)` reach the parser as Elf64_Sym. */
	struct token_list* pst = expansion;
	while(NULL != pst)
	{
		if(NULL != pst->next)
		{
			if(match("##", pst->next->s))
			{
				struct token_list* op = pst->next;
				if(NULL != op->next)
				{
					pst->s = concat_strings2(pst->s, op->next->s);
					/* unlink the operator and its right operand */
					pst->next = op->next->next;
					if(NULL != pst->next)
					{
						pst->next->prev = pst;
					}
					/* fold again from the same token, for chains */
					continue;
				}
			}
		}
		pst = pst->next;
	}

	/* Paint every occurrence of this macro's own name in what we are about to
	 * splice. For a function-like macro `expansion` is a fresh deep copy, so
	 * this is per-invocation; for an object-like macro it is the stored list,
	 * and painting it once is both correct and idempotent -- an occurrence of
	 * the name inside its own expansion can never be expandable. */
	struct token_list* paint = expansion;
	while(NULL != paint)
	{
		if(match(hold->symbol, paint->s))
		{
			paint->no_expand = TRUE;
		}
		paint = paint->next;
	}

	/* MUTUAL RECURSION IS NOT COVERED BY THE PAINT, AND MUST NOT HANG.
	 *     #define A B
	 *     #define B A
	 * Neither body contains its own name, so nothing gets painted, and
	 * rescanning from the head above makes them expand into each other
	 * forever. C solves this with a per-token HIDE SET -- the set of macros
	 * being expanded when the token was produced -- which is the real fix and
	 * more machinery than a single flag.
	 *
	 * Until that exists, bound it and say so. A diagnostic is recoverable; a
	 * hang in CI is forty minutes and no information. The bound is far above
	 * any legitimate nesting: tcc's deepest real chain is three. */
	expand_depth = expand_depth + 1;
	if(expand_depth > 10000)
	{
		line_error_token(macro_token);
		fputs("macro expansion did not terminate (mutually recursive?) at '", stderr);
		fputs(hold->symbol, stderr);
		fputs("'\n", stderr);
		exit(EXIT_FAILURE);
	}

	struct token_list* hold2 = insert_tokens(token, expansion, invocation_file, invocation_line);

	/* RESCAN FROM THE FIRST INSERTED TOKEN, NOT PAST IT. Returning hold2->next
	 * skipped the head of every expansion, so a macro whose body STARTS with
	 * another macro never expanded it:
	 *     #define addr_t ElfW(Addr)
	 * put [ElfW] [(] [Addr] [)] in the stream and resumed at '(', leaving ElfW
	 * to reach the parser as an identifier -- "Unknown type ElfW", tcc.h:421.
	 *
	 * This is only safe because of the blue paint above: rescanning from the
	 * head is exactly what makes a self-referential macro loop, and the paint
	 * is what stops it. The two changes belong together. */
	return hold2;
}

/* STRIP `__attribute__ ((...))` FROM THE TOKEN STREAM.
 *
 * A GCC extension, used 16 times in the pinned tcc tree -- but almost all of
 * those are inside STRING LITERALS (tccelf.c emitting C source for tcc to
 * compile later) or comments. Exactly one is a real use in code we parse:
 *
 *     libtcc.c:332   ALIGNED(16) unsigned char magic3[4];
 *
 * tcc.h offers no portable branch: #ifdef _MSC_VER gives __declspec instead,
 * which is no better. So ignoring the construct is what any compiler building
 * GCC-flavoured C has to do at minimum.
 *
 * WHAT IGNORING COSTS, STATED: `noreturn` and `format` are hints and cost
 * nothing. `aligned(16)` is NOT a hint -- that member will not be 16-aligned,
 * and if anything depends on it a built tcc would be subtly wrong. One site,
 * recorded here rather than discovered later.
 *
 * A stream pass rather than a parser rule because the construct is legal in
 * many positions -- before a type, after a declarator, on a struct member --
 * and catching them all in the grammar is far more surface than deleting them. */
void strip_attributes(void)
{
	struct token_list* t = global_token;
	while(NULL != t)
	{
		if(match("__attribute__", t->s))
		{
			struct token_list* start = t;
			struct token_list* scan = t->next;
			int depth = 0;
			/* skip to the opening paren, then over the balanced group */
			while(NULL != scan)
			{
				if('(' == scan->s[0]) depth = depth + 1;
				else if(')' == scan->s[0])
				{
					depth = depth - 1;
					if(0 == depth) { scan = scan->next; break; }
				}
				else if(0 == depth) break;   /* no parens: nothing to skip */
				scan = scan->next;
			}
			/* unlink [start, scan) */
			if(NULL != start->prev) start->prev->next = scan;
			else global_token = scan;
			if(NULL != scan) scan->prev = start->prev;
			t = scan;
			continue;
		}
		t = t->next;
	}
}

void preprocess(void)
{
	int start_of_line = TRUE;
	macro_token = global_token;

	while(NULL != macro_token)
	{
		if(start_of_line && '#' == macro_token->s[0])
		{
			macro_directive();

			if(macro_token)
			{
				if('\n' != macro_token->s[0])
				{
					line_error_token(macro_token);
					fputs("newline expected at end of macro directive\n", stderr);
					fputs("found: '", stderr);
					fputs(macro_token->s, stderr);
					fputs("'\n", stderr);
					exit(EXIT_FAILURE);
				}
			}
		}
		else if('\n' == macro_token->s[0])
		{
			start_of_line = TRUE;
			/* RESET THE EXPANSION BOUND PER LINE. It was cumulative across the
			 * whole translation unit, so it fired on arm64-asm.c's OPT_ANY_GPR
			 * -- which expands two levels deep and terminates -- purely because
			 * ten thousand unrelated expansions had happened earlier in the
			 * file. A runaway is a property of one expansion chain, and a line
			 * is the closest scope available without a hide set. */
			expand_depth = 0;
			macro_token = macro_token->next;
		}
		else
		{
			start_of_line = FALSE;
			macro_token = maybe_expand(macro_token);
		}
	}
}
