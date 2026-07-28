/* micro-c: minimal errno.h. tcc tests errno against EINTR on interrupted IO. */
#ifndef _MICROC_ERRNO_H
#define _MICROC_ERRNO_H
extern int errno;
#define EINTR 4
#endif
