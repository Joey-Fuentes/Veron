/* micro-c: minimal time.h.
 *
 * tcc uses this for __DATE__ and __TIME__ only (tccpp.c:3424) -- time(),
 * localtime(), and the struct tm fields those two macros format. The field
 * set below is exactly what tccpp.c reads, not the whole of struct tm; the
 * layout still has to match whatever runtime supplies localtime, so this is a
 * place to check if the dates ever come out wrong. */
#ifndef _MICROC_TIME_H
#define _MICROC_TIME_H

typedef long time_t;
typedef long clock_t;

struct tm {
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
};

time_t time(time_t* t);
clock_t clock(void);
struct tm* localtime(time_t* timep);

#endif
