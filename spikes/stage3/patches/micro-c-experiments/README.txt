EXPERIMENTS, NOT PATCHES. DO NOT APPLY TO A BUILD THAT MATTERS.
================================================================

These are the changes that walked micro-c (our enhanced M2-Planet) from
"hangs forever on tcc.c" to "stops at the comma operator, tcc.h:1947 of 2013".
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

The other seven look sound and are candidates for promotion once reviewed.
The declarator one is the strongest candidate: `int a, b, c;` now emits
output BYTE-IDENTICAL to `int a; int b; int c;`, which proves the member
offsets rather than only the parse.

WHAT THIS BOUGHT
----------------
Twenty-two walls between a hanging compiler and tcc's first genuinely large
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
