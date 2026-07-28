EXPERIMENTS, NOT PATCHES. DO NOT APPLY TO A BUILD THAT MATTERS.
================================================================

These are the changes that walked micro-c (our enhanced M2-Planet) from
"hangs forever on tcc.c" to "stops at bitfields in tcc.h:504".
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

The other six look sound and are candidates for promotion once reviewed.
The declarator one is the strongest candidate: `int a, b, c;` now emits
output BYTE-IDENTICAL to `int a; int b; int c;`, which proves the member
offsets rather than only the parse.

WHAT THIS BOUGHT
----------------
Twelve walls between a hanging compiler and tcc's first genuinely large
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
