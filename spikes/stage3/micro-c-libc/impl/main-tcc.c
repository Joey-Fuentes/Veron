/* THE REAL main FOR A micro-c-BUILT tcc.
 *
 * Everything before this used a probe main that called one function and
 * exited. This is tcc's actual entry point: parse argv, compile, write output.
 *
 * tcc.c has its own main, but tcc.c pulls in tcctools.c which micro-c cannot
 * yet parse (a string in a constant expression, tcctools.c:60). This is the
 * smallest driver that exercises the same path -- new, set output type, add
 * the input file, output -- so that "can it compile a file" can be asked
 * without waiting for tcctools.c.
 *
 * Usage mirrors tcc's: mc-tcc-bin input.c -o output
 */

void* tcc_new(void);
void tcc_delete(void* s);
int tcc_set_output_type(void* s, int output_type);
int tcc_add_file(void* s, char* filename);
int tcc_output_file(void* s, char* filename);
int tcc_add_include_path(void* s, char* path);
int tcc_set_options(void* s, char* str);
int strcmp(char* a, char* b);
int puts(char* s);
int write(int fd, char* buf, int count);

/* PROGRESS MARKERS. The driver segfaults somewhere between tcc_new and a
 * written output file, and a segfault says nothing about WHERE. Each call is
 * bracketed so the last marker on stderr names the last one that returned.
 *
 * write() straight to fd 2 rather than puts(), because puts goes through
 * stdio buffering and a buffer that is never flushed loses exactly the
 * evidence being collected. */
static void mark(char* s) { write(2, s, 3); }   /* 3, not 4: "D1\n" is three
                                                 * characters and writing four
                                                 * sends the NUL too, which turns
                                                 * the log into a binary file */

#define TCC_OUTPUT_EXE 2
#define TCC_OUTPUT_OBJ 3

int main(int argc, char** argv)
{
    void* s;
    char* input = 0;
    char* output = "a.out";
    int i = 1;
    int output_type = TCC_OUTPUT_EXE;

    if(argc < 2)
    {
        puts("usage: tcc input.c [-o output] [-I path] [-B path]");
        return 1;
    }

    mark("D1\n");
    s = tcc_new();
    mark("D2\n");
    if(0 == s)
    {
        puts("tcc_new failed");
        return 1;
    }

    /* OPTIONS FIRST, THEN THE OUTPUT TYPE. tcc.c does exactly this --
     * tcc_parse_args at tcc.c:301, tcc_set_output_type at tcc.c:357 -- and
     * this driver had them the other way round.
     *
     * tcc_set_output_type is what resolves the library paths and goes looking
     * for crt1.o and crti.o. Calling it before -B and -L have been applied
     * makes it search the wrong directories, and the two "file not found"
     * errors it raises set the error count, after which tcc_add_file declines
     * to do anything. Every run of this driver has ended that way, and it was
     * read as a compiler problem for several rounds. It is a driver problem:
     * four lines in the wrong order. */
    while(i < argc)
    {
        if(0 == strcmp(argv[i], "-o"))
        {
            i = i + 1;
            if(i < argc) output = argv[i];
        }
        else if(0 == strcmp(argv[i], "-I"))
        {
            i = i + 1;
            if(i < argc) tcc_add_include_path(s, argv[i]);
        }
        else if('-' == argv[i][0] && 'I' == argv[i][1])
        {
            tcc_add_include_path(s, argv[i] + 2);
        }
        else if(0 == strcmp(argv[i], "-c"))
        {
            /* -c HAS TO REACH tcc_set_output_type, NOT JUST tcc_set_options.
             * The driver used to hardcode TCC_OUTPUT_EXE and call it anyway,
             * so tcc reported "-c: overriding compiler action already
             * specified" and went on trying to link -- which needs crt1.o and
             * crti.o and fails without them. Compiling to an object asks the
             * question this spike is actually about, and asks it without a C
             * runtime present at all. */
            output_type = TCC_OUTPUT_OBJ;
        }
        else if('-' == argv[i][0])
        {
            /* -B, -D and the rest go through tcc's own option parser rather
             * than being reimplemented here. */
            tcc_set_options(s, argv[i]);
        }
        else
        {
            input = argv[i];
        }
        i = i + 1;
    }

    if(0 == input)
    {
        puts("no input file");
        return 1;
    }

    tcc_set_output_type(s, output_type);
    mark("D3\n");

    mark("D4\n");
    int addrc = tcc_add_file(s, input);
    if(addrc < 0)
    {
        /* write(), not puts(): puts goes through stdio buffering and a buffer
         * that is never flushed loses exactly the evidence being collected --
         * the same reason mark() uses write. This message was invisible for
         * one round because of it. */
        write(2, "compilation failed\n", 19);
        return 1;
    }

    mark("D5\n");
    if(tcc_output_file(s, output) < 0)
    {
        puts("could not write output");
        return 1;
    }

    mark("D6\n");
    tcc_delete(s);
    return 0;
}
