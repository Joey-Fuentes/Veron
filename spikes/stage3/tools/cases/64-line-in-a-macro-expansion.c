/* __LINE__ inside a macro body is the line of the INVOCATION.
 *
 * It was the line of the `#define`, so every call site reported the same
 * number. Found while instrumenting tcc:
 *
 *     #define tcc_free(ptr)  tcc_free_at(ptr, __LINE__)     tcc.h:1229
 *
 * Every tcc_free in the program reported 1229. tcc uses __LINE__ in
 * tcc_error, in MEM_DEBUG and in tcc_strdup_debug(str, __FILE__, __LINE__),
 * so every line number tcc printed was the line of a macro definition in a
 * header -- including the ones this spike has been reading as evidence.
 *
 * THE FIRST FIX WAS WRONG IN AN INSTRUCTIVE WAY. Taking the position from the
 * insertion point looks right and is right for an object-like macro. For a
 * FUNCTION-LIKE one the token pointer has already advanced past the argument
 * list by the time the splice happens, so a call on line 7 reported 8. Hence
 * probe 1 below is a function-like macro spanning to the end of its line, and
 * probe 8 is the same macro invoked with the call and the arguments on
 * DIFFERENT lines -- the case that made the off-by-one visible.
 *
 * Sequential returns, not a bitmask: the numbers here are line numbers and
 * reading a line number as a bitmask is how two earlier rounds went wrong. */
#define WHERE() here(__LINE__)
#define WHERE2(a) here(__LINE__)
int here(int n) { return n; }
int plain(void) { return __LINE__; }
int main(void)
{
	int a;
	if(WHERE() != 30) return 1;
	if(__LINE__ != 31) return 2;
	if(plain() != 26) return 3;
	a = WHERE();
	if(a != 33) return 4;
	if(WHERE2(1) != 35) return 5;
	if(WHERE2(
		1) != 36) return 6;
	return 0;
}
