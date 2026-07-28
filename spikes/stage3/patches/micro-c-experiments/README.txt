EXPERIMENTS, NOT PATCHES. DO NOT APPLY TO A BUILD THAT MATTERS.
================================================================

These are the changes that walked micro-c (our enhanced M2-Planet) from
"hangs forever on tcc.c" to "libtcc.c COMPILES, ASSEMBLES AND LINKS -- a 1.5MB aarch64 ELF".
They exist to MEASURE how far the compiler gets, and two of them are
knowingly unsound.

Applied on top of the four real fixes in ../m2-planet/, in order:

  float / double as word-sized primitives      cc_types.c
  long double as one token -> double           cc_types.c
  function-TYPE typedef, `typedef T name(a)`   cc_core.c   libtcc.h x3
  function-POINTER parameter in a prototype    cc_core.c   libtcc.h:99
  parenthesised constant expression            cc_core.c   elf.h:75
  ')' added to the constant terminator set     cc_core.c
  * / % in constant expressions                cc_core.c   tcc.h:483
  multiple declarators per struct member       cc_types.c  tcc.h:493
  bitfield LAYOUT (not access)                 cc.h,       tcc.h:504
                                               cc_types.c,
                                               cc_core.c
  '##' as one token                            cc_reader.c tcc.h:407
  token pasting during expansion               cc_macro.c
  rescan from the HEAD of an expansion         cc_macro.c  tcc.h:421
  per-line expansion bound (mutual recursion)  cc_macro.c, cc_globals.c
  pointer declarators, `T *a, *b` and         cc_types.c, tcc.h:899
    `int *seg2lc, nseg`                        cc_globals.*
  strip __attribute__((...)) from the stream   cc_macro.c, tcc.h:117
                                               cc.c
  an empty macro must not skip the next token  cc_macro.c
  ternary `c ? a : b`                          cc_core.c   tcc.h:1417, 405 uses
  cast vs parens after unary `*`               cc_core.c   tcc.h:1874
  comma operator, at STATEMENT level           cc_core.c   tcc.h:1947, 21 uses
  global char array = string literal           cc_core.c   tcc.c:32, tccpp.c:64
  '#' stringify operator                       cc_macro.c  tcctok.h:187, 77 uses
  full 0..255 byte range in global data        cc_emit.c   tccpp.c
  `sizeof x` without parentheses               cc_core.c   tccpp.c:104
  load_value error names type and token        cc_core.c   diagnostic only
  mirror_type: the MISSING THIRD indirection   cc_types.c  tccpp.c:177
  a cast applies to the POSTFIX expression     cc_core.c   tccpp.c:281
  cast with a PARENTHESISED operand           cc_core.c   tccpp.c:390
  empty `for` clauses, `for (;;)`             cc_core.c   tccpp.c:415
  a call's result carries its RETURN TYPE     cc_core.c   tccpp.c:523
  unary `*` deferred past the postfix chain   cc_core.c   tccpp.c:660
  prefix ++/-- under a dereference           cc_core.c   tccpp.c:673
  `continue` inside a switch inside a loop   cc_core.c   tccpp.c:893
  a goto label between switch cases         cc_core.c   tccpp.c:952
  comma_expression: statement, condition,   cc_core.c   tccpp.c:1536,
    and grouping parens                                  tcc.h:1996
  a function designator is a fn pointer     cc_core.c   tccpp.c:1781
  `sizeof x->y` over a member chain         cc_core.c   tccpp.c:1809
  commas in `for` init and increment        cc_core.c   tccpp.c:1946
  FLOAT LITERALS as single tokens           cc_reader.c tccpp.c:2398
  TWO-DIMENSIONAL ARRAYS, local + global    cc_types.c, tccpp.c:3428
                                            cc_core.c
  string rows in a 2D initialiser           cc_core.c   tccpp.c:3429
  adjacent literals for a pointer init      cc_core.c   tccpp.c:3596
  an inline struct defn may carry a         cc_types.c  tccgen.c:94
    declarator, `struct X {...} **p`
  STRUCT ASSIGNMENT as a word-by-word copy  cc_core.c   tccgen.c:392
  BITFIELD READ and READ-MODIFY-WRITE      cc_core.c   tccgen.c:397
  a struct is never LOADED into a register  cc_core.c   tccgen.c:895
  struct assignment to an array element     cc_core.c   tccgen.c:907
  a LOCAL struct is not loaded either        cc_core.c   tccgen.c:909
  local struct BRACE INITIALISER             cc_core.c   tccgen.c:1167
  OPERATOR TOKENIZING, bounded              cc_reader.c tccgen.c:1549
  `default:` need not come last             cc_core.c   tccgen.c:2396
  a unary operator does not PROMOTE         cc_core.c   tccgen.c:3300
  indexing yields the ELEMENT type          cc_core.c   tccgen.c:3300
  postfix ++/-- binds tighter than `*`      cc_core.c   tccgen.c:7335
  __FUNCTION__                              cc_core.c   tcc.h:1250
  aggregate members zeroed word by word     cc_core.c   tccgen.c:7732
  copy chunks must be 8/4/2/1               cc_core.c   tccgen.c:8723
  bitwise ops in constant_expression        cc_core.c   tccdbg.c:36
  `sizeof (x[0])`                           cc_core.c   tccdbg.c:82
  `sizeof ((T*)0)->member`                  cc_core.c   tccdbg.c:497
  a cast applies after postfix, deref path  cc_core.c   tccdbg.c:551
  `static` may follow the type              cc_types.c  tccrun.c:68
  comma in a do-while condition             cc_core.c   tccrun.c:296
  block-scope function declarations         cc_core.c   tccrun.c:476
  function-type typedefs are CALLABLE       cc_core.c   tccrun.c:1140
  real headers: stdio, string, unistd,      micro-c-libc/
    signal, sys/ucontext
  #undef removes EVERY definition           cc_macro.c  arm64-gen.c:252
  a struct INITIALISER is a copy            cc_core.c   arm64-gen.c:1445
  stdint limit macros                       micro-c-libc/ arm64-asm.c:1699
  global fn pointer = a function name       cc_core.c   libtcc.c:265
  comma in a `for` CONDITION                cc_core.c   libtcc.c:582
  offsetof folded at compile time           cc_core.c   tcc.h:102
  --- found by ASSEMBLING the output ---
  temps take mov only from x0               cc_core.c   M1 vocabulary
  temps cannot be add-immediate'd           cc_core.c   M1 vocabulary
  fn-pointer parameters need a DEPTH        cc_core.c   sub_x0,x17,0
  a label must not be a string's contents   cc_core.c   tccdbg.c strings

UNSOUND, AND WHY
----------------
1. float/double are REGISTER-SIZED INTEGERS here. Declarations parse, which
   is all tcc.h:49-50 needed (`extern float strtof(...)`). Any actual float
   ARITHMETIC would be integer operations on float bits -- silently wrong
   results, which is the single failure class this project exists to avoid.
   A shippable version must make operations on these types a hard ERROR, so
   declarations parse and misuse is loud.

2. constant_expression has NO PRECEDENCE LEVELS. It is right-recursive, so
   `2 * 3 + 1` evaluates as 2 * (3 + 1). That defect predates this change --
   `3 - 1 + 1` already returned 1 -- but adding * / % widened its blast
   radius from additive-only to everything. A shippable version needs real
   precedence levels, as the ordinary expression parser already has.

3. BITFIELD ACCESS IS NOT IMPLEMENTED, ON PURPOSE. Layout is: bit_offset and
   bit_width are assigned, consecutive fields pack into one storage unit, and
   `{a:5, b:1, c:2; int after;}` emits output BYTE-IDENTICAL to
   `{unsigned short unit; int after;}` -- which proves the offsets, not just
   the parse. But READING such a member would return the whole storage unit
   with its neighbours in it, and writing would clobber them, silently. So
   access is a hard ERROR instead:

       bfacc.c:2: bitfield member 'a' cannot be read or written yet

   What is left: shift right by bit_offset and mask to bit_width on read, and
   a read-modify-write on assignment. Both are per-architecture emission,
   which is why they are not here. tcc parses past tcc.h:504 without them
   because the declarations are what blocked it, not the uses.

4. THE EXPANSION BOUND IS A PLACEHOLDER FOR A HIDE SET. Rescanning from the
   head of an expansion is required -- without it a macro whose body STARTS
   with another macro never expands it, which is what made `#define addr_t
   ElfW(Addr)` fail. But rescanning from the head is also what lets mutually
   recursive macros loop:

       #define A B
       #define B A

   Blue paint does not catch that: neither body contains its own name. C
   solves it with a per-token HIDE SET -- the set of macros being expanded
   when the token was produced -- and that is the real fix. Until it exists,
   expansion is bounded PER SOURCE LINE and a runaway is a diagnostic with a
   line number rather than a hang.

   The first version of that bound was cumulative across the whole file and
   fired on arm64-asm.c's OPT_ANY_GPR, which expands two levels and
   terminates. A runaway is a property of one chain, not of a file.

5. THE DECLARATOR WORK IS THE STRONGEST PROMOTION CANDIDATE. Every form is
   verified by emitting BYTE-IDENTICAL code to its split equivalent:

       int a, b, c;      == int a; int b; int c;
       int *x, *y;       == int *x; int *y;
       int *a, b;        == int *a; int b;

   That last one matters: tcc uses the mixed form five times (`int *seg2lc,
   nseg`) alongside 107 all-pointer ones, and reusing the previous member's
   type -- the obvious implementation -- gives `nseg` a pointer type silently.
   Two earlier attempts to detect it were wrong: reading direction off the
   indirect chain, and counting stars in the type NAME, which works for
   primitives and fails for struct pointers whose name is just "T". The base
   type and the star depth are now recorded in fallible_type_name, where the
   stars are actually consumed and both are known.

6. IGNORING __attribute__ HAS ONE REAL COST, AND IT IS RECORDED RATHER THAN
   DISCOVERED LATER. Of 16 uses in the pinned tree, all but one are inside
   STRING LITERALS (tccelf.c emitting C for tcc to compile) or comments.
   `noreturn` and `format` are hints. The exception is real:

       libtcc.c:332   ALIGNED(16) unsigned char magic3[4];

   That member will not be 16-aligned. If anything depends on it, a built tcc
   is subtly wrong -- one site, known, not yet handled.

7. THE EMPTY-MACRO FIX IS THE COMPANION TO RESCAN-FROM-HEAD. `maybe_expand`
   returned token->next for an empty expansion, and since `token` already
   points past the macro name, that SKIPPED whatever followed:

       #define PUB_FUNC
       #define NORETURN __attribute__((noreturn))
       PUB_FUNC NORETURN void die(char*);   -> NORETURN never expanded

   Uniformly wrong before; inconsistent once expansions began rescanning from
   their head. Both now resume AT the next token, never past it.

8. THE TERNARY IS ROADMAP.md's LARGEST PREDICTED ITEM AND THE FIRST OF ITS
   FOUR TO BE EXACTLY WHAT IT SAID. 405 uses. It goes above assignment in
   expression(), which is where C puts conditional-expression, so `x = c ? a
   : b` still parses its left side correctly. Codegen is process_if's shape:

       cmp / cset            condition -> x0
       cbnz  -> skip
         -> TERNARY_ELSE     false arm
       mov_x0,42             true arm
         -> _END_TERNARY
       :TERNARY_ELSE
       mov_x0,7              false arm
       :_END_TERNARY

   Both arms leave the result in the same register, so the join needs nothing.
   Verified by reading the emitted M1 -- aarch64 cannot be executed here, so
   this one is inspected rather than run, unlike the layout work which is
   proven by byte-identical output.

9. `*(p)` TOOK TWO ATTEMPTS, AND THE SECOND IS THE ONE TO READ. After a unary
   `*`, seeing '(' the parser called type_name(), which HARD-ERRORS on a
   non-type -- so `*(p)++` died as "Unknown type p". tcc reaches it through

       #define dwarf_read_1(ln,end) ((ln) < (end) ? *(ln)++ : 0)

   fallible_type_name() plus delegation to primary_expr parses it. The trap is
   the dereference that follows: the first version loaded and THEN stepped
   current_target down, which emitted an 8-byte read where `*p` on a char*
   correctly emits ldrsb -- a silently wrong VALUE. The ordinary dereference
   path steps down FIRST, then loads at that type's width, and carries a
   function-pointer guard. Using that exact sequence makes `*(p)` emit
   BYTE-IDENTICAL code to `*p` for char, int, long and `**p`.

   Twice now a change here has looked right and had the wrong load width --
   bitfields were the other. Both were caught by diffing against a known-good
   equivalent, not by reading the code. That is the technique that works here.

10. THE COMMA OPERATOR GOES AT STATEMENT LEVEL, AND THAT IS THE WHOLE POINT.
    It is C's LOWEST-precedence operator, but the same character separates
    function arguments, struct declarators and initialiser lists, where it is
    punctuation. Handling it in expression() would make `f(a, b)` parse as a
    single argument. At statement level a full expression is expected, so a
    comma there can only be the operator.

    `g = 1, h = 2;` emits BYTE-IDENTICAL code to `g = 1; h = 2;`, and nothing
    is emitted to discard the left value -- each expression leaves its result
    in the return register and the next overwrites it, which is the semantics
    wanted.

    NOT COVERED: the parenthesised form, `(g = 1, 5)`. tcc does not use it --
    checked, the apparent matches are all `(tok == ',')` character literals.

11. STRING-INITIALISED GLOBAL ARRAYS were the FIRST wall this probe ever hit,
    at tcc.c:32, and could not be reached again until the preprocessor work
    landed. tccpp.c builds one from 433 lines of macro expansion:

        static const char tcc_keywords[] =
        #define DEF(id, str) str "\0"
        #include "tcctok.h"
        ;

    Adjacent literals concatenate, so the accumulation mirrors what
    primary_expr_string already does. The difference is where the bytes go:
    a string EXPRESSION gets its own STRING_ label and is referenced by
    address, while this emits under the GLOBAL's own label. Verified by
    reading the emitted M1: `:GLOBAL_STORAGE_help` / `"hello"`, and adjacent
    literals arriving as `"ab"`.

    It then hit MAX_STRING, which is a capacity limit rather than a language
    gap -- M2-Planet takes `--max-string`. The probe passes 65536.

12. STRINGIFY `#x` IS A ONE-TOKEN MATCH, not a two-token pattern: the
    tokenizer's '#' branch consumes the hash and then grabs the following
    alphanumerics, so `#x` arrives as a single token. Substitution therefore
    compares against "#" + the parameter name, alongside the existing
    parameter comparison.

    THE STRING TOKEN CARRIES ONLY ITS LEADING QUOTE -- parse_string supplies
    the terminator when bytes are emitted. Adding a closing quote here put a
    literal 0x22 INSIDE the data, and `-E` did not show it because -E prints
    raw tokens; the hex dump did. Compare emitted output, not preprocessed
    text. With that right, `STR(hello)` emits BYTE-IDENTICAL code to a
    hand-written "hello".

    Argument text is joined with single spaces, which is not what C specifies
    -- the standard preserves the original spelling. Every use in tcc
    stringifies a single identifier, where the two agree exactly. A
    multi-token argument would normalise its spacing.

13. integer_to_raw_byte_string ACCEPTED ONLY -128..127, so any global char
    array holding a value with the high bit set was rejected; tcc supplies
    158. Both ranges denote the same eight bits, so the check now takes
    0..255 as well and the encoding masks to eight bits -- otherwise -1 would
    shift in sign bits instead of encoding as FF. Verified: 158 -> 9E,
    -1 -> FF, -128 -> 80.

14. `sizeof x` WITHOUT PARENTHESES. C requires them only for a TYPE operand;
    for an expression `sizeof x` is legal, and tccpp.c:104 writes
    `pstrcpy(tmp, sizeof tmp, ...)`. The body already resolved a variable and
    computed its size -- only the mandatory '(' was in the way. Remember
    whether one was consumed, and require the matching ')' only then.
    `sizeof t` emits BYTE-IDENTICAL code to `sizeof(t)`.

15. THE TYPEDEF INDIRECTION BUG -- the best find of this stretch, and worth
    the method more than the fix.

    `mirror_type`, which builds the type record for `typedef struct X {...} X;`,
    built only TWO levels and then looped back:

        head->indirect = i;      /* T  -> T*  */
        i->indirect = head;      /* T* -> T   <-- should be T** */

    So T** resolved to T ITSELF, and `*pal` on a T** loaded sizeof(T) rather
    than sizeof(T*). create_forward_declared_struct has always built three
    levels (head / i / ii, ii->indirect = ii); the typedef path never did.

    It reproduces in three lines and the discriminator is the typedef:

        struct T { struct T* next; int a; };                        OK
        typedef struct T { struct T* next; int a; } T;              FAILS
        int f(T** pal) { T* q; q = *pal; return 0; }

    HOW IT WAS FOUND, because guessing had failed twice: teach load_value to
    name the type and token, which turned "unsupported size 48" into "of type
    'TinyAlloc' near token ','". Then eliminate -- the comma was innocent, the
    member order was innocent, each individual struct feature was innocent --
    until only the typedef was left.

    VERIFIED: the typedef'd form now emits BYTE-IDENTICAL code to the
    non-typedef'd one, and T*** still resolves correctly.

16. A CAST APPLIES TO THE POSTFIX EXPRESSION, NOT THE PRIMARY ONE. The cast
    branch called primary_expr(), which consumes only `al`, then set
    current_target to the cast type -- leaving `->p` for the caller, which
    looked the member up in the CAST type:

        ERROR in lookup_member tal_header_t->p does not exist

    at tccpp.c:281, `memcpy((tal_header_t*)al->p + 1, p, header->size)`.
    `(T*)al->p` means `(T*)(al->p)`, so calling postfix_expr() is the fix.

    It also shows why the shared-type-record theory in the previous entry was
    WRONG. `tal_header_t` really did have no member `p` -- the parser was
    asking the wrong type. Two-typedef reproductions passed because the
    trigger was never the typedefs; it was the cast. The first fix attempt
    went into primary_expr_variable, which is not even on this path, and a
    debug print showed it never ran. Instrument before editing.

17. A CAST WHOSE OPERAND IS PARENTHESISED, under a dereference:

        *(nwchar_t *)(cstr->data + size - sizeof(nwchar_t)) = ch;   tccpp.c:390

    After consuming the cast the code expected an identifier and found '(' --
    "( is not a defined symbol". Same delegation the no-cast branch uses, with
    the cast type applied before the dereference walk.

    STORE WIDTH CHECKED, because it has been wrong twice before. The cast form
    and the equivalent `q = (T*)(d+n); *q = 5;` emit the SAME store for char,
    int and long -- all str_x0. That 8-byte store for an int* is pre-existing
    M2-Planet behaviour, not something this change introduced, and it is worth
    knowing separately: assignment through a pointer appears to use register
    size rather than the pointed-to type.

18. EMPTY `for` CLAUSES. `for (;;)` at tccpp.c:415 has all three empty. The
    INIT clause already handled it; the condition and increment called
    expression() unconditionally and died on ';' and ')'.

    Skipping the EXIT JUMP matters as much as skipping the expression: an
    empty condition is always true in C, so emitting jump-if-zero on whatever
    happened to be left in the register would end the loop on the previous
    statement's value. Verified in the emitted M1 -- no "Jump to end" at all,
    so the break is the only exit -- and an ordinary three-clause `for` emits
    code IDENTICAL to the pre-change build.

19. A CALL'S RESULT HAD NO TYPE. declare_function registered every function
    with sym_declare(..., NULL, ...), so after a call current_target kept
    whatever the last ARGUMENT left behind:

        tok_alloc(str, strlen(str))->tok            tccpp.c:523
        ERROR in lookup_member char*->tok does not exist

    `char*` being the type of `str`. The declared return type was already in
    scope at the only call site, so it just needed passing through.

    Verified by offset rather than by "it compiles": `alloc(s)->len` and
    `t = alloc(s); t->len` both emit +8 for the second member.

    Instrumenting first was again what found it -- printing s->type showed
    NULL, where the guess would have been that the type was simply wrong.

20. A UNARY `*` BINDS LOOSER THAN A POSTFIX ACCESS, the same lesson the cast
    taught two entries ago. `*bf->buf_end` means `*(bf->buf_end)`, but the
    star was applied to `bf`, loading the whole struct:

        *bf->buf_end = CH_EOB;                      tccpp.c:660
        unsupported size 1125 of type 'BufferedFile' near '->'

    Deferring it to postfix_expr -- which runs after postfix_expr_stub's
    recursion finishes -- is the fix. TWO THINGS WENT WRONG ON THE WAY, both
    caught by comparing emitted code against the `t = bf->buf_end; *t = 7;`
    equivalent rather than by whether it compiled:

    (a) An ASSIGNMENT TARGET must not be loaded. The first version emitted
        `ldrb` -- one byte of an eight-byte pointer -- and then stored through
        the truncated address. The ordinary path guards this with
        is_assignment; the deferred path needed the same guard.

    (b) The is_assignment branch applies the dereference ITSELF, so leaving
        the deferred count set made postfix_expr apply it a SECOND time. That
        broke `*pal = al` and sent tcc BACKWARDS from line 660 to 177 -- a
        regression in a case that had passed for six rounds, caught only
        because the local test files are re-run every time.

    Both write and read now match the temp-variable equivalent exactly.

21. A PREFIX ++/-- UNDER A DEREFERENCE. `*++file->buf_ptr` at tccpp.c:673 is
    `*(++(file->buf_ptr))`. The stars are consumed first and the function then
    expects an identifier, so it died on "++ is not a defined symbol".
    primary_expr already has the prefix handler and it already calls
    postfix_expr, so this delegates to it and applies the dereference after --
    the same shape as the parenthesised-operand case.

    COMPARING AGAINST `++file->buf_ptr; ch = *file->buf_ptr;` WOULD HAVE BEEN
    WRONG: that form re-reads the member and legitimately emits more work. The
    exact equivalent is `q = ++file->buf_ptr; ch = *q;`, and against that the
    counts match. Picking the right comparison matters as much as making one.

22. `continue` INSIDE A `switch` WAS BANNED, and the ban was load-bearing.
    process_switch did

        continue_target_head = NULL; /* don't allow continue in switch */

    which is not C -- continue targets the enclosing LOOP, break targets the
    switch. But simply removing the line would have been wrong: continue built
    its label from break_target_func/num, which the switch OVERWRITES with its
    own id, so the jump would have gone to the switch.

    So continue now carries its own func/num, saved and restored at all four
    sites that scope it. Verified in the emitted labels rather than by
    compiling:

        continue -> &FOR_ITER_f_0      the LOOP's iteration label
        break    -> &_SWITCH_END_f_1   the SWITCH's end

23. A GOTO LABEL BETWEEN SWITCH CASES.

        break;
    _default:
        default:                                    tccpp.c:952

    `_default:` is a goto target, not a case. process_case RETURNS after a
    `break`, so the label lands back in process_switch's dispatch loop, which
    accepted only case/default/}. statement() has handled labels all along --
    this loop simply never saw one. Emit it in place and carry on.

    Worth 584 lines: tccpp.c:952 -> 1536, the largest single jump of the run.

24. THE COMMA OPERATOR, PROPERLY THIS TIME. Entry 10 put it at statement
    level and recorded that the parenthesised form was uncovered and looked
    unused by tcc. Half right: it was uncovered, and tcc uses it twice over.

        while (next(), tok != TOK_EOF)              tccpp.c:1536
        #define tcc_warning_c(sw) TCC_SET_STATE((
            tcc_state->warn_num = ... , _tcc_warning))    tcc.h:1996

    The earlier check grepped for `(x = ..., ...)` shapes and found only
    `(tok == ',')` character literals -- it missed a controlling expression
    and a macro body, both different shapes.

    So there is now one comma_expression() helper, used at all THREE positions
    where C expects a full expression: a statement, a controlling expression
    (while/if), and inside grouping parens. It stays out of expression()
    itself, because the same character separates function arguments, struct
    declarators and initialiser lists -- `f(a, b)` must remain two arguments,
    and is checked every round.

    The second of those reported tcc.h:1996 -- where the macro is DEFINED, not
    where it is used. A line number in a header is not always a wall in that
    header.

25. A FUNCTION DESIGNATOR USED AS A VALUE IS A FUNCTION POINTER.
    load_address_of_variable_into_register already emitted the function's
    address but left current_target alone -- unlike the global branch right
    below it -- so calling through the result failed:

        tcc_warning_c(warn_all)("#pragma %s ignored", ...)      tccpp.c:1781
        Attempted to use operator ( on non-function pointer -- type 'int'

    tcc_warning_c expands to `(..., _tcc_warning)` and the call applies to
    that result. One line, found by making the error print the type it saw.

26. `sizeof x->y` OVER A MEMBER CHAIN. The earlier paren-less sizeof handled
    bare variables; `sizeof file->filename` (tccpp.c:1809) resolved only the
    base and then looked `filename` up in whatever followed. Walking the
    member chain is compile-time only, nothing emitted. Both `sizeof f->m`
    and `sizeof(f->m)` yield 40 for a `char[40]` member.

27. COMMAS IN `for` INIT AND INCREMENT -- `for (n = 0, q = ...; *q; ++q)` at
    tccpp.c:1946. The fourth and fifth positions taking comma_expression.

28. FLOAT LITERALS ARE ONE TOKEN. Digits share the identifier character set,
    so `79228162514264337593543950336.0L` came out as three tokens -- the
    digits, a '.', and `0L` -- and the parser read the dot as a member access:

        ERROR in lookup_member double->0L does not exist     tccpp.c:2398

    The token now absorbs a decimal point, an exponent (signed included) and
    any suffix letters, but ONLY when it started with a digit -- so `x.y`
    stays a member access, which is checked every round.

    WHAT THIS IS AND IS NOT. It is lexical: tcc's float-parsing code now
    PARSES. It is not float arithmetic. micro-c still maps float, double and
    long double to one word-sized integer type, so any of that code would
    compute nonsense if run. Entry 1's warning is unchanged and now matters
    more, because the code that would hit it is no longer unreachable.

29. THE LIBC SURFACE GREW TO MATCH. Three headers, all measured from what tcc
    actually references:

      math.h    fabs, ldexp, ldexpl, pow, frexp
      stdlib.h  the standard set plus strtod/strtof/strtold
      time.h    time, localtime, and exactly the six struct tm fields
                tccpp.c reads for __DATE__ and __TIME__

    stdlib.h had to become COMPLETE rather than additive: micro-c-libc is
    searched before M2libc, so a header here shadows instead of extending.
    That is not a fork -- these are the C standard's signatures, and the
    implementations still come from whatever supplies the runtime.

30. TWO-DIMENSIONAL ARRAYS. `char m[12][4]` is an array of 12 things each 4
    chars wide. micro-c carries ONE element count per declarator, so the inner
    dimension had nowhere to live.

    FLATTENING TO char[48] WOULD HAVE BEEN WRONG, not merely lossy: indexing
    strides by current_target->type->size, so m[i] would step by 1 instead of
    4 -- right total size, wrong address, silently.

    TWO synthetic levels are needed, not one, because postfix_expr_array takes
    its stride from current_target->type->size and only THEN steps down:

        m -> wrapper(size 4) -> row(size 4) -> element(size 1)
             stride = wrapper->type->size = 4      then current_target = row
             stride = row->type->size     = 1

    A self-referential row gives 4 twice; a row pointing straight at the
    element gives 1 twice. Verified: `char m[12][4]` reserves 48 bytes (same
    as char[48]) and m[2][3] computes 2*4 + 3*1 = 11.

    The global path needed the storage size RECOMPUTED -- it was calculated
    from the first dimension a dozen lines before the second is parsed, so it
    allocated 12 bytes instead of 48.

31. STRING ROWS IN A 2D INITIALISER -- `{"Jan", "Feb", ...}`. Each element
    fills a whole row, so the bytes are emitted and padded to the row width.
    Without the padding the rows run together and every index past the first
    is wrong while the total size still looks right. Verified byte by byte:
    4A 61 6E 00 / 46 65 62 00 / 4D 61 72 00.

32. ADJACENT LITERALS FOR A POINTER INITIALISER --
    `static const char * const x = "a\0" "b\0" ...` at tccpp.c:3596. The
    pointer path existed but consumed only the first literal. Third place this
    same concatenation rule has had to be written; primary_expr_string and the
    array initialiser were the others.

MILESTONE: tccpp.c PARSES COMPLETELY -- all 3,900+ lines. Four files done:
tcc.h, libtcc.h, elf.h, tcctok.h and now tccpp.c. Now in tccgen.c.

33. AN INLINE STRUCT DEFINITION MAY CARRY A DECLARATOR.

        static struct switch_t {
            struct case_t { int64_t v1, v2; int ind, line; } **p; int n;
        };                                              tccgen.c:94

    fallible_type_name RETURNED straight out of create_struct, skipping the
    '*' loop at the bottom of the function, so `**p` was never consumed and
    the member list died on "Missing ;". The named-struct path needs a
    require_extra_token to eat the tag; this path must not, because
    create_struct has already eaten both tag and body -- so the star loop is
    repeated inline rather than shared.

34. STRUCT ASSIGNMENT IS A COPY, NOT A STORE. `char_pointer_type =
    char_type;` at tccgen.c:392 is 16 bytes; store_value(16) is where it
    failed.

    It turned out smaller than it looked. A struct variable never gets LOADED
    -- micro-c skips the load whenever the size exceeds a register, which is
    the same guard that makes struct member access work -- so both sides
    already arrive as ADDRESSES. The work is then a word-by-word copy.

    REGISTER_TEMP and TEMP2 make it a plain loop: TEMP holds the source,
    TEMP2 the destination, ZERO carries each word. ZERO and ONE alone cannot
    do it, because the load clobbers the very pointer it loads through.

    Verified by reading the emitted copy and by chunk count: a 16-byte struct
    emits two load/store pairs, a 24-byte struct three, and both pointers
    advance by a word each time.

35. BITFIELD ACCESS -- THE DEBT FROM WALL 12, PAID.

    The error planted there fired exactly as intended, at tccgen.c:397:
    `func_old_type.ref->f.func_call = FUNC_CDECL;`. Layout had been done and
    proved byte-identical; access was left as a HARD ERROR rather than a read
    that silently returned the whole storage unit with its neighbours in it.

    READ is `(unit >> off) & ((1 << width) - 1)`. The macros take dest x0 and
    first source x1, so each step moves the running value into ONE and the
    operand into ZERO. For `b:3` after `a:5` this emits

        ldrh_w0,[x0]   lsr by 5   and with 7

    WRITE is a read-modify-write, and it lives in expression()'s '=' branch
    because that is the only place holding BOTH the address and the new value:

        unit = (unit & ~(mask << off)) | ((value & mask) << off)

    Verified in the emitted clear mask: 65311 = 0xFF1F, which is exactly
    ~(7<<5) within a 16-bit unit, with ldrh in and strh out.

    ONE TRAP: the unit width is i->type->size, NOT i->size. The layout work
    made only the field that OPENS a unit carry its size, so a packed field
    reports 0 -- and load_value(0) is not a load. The declared type is the
    unit.

36. A STRUCT IS NEVER LOADED INTO A REGISTER. Member access has had that
    guard all along; the nine dereference sites did not, so `x = *p` for a
    struct tried load_value(16) at tccgen.c:895. Dereferencing a struct
    pointer yields its ADDRESS, which is what every other struct path already
    assumes.

37. STRUCT ASSIGNMENT TO AN ARRAY ELEMENT -- `vtop[0] = vtop[-1]` at
    tccgen.c:907, 60 bytes. The size comes from current_target->type there,
    the same place the ordinary indexed store reads it.

38. A LOCAL STRUCT IS NOT LOADED EITHER. The dereference sites were guarded
    in entry 36; this is the plain-variable path, which loads
    current_target->size for a LOCAL or ARGUMENT. For a struct that is 16, so
    `vtop[0] = tmp` failed at tccgen.c:909 where tcc swaps two SValues through
    a local. Four places now know the same rule -- member access, dereference,
    local, argument -- which suggests it wants to be one predicate rather than
    four copies, if this were being written properly rather than measured.

39. LOCAL STRUCT BRACE INITIALISERS -- `CType ct = { VT_ASM_FUNC, NULL };` at
    tccgen.c:1167. Walk the members in order, store each initialiser at its
    own offset, and ZERO the ones left out: an incomplete initialiser zeroes
    the rest in C, and skipping that would leave stack garbage in the tail of
    the struct, silently.

    Store widths match field-by-field assignment exactly, so the initialiser
    inherits micro-c's existing behaviour rather than inventing its own.

40. THE OPERATOR TOKENIZER ABSORBED ANY RUN OF "<=>|&!^%".

        temp_var=&arr_temp_local_vars[i];            tccgen.c:1549

    tokenized `=&` as ONE token. Worth 847 lines when fixed -- tccgen.c:1549
    to 2396, the largest single jump of the whole run.

    HOW IT HID FOR FIFTY-FOUR WALLS: every reproduction written by hand had
    spaces around the '=' and passed. I chased "global vs local pointer" and
    "struct vs int" for three rounds because those were the differences
    between my repros and tcc's line. The discriminator was WHITESPACE. What
    found it was making the statement error print the token it stopped on --
    `=&` -- rather than narrowing by guesswork.

    The fix spells out the valid combinations (== != <= >= |= &= ^= %= << >>
    && || <<= >>=) instead of approximating them with a character class.

41. `default:` NEED NOT COME LAST. The default branch collected statements
    straight through to '}', so a `case` after it hit statement() as an
    undefined symbol.

    Fixing it moved the jump that skips the jump-table OUT of the default
    branch to after the whole body, which is where it belongs. Two things
    were wrong before: emitting it at the end of default cuts the legal
    fall-through from default into a following case, and a switch with NO
    default emitted no such jump at all -- running its last case's statements
    straight into the comparison table.

42. A UNARY OPERATOR MUST NOT PROMOTE AGAINST THE PREVIOUS TYPE.
    common_recursion ends with promote_type(current_target, last_type), which
    is right for a BINARY operator and wrong for a unary one -- last_type is
    simply whatever was current before. In

        vtop->c.ld = -(long double)-vtop->c.i;      tccgen.c:3300

    that is `double` from the left-hand side, so the operand came back as
    double and the following `->c` was looked up in it.

    Setting current_target to integer first only MOVED it --
    promote_type(SValue*, integer) picks integer. The answer is not to promote
    at all: unary minus and logical not now do common_recursion's
    push/parse/pop WITHOUT its final promotion, so the result keeps the
    operand's type.

43. INDEXING YIELDS THE ELEMENT TYPE, WHATEVER FOLLOWS. Only a following '['
    stepped current_target down, so `p[0]->v2` on a `struct case_t **p` left
    it at the double pointer.

    Worth 4,035 lines: tccgen.c:3300 -> 7335.

    THE COMMA DECLARATORS WERE A RED HERRING. The failing member was the
    second of `long v1, v2;`, so two rounds went into whether multiple
    declarators registered for lookup. Testing p[0]->v1 -- the FIRST member --
    proved them innocent in one line. Test the thing you believe works, not
    just the thing that failed.

44. POSTFIX ++/-- BINDS TIGHTER THAN UNARY '*'. `sw->sv = *vtop--` is
    `*(vtop--)`: the POINTER is decremented, not the struct it points at.
    Simply missing from the deferral list alongside -> . and [.

    It then needed the struct guard in a THIRD deferred-dereference loop --
    postfix_expr_inc_or_dec has its own, beside the ones in
    primary_expr_variable and postfix_expr. Three copies of one rule.

45. __FUNCTION__ IS NOT A PREPROCESSOR MACRO. __LINE__ and __FILE__ live in
    lookup_macro because their values are known while preprocessing; the
    enclosing function's name is not known until parsing, so it belongs in
    primary_expr. tcc reaches it through tcc_internal_error at tcc.h:1250.
    Emits "myfunc" for a function named myfunc.

46. AN AGGREGATE MEMBER CANNOT BE STORED IN ONE GO. `Sym aref = {0};` at
    tccgen.c:7732 -- Sym's members include structs, so a member store hit 16
    bytes. Zeroing writes a word at a time.

    ONLY the zero case: storing a non-zero value into an aggregate member
    would need a copy from a source address, and there is no source here, so
    that path stops rather than writing one word and calling it done.

47. A COPY CHUNK MUST BE A SIZE THE MACHINE CAN LOAD -- 8, 4, 2 or 1.

    `AttributeDef ad, adbase; ad = adbase;` at tccgen.c:8723. AttributeDef is
    27 bytes, so the struct copy did 8+8+8 and then asked for a 3-byte tail.
    load_value(3) is not an instruction.

    THE ERROR READ "unsupported size 3 ... of type 'AttributeDef'", WHICH
    LOOKED LIKE A BROKEN LAYOUT. Two rounds went into whether bitfield structs
    were sizing wrong. Instrumenting create_struct showed the layout was
    perfect -- 2, 8, 8, 8, 8, 8, 1 summing to 43 -- and the fault was in the
    COPY I wrote three rounds earlier, which only ever ran on multiples of 8
    until now.

    Fixed in both places that chunk: the struct copy and the aggregate-member
    zeroing. A 27-byte struct now copies as 8+8+8+2+1.

MILESTONE: tccgen.c PARSES COMPLETELY -- all 8,917 lines, the largest file in
the compilation unit. Six files done: tcc.h, libtcc.h, elf.h, tcctok.h,
tccpp.c and tccgen.c. Now in tccdbg.c.

48. THE BITWISE OPERATORS IN constant_expression -- `| & ^ << >>`, which
    entry 10 left out when it added * / %.

    WORTH SAYING PLAINLY: this was not tcc using an exotic construct in a new
    file. constant_expression is a SECOND, much smaller expression parser than
    the real one, and it shipped knowing only + and -. Every addition to it so
    far has been in response to a wall. This completes the integer set so the
    rest do not arrive one at a time.

    Precedence is still absent, and now matters more: `a | b & c` evaluates
    right to left, which is wrong for operators of genuinely different
    precedence. Recorded, not fixed.

49. `sizeof (x[0])` -- the idiom C uses to count array elements, so it appears
    wherever a table is declared. The index is parsed and discarded, since
    sizeof asks about the type.

    INDEXING DROPS THE ARRAY COUNT, it does not step the type: for
    `struct D tbl[8]` the element type IS D, and the array-ness lives in
    array_modifier. Stepping the type gave sizeof(tbl[0]) == sizeof(tbl).
    Verified: 128/16 = 8 elements, 80/8 = 10 elements.

50. `sizeof ((T*)0)->member` -- the size of a member without an instance. The
    '(' after sizeof was NOT its delimiter; it opened a cast expression, and
    the member walk continues after the closing paren.

51. A CAST APPLIES AFTER THE POSTFIX -- IN THE DEREFERENCE PATH TOO.
    primary_expr's cast branch learned this at tccgen.c:281; the dereference
    path kept its own copy and had to learn it again at
        (*(uint8_t*)section_ptr_add((s), 1) = (data))   tccdbg.c:551

52. `static` MAY FOLLOW THE TYPE. `#define TCC_SEM(s) TCCSem s` with
    `TCC_SEM(static rt_sem)` expands to `TCCSem static rt_sem;`, which C
    allows -- storage class and type specifiers may appear in any order.

53. COMMA IN A do-while CONDITION -- `} while (++p, f);`. The sixth and last
    controlling-expression position to take comma_expression.

54. FUNCTION DECLARATIONS AT BLOCK SCOPE -- `void __clear_cache(void*, void*);`
    inside a function body. Skipping it entirely was not enough: the CALL is
    the next line, so it has to be registered in the global function list.

55. FUNCTION-TYPE TYPEDEFS MUST BE MARKED CALLABLE. Entry 3 registered them
    pointer-sized, which was enough to PARSE the declaration and not enough to
    call through one -- postfix_expr_stub refused the '(' on a
    non-function-pointer at tccrun.c:1140.

56. FIVE REAL HEADERS REPLACED STUBS: stdio (the whole printf family, which
    M2libc lacks), string (strerror), unistd (environ, getcwd), signal, and
    sys/ucontext.

    THE LAST TWO HAVE LAYOUTS THAT MUST MATCH THE KERNEL, not merely parse.
    ucontext mirrors Linux arm64's sigcontext because tcc's backtrace reads
    mcontext.pc and regs[29] out of it; the signal numbers and si_code values
    are ABI. A wrong value there installs a handler for the wrong signal --
    the kind of thing that looks fine until something crashes. Every field is
    explicitly sized, because micro-c's 8-byte `int` would otherwise corrupt
    any struct declared with plain ints.

MILESTONE: SIX .c FILES PARSE COMPLETELY -- tccpp.c, tccgen.c, tccdbg.c,
tccasm.c, tccelf.c and tccrun.c, plus all four headers. Now in arm64-gen.c,
the backend.

57. `#undef` REMOVED ONLY THE FIRST DEFINITION.

    A #define does not replace an existing entry -- it PREPENDS a new one --
    so a macro defined N times has N entries and lookup finds the newest.
    remove_macro returned after unlinking one, leaving the older ones live and
    the symbol still defined.

        #define X poison
        #define X poison
        #undef X
        int X;              ->  became `int poison;`

    tcc hits it because EVERY .c file re-includes tcc.h, whose tail defines
    `_tcc_error` as a poison for files that do not set USING_GLOBALS and
    #undefs it for those that do. By arm64-gen.c there were several poison
    entries and one #undef could not clear them.

    FOUR MECHANISMS WERE TESTED AND CLEARED FIRST -- re-inclusion, guard
    skipping, nested conditionals inside a skipped guard, and the ONE_SOURCE
    nesting shape -- each in a small file, each working. The bug was in none
    of them. A #warning probe inside tcc's own arm64-gen.c is what narrowed
    it, and even that answered the wrong question at first: USING_GLOBALS is
    deliberately undefined by tcc.h after use, so "not set" was correct
    behaviour rather than the fault.

58. A STRUCT INITIALISER IS A COPY, NOT A STORE -- `CType type = *func_type;`
    at arm64-gen.c:1445. The ASSIGNMENT path learned this at tccgen.c:392; the
    DECLARATION path kept its own store and had to learn it separately. That
    is the eighth place carrying its own copy of "a struct is used by address".

59. stdint LIMIT MACROS. M2libc's stdint.h is empty -- the fixed-width types
    are built into M2-Planet -- so this ADDS rather than shadows. Written in
    HEX: micro-c folds constants as signed 64-bit, so the decimal spelling of
    UINT64_MAX would overflow, and the hex form is the same bits.

60. A GLOBAL FUNCTION POINTER MAY BE INITIALISED WITH A FUNCTION NAME:
        static void *(*reallocator)(void*, unsigned long)
            = default_reallocator;                libtcc.c:265
    The pointer branch took "string", 0 and &name but not a bare function --
    the ordinary way to fill a function pointer. A designator IS its address,
    so it emits the same &FUNCTION_ reference.

61. COMMA IN A `for` CONDITION -- `for (p = in; c = *p, c != 0 && ...; ++p)`.
    Init and increment already took comma_expression; the middle clause was
    the one still missing. Seven positions now.

MILESTONE: EVERY INCLUDED FILE PARSES -- tccpp.c, tccgen.c, tccdbg.c,
tccasm.c, tccelf.c, tccrun.c, arm64-gen.c, arm64-link.c and arm64-asm.c, plus
all four headers. What remains is libtcc.c's own body.

62. offsetof, FOLDED AT COMPILE TIME. Two pieces were missing:

    A CAST IN A CONSTANT EXPRESSION -- offsetof wraps its result in
    `(size_t)`, and a cast does not change a compile-time value. Told apart
    from grouping parens by trying fallible_type_name and rewinding.

    `&((T *)0)->field` -- taken relative to a null pointer, that address IS
    the member's byte offset, which is the whole point of the idiom. Folding
    it emits no code; it reads the offset out of the type. Verified: 0, 8, 16
    for `int a; long b; long c;`.

=============================================================================
MILESTONE: micro-c COMPILES THE WHOLE OF libtcc.c.

    rc=0, nothing on stderr, 36 seconds
    350,808 lines of output -- 695 functions, 310 globals

That is the entire ONE_SOURCE unit: tccpp.c, tccgen.c, tccdbg.c, tccasm.c,
tccelf.c, tccrun.c, arm64-gen.c, arm64-link.c, arm64-asm.c and libtcc.c's own
body, plus tcc.h, libtcc.h, elf.h and tcctok.h. Roughly 34,000 lines of C.

WHAT THIS IS NOT. It PARSES and EMITS; nothing has been assembled, linked or
run. The unsound items in this file are unchanged and now matter more, not
less, because there is finally output to be wrong:

  - float, double and long double are one word-sized INTEGER type. Any float
    arithmetic in that output computes nonsense.
  - `int` is EIGHT bytes, so every call into a runtime compiled by anything
    else has the wrong ABI.
  - constant_expression still has no precedence: `a | b & c` folds right to
    left.

=============================================================================
THE OUTPUT ASSEMBLES. M1 rc=0, 332,893 lines of hex2.

Running M1 over it found FIVE real bugs that parsing never could. Every one
had emitted happily for the whole run:

63. `mov_x15,x1` AND `mov_x16,x1` DO NOT EXIST. M2libc's aarch64_defs.M1
    defines mov INTO x15/x16 only from x0. The struct copy, the struct
    initialiser copy and the bitfield write all moved x1 straight into a temp.
    Routed through x0 instead.

64. THE TEMPS CANNOT BE ADD-IMMEDIATE'D. There is no `add_x16,x14,x16`, so
    emit_add_immediate cannot be pointed at x15/x16 -- which the copy loops
    did to advance their pointers. What IS defined is `add_x0,x16,x0`, so
    emit_advance_temp round-trips through x0.

65. A FUNCTION-POINTER PARAMETER NEEDS A STACK DEPTH. Entry 4 registered the
    name, which was enough to parse and enough to reference, but left depth 0
    -- and `sub_x0,x17,0` is not in the vocabulary at all, since argument
    offsets start at 8. Three functions in tcc take one (expr_type,
    list_elf_symbols, tcc_list_symbols) and M2-Planet's own source has NONE,
    which is why nine hundred regression runs never saw it.

66. A LABEL MUST NOT BE A STRING'S CONTENTS. global_value_selection used the
    text of a string as its symbol name, which works only while every such
    string is a plain identifier. tccdbg.c has
        "long int:t3=r3;-9223372036854775808;9223372036854775807;"
    and M1 rejected the label outright. A generated id is valid and unique.

WHAT THE VOCABULARY LESSON IS. Four of these are the same mistake: I wrote
emission that was correct aarch64 and not in the target's macro set. The M1
vocabulary is much narrower than the instruction set, and nothing in parsing
or in the byte-identical regression could tell me -- M2-Planet's own sources
never exercise those combinations.

STILL NOT LINKED. hex2 stops on `FUNCTION___init_malloc`, which libc-full.M1
REFERENCES but does not DEFINE -- a gap in the vendored M2libc, not in our
output. Worth remembering that M1 and hex2 are scaffolding here: the plan
replaces both with the .s0 backend, and they are being used only because they
can validate what parsing cannot.

IT LINKS.

    micro-c    libtcc.c        ->  350,951 lines of M1
    micro-c    all of M2libc   ->   25,837 lines, 242 functions
    M1         everything      ->  332,893 lines of hex2, rc=0
    hex2       + ELF header    ->  1,489,312 bytes, rc=0

    ELF64, EXEC, AArch64, entry 0x400078 -- structurally valid.

WHAT IT TOOK. A compiled libtcc.c references 742 functions and defines 695,
leaving 59 undefined. M2libc -- itself compiled by micro-c, which is its own
result -- covers 34. The other 25 are in impl/stubs.c and every one of them is
DELIBERATELY WRONG: strtoX returns 0, setjmp/longjmp do nothing, qsort does
not sort, the signal and semaphore calls are no-ops. A tcc linked against that
starts and does not work.

The stub file also supplies main, because libtcc.c is a LIBRARY and the ELF
entry point needs one. tcc.c has the real main and does not compile yet.

WHY DO IT ANYWAY. The link is the only thing that answers "does every symbol
exist and resolve", and it produced a precise list of what a real runtime
owes: 25 functions, of which the interesting ones are setjmp/longjmp (needs
assembly), the strtoX family, qsort, and the float parsers -- which micro-c
could not compile correctly regardless, since float is still a word-sized
integer.

NOT RUN. This container is x86_64 with no qemu, so execution is untested. The
binary's structure is valid; its behaviour is unknown and, given the stubs and
the unsound items above, would not be correct yet.
=============================================================================
=============================================================================

STOPPED AT: tcctools.c:60 for the FULL DRIVER. tcc.c includes tcctools.c on
top of libtcc.c and hits a string in a constant expression there. libtcc.c is
the library; tcc.c is the command-line front end.

MILESTONE: EVERY HEADER PARSES -- tcc.h, libtcc.h, elf.h and tcctok.h. The
walls are now inside tccpp.c, the first .c file reached.

MILESTONE: tcc.h PARSES COMPLETELY. All 2013 lines. It had been the wall for
fifteen consecutive rounds; the remaining walls are in other files.

The other seven look sound and are candidates for promotion once reviewed.
The declarator one is the strongest candidate: `int a, b, c;` now emits
output BYTE-IDENTICAL to `int a; int b; int c;`, which proves the member
offsets rather than only the parse.

WHAT THIS BOUGHT
----------------
Eighty-one walls between a hanging compiler and tcc's first genuinely large
feature, each with a file and line.

A LABEL THAT WAS WRONG, RECORDED BECAUSE THE MISTAKE IS INSTRUCTIVE. Wall 11
was called "anonymous union" because that is what surrounded the error. It
was not. Plain anonymous unions already worked, and anonymous structs nested
inside them work too -- the failure was `int jtrue, jfalse;`, multiple
declarators in one member, which build_member never handled. Three test
files settled it in under a minute. Reading the context around an error and
naming the wall after it is not the same as isolating the cause. ROADMAP.md's static census predicted
ternary, bitfields, float/double and stack aggregate init. Ternary and
bitfields have not appeared at all; float turned out to be two extern
declarations rather than arithmetic. The list a compiler produces and the
list a regex produces are not the same list.

=============================================================================
WHY THE PATCH SERIES FAILED IN CI, AND WHAT IT HID

TWO MISTAKES IN HOW THESE PATCHES WERE GENERATED, both mine, both invisible
to the local checks because the local checks shared the mistake.

  1. WRONG BASE. Every patch was diffed against spikes/reference/m2-planet --
     an OLDER vendored M2-Planet -- while CI applies them to the pin, bd2fe4b.
     The two differ by dozens of lines per file. 0001 and 0002 happened to
     apply to both; 0003 did not, and CI stopped there. The "applies cleanly
     from a fresh tree" check I ran after every batch was checking the wrong
     tree.

  2. HARDCODED FILE LIST. Patch generation enumerated nine source files by
     name. cc_emit.h was not among them, so a changed function signature never
     made it into the series: the tree applied and then failed to COMPILE.
     Generation now DISCOVERS every differing file instead.

Both are the same class of error -- a verification step that shares an
assumption with the thing it verifies cannot catch that assumption being
wrong.

=============================================================================
THE ALIGNMENT BUG

The ladder said: 248-byte binary RAN, every larger one SIGBUS. That looked
like size, and size is not a cause. Reading the entry point settled it:

    ldr  w16, #8
    b    #8
    <literal>        <- main's address
    blr  x16

    248-byte binary   main = 0x004000e4   aligned
    14,478-byte one   main = 0x0040387a   NOT aligned
    1.4MB one         main = 0x0055f032   NOT aligned

aarch64 requires instruction addresses to be a multiple of four. A branch to
an odd address is SIGBUS -- exactly the signal seen, on every rung above the
first.

TWO CAUSES, BOTH NEEDED FIXING:

  - micro-c's global STRING initialisers wrote an arbitrary number of bytes
    and did not pad. Every other global path calls
    global_pad_to_register_size; the string paths, added later in this series,
    did not. That is my bug.

  - CONCATENATING objects puts one object's string pool immediately before the
    next object's code. micro-c emits code then strings per object, which is
    correct for a single translation unit and wrong the moment objects are
    joined. The workflow now splits at the marker and emits all code first.

WHAT THIS COST: eight rungs of link-set bisection that all pointed at
"content", when the answer was in four bytes at a fixed offset in the ELF.
Decoding the entry point should have come first -- the ladder was measuring
a symptom that varied with size because the CAUSE varied with size.
