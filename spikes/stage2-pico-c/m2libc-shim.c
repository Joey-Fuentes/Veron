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

/* fflush -- NOTHING IS BUFFERED HERE, SO THERE IS NOTHING TO FLUSH.
 *
 * hex2.c:188 calls fflush(output) before chmod-ing its result. M2libc's FILE*
 * is a bare file descriptor and fputs/fputc go straight out through the write
 * syscall, so a flush has no work to do and returning 0 is the honest answer
 * rather than a stub.
 *
 * It lives here and not by adding M2libc/stdio.c to the unit because
 * bootstrap.c already defines fopen, fclose and fputs -- pulling stdio.c in
 * would redefine all three to get this one function.
 */
int fflush(FILE* f)
{
	return 0;
}

/* fread -- ONE READ, EXACTLY AS UPSTREAM WRITES IT.
 *
 * EXPERIMENT-cc_reader.c.patch made micro-c read its input in
 * FILE_BUFFER_SIZE blocks instead of a byte at a time, and that call is
 * cc_reader.c:46:
 *
 *     file_max = fread(file_buffer, 1, FILE_BUFFER_SIZE, input);
 *
 * M2libc has fread, but in the GENERIC M2libc/bootstrap.c -- which the m71
 * rule omits from this unit -- and not in aarch64/linux/bootstrap.c, which is
 * the one drop_asm.py turns into patched_bootstrap.c. So the one function the
 * patch series needs is in the one file the unit leaves out.
 *
 * The body is upstream's, unchanged: a single read of size*count bytes,
 * returning what read returned. That is not strict ISO fread -- it reports
 * BYTES rather than items -- but it is what M2libc does and what cc_reader.c
 * is written against, and matching upstream matters more here than matching
 * the standard.
 */
unsigned fread(char* buffer, unsigned size, unsigned count, FILE* f)
{
	return read(f, buffer, size * count);
}
