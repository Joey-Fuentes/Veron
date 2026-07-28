EXPERIMENTS, NOT PATCHES. DO NOT APPLY TO A BUILD THAT MATTERS.
================================================================

These are the changes that walked micro-c (our enhanced M2-Planet) from
"hangs forever on tcc.c" to "stops on an empty header stub at tcc.h:858".
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

The other seven look sound and are candidates for promotion once reviewed.
The declarator one is the strongest candidate: `int a, b, c;` now emits
output BYTE-IDENTICAL to `int a; int b; int c;`, which proves the member
offsets rather than only the parse.

WHAT THIS BOUGHT
----------------
Sixteen walls between a hanging compiler and tcc's first genuinely large
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
