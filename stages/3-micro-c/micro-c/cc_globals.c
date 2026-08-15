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

/* What types we have */
struct type* global_types;
struct type* prim_types;

struct include_path_list* include_paths;

/* What we are currently working on */
struct token_list* global_token;

/* Output reorder collections*/
struct token_list* output_list;
struct token_list* strings_list;
struct token_list* globals_list;
struct token_list* global_constant_list;

struct static_variable_list* function_static_variables_list;

/* Make our string collection more efficient */
char* hold_string;
int string_index;
int file_index;
int file_max;
char* file_buffer;
int output_file_index;
char* output_file_buffer;

/* Our Target Architecture */
int Architecture;
int register_size;
int stack_direction;
char* return_instruction;

int MAX_STRING;
struct type* integer;
/* `void*`, kept so a conditional can recognise (void*)0 by IDENTITY rather
 * than by name. See the ternary in cc_core.c. */
struct type* void_pointer;
struct type* unsigned_integer;
struct type* character;
struct type* signed_char;
struct type* unsigned_char;
struct type* signed_short;
struct type* unsigned_short;
struct type* signed_long;
struct type* unsigned_long;
struct type* signed_long_long;
struct type* unsigned_long_long;
struct type* function_pointer;

/* enable bootstrap-mode */
int BOOTSTRAP_MODE;

int FOLLOW_INCLUDES;

/* enable preprocessor-only mode */
int PREPROCESSOR_MODE;

/* feature unsupported by cc_* */
void maybe_bootstrap_error(char* feature);

int expand_depth;

struct type* last_type_base;
int last_type_stars;

int global_second_dimension;

int pending_bitfield_offset;
int pending_bitfield_width;
int pending_bitfield_size;

/* Set immediately before an indexing expression when the thing being indexed
 * is known to be an ARRAY rather than a pointer. See postfix_expr_array. */
int indexing_an_array;

/* The element width the last index expression settled on. The STORE for an
 * indexed assignment happens in expression(), a different function from the
 * one that worked out the width, and the two must agree -- so the answer is
 * carried rather than recomputed from a type that cannot express it. */
int indexed_element_size;
int address_of_through_parens;
/* An assignment follows the closing paren of a parenthesised target, so the
 * thing inside must yield its ADDRESS rather than be loaded. See
 * primary_expr's paren branch and postfix_expr_variable. */
int assign_through_parens;

int extern_declaration;
