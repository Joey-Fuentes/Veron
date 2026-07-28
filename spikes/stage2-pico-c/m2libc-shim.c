/* m2libc-shim.c -- the two functions drop_asm removes that our builtins do not
 * already supply.
 *
 * At M2-Planet 1.13.1, M2libc/aarch64/linux/bootstrap.c writes six functions
 * with asm() bodies: fgetc, fputc, open, close, brk, exit. Our builtins cover
 * four of them directly -- open/close from m53, brk from m69, exit from m53 --
 * but fgetc and fputc are a level ABOVE the raw syscalls, so dropping them
 * leaves M2-Planet with no character I/O.
 *
 * They are ten lines of ordinary C over our read/write builtins, which is a far
 * smaller substitution than embedding an M1 assembler would be. This is the
 * same category as m71's omission and should be recorded in the ledger the same
 * way: a substitution, not a patch to upstream behaviour.
 *
 * Concatenate AFTER the patched bootstrap.c so the enums it defines (NULL, EOF,
 * TRUE, FALSE, stdin/stdout/stderr, EXIT_*) are already in scope, and BEFORE
 * M2-Planet's own sources.
 *
 * Semantics match the upstream asm versions: fgetc returns EOF at end of file
 * or on error and otherwise the byte as an unsigned value; fputc writes one
 * byte and returns nothing. A single shared one-byte buffer is used rather than
 * allocating per call -- M2-Planet is single-threaded and never holds a
 * character across a call.
 */

char* __shim_buf;

int fgetc(FILE* f)
{
	if(NULL == __shim_buf)
	{
		__shim_buf = calloc(2, 1);
	}

	if(read(f, __shim_buf, 1) <= 0)
	{
		return EOF;
	}

	return __shim_buf[0];
}

void fputc(char s, FILE* f)
{
	if(NULL == __shim_buf)
	{
		__shim_buf = calloc(2, 1);
	}

	__shim_buf[0] = s;
	write(f, __shim_buf, 1);
}
