/* micro-c: stdint.h limits.
 *
 * M2libc's stdint.h is empty -- the fixed-width types are built into
 * M2-Planet itself -- so this ADDS the limit macros rather than shadowing
 * anything. tcc uses UINT64_MAX (arm64-asm.c:1699); the rest are here so the
 * next one does not need another round.
 *
 * Written in HEX. micro-c's constant folding is signed 64-bit, so the decimal
 * spelling of UINT64_MAX would overflow it; the hex form is the same bits and
 * parses. */
#ifndef _MICROC_STDINT_H
#define _MICROC_STDINT_H

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

#endif
