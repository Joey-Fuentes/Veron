/* micro-c: stdint.h -- the fixed-width types and their limits.
 *
 * M2libc's stdint.h is empty because the fixed-width types are built into
 * M2-Planet itself, so this file ADDS rather than shadowing.
 *
 * THE TYPEDEFS ARE HERE FOR THE TCC WE BUILD, NOT FOR micro-c. micro-c has
 * int32_t and friends as builtins and never needed them declared; mc-tcc is a
 * real tcc and does. Without them the first header that spells a width --
 * time.h's `struct tm` -- stops it with
 *
 *     time.h:26: error: ';' expected (got 'int32_t')
 *
 * before a single instruction of tcc.c has been generated, which is what
 * blocked step 13 of stage3-hermetic-arm64 (self-compilation) at its first
 * step. A header gap, not a codegen result, and worth telling apart.
 *
 * REDEFINING A BUILTIN IS ACCEPTED BY micro-c AND CHANGES NOTHING. Checked
 * rather than assumed: `int` is four bytes and `long` eight since
 * EXPERIMENT-zzw, so every typedef below names the width micro-c already used,
 * and compiling the whole tcc unit with and without this block gives a
 * BYTE-IDENTICAL .M1. That equality is the guard on this file -- if a typedef
 * here ever disagrees with the builtin it replaces, the hash moves.
 *
 * Written in HEX. micro-c's constant folding is signed 64-bit, so the decimal
 * spelling of UINT64_MAX would overflow it; the hex form is the same bits and
 * parses. */
#ifndef _MICROC_STDINT_H
#define _MICROC_STDINT_H

typedef signed char        int8_t;
typedef short              int16_t;
typedef int                int32_t;
typedef long               int64_t;

typedef unsigned char      uint8_t;
typedef unsigned short     uint16_t;
typedef unsigned int       uint32_t;
typedef unsigned long      uint64_t;

/* Pointer-sized. Both are eight bytes on every target this rung builds for;
 * a 32-bit target would need its own answer here and does not exist yet. */
typedef long               intptr_t;
typedef unsigned long      uintptr_t;

/* The `least` and `fast` families, which tcc's elf.h and stdatomic.h spell
 * even though nothing here needs them to differ from the exact widths. */
typedef signed char        int_least8_t;
typedef short              int_least16_t;
typedef int                int_least32_t;
typedef long               int_least64_t;
typedef unsigned char      uint_least8_t;
typedef unsigned short     uint_least16_t;
typedef unsigned int       uint_least32_t;
typedef unsigned long      uint_least64_t;

typedef signed char        int_fast8_t;
typedef long               int_fast16_t;
typedef long               int_fast32_t;
typedef long               int_fast64_t;
typedef unsigned char      uint_fast8_t;
typedef unsigned long      uint_fast16_t;
typedef unsigned long      uint_fast32_t;
typedef unsigned long      uint_fast64_t;

typedef long               intmax_t;
typedef unsigned long      uintmax_t;

#define INT8_MAX    0x7F
#define INT16_MAX   0x7FFF
#define INT32_MAX   0x7FFFFFFF
#define INT64_MAX   0x7FFFFFFFFFFFFFFF

#define INT8_MIN    (-0x80)
#define INT16_MIN   (-0x8000)
#define INT32_MIN   (-0x80000000)
#define INT64_MIN   (-0x7FFFFFFFFFFFFFFF - 1)

#define UINT8_MAX   0xFF
#define UINT16_MAX  0xFFFF
#define UINT32_MAX  0xFFFFFFFF
#define UINT64_MAX  0xFFFFFFFFFFFFFFFF

#define INTPTR_MAX  INT64_MAX
#define INTPTR_MIN  INT64_MIN
#define UINTPTR_MAX UINT64_MAX
#define INTMAX_MAX  INT64_MAX
#define INTMAX_MIN  INT64_MIN
#define UINTMAX_MAX UINT64_MAX
#define SIZE_MAX    UINT64_MAX

#endif
