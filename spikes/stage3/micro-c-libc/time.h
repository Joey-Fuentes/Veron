/* micro-c: minimal time.h.
 *
 * tcc uses this for __DATE__ and __TIME__ only (tccpp.c:3424) -- time(),
 * localtime(), and the struct tm fields those two macros format. The field
 * set below is exactly what tccpp.c reads, not the whole of struct tm; the
 * layout still has to match whatever runtime supplies localtime, so this is a
 * place to check if the dates ever come out wrong. */
#ifndef _MICROC_TIME_H
#define _MICROC_TIME_H

#include <stdint.h>

typedef long time_t;
typedef long clock_t;

/* EXPLICITLY SIZED, because micro-c makes `int` EIGHT bytes and struct tm's
 * layout is not ours to choose -- anything that fills one in expects the C
 * library's shape, nine 4-byte fields.
 *
 * Written with plain int this was 72 bytes with every field at twice its
 * proper offset. It has never mattered because localtime is stubbed in
 * runtime.c and returns NULL, so a caller faults on the null before it can
 * read a field. That is luck rather than design, and the layout is corrected
 * so it stays correct when localtime becomes real. */
struct tm {
    int32_t tm_sec;
    int32_t tm_min;
    int32_t tm_hour;
    int32_t tm_mday;
    int32_t tm_mon;
    int32_t tm_year;
    int32_t tm_wday;
    int32_t tm_yday;
    int32_t tm_isdst;
};

time_t time(time_t* t);
clock_t clock(void);
struct tm* localtime(time_t* timep);

#endif
