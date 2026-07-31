/* micro-c: fcntl.h.
 *
 * WHY OURS AND NOT M2libc's. This directory is searched BEFORE M2libc, so a
 * header here shadows rather than extends. M2libc declares
 *
 *     extern int open(char* name, int flag, int mode);
 *
 * -- three parameters, no ellipsis. micro-c does not check a call against a
 * prototype, so tcc's own two-argument form went through unnoticed:
 *
 *     fd = open(filename, O_RDONLY | O_BINARY);      libtcc.c:776
 *
 * mc-tcc is a real tcc and does check, so it stopped there with "too few
 * arguments to function". POSIX spells open variadic because the third
 * argument is the creation mode and is read only when O_CREAT is set; that is
 * the form tcc is written against and the form here.
 *
 * THE FLAG VALUES ARE COPIED FROM M2libc CHARACTER FOR CHARACTER, including
 * the octal spelling, and that is deliberate. They are the values the syscall
 * wrapper underneath actually implements, so a re-derived decimal set here
 * would be a second copy of the same constants free to drift from the first --
 * and a file opening with the wrong mode is invisible until it is not. Only
 * the DECLARATION differs from M2libc; every #define below is verbatim.
 *
 * OCTAL IS SAFE IN BOTH PARSERS, checked rather than assumed: micro-c reads
 * 00100 as 64 in its ordinary expression parser AND in constant_expression,
 * which is a second and much smaller parser that has lagged the first before.
 * If it did not, M2libc's own fcntl.h would already be misread. */
#ifndef _MICROC_FCNTL_H
#define _MICROC_FCNTL_H

/* THE __M2__ BRANCH IS M2libc's OWN AND MUST STAY, which the first version of
 * this file got wrong. M2libc's fcntl.h is not only declarations: under
 * __M2__ it pulls in <fcntl.c>, the IMPLEMENTATION of open and _open.
 * Shadowing it wholesale therefore compiled fine and silently dropped
 * _open from the output -- 95 lines of it -- which the byte-identity check on
 * micro-c's tcc unit caught immediately and nothing else would have.
 *
 * So this file only supplies the branch M2libc's #else supplies, and defers
 * to M2libc untouched when micro-c is the compiler. micro-c defines __M2__;
 * mc-tcc does not, which is exactly the distinction wanted. */
#ifdef __M2__
#include <sys/types.h>
#include <stddef.h>
#include <fcntl.c>
#else

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 00100
#define O_EXCL 00200
#define O_TRUNC 001000
#define O_APPEND 002000

#define S_IXUSR 00100
#define S_IWUSR 00200
#define S_IRUSR 00400
#define S_IRWXU 00700

/* tcc spells `| O_BINARY` on platforms with a text/binary distinction. Linux
 * has none, so it is zero and the or is a no-op. Guarded because tcc's own
 * headers define it on the targets that have one. */
#ifndef O_BINARY
#define O_BINARY 0
#endif

int open(const char* name, int flag, ...);

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#endif /* __M2__ */

#endif
