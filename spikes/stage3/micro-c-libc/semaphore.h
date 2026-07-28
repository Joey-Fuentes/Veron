/* micro-c: minimal semaphore.h. One sem_t in the pinned tree, in code we do
 * not build; opaque is enough. */
#ifndef _MICROC_SEMAPHORE_H
#define _MICROC_SEMAPHORE_H
typedef struct { long __opaque[4]; } sem_t;
#endif
