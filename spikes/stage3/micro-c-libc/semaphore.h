/* micro-c: minimal semaphore.h.
 *
 * tcc guards its own compilation with a semaphore (TCCSem in tcc.h:1944) so
 * libtcc is usable from more than one thread. It uses exactly three calls,
 * and only when CONFIG_TCC_SEMLOCK is on.
 *
 * DECLARATIONS ONLY, like everything else here -- there is no implementation
 * behind them. A built tcc single-threaded does not need real semaphores, but
 * it does need these symbols to resolve, so whatever supplies the runtime has
 * to provide them even if the bodies do nothing. */
#ifndef _MICROC_SEMAPHORE_H
#define _MICROC_SEMAPHORE_H

typedef struct { long __opaque[4]; } sem_t;

int sem_init(sem_t* sem, int pshared, unsigned int value);
int sem_wait(sem_t* sem);
int sem_post(sem_t* sem);

#endif
