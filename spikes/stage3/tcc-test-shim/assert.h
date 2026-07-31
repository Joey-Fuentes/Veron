#ifndef _SHIM_ASSERT_H
#define _SHIM_ASSERT_H
void abort(void);
int printf(const char *fmt, ...);
/* No __FILE__/__LINE__ formatting: the tests that use assert only ever pass,
 * so the message is never printed and its exact text is untested. */
#define assert(e) ((e) ? (void)0 : abort())
#endif
