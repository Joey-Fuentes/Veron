/* -*- c-file-style: "linux";indent-tabs-mode:t -*- */
/* Copyright (C) 2017 Jeremiah Orians
 * Copyright (C) 2017 Jan Nieuwenhuizen <janneke@gnu.org>
 * This file is part of mescc-tools
 *
 * mescc-tools is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * mescc-tools is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with mescc-tools.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "M2libc/bootstrappable.h"

enum { max_string = 4096 };
/* TRUE: same value already defined at M2libc/bootstrappable.h:22 */
/* FALSE: same value already defined at M2libc/bootstrappable.h:23 */

enum { KNIGHT = 0 };
enum { X86 = 0x03 };
enum { AMD64 = 0x3E };
enum { ARMV7L = 0x28 };
enum { AARM64 = 0xB7 };
enum { PPC64LE = 0x15 };
enum { RISCV32 = 0xF3 };
enum { RISCV64 = 0x100F3 };

enum { HEX = 16 };
enum { OCTAL = 8 };
enum { BINARY = 2 };


struct input_files
{
	struct input_files* next;
	char* filename;
};

struct entry
{
	struct entry* next;
	unsigned target;
	char* name;
};

