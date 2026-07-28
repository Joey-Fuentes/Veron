/* micro-c: unistd.h.
 *
 * M2libc has a unistd.h and it covers what tcc needs, EXCEPT `environ` --
 * the process environment, which tccrun.c:217 passes to a program it runs.
 * Shadowing means this file has to carry the rest too; same reasoning as
 * stdlib.h and string.h. */
#ifndef _MICROC_UNISTD_H
#define _MICROC_UNISTD_H

#include <stddef.h>

extern char** environ;

int read(int fd, void* buf, size_t count);
int write(int fd, void* buf, size_t count);
int close(int fd);
int unlink(char* pathname);
int access(char* pathname, int mode);
int chdir(char* path);
int execve(char* path, char** argv, char** envp);
int fork(void);
int _exit(int status);
long lseek(int fd, long offset, int whence);
int getpid(void);
char* getcwd(char* buf, size_t size);
char* realpath(char* path, char* resolved);

#endif
