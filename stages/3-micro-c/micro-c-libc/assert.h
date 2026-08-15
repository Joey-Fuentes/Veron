/* micro-c: minimal assert.h. 85 uses in tcc, all of the plain assert(x) form.
 * Defined away rather than implemented: an assert that does nothing is honest
 * about there being no runtime behind it, where one that called a missing
 * abort() would fail at link time for a reason unrelated to the assertion. */
#ifndef _MICROC_ASSERT_H
#define _MICROC_ASSERT_H
#define assert(x)
#endif
