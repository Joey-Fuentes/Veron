/* micro-c: minimal time.h. One time_t in the pinned tree. */
#ifndef _MICROC_TIME_H
#define _MICROC_TIME_H
typedef long time_t;
typedef long clock_t;
time_t time(time_t* t);
clock_t clock(void);
#endif
