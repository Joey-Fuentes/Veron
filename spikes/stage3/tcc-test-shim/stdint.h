#ifndef _SHIM_STDINT_H
#define _SHIM_STDINT_H
typedef signed char int8_t;
typedef unsigned char uint8_t;
typedef short int16_t;
typedef unsigned short uint16_t;
typedef int int32_t;
typedef unsigned int uint32_t;
typedef long int64_t;
typedef unsigned long uint64_t;
typedef long intptr_t;
typedef unsigned long uintptr_t;
/* THE 8-BIT LEAST TYPES, WHICH tcc's OWN stdatomic.h NEEDS.
 *     typedef _Atomic(int_least8_t) atomic_int_least8_t;   stdatomic.h:52
 * 136_atomic_gcc_style moved from 'wchar_t' undeclared to 'int_least8_t'
 * undeclared the moment wchar_t was supplied -- the header declares the whole
 * least/fast family in one run and stops at the first one missing. */
typedef signed char int_least8_t;
typedef unsigned char uint_least8_t;
typedef long int_least64_t;
typedef unsigned long uint_least64_t;
typedef signed char int_fast8_t;
typedef unsigned char uint_fast8_t;
typedef long int_fast16_t;
typedef unsigned long uint_fast16_t;
typedef long int_fast32_t;
typedef unsigned long uint_fast32_t;
typedef long int_fast64_t;
typedef unsigned long uint_fast64_t;
typedef long intmax_t;
typedef unsigned long uintmax_t;
typedef unsigned short uint_least16_t;
typedef unsigned int uint_least32_t;
typedef short int_least16_t;
typedef int int_least32_t;
#endif
