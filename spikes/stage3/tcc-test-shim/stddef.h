#ifndef _SHIM_STDDEF_H
#define _SHIM_STDDEF_H
typedef unsigned long size_t;
typedef long ptrdiff_t;
/* WCHAR_T IS FOUR BYTES AND UNSIGNED ON aarch64 Linux, which is what gcc
 * reports for this target. It is here because tcc's OWN include/stdatomic.h
 * uses it --
 *     typedef _Atomic(wchar_t) atomic_wchar_t;      stdatomic.h:51
 * -- so 136_atomic_gcc_style failed on `'wchar_t' undeclared` before reaching
 * a single atomic operation. ISO C puts wchar_t in stddef.h; it was missing
 * here, not misdeclared. */
typedef unsigned int wchar_t;
#define NULL ((void*)0)
#endif
