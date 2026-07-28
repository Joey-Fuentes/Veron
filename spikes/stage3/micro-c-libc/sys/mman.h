/* micro-c: minimal sys/mman.h. tcc maps its own generated code executable in
 * tccrun.c -- 5 mmap sites, 2 munmap, and the PROT_/MAP_ constants. The values
 * are Linux's; they are ABI, not choices. */
#ifndef _MICROC_SYS_MMAN_H
#define _MICROC_SYS_MMAN_H

#define PROT_NONE  0
#define PROT_READ  1
#define PROT_WRITE 2
#define PROT_EXEC  4

#define MAP_SHARED    1
#define MAP_PRIVATE   2
#define MAP_FIXED     16
#define MAP_ANONYMOUS 32
#define MAP_FAILED    0

void* mmap(void* addr, unsigned long length, int prot, int flags, int fd, long offset);
int munmap(void* addr, unsigned long length);
int mprotect(void* addr, unsigned long len, int prot);

#endif
