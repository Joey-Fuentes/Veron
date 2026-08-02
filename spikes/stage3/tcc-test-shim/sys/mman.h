#ifndef _SHIM_SYS_MMAN_H
#define _SHIM_SYS_MMAN_H
/* THE FLAG VALUES ARE THE KERNEL'S, NOT INVENTED.
 *
 * 119_random_stuff asks for a fixed anonymous mapping:
 *     mmap((void*)0x20000000, 4096, PROT_READ|PROT_WRITE,
 *          MAP_FIXED|MAP_ANONYMOUS, -1, 0);
 * and then writes through it, so the numbers have to be the ones the aarch64
 * kernel actually reads. PROT_* are architecture-independent in Linux; MAP_*
 * are the asm-generic values, which aarch64 uses unchanged.
 *
 * NOTE WHAT THE TEST OMITS: neither MAP_PRIVATE nor MAP_SHARED is passed. On
 * Linux that is EINVAL, and the test checks for MAP_FAILED and skips the body
 * when it gets it -- which is the path this will take. That is the test's own
 * behaviour under a real libc too; it is not a shim limitation. */
#include <stddef.h>

#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4

#define MAP_SHARED    0x01
#define MAP_PRIVATE   0x02
#define MAP_FIXED     0x10
#define MAP_ANONYMOUS 0x20
#define MAP_ANON      MAP_ANONYMOUS

#define MAP_FAILED ((void *)-1)

void *mmap(void *addr, unsigned long len, int prot, int flags, int fd, long off);
int munmap(void *addr, unsigned long len);
#endif
