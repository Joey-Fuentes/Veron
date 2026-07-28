/* micro-c: minimal sys/time.h. */
#ifndef _MICROC_SYS_TIME_H
#define _MICROC_SYS_TIME_H
struct timeval { long tv_sec; long tv_usec; };
int gettimeofday(struct timeval* tv, void* tz);
#endif
