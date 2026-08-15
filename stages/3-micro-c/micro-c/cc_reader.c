/* Copyright (C) 2016 Jeremiah Orians
 * Copyright (C) 2021 Andrius Štikonas <andrius@stikonas.eu>
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

int strtoint(char *a);

/* Globals */
FILE* input;
struct token_list* token;
int line;
char* file;

enum
{
	DEFINE_STATE_NONE = 0,
	DEFINE_STATE_DEFINE = 1,
};

/* Defines require knowing about whitespace to differentiate a function-like macro
 * #define FUNCTION_LIKE_MACRO(x)
 * and a regular macro that starts with an open parens
 * #define REGULAR_MACRO (x)
 * */
int define_state;

int grab_byte(void)
{
	if (file_index >= FILE_BUFFER_SIZE)
	{
		file_max = fread(file_buffer, 1, FILE_BUFFER_SIZE, input);
		file_index = 0;
	}

	if (file_index == file_max)
	{
		return EOF;
	}

	int c = file_buffer[file_index];
	file_index = file_index + 1;

	if (c == '\n')
	{
		line = line + 1;
	}

	return c;
}

int clearWhiteSpace(int c)
{
	if((32 == c) || (9 == c)) return clearWhiteSpace(grab_byte());
	return c;
}

int consume_byte(int c)
{
	hold_string[string_index] = c;
	string_index = string_index + 1;
	require(MAX_STRING > string_index, "Token exceeded MAX_STRING char limit\nuse --max-string number to increase\n");
	return grab_byte();
}

int preserve_string(int c)
{
	int frequent = c;
	int escape = FALSE;
	do
	{
		if(!escape && '\\' == c ) escape = TRUE;
		else escape = FALSE;
		c = consume_byte(c);
		if(EOF == c)
		{
			line_error_token(token);
			fputs("Unterminated string\n", stderr);
			exit(EXIT_FAILURE);
		}
	} while(escape || (c != frequent));
	return grab_byte();
}

char* concat_strings2(char* a, char* b)
{
	char* buf = calloc(MAX_STRING, sizeof(char));
	int offset = copy_string(buf, a, MAX_STRING);
	copy_string(buf + offset, b, MAX_STRING - offset);
	return buf;
}

char* concat_strings3(char* a, char* b, char* c)
{
	char* buf = calloc(MAX_STRING, sizeof(char));
	int offset = copy_string(buf, a, MAX_STRING);
	offset = offset + copy_string(buf + offset, b, MAX_STRING - offset);
	copy_string(buf + offset, c, MAX_STRING - offset);
	return buf;
}

char* concat_strings4(char* a, char* b, char* c, char* d)
{
	char* buf = calloc(MAX_STRING, sizeof(char));
	int offset = copy_string(buf, a, MAX_STRING);
	offset = offset + copy_string(buf + offset, b, MAX_STRING - offset);
	offset = offset + copy_string(buf + offset, c, MAX_STRING - offset);
	copy_string(buf + offset, d, MAX_STRING - offset);
	return buf;
}

int copy_string(char* target, char* source, int max)
{
	int i = 0;
	while(0 != source[i])
	{
		target[i] = source[i];
		i = i + 1;
		if(i == max) break;
	}
	return i;
}

int string_length(char* a)
{
	int i = 0;
	while(0 != a[i]) i = i + 1;
	return i;
}

int preserve_keyword(int c, char* S)
{
	while(in_set(c, S))
	{
		c = consume_byte(c);
	}
	return c;
}

void reset_hold_string(void)
{
	int i = MAX_STRING;
	while(0 <= i)
	{
		hold_string[i] = 0;
		i = i - 1;
	}
	string_index = 0;
}

/* note if this is the first token in the list, head needs fixing up */
struct token_list* eat_token(struct token_list* token)
{
	if(NULL != token->prev)
	{
		token->prev->next = token->next;
	}

	/* update backlinks */
	if(NULL != token->next)
	{
		token->next->prev = token->prev;
	}

	return token->next;
}

struct token_list* eat_until_newline(struct token_list* head)
{
	while (NULL != head)
	{
		if('\n' == head->s[0])
		{
			return head;
		}
		else
		{
			head = eat_token(head);
		}
	}

	return NULL;
}

struct token_list* remove_preprocessor_directives(struct token_list* head)
{
	struct token_list* first = NULL;

	while (NULL != head)
	{
		if('#' == head->s[0])
		{
			head = eat_until_newline(head);
		}
		else
		{
			if(NULL == first)
			{
				first = head;
			}
			head = head->next;
		}
	}

	return first;
}

void new_token(char* s, int size)
{
	struct token_list* current = calloc(1, sizeof(struct token_list));
	require(NULL != current, "Exhausted memory while getting token\n");

	/* More efficiently allocate memory for string */
	current->s = calloc(size, sizeof(char));
	require(NULL != current->s, "Exhausted memory while trying to copy a token\n");
	copy_string(current->s, s, MAX_STRING);

	current->prev = token;
	current->next = token;
	current->linenumber = line;
	current->filename = file;
	token = current;
}

int get_token(int c)
{
	struct token_list* current = calloc(1, sizeof(struct token_list));
	require(NULL != current, "Exhausted memory while getting token\n");

reset:
	reset_hold_string();
	string_index = 0;

	c = clearWhiteSpace(c);
	if(c == EOF)
	{
		free(current);
		return c;
	}
	else if('#' == c)
	{
		c = consume_byte(c);

		/* '##' IS ONE TOKEN. Without this, `a##b` tokenizes as `a`, `#`, `#b`:
		 * the first '#' takes no following alphanumerics because the next
		 * character is another '#', and the second '#' swallows `b`. The paste
		 * operator then never exists for expansion to act on, and tcc.h:407
		 *     # define ElfW(type) Elf##64##_##type
		 * fails as "Elf is not a defined symbol". */
		if('#' == c)
		{
			c = consume_byte(c);
			/* Fall THROUGH to new_token at the bottom. Returning here consumed
			 * the '##' and then threw it away, because that is where the token
			 * is actually created -- which is why the expansion list arrived at
			 * the paste pass already reading [Elf64_] [Sym] with no operator
			 * between them. */
			new_token(hold_string, string_index + 2);
			return c;
		}

		while (c == ' ' || c == '\t')
		{
			c = grab_byte();
		}
		c = preserve_keyword(c, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_");

		if(match(hold_string, "#define"))
		{
			define_state = DEFINE_STATE_DEFINE;
		}
	}
	else if(in_set(c, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"))
	{
		int starts_with_digit = in_set(c, "0123456789");
		c = preserve_keyword(c, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_");

		/* A FLOATING-POINT LITERAL IS ONE TOKEN. Digits share the identifier
		 * character set, so `79228162514264337593543950336.0L` came out as
		 * three tokens -- the number, a '.', and `0L` -- and the parser read
		 * the '.' as a member access:
		 *     ERROR in lookup_member double->0L does not exist   tccpp.c:2398
		 *
		 * Only absorb the '.' when the token STARTED with a digit, so `x.y`
		 * stays a member access. The exponent is taken too, including a signed
		 * one, and then any suffix letters (f, F, l, L). */
		if(starts_with_digit)
		{
			if('.' == c)
			{
				c = consume_byte(c);
				c = preserve_keyword(c, "0123456789");
			}
			if('e' == c || 'E' == c)
			{
				c = consume_byte(c);
				if('+' == c || '-' == c)
				{
					c = consume_byte(c);
				}
				c = preserve_keyword(c, "0123456789");
			}
			c = preserve_keyword(c, "fFlLuU");
		}
		if(define_state == DEFINE_STATE_DEFINE)
		{
			if(c != '(')
			{
				define_state = DEFINE_STATE_NONE;

				new_token(hold_string, string_index + 2);
				new_token(" ", 2);
				return c;
			}
		}

		define_state = DEFINE_STATE_NONE;
	}
	else if(in_set(c, "<=>|&!^%"))
	{
		/* ONLY ABSORB A REAL MULTI-CHARACTER OPERATOR.
		 *
		 * preserve_keyword took ANY run of "<=>|&!^%", so tcc's
		 *     temp_var=&arr_temp_local_vars[i];            tccgen.c:1549
		 * tokenized `=&` as ONE token and the statement died on a missing ';'.
		 * Every repro of this written with spaces around the '=' passed, which
		 * is how it stayed hidden: the discriminator was whitespace, not
		 * anything about the operands.
		 *
		 * The valid combinations are small and worth spelling out rather than
		 * approximating with a character class. */
		int first = c;
		c = consume_byte(c);

		int take = 0;
		if('=' == c)
		{
			/* == != <= >= |= &= ^= %= */
			if('=' == first || '!' == first || '<' == first || '>' == first ||
			   '|' == first || '&' == first || '^' == first || '%' == first)
			{
				take = 1;
			}
		}
		else if(c == first)
		{
			/* << >> && || */
			if('<' == first || '>' == first || '&' == first || '|' == first)
			{
				take = 1;
			}
		}

		if(take)
		{
			int second = c;
			c = consume_byte(c);
			/* <<= and >>= are the only three-character forms. */
			if('=' == c)
			{
				if(second == first)
				{
					if('<' == first || '>' == first)
					{
						c = consume_byte(c);
					}
				}
			}
		}
	}
	else if(in_set(c, "'\""))
	{
		c = preserve_string(c);
	}
	else if(c == '/')
	{
		c = consume_byte(c);
		if(c == '*')
		{
			c = grab_byte();
			while(c != '/')
			{
				while(c != '*')
				{
					c = grab_byte();
					require(EOF != c, "Hit EOF inside of block comment\n");
				}
				c = grab_byte();
				require(EOF != c, "Hit EOF inside of block comment\n");
			}
			c = grab_byte();
			goto reset;
		}
		else if(c == '/')
		{
			c = grab_byte();
			while (c != '\n')
			{
				c = grab_byte();
			}
			goto reset;
		}
		else if(c == '=')
		{
			c = consume_byte(c);
		}
	}
	else if (c == '\n')
	{
		c = consume_byte(c);
	}
	else if(c == '*')
	{
		c = consume_byte(c);
		if(c == '=')
		{
			c = consume_byte(c);
		}
	}
	else if(c == '+')
	{
		c = consume_byte(c);
		if(c == '=')
		{
			c = consume_byte(c);
		}
		if(c == '+')
		{
			c = consume_byte(c);
		}
	}
	else if(c == '-')
	{
		c = consume_byte(c);
		if(c == '=')
		{
			c = consume_byte(c);
		}
		if(c == '>')
		{
			c = consume_byte(c);
		}
		if(c == '-')
		{
			c = consume_byte(c);
		}
	}
	else if(c == '\\')
	{
		c = consume_byte(c);
		if(c == '\n')
		{
			c = consume_byte(c);
			goto reset;
		}
	}
	else
	{
		c = consume_byte(c);
	}

	new_token(hold_string, string_index + 2);
	return c;
}


int consume_filename(int c)
{
	reset_hold_string();
	int done = FALSE;

	while(!done)
	{
		if(c == EOF)
		{
			fputs("we don't support EOF as a filename in #FILENAME statements\n", stderr);
			exit(EXIT_FAILURE);
		}
		else if((32 == c) || (9 == c) || (c == '\n'))
		{
			c = grab_byte();
		}
		else
		{
			do
			{
				c = consume_byte(c);
				require(EOF != c, "Unterminated filename in #FILENAME\n");
			} while((32 != c) && (9 != c) && ('\n' != c));
			done = TRUE;
		}
	}

	/* with just a little extra to put in the matching at the end */
	new_token(hold_string, string_index + 3);
	return c;
}


int change_filename(int ch)
{
	require(EOF != ch, "#FILENAME failed to receive filename\n");
	/* Remove the #FILENAME */
	token = token->next;

	/* Get new filename */
	ch = consume_filename(ch);
	file = token->s;
	/* Remove it from the processing list */
	token = token->next;
	require(EOF != ch, "#FILENAME failed to receive filename\n");

	/* Get new line number */
	define_state = DEFINE_STATE_NONE;
	ch = get_token(ch);
	line = strtoint(token->s);
	if(0 == line)
	{
		if('0' != token->s[0])
		{
			fputs("non-line number: ", stderr);
			fputs(token->s, stderr);
			fputs(" provided to #FILENAME\n", stderr);
			exit(EXIT_FAILURE);
		}
	}
	/* Remove it from the processing list */
	token = token->next;

	return ch;
}

struct token_list* reverse_list(struct token_list* head)
{
	struct token_list* root = NULL;
	struct token_list* next;
	while(NULL != head)
	{
		next = head->next;
		head->next = root;
		root = head;
		head = next;
	}
	return root;
}

struct token_list* read_all_tokens(FILE* a, struct token_list* current, char* filename)
{
	input  = a;
	line = 1;
	file = filename;
	token = current;
	file_index = FILE_BUFFER_SIZE;
	int ch = grab_byte();
	define_state = DEFINE_STATE_NONE;
	while(EOF != ch)
	{
		ch = get_token(ch);
		require(NULL != token, "Empty files don't need to be compiled\n");
		if(match("#FILENAME", token->s)) ch = change_filename(ch);
	}

	return token;
}
