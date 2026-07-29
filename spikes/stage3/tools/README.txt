TOOLS

difftest.sh    the same C program compiled by gcc and by micro-c, both RUN,
               behaviour compared. Targets amd64, which is what this and most
               development machines are, so it needs no emulation and no CI.

regression.sh  micro-c against the reference M2-Planet on the reference's own
               sources. Replaces a check that was VACUOUS -- it compared two
               empty files and reported success on every run for the whole of
               this work.

WHY difftest EXISTS, AND WHY IT SHOULD HAVE EXISTED FIRST.

Every codegen bug found in this work was found the hard way: a CI round trip
(fetch, patch, compile 350,000 lines, assemble, link, run on an aarch64
runner, read progress markers) to narrow it to a function, then a careful read
of emitted assembly to identify it.

    array members loaded instead of decaying to an address
    array members sized by the element's TARGET type
    &s->member not loading s first
    global string data unpadded, leaving functions unaligned
    && and || not short-circuiting

Every one is a dozen lines of C that behaves differently under gcc. The cases
in cases/ are exactly those bugs, and each takes under a second to check.

The reason this did not exist is that the work was aimed at aarch64, which the
development machine cannot execute. micro-c targets amd64 too, and the
development machine is amd64. That was true from the first day.

WHAT IT FOUND ON ITS FIRST RUN:

    01-array-member          returns 1   (gcc returns 0)
    04-short-circuit         SIGNAL 11   -- known, reverted, deferred
    05-struct-assign         will not assemble: emits mov_rbx,r15, which is
                             not in M2libc's amd64 macro vocabulary
    06-global-string-align   returns 1

05 is the interesting one. The struct-copy fix was written against aarch64's
vocabulary and checked against aarch64's macro list. On amd64 it emits an
instruction that does not exist. SEVERAL FIXES IN THIS SERIES ARE
AARCH64-ONLY, and nothing until now would have said so.

HOW TO ADD A CASE. Write a C program that returns 0 when correct and a
distinct small number for each way it can fail. gcc is the reference: if gcc
does not return 0, the harness reports the CASE as broken rather than blaming
micro-c.

=============================================================================
CURRENT STATE OF THE CASES, AND WHAT EACH ONE MEANS

    01-array-member          returns 2   was 1 -- the decay is fixed, the
                                         remaining failure is s.ptr[0][0],
                                         a double index through a member
    04-short-circuit         SIGNAL 11   deferred; see
                                         patches/micro-c-deferred/
    05-struct-assign         no assemble the struct copy emits mov_rbx,r15,
                                         which amd64's macro set lacks. The
                                         fix was written and checked against
                                         AARCH64 only.
    06-global-string-align   returns 1   the padding fix is also likely
                                         aarch64-shaped

TWO OF THESE FOUR ARE PORTABILITY FAILURES IN FIXES THAT WORK ON AARCH64.
That is worth stating plainly: this series has been developed against one
architecture and verified against one architecture, and running the same code
on a second one immediately shows where that assumption leaked in.

WHAT THIS TOOL IS AND IS NOT. It is fast, local and specific -- twelve lines
of C, an exit code, a second. It is not a substitute for the CI job: it does
not build tcc, does not link 350,000 lines, and cannot see anything that only
appears at that scale. What it does is take the class of bug that dominated
this work -- ordinary C constructs compiled wrongly -- out of the CI loop
entirely.

Every case here was written FROM a bug that had already been found the slow
way. The obvious next move is to write cases for constructs that have NOT
failed yet, so the tool starts finding bugs before tcc does rather than after.

=============================================================================
A CASE THAT CANNOT ISOLATE IS NOT A CASE

05-struct-assign checked its result with

    if (y.a != 1 || y.b != 2 || y.c != 3 || y.d != 4) return 1;

and failed on aarch64 while passing on amd64. That looked like a struct-copy
bug and consumed a round chasing one -- but the case contains a chain of ||,
and micro-c's || is the known non-short-circuiting one that 04 already fails
on. The case could not tell the two apart, and neither could I.

Split into four separate ifs, each returning its own code, plus a new case
11-logical-or-chain that exercises || with operands that cannot fault. The
next run distinguishes them:

    11 passes, 05 fails    -> the struct copy
    both fail              -> the || itself

WHEN WRITING A CASE, THE FAILURE CODE SHOULD NAME ONE THING. A case that
combines constructs tests their conjunction, which is rarely what is wanted
and is actively misleading when one of the constructs is already known broken.

=============================================================================
WHY THERE IS ALWAYS ONE MORE

A fair observation, and worth answering rather than patching around.

    amd64    11 pass / 0 fail
    aarch64  10 pass / 1 fail

THREE REASONS, and only one of them is fixable by trying harder.

1. THE CASES ARE RETROSPECTIVE. Every one was written FROM a bug already
   found. The suite therefore measures what has been FIXED, not what remains,
   and will keep producing "one more" until cases exist for constructs that
   have never failed. That is the honest limit of the tool as built.

2. TWO ARCHITECTURES DISAGREE ABOUT WHAT IS LEGAL. amd64 tolerates unaligned
   loads; aarch64 faults on them. Four separate bugs -- member alignment,
   struct total padding, instruction alignment, global data padding -- were
   invisible locally and fatal on the runner. Every one cost a round trip
   because the development machine cannot execute aarch64.

3. ONE CLASS WAS RECURRING AND IS NOW CLOSED. vocabulary.sh checks that every
   macro micro-c can emit actually exists in M2libc's defs for the
   architecture it is emitting for. That is four of the bugs found so far:

       mov_x15,x1        not in aarch64's defs
       mov_rbx,r15       not in amd64's defs
       add_x16,x14,x16   not in aarch64's defs
       mov_x0,lr         not in aarch64's defs (setjmp)

   Each was found by assembling or running. All four are the same question --
   "does this instruction exist here" -- and it can be answered statically,
   for FIVE architectures at once, with no runner and no emulation. It is a
   hard gate in CI now.

   It came back CLEAN this round, which is itself informative: the remaining
   aarch64 failure is a LOGIC bug, not a missing instruction, and that rules
   out the class that produced most of the recent ones.

WHAT WOULD ACTUALLY STOP THE PATTERN: cases written for constructs that have
NOT failed yet -- unions, function pointers in structs, nested initialisers,
const and volatile, wide switches, varargs. Writing those is the difference
between a suite that confirms fixes and one that finds bugs.

=============================================================================
instrument.py -- WHY MARKERS WERE PLACED BY HAND FOR SO LONG

Asked why T9 could not be broken down further, the honest answer was that
markers were being placed BY HAND, six or eight to a function, one refinement
per CI round. After several rounds the answer was still "somewhere in
tcc_set_output_type".

Nothing about that placement requires judgement. instrument.py puts a marker
after EVERY statement of a named function, so one run names the exact line.

    instrument.py --map libtcc.c tcc_set_output_type    the line map
    instrument.py libtcc.c tcc_set_output_type          the patched source

On tcc_set_output_type it produces 18 markers where 8 were placed by hand, and
covers statements no one thought to mark -- including the ones inside the
early-return branches.

WHAT IT REFUSES TO INSTRUMENT, because each would emit code that does not
compile and cost a round in a different way:

    declarations with initialisers   a marker cannot split a declarator from
                                     its initialiser
    for(;;) headers                  the semicolons are separators
    preprocessor lines               the semicolon may be inside a branch that
                                     is compiled out
    loop-body opening braces         a marker there repeats every iteration and
                                     drowns the log

THE LINE MAP IS PART OF THE OUTPUT, not an afterthought. "L07" means nothing
without it, and it changes whenever the source does -- so the CI stage prints
the map next to the result rather than expecting anyone to reconstruct it.

Verified before shipping: the instrumented libtcc.c compiles under micro-c to
367,040 lines with 15 markers emitted -- 15 and not 18 because three sit in
#ifdef branches for other targets, which is correct.

=============================================================================
THE LAST MARKER IS AMBIGUOUS AND I READ IT WRONG

    LAST STATEMENT THAT COMPLETED: L38
    L38  libtcc.c:1042  write(2, "TC\n", 3);
    the fault is in whatever follows that line

The statement after L38 was `return 0;`. Markers go AFTER statements, and
nothing runs after a return -- so a function that FINISHES NORMALLY stops at
its last marker too. "Last marker is L38" and "faulted at L38" are
indistinguishable from the number alone.

The rest of the log said so plainly: TC then C3, and C3 is in the CALLER. The
function had returned and the driver had moved on. My report asserted a fault
where there was none.

TWO FIXES, because the report was wrong in two ways:

  1. instrument.py no longer places markers after return, break, continue or
     goto. They are unreachable, so their absence was never evidence.
  2. the CI report checks whether the caller resumed. If the driver's next
     marker printed, it says the function returned normally instead of
     claiming a fault. It also notes when the exit code is not a signal --
     exit 1 means something called exit(), which is an error path, not a
     crash.

A tool that answers confidently in the one case it cannot distinguish is
worse than one that says it does not know, and this one did that for a full
round.

=============================================================================
WHY THE FAULT LOOKED INVISIBLE

"I don't see the line it's crashing on."

Two separate reasons, and neither was a mystery about tcc.

FIRST, IT WAS NOT CRASHING. exit 1 is not a signal. tcc printed its own
"memory full" and called exit() deliberately -- an error path, not a fault.
There is no crashing line to find.

SECOND, NOTHING WAS INSTRUMENTED WHERE IT WAS FAILING. instrument.py took ONE
function name and the CI default was tcc_set_output_type. Once execution moved
past that into tcc_compile there were no markers at all, so the report went
quiet -- and a quiet report reads like a vanished fault.

That is a limitation of the instrument, and it is now fixed: the tool takes a
comma-separated list, the map records WHICH function each marker belongs to,
and the CI default covers the whole path

    tcc_set_output_type,tcc_compile,tcc_compile_string

which is 46 statements including `if (setjmp(s1->error_jmp_buf) == 0)` -- the
setjmp written by hand for this compiler, which nothing had exercised until
now.

THE GENERAL LESSON. Both times the tooling went quiet this session it was read
as the program becoming mysterious, when it was the instrument running out of
reach. A tool that says nothing should be assumed silent rather than
conclusive.

=============================================================================
THE REPORTING WAS WRONG THREE TIMES, AND EACH TIME IT SOUNDED CERTAIN

    markers: ... T9 TD TE TF TA
    last libtcc marker: T9
    DIED IN: tcc_set_output_type

Every part of those last two lines is wrong, and the raw markers on the line
above say so.

  1. THE GREP MATCHED ONLY DIGITS. `grep -aoE '^T[0-9]'` cannot see TA, TB,
     TC, TD, TE or TF -- so the six markers added specifically to narrow this
     down were invisible to the thing reporting on them. The last marker was
     TA, inside tccelf_add_crtbegin.

  2. "DIED IN tcc_set_output_type" came from the DRIVER's D markers, which
     only bracket the driver's own calls. D2 means "tcc_new returned". It
     never meant what it printed.

  3. AN EARLIER VERSION announced "RETURNED NORMALLY -- the fault is later"
     while the process was dumping core, because it checked for a hardcoded C3
     that the driver prints regardless.

All three replaced. The report now prints the raw marker sequence and says
what the exit code means, instead of asserting a conclusion it cannot support.

AND THE INSTRUMENTER SKIPPED THE ONE LINE THAT MATTERED. Loop detection was

    if t.endswith('{') and ('for' in t or 'while' in t or 'do' in t)

and the statement immediately after the last completed marker is

    if (s1->do_debug && filename) {

"do" appears inside "do_debug", so it was treated as a do-loop and skipped.
Matched as a word now. A substring test for a keyword will eventually hit an
identifier that contains it, and this one hit the single most important line
in the run.

=============================================================================
A SKIPPED BRANCH HIDES PROGRESS

    LAST STATEMENT THAT COMPLETED: L08  memcpy(file->buffer, str, len);
    exit 139 is SIGNAL 11: the fault is at or just after that line

The second line is still too confident. L09 is

    if (s1->do_debug && filename) {

and a marker placed after that line sits INSIDE the body. do_debug is zero, so
the branch is never taken and L09 CANNOT print in a correct run either. The
same is true of L10 through L18. The first marker that would print again is
whatever follows the whole construct.

So "last marker was L08" was consistent with the fault being anywhere in the
next dozen statements, and the report named the wrong one.

FIXED by marking REJOIN POINTS -- a closing brace that leaves a block while
still inside the function. Both paths pass through it, so a skipped branch no
longer creates a blind stretch:

    L14  (rejoin) }
    L15  (rejoin) }
    L19  (rejoin) }
    L20  preprocess_start(s1, filetype);

Now L19 printing and L20 not means the fault is in preprocess_start, and there
is no interpretation left to get wrong.

THE PATTERN ACROSS ALL OF THESE. Every reporting bug this session -- the
digit-only grep, the hardcoded C3, the do_debug substring, and now this -- had
the same shape: the tool answered confidently in a case it could not
distinguish. The raw marker sequence was correct every single time. It was the
sentence underneath it that was wrong.

=============================================================================
THE REJOIN MARKERS WORKED

    LAST STATEMENT THAT COMPLETED: L19  libtcc.c:823  tcc_compile: (rejoin) }

L19 is the rejoin after the if/else. L20 is

    preprocess_start(s1, filetype);

and it never printed. THE FAULT IS IN preprocess_start, named exactly, with no
interpretation required -- which is what the rejoin markers were added for one
round earlier.

preprocess_start is in tccpp.c, a different file, so instrumenting libtcc.c
could not see inside it. instrument.py now takes --prefix so each FILE gets its
own marker letter -- both number from 1, and two L07s in one log cannot be
told apart. CI instruments libtcc.c as L and tccpp.c as P.

WORTH NOTING WHAT IS IN THERE:

    P04  s1->include_stack_ptr = s1->include_stack;

That is the array-member decay bug from early in this work -- a member that
must yield its ADDRESS, not its first element. It was fixed for `->`, then
found again for `.`, and this is the exact line in tcc that first exposed it.
If it faults there again it will be the third time that one rule has been
missing from a fourth place.

=============================================================================
THE P04 PREDICTION WAS WRONG

Predicted: the fault would be at

    P04  s1->include_stack_ptr = s1->include_stack;

the array-member decay line, on the reasoning that one rule has nineteen
implementations in cc_core.c and this would be a twentieth site missing it.

Actual:

    LAST STATEMENT THAT COMPLETED: P44
    P45  tccpp.c:3772  tccpp_new: tok_alloc(p, r - p - 1);

P04 executed fine. The nineteen-implementations analysis is still true and
still useful -- it is a real structural problem and it caused four bugs this
session -- but it did not predict this one, and using it to guess a specific
line was overreach.

AND THEN A SECOND MISTAKE, IMMEDIATELY. Case 23 was written for the shape at
P45 -- a pointer difference computed inside an argument list -- and it passes.
It was testing the wrong thing: P45 not printing means tok_alloc DID NOT
RETURN. The fault can be anywhere inside that function. "The last marker names
the statement" is only true when the statement does not call anything.

tok_alloc and tok_alloc_new are instrumented now, 82 markers across four
functions. Worth noting what is waiting in there:

    P07  ptable = tcc_realloc(table_ident, (i + TOK_ALLOC_INCR) * sizeof(TokenSym *));
    P10  ts = tal_realloc(&toksym_alloc, 0, sizeof(TokenSym) + len);
    P11  table_ident[i] = ts;

an array of pointers written by index, and two allocations sized from a
sizeof -- both shapes with a history in this work.

=============================================================================
ROUND 1 OF THE FIX ORDER: THE SAFETY NET

The refactor these cases exist to protect -- one should_load(), one carried
type descriptor, replacing the global flags Address_of / indexing_an_array /
indexed_element_size -- touches 19 sites. Building the net first is the whole
point; a refactor with no way to tell whether it broke something is not a
refactor, it is a rewrite with extra steps.

FOUR NEW CASES AIMED AT THE CURRENT FAULT

The micro-c-built tcc dies at tccpp.c:509

    pts = &hash_ident[h];       completed
    ts = *pts;                  never printed

h is masked to the table size on the line before, so the index is in range
whatever else is wrong. That leaves the address computation, and the reason to
suspect it is structural: "is this an array" is not a property of the type. It
is the global flag indexing_an_array, set from three different places --
is_array for members, TLO_LOCAL_ARRAY for locals, array_modifier for globals --
and reset after one use. Address_of is a second global flag, read at a
different point. &global[i] needs both to survive together.

    24-address-of-global-index    &global[i], 8-byte elements, BSS
    25-address-of-local-index     THE SAME SHAPE ON A LOCAL -- the control
    26-address-of-member-index    &s.arr[i] and &s->arr[i], the third mechanism
    27-address-of-index-in-arglist   two of them in one argument list
    28-hash-bucket-walk           the whole tok_alloc idiom, no allocation

24 and 25 are a PAIR and the pair is the point. If 24 fails and 25 passes, the
hole is the global path and the fix is narrow. If both fail, the address-of-
index site is wrong everywhere and the fix is the shared one. Either answer is
worth more than either case alone.

THE INSTRUMENTER WAS MISCOUNTING LOOPS

    for(i=0;i<len;i++)
        h = TOK_HASH_FUNC(h, ((unsigned char *)str)[i]);

The body is unbraced, so a marker appended after it is a SIBLING of the loop,
not part of it. Its count read 1 no matter how many times the loop ran, and 1
was read as "the loop ran once" -- a claim the instrument cannot make. Same
failure as every other reporting bug here: the data was right, the sentence
underneath it was wrong.

Fixed by BRACING the body around its marker, so a count means iterations
everywhere. Three consequences worth knowing:

  - a braceless `if (c)\n    stmt;` before an `else` used to emit a marker
    between the body and the else, which does not compile at all
  - `if (x) foo();` on ONE line still gets no marker: one placed after it runs
    whether or not the branch was taken, so it cannot mean what every other
    marker means. It is now listed in the map as a blind spot rather than
    silently absent
  - a loop written Allman-style
        while (x)
        {
    had its brace line instrumented, repeating the marker every iteration --
    the drowning the K&R guard already prevented, in the other brace style

DIFFTEST IS NOW A GATE, AND IT RUNS LAST

Failing at the difftest step itself would abort the job and skip every probe
and the instrumented run, so a red round would cost as much as a green one and
tell us less. The step records its result; a final step reads it and fails.
Evidence first, verdict after.

=============================================================================
ROUND 1 RESULT: THE PAIR ANSWERED

    24-address-of-global-index      returns 1   FAILS
    25-address-of-local-index       -           passes
    26-address-of-member-index      -           passes
    18-array-of-struct-member       -           passes (already did)

The identical shape passes on a local and fails on a global. That is what the
pair was for, and it narrows the fault at tccpp.c:509 from "somewhere in the
address computation" to the global path specifically.

24 returns 1, which is its FIRST check -- `p = &g[3]; if (*p != 103)`. So the
plain read through the computed address is already wrong, and the eight probes
after it are unmeasured. That is the right shape for a regression test and the
wrong one for a diagnosis, which is why 29 exists.

THE INSTRUMENTER FIX PAID FOR ITSELF ON THE SAME ROUND

With loop bodies braced, tok_alloc's hash loop reports

    P26  h = TOK_HASH_FUNC(h, ((unsigned char *)str)[i])   x2
    P74  c = *r++                                          x3

Three characters scanned including the terminator, two hash rounds: len is 2
and `tok_alloc(p, r - p - 1)` computed it CORRECTLY. Before the fix the same
loop reported x1, and x1 was read as evidence that the pointer difference was
broken. It is not. That reading was wrong and the round would have been spent
on it.

A CASE THAT FAILS FOR ANOTHER CASE'S REASON IS WORSE THAN NO CASE

27-address-of-index-in-arglist used a GLOBAL array, so it failed -- on 24's
bug, not on anything to do with argument lists. It would have gone green when
the global path was fixed and nobody would have learned whether the construct
it names works. Its array is local now. Locals pass, so a failure there means
the argument list.

29 IS A DIAGNOSTIC, NOT A REGRESSION TEST, AND RETURNS A BITMASK

Every other case returns at the first failure. 29 sets a bit per probe and
keeps going, so one number describes the whole shape:

    1 &g[0]   2 &g[3]   4 g[3] plain   8 write   16 decay
   32 &g[i]  64 char element  128 array of pointers

Bits 2|1 set with bit 4 clear means plain indexing of a global is fine and only
ADDRESS-OF an indexed global is wrong -- one site, one fix. Bit 4 set means
global arrays are wrong generally and the fix is elsewhere. Case 18 makes the
second unlikely; 29 settles it instead of assuming.

THE JOB WAS NOT HANGING

After the marker map prints, the instrumented libtcc.c is recompiled -- 55
seconds, silent. In a live log the last line is the map's last marker, so the
job reads as stuck at a tccpp_new statement. It is now announced.

WHAT THE EMIT STEP IS FOR

difftest names the construct. It cannot say whether the base was loaded
instead of decayed, or the index was not scaled -- two different one-line
fixes that look identical from outside. The emit step compiles four shapes of
the same access and prints the M1 for each, with plain_global as the control:
case 18 says that one works, so its emission is what correct looks like for
the same array.

=============================================================================
ROUND 2: THE M1 NAMED IT, AND THE FIX IS FOUR LINES

29 returned 235, which difftest printed as "SIGNAL 107" -- a signal number
that does not exist. The bitmask reached past 128 and an exit code above 128
is indistinguishable from a fatal signal at the shell. My case, my bug; it is
seven probes now and difftest refuses to decode an out-of-range one rather
than reporting a number it cannot trust.

Decoded, 235 is bits 1|2|8|32|64 with 4 and 16 CLEAR:

    &g[0]            FAILS        g[3]  plain indexing   passes
    &g[3]            FAILS        p = g decay           passes
    write via &g[2]  FAILS
    &g[i] variable   FAILS
    &cg[2] char      FAILS

Every address-of variant fails; every non-address-of variant passes. It fails
at index ZERO and with element size ONE, so it is not a scaling bug -- with a
zero index or a one-byte element there is nothing to scale. The BASE is wrong.

THE EMITTED M1, which is why this round did not need another guess:

    return g[2]      &GLOBAL_g ; ldr_x0,[x0] ; mov_x0,2 ; mul ; add ; ldr
    p = &g[2]        &GLOBAL_g ;              mov_x0,2 ; mul ; add
                                ^^^^^^^^^^^^
A GLOBAL ARRAY'S SYMBOL IS A POINTER CELL, NOT THE STORAGE. `static long g[4]`
emits a cell holding the address of the data, so every access dereferences the
cell first. The ordinary path does, at the bottom of primary_expr_variable,
guarded by !is_local_array. The Address_of branch returns before reaching it,
so &g[i] added the index to the address of the CELL.

A LOCAL array is the opposite: its storage is inline on the stack, the slot IS
the data, and no load belongs there. That is why 24 failed and 25 passed, and
TLO_LOCAL_ARRAY already draws exactly that line -- the address-of path just
never consulted it.

    if(match("[", global_token->s) && !(type->options & TLO_LOCAL_ARRAY))
    {
        emit_out(load_value(register_size, FALSE));
    }

in EXPERIMENT-zz-global-array-address-of.patch, applied after the series.

NOT "GLOBAL ARRAYS NEED A LOAD" -- EVERYTHING BUT A LOCAL ARRAY DOES

The rule is the one the ordinary path already uses. A pointer variable's slot
holds a pointer and must be loaded before an index is added to it, exactly as
a global array's cell must. So `char* p; &p[3]` is broken today for the same
reason, and case 30 says so BEFORE the fix lands rather than after. A case
written to predict a fix can be wrong, which is what makes it worth writing.

27 WENT GREEN

With its array made local it passes, which retires the argument-list theory:
the flags survive nesting fine, and its earlier failure was 24's bug wearing
another case's name.

STILL OPEN, UNTOUCHED BY THIS

    05-struct-assign    SIGNAL 11 on aarch64
    16-switch-wide      returns 1
    21                  known gap, pointer arithmetic does not scale
