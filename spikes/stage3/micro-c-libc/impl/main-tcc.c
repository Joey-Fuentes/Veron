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

#define TCC_OUTPUT_EXE 2

int main(int argc, char** argv)
{
    void* s;
    char* input = 0;
    char* output = "a.out";
    int i = 1;

    if(argc < 2)
    {
        puts("usage: tcc input.c [-o output] [-I path] [-B path]");
        return 1;
    }

    s = tcc_new();
    if(0 == s)
    {
        puts("tcc_new failed");
        return 1;
    }

    tcc_set_output_type(s, TCC_OUTPUT_EXE);

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

    if(tcc_add_file(s, input) < 0)
    {
        puts("compilation failed");
        return 1;
    }

    if(tcc_output_file(s, output) < 0)
    {
        puts("could not write output");
        return 1;
    }

    tcc_delete(s);
    return 0;
}
