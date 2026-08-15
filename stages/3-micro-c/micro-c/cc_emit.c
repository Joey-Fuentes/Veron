/* Copyright (C) 2025 Gtker
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

void emit_load_named_immediate(int reg, char* prefix, char* name, char* note);

struct token_list* emit(char *s, struct token_list* head)
{
	struct token_list* t = calloc(1, sizeof(struct token_list));
	require(NULL != t, "Exhausted memory while generating token to emit\n");
	t->next = head;
	t->s = s;
	return t;
}

void emit_out(char* s)
{
	output_list = emit(s, output_list);
}

void emit_label(char* prefix, char* name)
{
	emit_out(":");
	emit_out(prefix);
	emit_out(name);
	emit_out("\n");
}

char* emit_string;
int emit_string_index;
int emit_string_capacity;

/* THE EMIT BUFFER GROWS ON DEMAND INSTEAD OF STARTING AT MAX_STRING.
 *
 * reset_emit_string used to calloc MAX_STRING for EVERY emitted instruction,
 * and nothing is ever freed. With --max-string 65536 that is 64 KB per line of
 * output. Measured against a file with N logical operators, each of which
 * emits about six instructions:
 *
 *     200 operators     83 MB
 *     800 operators    320 MB
 *    3200 operators   1279 MB     -- about 400 KB per operator
 *
 * which is 64 KB times six, exactly. Adding short-circuit && and || pushed the
 * full tcc unit past 4 GB and it was killed by the OOM reaper -- a failure
 * that looked like a bug in short-circuit and was nothing of the kind.
 *
 * Emitted lines are short: the longest in 350,000 lines of tcc output is the
 * tcc_keywords byte string at 19,571 characters, and everything else is an
 * instruction of a few dozen. So start small and grow only when something
 * actually needs the room.
 *
 * MAX_STRING remains the hard ceiling, so nothing that used to fit stops
 * fitting. */
void grow_emit_string(int needed)
{
	if(needed <= emit_string_capacity) return;

	int bigger = emit_string_capacity;
	while(bigger < needed)
	{
		bigger = bigger * 2;
		if(bigger > MAX_STRING) bigger = MAX_STRING;
		if(bigger == MAX_STRING) break;
	}

	char* fresh = calloc(bigger + 1, sizeof(char));
	require(NULL != fresh, "Exhausted memory while growing the emit buffer\n");
	if(NULL != emit_string)
	{
		copy_string(fresh, emit_string, bigger);
	}
	emit_string = fresh;
	emit_string_capacity = bigger;
}

void emit_to_string(char* s)
{
	int length = string_length(s);
	grow_emit_string(emit_string_index + length + 1);
	emit_string_index = emit_string_index + copy_string(emit_string + emit_string_index, s, emit_string_capacity - emit_string_index);
}

void reset_emit_string(void)
{
	/* Emitted strings are just added to a linked list so we need a new one each
	 * time -- but only as much as this one turns out to need. */
	emit_string_capacity = 256;
	emit_string = calloc(emit_string_capacity + 1, sizeof(char));
	emit_string_index = 0;
}

char* integer_to_raw_byte_string(int value)
{
	/* A BYTE IS A BYTE: accept the full 0..255 as well as -128..127. The check
	 * allowed only the SIGNED range, so a global char array holding any value
	 * with the high bit set was rejected -- tcc hits it with 158. Both ranges
	 * denote the same eight bits; masking below makes the encoding agree. */
	if(value > 255 || value < -128)
	{
		fputs("Value out of range provided to 'integer_to_raw_byte_string': ", stderr);
		fputs(int2str(value, 10, TRUE), stderr);
		fputs("\n.", stderr);
		exit(EXIT_FAILURE);
	}

	char* hex_table = "0123456789ABCDEF";
	char* string;

	string = calloc(6, sizeof(char));
	string[0] = '\'';
	/* Mask to eight bits so a negative value encodes as its two's-complement
	 * byte rather than shifting in sign bits: -1 must be FF, not F...F. */
	int b8 = value & 255;
	string[1] = hex_table[b8 >> 4];
	string[2] = hex_table[b8 & 15];
	string[3] = '\'';
	string[4] = ' ';

	return string;
}

char* register_from_string(int reg)
{
	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		if(reg == REGISTER_ZERO) return "0";
		else if(reg == REGISTER_ONE) return "1";
		else if(reg == REGISTER_EMIT_TEMP) return "10";
		else if(reg == REGISTER_TEMP2) return "11";
		else if(reg == REGISTER_LOCALS) return "12";
		else if(reg == REGISTER_TEMP) return "13";
		else if(reg == REGISTER_BASE) return "14";
		else if(reg == REGISTER_STACK) return "15";
	}
	else if(X86 == Architecture)
	{
		if(reg == REGISTER_ZERO) return "eax";
		else if(reg == REGISTER_ONE) return "ebx";
		else if(reg == REGISTER_TEMP) return "edi";
		else if(reg == REGISTER_BASE) return "ebp";
		else if(reg == REGISTER_STACK) return "esp";
		else if(reg == REGISTER_LOCALS) return "esi";
		else if(reg == REGISTER_EMIT_TEMP) return "ecx";
		else if(reg == REGISTER_TEMP2) return "edx";
	}
	else if(AMD64 == Architecture)
	{
		if(reg == REGISTER_ZERO) return "rax";
		else if(reg == REGISTER_ONE) return "rbx";
		else if(reg == REGISTER_TEMP) return "rdi";
		else if(reg == REGISTER_BASE) return "rbp";
		else if(reg == REGISTER_STACK) return "rsp";
		else if(reg == REGISTER_LOCALS) return "r13";
		else if(reg == REGISTER_EMIT_TEMP) return "r14";
		else if(reg == REGISTER_TEMP2) return "r15";
	}
	else if(ARMV7L == Architecture)
	{
		if(reg == REGISTER_ZERO) return "R0";
		else if(reg == REGISTER_ONE) return "R1";
		else if(reg == REGISTER_LOCALS) return "R8";
		else if(reg == REGISTER_EMIT_TEMP) return "R9";
		else if(reg == REGISTER_TEMP2) return "R10";
		else if(reg == REGISTER_TEMP) return "R11";
		else if(reg == REGISTER_BASE) return "BP";
		else if(reg == REGISTER_RETURN) return "LR";
		else if(reg == REGISTER_STACK) return "SP";
	}
	else if(AARCH64 == Architecture)
	{
		if(reg == REGISTER_ZERO) return "x0";
		else if(reg == REGISTER_ONE) return "x1";
		else if(reg == REGISTER_LOCALS) return "x13";
		else if(reg == REGISTER_EMIT_TEMP) return "x14";
		else if(reg == REGISTER_TEMP2) return "x15";
		else if(reg == REGISTER_TEMP) return "x16";
		else if(reg == REGISTER_BASE) return "x17";
		else if(reg == REGISTER_RETURN) return "lr";
		else if(reg == REGISTER_STACK) return "x18";
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		if(reg == REGISTER_ZERO) return "a0";
		else if(reg == REGISTER_ONE) return "a1";
		else if(reg == REGISTER_LOCALS) return "t3";
		else if(reg == REGISTER_EMIT_TEMP) return "t4";
		else if(reg == REGISTER_TEMP2) return "t5";
		else if(reg == REGISTER_TEMP) return "tp";
		else if(reg == REGISTER_BASE) return "fp";
		else if(reg == REGISTER_RETURN) return "ra";
		else if(reg == REGISTER_STACK) return "sp";
	}

	fputs("PROGRAMMING ERROR: Invalid register passed to register_from_string: '", stderr);
	fputs(int2str(reg, 10, FALSE), stderr);
	fputs("' for architecture '", stderr);
	fputs(int2str(Architecture, 10, FALSE), stderr);
	fputs("'\n.", stderr);
	exit(EXIT_FAILURE);
}
void emit_unconditional_jump(char* prefix, char* name, char* note)
{
	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("JUMP @");
		emit_out(prefix);
		emit_out(name);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("jmp %");
		emit_out(prefix);
		emit_out(name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("^~");
		emit_out(prefix);
		emit_out(name);
		emit_out(" JUMP_ALWAYS");
	}
	else if(AARCH64 == Architecture)
	{
		emit_load_named_immediate(REGISTER_TEMP, prefix, name, note);
		emit_out("br_x16");
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_out("$");
		emit_out(prefix);
		emit_out(name);
		emit_out(" jal");
	}

	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_jump_if_zero(int reg, char* prefix, char* name, char* note)
{
	char* reg_name = register_from_string(reg);

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("JUMP.Z R");
		emit_out(reg_name);
		emit_out(" @");
		emit_out(prefix);
		emit_out(name);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("test_");
		emit_out(reg_name);
		emit_out(",");
		emit_out(reg_name);
		emit_out("\nje %");
		emit_out(prefix);
		emit_out(name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("!0 CMPI8 ");
		emit_out(reg_name);
		emit_out(" IMM_ALWAYS\n^~");
		emit_out(prefix);
		emit_out(name);
		emit_out(" JUMP_EQUAL");
	}
	else if(AARCH64 == Architecture)
	{
		emit_out("cbnz_");
		emit_out(reg_name);
		emit_out(",20\n");
		emit_load_named_immediate(REGISTER_TEMP, prefix, name, note);
		emit_out("br_x16");
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_out("rs1_");
		emit_out(reg_name);
		emit_out(" @8 bnez\n$");
		emit_out(prefix);
		emit_out(name);
		emit_out(" jal");
	}

	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_jump_if_not_zero(int reg, char* prefix, char* name, char* note)
{
	char* reg_name = register_from_string(reg);

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("JUMP.NZ R");
		emit_out(reg_name);
		emit_out(" @");
		emit_out(prefix);
		emit_out(name);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("test_");
		emit_out(reg_name);
		emit_out(",");
		emit_out(reg_name);
		emit_out("\njne %");
		emit_out(prefix);
		emit_out(name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("!0 CMPI8 ");
		emit_out(reg_name);
		emit_out(" IMM_ALWAYS\n^~");
		emit_out(prefix);
		emit_out(name);
		emit_out(" JUMP_NE");
	}
	else if(AARCH64 == Architecture)
	{
		emit_out("cbz_");
		emit_out(reg_name);
		emit_out(",20\n");
		emit_load_named_immediate(REGISTER_TEMP, prefix, name, note);
		emit_out("br_x16");
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_out("rs1_");
		emit_out(reg_name);
		emit_out(" @8 beqz\n$");
		emit_out(prefix);
		emit_out(name);
		emit_out(" jal\n");
	}

	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_jump_if_equal(int reg1, int reg2, char* prefix, char* name, char* note)
{
	char* reg1_name = register_from_string(reg1);
	char* reg2_name = register_from_string(reg2);

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("CMPU R");
		emit_out(reg1_name); /* source of CMPU */
		emit_out(" R");
		emit_out(reg1_name);
		emit_out(" R");
		emit_out(reg2_name);
		emit_out("\nJUMP.E R");
		emit_out(reg1_name); /* source of CMPU */
		emit_out(" @");
		emit_out(prefix);
		emit_out(name);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("cmp_");
		emit_out(reg2_name);
		emit_out(",");
		emit_out(reg1_name);

		emit_out("\nje %");
		emit_out(prefix);
		emit_out(name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("'0' ");
		emit_out(reg1_name);
		emit_out(" CMP ");
		emit_out(reg2_name);
		emit_out(" AUX_ALWAYS\n^~");
		emit_out(prefix);
		emit_out(name);
		emit_out(" JUMP_EQUAL");
	}
	else if(AARCH64 == Architecture)
	{
		emit_out("cmp_");
		emit_out(reg2_name);
		emit_out(",");
		emit_out(reg1_name);
		emit_out("\n");
		emit_load_named_immediate(REGISTER_TEMP, prefix, name, note);
		emit_out("b.ne_8\nbr_x16");
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_out("rd_");
		emit_out(reg1_name);
		emit_out(" rs1_");
		emit_out(reg1_name);
		emit_out(" rs2_");
		emit_out(reg2_name);
		emit_out(" sub\nrs1_");
		emit_out(reg1_name);
		emit_out(" @8 bnez\n$");
		emit_out(prefix);
		emit_out(name);
		emit_out(" jal");
	}

	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_load_named_immediate(int reg, char* prefix, char* name, char* note)
{
	char* reg_name = register_from_string(reg);
	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("LOADR R");
		emit_out(reg_name);
		emit_out(" 4\nJUMP 4\n&");
		emit_out(prefix);
		emit_out(name);
	}
	else if(X86 == Architecture)
	{
		emit_out("mov_");
		emit_out(reg_name);
		emit_out(", &");
		emit_out(prefix);
		emit_out(name);
	}
	else if(AMD64 == Architecture)
	{
		emit_out("lea_");
		emit_out(reg_name);
		emit_out(",[rip+DWORD] %");
		emit_out(prefix);
		emit_out(name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("!0 ");
		emit_out(reg_name);
		emit_out(" LOAD32 R15 MEMORY\n~0 JUMP_ALWAYS\n&");
		emit_out(prefix);
		emit_out(name);
	}
	else if(AARCH64 == Architecture)
	{
		emit_out("ldr_w");
		/* Normal register starts with X for 64bit wide
		 * but we need W. */
		emit_out(reg_name + 1);
		emit_out(",8\nb_8\n&");
		emit_out(prefix);
		emit_out(name);
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_out("rd_");
		emit_out(reg_name);
		emit_out(" ~");
		emit_out(prefix);
		emit_out(name);
		emit_out(" auipc\n");

		emit_out("rd_");
		emit_out(reg_name);
		emit_out(" rs1_");
		emit_out(reg_name);
		emit_out(" !");
		emit_out(prefix);
		emit_out(name);
		emit_out(" addi");
	}


	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

/* DOES THIS CONSTANT FIT THE 32-BIT FORMS BELOW?
 *
 * The honest answer is architecture-dependent, and the two targets disagree in
 * OPPOSITE DIRECTIONS -- which is why one threshold is used for both and it is
 * the intersection of what each gets right, not the union.
 *
 *     aarch64   ldr_w<r>,8 loads a WORD and ZERO-extends. Correct for
 *               0 .. 0xFFFFFFFF, wrong for every negative value.
 *     amd64     mov_<r>, %imm32 is MOV r/m64, imm32 and SIGN-extends.
 *               Correct for -0x80000000 .. 0x7FFFFFFF, wrong above it.
 *
 * The overlap is 0 .. 0x7FFFFFFF and nothing else. A threshold of 2^32 would
 * have left 189 sites in one compile of libtcc.c emitting a constant that is
 * right on one architecture and wrong on the other -- the sixth instance of
 * the class MICRO-C.md counts, running in the direction nobody watches, since
 * here it is amd64 that is wrong and aarch64 that is right.
 *
 * Written as a shift rather than as a comparison against a literal because a
 * literal is exactly the thing this patch is fixing: `value > 0x7FFFFFFF` is a
 * test whose meaning depends on the compiler that built this compiler. */
int immediate_is_wide(long long value)
{
	if(0 == (value >> 31)) return FALSE;
	return TRUE;
}

void write_load_immediate(int reg, long long value, char* note)
{
	char* reg_name = register_from_string(reg);
	char* value_string = long2str(value, 10, TRUE);

	if(immediate_is_wide(value) && (AARCH64 == Architecture))
	{
		/* ldr_x<r>,8 / b_12 / %lo / %hi -- a PC-relative 64-bit literal load,
		 * a branch over the eight-byte pool, and the pool itself. The macros
		 * are byte-anchored against real `as` in CI and verified by EXECUTION
		 * under the committed emulator; see patches/m2libc/0005 and
		 * tools/verify-imm64.sh, which reads BOTH halves back because a form
		 * that loaded only the low one passes a low-byte check. */
		emit_to_string("ldr_");
		emit_to_string(reg_name);
		emit_to_string(",8\nb_12\n%");
		emit_to_string(long2str(immediate_low_word(value), 10, FALSE));
		emit_to_string("\n%");
		emit_to_string(long2str(immediate_high_word(value), 10, FALSE));
	}
	else if(immediate_is_wide(value) && (AMD64 == Architecture))
	{
		/* movabs is the only x86-64 form that takes a full 64-bit immediate. */
		emit_to_string("movabs_");
		emit_to_string(reg_name);
		emit_to_string(", %");
		emit_to_string(long2str(immediate_low_word(value), 10, FALSE));
		emit_to_string(" %");
		emit_to_string(long2str(immediate_high_word(value), 10, FALSE));
	}
	else if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		if((32767 > value) && (value > -32768))
		{
			emit_to_string("LOADI R");
			emit_to_string(reg_name);
			emit_to_string(" ");
			emit_to_string(value_string);
		}
		else
		{
			emit_to_string("LOADR R");
			emit_to_string(reg_name);
			emit_to_string(" 4\nJUMP 4\n%");
			emit_to_string(int2str(value, 10, TRUE));
		}
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		if(value == 0)
		{
			/* This is the recommended way of zeroing a register on x86/amd64.
			 * xor eax, eax (32 bit registers) for both x86 and amd64 since it
			 * takes up a byte less and still zeros the register. */
			emit_to_string("xor_e");
			/* amd64 register starts with r but we need it to start with e */
			emit_to_string(reg_name + 1);
			emit_to_string(",e");
			emit_to_string(reg_name + 1);
		}
		else
		{
			emit_to_string("mov_");
			emit_to_string(reg_name);
			emit_to_string(", %");
			emit_to_string(value_string);
		}
	}
	else if(ARMV7L == Architecture)
	{
		if((127 >= value) && (value >= 0))
		{
			emit_to_string("!");
			emit_to_string(value_string);
			emit_to_string(" ");
			emit_to_string(reg_name);
			emit_to_string(" LOADI8_ALWAYS");
		}
		else
		{
			emit_to_string("!0 ");
			emit_to_string(reg_name);
			emit_to_string(" LOAD32 R15 MEMORY\n~0 JUMP_ALWAYS\n%");
			emit_to_string(value_string);
		}
	}
	else if(AARCH64 == Architecture)
	{
		int has_short_version = (reg == REGISTER_ZERO && value >= -1 && value <= 128) || (reg == REGISTER_EMIT_TEMP &&
			value <= 128 && value >= 0 && value % 8 == 0);
		if ((value == 0 && reg == 1) || has_short_version)
		{
			emit_to_string("mov_");
			emit_to_string(reg_name);
			emit_to_string(",");
			emit_to_string(value_string);
		}
		else
		{
			emit_to_string("ldr_w");
			/* Normal register starts with X for 64bit wide
			 * but we need W. */
			emit_to_string(reg_name + 1);
			emit_to_string(",8\nb_8\n%");
			emit_to_string(value_string);
		}
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		if((2047 >= value) && (value >= -2048))
		{
			emit_to_string("rd_");
			emit_to_string(reg_name);
			emit_to_string(" !");
			emit_to_string(value_string);
			emit_to_string(" addi");
		}
		else if (0 == (value >> 30))
		{
			emit_to_string("rd_");
			emit_to_string(reg_name);
			emit_to_string(" ~");
			emit_to_string(value_string);
			emit_to_string(" lui\n");

			emit_to_string("rd_");
			emit_to_string(reg_name);
			emit_to_string(" rs1_");
			emit_to_string(reg_name);
			emit_to_string(" !");
			emit_to_string(value_string);
			emit_to_string(" addi");
		}
		else
		{
			int high = value >> 30;
			char* high_string = int2str(high, 10, TRUE);
			int low = ((value >> 30) << 30) ^ value;
			char* low_string = int2str(low, 10, TRUE);

			emit_to_string("rd_");
			emit_to_string(reg_name);
			emit_to_string(" ~");
			emit_to_string(high_string);
			emit_to_string(" lui\n");

			emit_to_string("rd_");
			emit_to_string(reg_name);
			emit_to_string(" rs1_");
			emit_to_string(reg_name);
			emit_to_string(" !");
			emit_to_string(high_string);
			emit_to_string(" addi\n");

			emit_to_string("rd_");
			emit_to_string(reg_name);
			emit_to_string(" rs1_");
			emit_to_string(reg_name);
			emit_to_string(" rs2_x30 slli\n");

			emit_to_string("rd_t1 ~");
			emit_to_string(low_string);
			emit_to_string(" lui\n");

			emit_to_string("rd_t1 rs1_t1 !");
			emit_to_string(low_string);
			emit_to_string(" addi\n");

			emit_to_string("rd_");
			emit_to_string(reg_name);
			emit_to_string(" rs1_");
			emit_to_string(reg_name);
			emit_to_string(" rs2_t1 or");
		}
	}

	if(note == NULL)
	{
		emit_to_string("\n");
	}
	else
	{
		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
}

/* AND IF THE TARGET CANNOT HOLD IT, SAY SO.
 *
 * knight, x86, armv7l and riscv32 have no 64-bit register, and riscv64's
 * long-immediate lowering here is a 30-bit split that has never been asked for
 * more. On those targets the value below is TRUNCATED, exactly as it was
 * everywhere before this patch. That is not fixable by an emitter change and
 * pretending otherwise would be worse than the truncation; what is fixable is
 * that it happened silently. It no longer does. */
void warn_immediate_truncated(long long value)
{
	fputs("WARNING: the constant ", stderr);
	fputs(long2str(value, 10, TRUE), stderr);
	fputs(" does not fit a 32-bit immediate and this architecture has no\n", stderr);
	fputs("         64-bit immediate form. It has been TRUNCATED.\n", stderr);
}

void emit_load_immediate(int reg, long long value, char* note)
{
	if(immediate_is_wide(value) && (AARCH64 != Architecture) && (AMD64 != Architecture))
	{
		warn_immediate_truncated(value);
	}

	reset_emit_string();
	write_load_immediate(reg, value, note);
	emit_out(emit_string);
}

/* Adds destination and source and places result in destination */
void write_add(int destination_reg, int source_reg, int is_signed, char* note)
{
	char* destination_name = register_from_string(destination_reg);
	char* source_name = register_from_string(source_reg);

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		if(is_signed)
			emit_to_string("ADD R");
		else
			emit_to_string("ADDU R");
		emit_to_string(destination_name);
		emit_to_string(" R");
		emit_to_string(destination_name);
		emit_to_string(" R");
		emit_to_string(source_name);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_to_string("add_");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(source_name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_to_string("'0' ");
		emit_to_string(destination_name);
		emit_to_string(" ");
		emit_to_string(destination_name);
		emit_to_string(" ADD ");
		emit_to_string(source_name);
		emit_to_string(" ARITH2_ALWAYS");
	}
	else if(AARCH64 == Architecture)
	{
		emit_to_string("add_");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(source_name);
		emit_to_string(",");
		emit_to_string(destination_name);
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_to_string("rd_");
		emit_to_string(destination_name);
		emit_to_string(" rs1_");
		emit_to_string(source_name);
		emit_to_string(" rs2_");
		emit_to_string(destination_name);
		emit_to_string(" add");
	}

	if(note == NULL)
	{
		emit_to_string("\n");
	}
	else
	{
		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
}

void emit_add(int destination_reg, int source_reg, int is_signed, char* note)
{
	reset_emit_string();
	write_add(destination_reg, source_reg, is_signed, note);
	emit_out(emit_string);
}

void write_add_immediate(int reg, int value, char* note)
{
	if((Architecture & ARCH_FAMILY_X86) && (reg == REGISTER_ZERO))
	{
		emit_to_string("add_");
		emit_to_string(register_from_string(reg));
		emit_to_string(",");

		if(127 >= value && value >= -128)
		{
			emit_to_string("BYTE ");
			emit_to_string(integer_to_raw_byte_string(value));
		}
		else
		{
			emit_to_string(" %");
			emit_to_string(int2str(value, 10, TRUE));
		}

		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
	else if(Architecture & ARCH_FAMILY_RISCV && (2047 >= value && value >= -2048))
	{
		emit_to_string("rd_");
		emit_to_string(register_from_string(reg));
		emit_to_string(" rs1_");
		emit_to_string(register_from_string(reg));
		emit_to_string(" !");
		emit_to_string(int2str(value, 10, TRUE));
		emit_to_string(" addi");

		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
	else
	{
		write_load_immediate(REGISTER_EMIT_TEMP, value, note);
		write_add(reg, REGISTER_EMIT_TEMP, TRUE, note);
	}
}

void emit_add_immediate(int reg, int value, char* note)
{
	reset_emit_string();
	write_add_immediate(reg, value, note);
	emit_out(emit_string);
}

/* Subtracts destination and source and places result in destination */
void write_sub(int destination_reg, int source_reg, int is_signed, char* note)
{
	char* destination_name = register_from_string(destination_reg);
	char* source_name = register_from_string(source_reg);

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		if(is_signed)
			emit_to_string("SUB R");
		else
			emit_to_string("SUBU R");
		emit_to_string(destination_name);
		emit_to_string(" R");
		emit_to_string(destination_name);
		emit_to_string(" R");
		emit_to_string(source_name);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_to_string("sub_");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(source_name);
		emit_to_string("\n");
	}
	else if(ARMV7L == Architecture)
	{
		emit_to_string("'0' ");
		emit_to_string(source_name);
		emit_to_string(" ");
		emit_to_string(destination_name);
		emit_to_string(" SUB ");
		emit_to_string(destination_name);
		emit_to_string(" ARITH2_ALWAYS");
	}
	else if(AARCH64 == Architecture)
	{
		emit_to_string("sub_");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(source_name);
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_to_string("rd_");
		emit_to_string(destination_name);
		emit_to_string(" rs1_");
		emit_to_string(destination_name);
		emit_to_string(" rs2_");
		emit_to_string(source_name);
		emit_to_string(" sub");
	}

	if(note == NULL)
	{
		emit_to_string("\n");
	}
	else
	{
		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
}

void emit_sub(int destination_reg, int source_reg, int is_signed, char* note)
{
	reset_emit_string();
	write_sub(destination_reg, source_reg, is_signed, note);
	emit_out(emit_string);
}

void write_sub_immediate(int reg, int value, char* note)
{
	if((Architecture & ARCH_FAMILY_X86) && (reg == REGISTER_STACK || reg == REGISTER_ZERO))
	{
		emit_to_string("sub_");
		emit_to_string(register_from_string(reg));
		emit_to_string(",");

		if(127 >= value && value >= -128)
		{

			emit_to_string("BYTE ");
			emit_to_string(integer_to_raw_byte_string(value));
		}
		else
		{
			emit_to_string(" %");
			emit_to_string(int2str(value, 10, TRUE));
		}

		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
	/* NOTE: This is not the normal range since we negate the value in the addi. */
	else if(Architecture & ARCH_FAMILY_RISCV && (2048 >= value && value >= -2047))
	{
		emit_to_string("rd_");
		emit_to_string(register_from_string(reg));
		emit_to_string(" rs1_");
		emit_to_string(register_from_string(reg));
		emit_to_string(" !");
		/* We negate the value because we're using addi.
		 * There is no subi in RISCV. */
		emit_to_string(int2str(-value, 10, TRUE));
		emit_to_string(" addi");

		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
	else
	{
		write_load_immediate(REGISTER_EMIT_TEMP, value, note);
		write_sub(reg, REGISTER_EMIT_TEMP, TRUE, note);
	}
}

void emit_sub_immediate(int reg, int value, char* note)
{
	reset_emit_string();
	write_sub_immediate(reg, value, note);
	emit_out(emit_string);
}

void write_rsub(int destination_reg, int source_reg, int is_signed, char* note)
{
	char* destination_name = register_from_string(destination_reg);
	char* source_name = register_from_string(source_reg);

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		if(is_signed)
			emit_to_string("SUB R");
		else
			emit_to_string("SUBU R");
		emit_to_string(destination_name);
		emit_to_string(" R");
		emit_to_string(source_name);
		emit_to_string(" R");
		emit_to_string(destination_name);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_to_string("sub_");
		emit_to_string(source_name);
		emit_to_string(",");
		emit_to_string(destination_name);
		emit_to_string("\n");
		emit_to_string("mov_");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(source_name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_to_string("'0' ");
		emit_to_string(destination_name);
		emit_to_string(" ");
		emit_to_string(destination_name);
		emit_to_string(" SUB ");
		emit_to_string(source_name);
		emit_to_string(" ARITH2_ALWAYS");
	}
	else if(AARCH64 == Architecture)
	{
		emit_to_string("sub_");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(source_name);
		emit_to_string(",");
		emit_to_string(destination_name);
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_to_string("rd_");
		emit_to_string(destination_name);
		emit_to_string(" rs1_");
		emit_to_string(source_name);
		emit_to_string(" rs2_");
		emit_to_string(destination_name);
		emit_to_string(" sub");
	}

	if(note == NULL)
	{
		emit_to_string("\n");
	}
	else
	{
		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
}

void emit_rsub(int destination_reg, int source_reg, int is_signed, char* note)
{
	reset_emit_string();
	write_rsub(destination_reg, source_reg, is_signed, note);
	emit_out(emit_string);
}

void emit_mul_into_register_zero(int reg, char* note)
{
	char* reg_name = register_from_string(reg);

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("MULU R0 R");
		emit_out(reg_name);
		emit_out(" R0");
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("mul_");
		emit_out(reg_name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("'9' R0 '0' ");
		emit_out(reg_name);
		emit_out(" MUL R0 ARITH2_ALWAYS");
	}
	else if(AARCH64 == Architecture)
	{
		emit_out("mul_x0,");
		emit_out(reg_name);
		emit_out(",x0");
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_out("rd_a0 rs1_");
		emit_out(reg_name);
		emit_out(" rs2_a0 mul");
	}

	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_mul_register_zero_with_immediate(int value, char* note)
{
	emit_load_immediate(REGISTER_EMIT_TEMP, value, note);
	emit_mul_into_register_zero(REGISTER_EMIT_TEMP, note);
}

void write_move(int destination_reg, int source_reg, char* note)
{
	char* destination_name = register_from_string(destination_reg);
	char* source_name = register_from_string(source_reg);

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_to_string("COPY R");
		emit_to_string(destination_name);
		emit_to_string(" R");
		emit_to_string(source_name);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_to_string("mov_");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(source_name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_to_string("'0' ");
		emit_to_string(source_name);
		emit_to_string(" ");
		emit_to_string(destination_name);
		emit_to_string(" NO_SHIFT MOVE_ALWAYS");
	}
	else if(AARCH64 == Architecture)
	{
		emit_to_string("mov_");
		emit_to_string(destination_name);
		emit_to_string(",");
		emit_to_string(source_name);
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_to_string("rd_");
		emit_to_string(destination_name);
		emit_to_string(" rs1_");
		emit_to_string(source_name);
		emit_to_string(" mv");
	}

	if(note == NULL)
	{
		emit_to_string("\n");
	}
	else
	{
		emit_to_string(" # ");
		emit_to_string(note);
		emit_to_string("\n");
	}
}

void emit_move(int destination_reg, int source_reg, char* note)
{
	reset_emit_string();
	write_move(destination_reg, source_reg, note);
	emit_out(emit_string);
}

void emit_load_relative_to_register(int destination, int offset_register, int value, char* note)
{
	char* destination_name = register_from_string(destination);
	char* offset_name = register_from_string(offset_register);
	char* value_string = int2str(value, 10, TRUE);
	int absolute_value = value;
	if(value < 0)
	{
		absolute_value = -absolute_value;
	}

	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("ADDI R");
		emit_out(destination_name);
		emit_out(" R");
		emit_out(offset_name);
		emit_out(" ");
		emit_out(value_string);
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("lea_");
		emit_out(destination_name);
		emit_out(",[");
		emit_out(offset_name);
		emit_out("+DWORD] %");
		emit_out(value_string);
	}
	else if(ARMV7L == Architecture)
	{
		if((127 >= absolute_value) && (absolute_value >= 0))
		{
			emit_out("!");
			emit_out(int2str(absolute_value, 10, FALSE));
			emit_out(" ");
			emit_out(destination_name);
			emit_out(" SUB ");
			emit_out(offset_name);
			emit_out(" ARITH_ALWAYS\n");
		}
		else
		{
			emit_move(destination, offset_register, note);
			emit_sub_immediate(destination, absolute_value, note);
		}
	}
	else if(AARCH64 == Architecture)
	{
		if (destination == REGISTER_ZERO && (offset_register == REGISTER_BASE || offset_register == REGISTER_LOCALS) &&
		    ((absolute_value % 8 == 0) && absolute_value <= 128))
		{
			emit_out("sub_");
			emit_out(destination_name);
			emit_out(",");
			emit_out(offset_name);
			emit_out(",");
			emit_out(int2str(absolute_value, 10, FALSE));
		}
		else
		{
			emit_move(destination, offset_register, note);
			emit_sub_immediate(destination, absolute_value, note);
		}
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		if((2047 >= value) && (value >= -2048))
		{
			emit_out("rd_");
			emit_out(destination_name);
			emit_out(" rs1_");
			emit_out(offset_name);
			emit_out(" !");
			emit_out(value_string);
			emit_out(" addi");
		}
		else
		{
			emit_out("rd_");
			emit_out(destination_name);
			emit_out(" ~");
			emit_out(value_string);
			emit_out(" lui\n");

			emit_out("rd_");
			emit_out(destination_name);
			emit_out(" rs1_");
			emit_out(offset_name);
			emit_out(" !");
			emit_out(value_string);
			emit_out(" addi");
		}
	}


	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_dereference(int reg, char* note)
{
	char* reg_name = register_from_string(reg);
	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("LOAD R");
		emit_out(reg_name);
		emit_out(" R");
		emit_out(reg_name);
		emit_out(" 0");
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("mov_");
		emit_out(reg_name);
		emit_out(",[");
		emit_out(reg_name);
		emit_out("]");
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("!0 ");
		emit_out(reg_name);
		emit_out(" LOAD32 ");
		emit_out(reg_name);
		emit_out(" MEMORY");
	}
	else if(AARCH64 == Architecture)
	{
		emit_out("ldr_");
		emit_out(reg_name);
		emit_out(",[");
		emit_out(reg_name);
		emit_out("]");
	}
	else if(Architecture & ARCH_FAMILY_RISCV)
	{
		emit_out("rd_");
		emit_out(reg_name);
		emit_out(" rs1_");
		emit_out(reg_name);
		if(RISCV32 == Architecture) emit_out(" lw");
		else emit_out(" ld");
	}

	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_push(int reg, char* note)
{
	char* reg_name = register_from_string(reg);
	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("PUSHR R");
		emit_out(reg_name);
		emit_out(" R15");
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("push_");
		emit_out(reg_name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("{");
		emit_out(reg_name);
		emit_out("} PUSH_ALWAYS");
	}
	else if(AARCH64 == Architecture)
	{
		emit_out("str_");
		emit_out(reg_name);
		emit_out(",[x18,-8]!");
	}
	else if(RISCV32 == Architecture)
	{
		emit_out("rd_sp rs1_sp !-4 addi\nrs1_sp rs2_");
		emit_out(reg_name);
		emit_out(" sw");
	}
	else if(RISCV64 == Architecture)
	{
		emit_out("rd_sp rs1_sp !-8 addi\nrs1_sp rs2_");
		emit_out(reg_name);
		emit_out(" sd");
	}

	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_pop(int reg, char* note)
{
	char* reg_name = register_from_string(reg);
	if(Architecture & ARCH_FAMILY_KNIGHT)
	{
		emit_out("POPR R");
		emit_out(reg_name);
		emit_out(" R15");
	}
	else if(Architecture & ARCH_FAMILY_X86)
	{
		emit_out("pop_");
		emit_out(reg_name);
	}
	else if(ARMV7L == Architecture)
	{
		emit_out("{");
		emit_out(reg_name);
		emit_out("} POP_ALWAYS");
	}
	else if(AARCH64 == Architecture)
	{
		emit_out("ldr_");
		emit_out(reg_name);
		emit_out(",[x18],8");
	}
	else if(RISCV32 == Architecture)
	{
		emit_out("rd_");
		emit_out(reg_name);
		emit_out(" rs1_sp lw\nrd_sp rs1_sp !4 addi");
	}
	else if(RISCV64 == Architecture)
	{
		emit_out("rd_");
		emit_out(reg_name);
		emit_out(" rs1_sp ld\nrd_sp rs1_sp !8 addi");
	}

	if(note == NULL)
	{
		emit_out("\n");
	}
	else
	{
		emit_out(" # ");
		emit_out(note);
		emit_out("\n");
	}
}

void emit_return()
{
	emit_out(return_instruction);
}

