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

=============================================================================
ROUND 3: THE ADDRESS-OF FIX WAS HALF THE CHANGE

difftest went 23 -> 26 pass. 24, 29 and 30 all went green and 30 had predicted
it. The bug was real and is gone.

tcc did not move by one statement. Same 202 markers, same trail, same P28,
same SIGSEGV -- byte for byte the previous round.

THAT COMBINATION IS THE INFORMATION. The construct at P28 is now proven
working in isolation and tcc still dies on it, so the statement was never the
cause on its own.

WHAT WAS ACTUALLY WRONG

Address_of returns early from primary_expr_variable. Everything that
configures the INDEX lives below that return:

    if(TRUE == Address_of) { ...; return; }      <- the base load went here

    int options = type->options;
    ...
    if(match("[", global_token->s))
    {
        indexing_an_array = (options & TLO_LOCAL_ARRAY) != 0;
        if(type->array_modifier > 1) indexing_an_array = TRUE;
    }

So `&a[i]` got its base loaded and left indexing_an_array unset.
postfix_expr_array then took its default:

    int element_size = current_target->type->size;
    if(indexing_an_array) element_size = current_target->size;

-- the size of what a POINTER points at, not the size of an ARRAY element.
For `TokenSym *hash_ident[16384]` that is sizeof(TokenSym) against
sizeof(TokenSym*), about eight to one. With h masked to 16383, &hash_ident[h]
landed roughly a megabyte past a 128 KB array and `ts = *pts` read unmapped
memory. One entry to tok_alloc, no tok_alloc_new, straight to SIGSEGV.

THE FIX IS NOT A SECOND COPY

Adding those four lines inside the Address_of branch would work and would be
the FOURTH place in this file carrying one rule -- the pattern that produced
this bug in the first place. The single copy moved ABOVE the branch instead,
so both paths run it and there is still one of it. That also reaches the
deferred-cast path below, which calls postfix_expr_stub, and therefore
possibly postfix_expr_array, at a point where the flag had never been set.

WHY THE SUITE WAS BLIND, WHICH IS THE PART WORTH KEEPING

Every array-of-pointers probe in cases 24, 28, 29 and 30 used `long*`.
current_target->size is 8 and current_target->type->size is 8. Those cases are
STRUCTURALLY INCAPABLE of detecting a wrong choice between the two numbers.
They passed before the fix, passed after it, and would pass with the element
width chosen by a coin toss.

Case 28 was the exception and it never went green. `struct Sym* buckets[16]`
with a 24-byte struct scales by 24 instead of 8, so &buckets[15] lands 360
bytes into a 128-byte array -- inside the pool, no fault, wrong slot, and
`a->len != 3` fires. It was reproducing the real bug the whole time and was
read twice as a struct-layout problem.

31-pointer-array-large-element makes the two numbers differ by six and checks
index 0, a small index, a large index, a write, a variable index, and plain
indexing as the control. A case whose two candidate answers are the same
number is not a test.

=============================================================================
ROUND 4: THE SCALE WAS NEVER THE PROBLEM IN 28 AND 31

The fix worked where it counted. tcc went from 202 markers to 214:

    P28  pts = &hash_ident[h]     completed
    P29  ts = *pts                COMPLETED -- the bucket read works
    P31  (rejoin)                 broke out of the walk, ts was NULL
    P01..P11                      tok_alloc_new RUNS
    P12  ts->tok = tok_ident++    SIGSEGV

First forward movement in this sequence, and exactly where the fix predicted.

But 28 got worse (returns 2 -> SIGNAL 11) and 31, written to catch the scale
bug, failed too. The theory was that ->size is not the pointer width for a
pointer-to-struct. THE EMISSION SAYS OTHERWISE:

    bigptr_addr    &GLOBAL_bigtab ; ldr_x0,[x0] ; mov_x0,40 ; mov_x14,8 ; mul ; add
    plain_bigptr   identical
    longptr_addr   identical

mov_x14,8 in all three. The construct is correct. Two rounds of reasoning
about ->size versus ->type->size were reasoning about something that was
already right, and the dump cost one step and settled it.

THE VARIABLE NOBODY CONTROLLED FOR

    every case that PASSES has a global array of <= 8 elements
    the two that FAIL have 16 and 64

Every case here was written to exercise a construct. None was written to vary
a size, so the size varied by accident and correlated perfectly with the
result. That is not evidence of a size bug yet -- it is evidence that the
suite cannot tell a size bug from a construct bug, which is worse.

AND THE HARNESS IS NOW A SUSPECT

difftest links cases against libc-core; tcc is built against libc-full. In the
same run, tcc memsets `TokenSym *hash_ident[16384]` across its full 128 KB
without faulting, while a 512-byte array in a difftest case segfaults. Both
cannot be micro-c's storage. If 32 fails, the conclusion is about libc-core
and this harness, not about the compiler -- and every future diagnosis drawn
from a large-array case would have been wrong.

32 and 33 test NO construct. No address-of, no pointer arrays. 32 varies the
element count at a fixed 8-byte element; 33 holds the count at four and grows
the element, so between them count and total bytes come apart.

=============================================================================
ROUND 5: SIZE WAS A RED HERRING, AND THE REAL VARIABLE IS THE ELEMENT TYPE

32 and 33 both PASS. A 64-element array of longs and a 4-element array of
96-byte structs both fill and read back with their guards intact. Global array
storage is fine, the harness is exonerated, and the size correlation was an
accident of which cases happened to be small.

That was worth one round to learn. Three hypotheses have now been killed by
measurement rather than argument -- the pointer difference, ->size versus
->type->size, and storage size -- and each died on the first round that
actually tested it.

WHAT THE SUITE SAYS WHEN YOU ASK IT THE RIGHT QUESTION

    grep -l 'struct X* name[' cases/*.c

    28-hash-bucket-walk.c
    31-pointer-array-large-element.c

Those are the only two cases in the directory holding POINTERS TO A STRUCT in
an array, and they are exactly the two that fail. Every passing case uses
long* or an array of structs. The variable was never controlled for because
every case was written to name a construct, and the element type came along
for the ride.

34 THROUGH 37 CROSS IT PROPERLY

    34  long*        x8    control
    35  long*       x64
    36  struct Big*  x8
    37  struct Big* x64

ONE COMBINATION PER FILE rather than one bitmask case. A bitmask is better
when the failure is a wrong value; 28 and 31 SEGFAULT, and a crash returns no
bitmask. Separate files each crash or pass independently and the return code
names which of the six steps did it.

A NOTE ON WHAT THE EMISSION PROVED, WHICH IS LESS THAN IT LOOKED

The M1 for exactly this access reads correctly -- base loaded, index scaled by
8, member offset applied. It was never RUN. The emit step compiles and prints;
it does not execute. If 36 and 37 fail, then reading an emission and calling
it correct is a step short of a measurement, and this is the round that says
so.

=============================================================================
ROUND 6: THE ELEMENT TYPE IS CONFIRMED

    34  long*        x8    passes
    35  long*       x64    passes
    36  struct Big*  x8    SIGNAL 11
    37  struct Big* x64    SIGNAL 11

Element type, not count, and not size. Four hypotheses have now been killed by
measurement: the pointer difference, ->size versus ->type->size, storage size,
and element count.

AND THE M1 I READ AS CORRECT IS NOT

Last round the emit step printed, for exactly this access,

    &GLOBAL_bigtab ; ldr_x0,[x0] ; mov_x0,40 ; mov_x14,8 ; mul ; add

and I read it as correct and said so. The emit step COMPILES AND PRINTS; it
never runs. 36 and 37 execute that shape and crash. So either the emission is
wrong somewhere I did not look, or the fault is in a statement the dump did
not cover -- and in both cases, reading an emission and calling it correct is
a step short of a measurement. The emit step should run what it prints, or
stop being described as evidence.

38, 39 AND 40 SPLIT 36 ALONG WHAT IS LEFT

A crash carries no return code, so 36's six numbered steps tell us only that
it died. These are the smallest programs that can each ask one question:

    38  a struct pointer, NO ARRAY at all
    39  a struct pointer in an array, PLAIN INDEX only
    40  a struct pointer in an array, ADDRESS-OF INDEX only

38 failing means arrays are irrelevant. 38 passing and 39 failing means it is
index access with a struct-pointer element. Both passing and 40 failing means
the address-of path specifically -- the same path already fixed twice.

difftest now prints whatever a crashing case wrote before it died. Cases do
not print today; it costs two lines and means one that does will be heard.

=============================================================================
ROUND 7: BUILT AND TESTED LOCALLY, FOR THE FIRST TIME

Vendoring M2-Planet at the pin changed the method, not just a file. micro-c now
builds in the sandbox and difftest runs there in about a second per case, so
what follows was measured rather than argued.

    before   pass 34   fail 8   known-gap 2
    after    pass 42   fail 0   known-gap 2

THREE BUGS, ALL THE SAME SHAPE

  1. THE STRUCT-COPY WIDTH.  `struct Big* arr[8]; arr[0] = 0;` compiled to a
     48-byte struct copy reading from a null pointer. The decision used
     current_target->type->size -- the POINTED-AT type -- where the ELEMENT
     width was wanted, and indexed_element_size twelve lines below already
     held it. `long*` was fine only because the two numbers coincide, which is
     why every case in this directory missed it for six rounds.

  2. GROUPING PARENS DESTROY Address_of.  primary_expr clears the flag unless
     it sees `&`, and `&(ts->hash_next)` -- tccpp.c:516, as tcc writes it --
     re-enters primary_expr for `ts`. `&ts->hash_next` was always right.

  3. THE INDEX PARSE DESTROYS IT TOO.  postfix_expr_array saves the flag for
     its own use and common_recursion clears the global, so the `.next` in
     `&pool[0].next` read FALSE and emitted the member load.

All three are one global written at one parse site and read at another. That is
the fourth, fifth and sixth time this file has recorded that sentence.

WHAT MEASURING CHANGED

Two candidate fixes for (2) were written. Clearing Address_of on the way out of
primary_expr instead of on the way in is the tidier change and it is WRONG:
22 cases pass against 42, because `&a[i]` parses its index through there and
needs the flag down. That took one minute to find and would have been a CI
round and a confident wrong explanation.

CASE 43 CAUGHT ME IN THE TRAP ITS OWN COMMENT DESCRIBES

It checked `&(x)` against `&x` and required them equal. Both were broken
identically -- both loaded the member -- so the pair agreed and the case
passed. It is anchored to a real address now. A case comparing two forms of the
same construct tests only that they are consistent.

STILL OPEN

    21  known gap, pointer arithmetic does not scale
    44  known gap, `&((*p)->m)` -- parens around a DEREFERENCE
    05  struct assignment, aarch64 only, untested here (no qemu)
    16  wide switch, aarch64 only, same

=============================================================================
ROUND 8: `++` ON A GLOBAL

The three fixes landed -- aarch64 difftest went to 40 pass / 2 fail, and the
two remaining are 05 and 16, the arch-specific pair. tcc did not move: still
214 markers, still

    P11  table_ident[i] = ts;      completed
    P12  ts->tok = tok_ident++;    SIGSEGV

With micro-c building locally, that took four minutes instead of a round.
Compiling TokenSym's exact shape reproduced it on amd64, and bisecting the
statement gave:

    LOCAL   i = n++     works
    GLOBAL  i = n++     SIGSEGV
    GLOBAL  n++         SIGSEGV
    GLOBAL  ++n         SIGSEGV
    GLOBAL  n = n + 1   works

Every form of increment on a global or static, broken. The cause is upstream's
own condition, unmodified at the pin:

    is_postfix_operator = match("++", ...) && (options != TLO_STATIC
                                            && options != TLO_GLOBAL);

It reads like a guard and is not one. Excluding a global makes it fall through
to the ordinary path, which LOADS the value; the increment then treats that
value as an address and stores through it. A local is excluded from the load
and keeps its ADDRESS, which is what the increment needs -- and a global
scalar's symbol IS the address of its value, so the same treatment fits.

M2-Planet never increments a global. tcc does it constantly. Nothing upstream
had reason to find this.

    43 pass   0 fail   2 known gaps   no regressions

A NOTE ON WHERE THE BUGS ARE COMING FROM NOW

The first six were ours -- one rule implemented in several places, and the
copies disagreeing. This one is upstream's, and it is the same category seen
from the other side: a path that was correct for every program its author
compiled, and had never been asked to compile tcc.

=============================================================================
ROUND 9: THE ERROR REPORTER WAS THE BUG

With qemu and the pinned tcc tree both local, the whole build runs here:
libtcc.c compiles in 26s to 369,255 lines, links to a 1.5 MB aarch64 binary,
and runs under qemu. Same numbers as CI.

A three-line program was enough:

    int main(void) { return 7; }

    tcc seven.c -o out    exit=139   markers D1 D2
    tcc -run seven.c      exit=139   markers D1 D2
    tcc -v                exit=139   markers D1 D2
    tcc                   exit=1     usage, no crash

`-v` FAILING IS THE TELL. It prints a version string; the driver ignores it and
calls tcc_set_output_type anyway. No source is read, no token allocated. So
this fault has nothing to do with compiling.

The trace, four instrumentation rounds at about a minute each:

    tcc_set_output_type -> tccelf_add_crtbegin -> tcc_add_crt("crt1.o")
      -> tcc_add_library_internal -> tcc_error_noabort -> error1
      -> cstr_vprintf                                        never returns

The crt files genuinely are not there. tcc was trying to SAY SO and crashed
formatting the message.

RULED OUT ON THE WAY, each in about a minute: a ternary returning a string in
an argument list; the same under an `if (flags & BIT)` guard; variadic calls;
va_arg consumed in place; va_list forwarded one and two levels; vsnprintf
missing from the link. All fine. Under CI that list is six rounds.

THE CAUSE IS ONE CHARACTER IN M2libc

    #define va_copy(ap1, ap2) ap2 = ap1

Reversed. va_copy(dest, src) copies src into dest; this does the opposite, so
tcc's `va_copy(v, ap)` becomes `ap = v` with v uninitialised -- destroying the
live argument pointer and passing garbage to vsnprintf.

    va_copy(v, ap)   C order      SIGSEGV
    va_copy(ap, v)   swapped      exit 0
    v = ap           plain        exit 0

HOW IT SURVIVED, WHICH IS THE INTERESTING PART. Nothing upstream uses va_copy.
Zero uses in M2libc, zero in M2-Planet's compiler. The only use in the tree is
test/run-pass/variadic_functions.c:57, and it is written backwards too --
va_copy(args, second_args) with second_args uninitialised. The test and the
macro are wrong in the same direction, so they agree, and the test has always
passed. Fixing the macro will BREAK that test; the test is wrong, not the fix.

That is the same trap case 43 caught me in one round earlier: two things broken
identically compare equal and look like a pass.

AFTER THE FIX

    tcc: error: file 'crt1.o' not found
    tcc: error: file 'crti.o' not found
    markers D1 D2 D3 D4

Past tcc_set_output_type and into tcc_add_file -- the compile path -- for the
first time.

AND THE PATCH WOULD HAVE DONE NOTHING

Both workflows apply the m2libc series to a copy of spikes/reference/m2libc,
while the libtcc.c compile includes m2/M2libc, M2-Planet's submodule. A header
fix landed in a tree that compile never reads. In micro-c-builds-tcc the
patching also happened AFTER the compile step.

Two copies of one dependency, patches applied to one of them. Third time this
file has recorded that shape: the vendored M2-Planet 56 commits off the pin,
the patch-count bound at 12 in one workflow and 18 in the other, and now this.

=============================================================================
ROUND 10: TWO BUGS WEARING ONE NAME

tccgen_init instrumented locally:

    N06  char_type.t |= VT_UNSIGNED;      completed
    N07  char_pointer_type = char_type;   never returns

A whole-struct assignment -- which looked like case 05, red on aarch64 since
the beginning. It is not case 05. Crossing storage class against architecture
separates them:

                        amd64   aarch64
    global y = x         139     139      <- tcc's shape, covered by NOTHING
    local  y = x           0     139      <- case 05

Two independent faults. Chasing 05 would have fixed something tcc never hits.

BUG 1, FIXED. primary_expr_variable's "do not load a struct" guard reads

    int size = register_size;
    if(options == TLO_LOCAL || options == TLO_ARGUMENT) size = current_target->size;
    if(register_size >= size) emit_out(load_value(size, ...));

`size` only becomes the type's real width for a local or an argument, so for a
GLOBAL struct it stayed at register_size and the guard could not see a struct
at all. It loaded the first eight bytes and used them as the copy's source
address -- char_type.t, the integer 3.

THE FIRST FIX WAS WRONG AND THE SUITE SAID SO IN ONE SECOND. Suppressing the
load on element size alone broke 31 and 43: that load does DOUBLE DUTY -- for
a scalar it fetches the value, for a GLOBAL ARRAY it dereferences the pointer
cell the symbol holds. `static struct Big items[4]` is 48 bytes per element
and still needs it. array_modifier separates them.

    amd64  41 pass 2 fail  ->  44 pass 0 fail

BUG 2, OPEN. Struct assignment fails on aarch64 in BOTH storage classes. The
emitted copy loop is instruction-for-instruction identical to amd64's, which
passes, so it is not the sequence. Case 05 stays red and is untouched.

CASE 46 IS A PAIR. Every check runs on a global and on a local with the same
contents. A single-sided case cannot say "the storage class is the variable",
which is the only thing that separated these two bugs. The struct is 25 bytes
of content on purpose -- three longs and a char -- so the copy has a tail
chunk rather than dividing evenly.

=============================================================================
ROUND 11: A MACRO THAT EXISTS AND IS WRONG

Bug 2 -- "struct assignment fails on aarch64, both storage classes, and the
emitted loop is instruction-for-instruction identical to amd64's, which
passes" -- is one wrong instruction encoding in M2libc.

    DEFINE add_x0,x16,x0 0020008b        ADD x0, x0, x0, LSL #8

Rn=16 needs bits 5-9 = 0x200. All three of these carry 0x100, which is Rn=8:

    add_x0,x16,x0      ADD x0, x0, x0, LSL #8
    add_x18,x16,x18    ADD x18, x8, x18
    sub_x18,x16,x18    SUB x18, x8, x18

The first is the SOURCE-POINTER ADVANCE in the struct copy, which is why the
struct's SIZE decided everything:

    8 bytes    one chunk, the advance is never used again    works
    16 bytes   second chunk reads 8 + (8 << 8) = 2056        SIGSEGV

315 uses in one compile of libtcc.c. Case 05 has been red since it was written
and this is why; the copy loop was correct all along and was assembling into
something else.

    aarch64  41 pass 3 fail  ->  43 pass 1 fail   (only 16-switch-wide)

THE GATE THAT COULD NOT HAVE CAUGHT IT, AND THE ONE THAT CAN

vocabulary.sh asks "does every macro micro-c can emit exist for this
architecture". It closed a whole class -- four bugs that were all "that
instruction does not exist here". It is structurally unable to ask whether the
macro that exists is CORRECT.

verify_defs.py asks that. For a register-to-register form the encoding is
fully determined by the name, so name and bytes can be compared by machine --
which is the only way, because by eye is exactly how three of them got in.
109 macros checked, those three reported, nothing else.

I NEARLY SHIPPED IT REPORTING EIGHT FALSE POSITIVES. The first version flagged
every mov involving sp. SP and XZR are both register 31, and MOV Xd,Xm is an
alias for ORR Xd,XZR,Xm where 31 means XZR -- so SP cannot be named that way
at all and those forms use ADD Xd,Xn,#0 instead. All eight were right and the
checker was wrong. A gate with false positives gets switched off, and then the
three real errors beside it go unnoticed too, which is the exact thing this
tool exists to prevent.

SCOPE IS STATED, NOT GUESSED. Only mov/add/sub register forms. Immediates,
loads, stores, branches and condition codes are left alone rather than
half-checked, and amd64 is not covered: x86-64 is variable-length and its
encoding is not a function of the mnemonic in the same way.

AND A COUNTING ERROR OF MINE, WORTH RECORDING

The previous round predicted "2 failures" one paragraph after saying case 46
would also be red. Three was correct. The deeper mistake is that I had been
quoting amd64 numbers from a local suite while CI runs aarch64 -- two
different suites with two different results, reported as though they were one.
Both numbers, always, from here.

THE SAME MISTAKE, A THIRD TIME, IN ONE ROUND

0004 failed to apply and the log said so. Chasing it found something worse:

    D=spikes/reference/m2libc/aarch64        <- the UNPATCHED copy
    ./M1 -f $D/aarch64_defs.M1 ...

The assembly read the vendored table, not the patched one, so the encoding fix
would have been assembled with the broken macros regardless of whether the
patch applied. THREE copies of M2libc in one job:

    spikes/reference/m2libc   the .c sources compiled into m2libc.M1
    m2libc-patched            the patched copy -- and, until now, the only
                              place a patch had any effect
    m2/M2libc                 the submodule, used as the -I for libtcc.c

Five sites across two workflows now read m2libc-patched. And the submodule is
a DIFFERENT REVISION (68a23cfd against ca023d8), so a patch written against
one need not apply to the other -- 0004 touches aarch64_defs.M1 and does not.
That copy is only an include path, so its series is applied leniently and then
ASSERTED:

    grep -q 'define va_copy(ap1, ap2) ap1 = ap2' m2/M2libc/stdarg.h || exit 1

"It was applied" and "the fix is present" are different claims and only the
second one matters. Every earlier version of this checked the first.

The verify_defs gate also ran AFTER the assembly it exists to guard. Moved
ahead of it, so a bad table fails before anything is built from it.

=============================================================================
A STEP THAT COULD NOT SAY WHAT IT DID

The encoding gate fired against m2libc-patched while the patching step that
feeds it reported nothing at all. Reading the log, "all four patches applied"
and "the loop never ran" are the same output: silence. The function echoed
only on failure.

Two things were ruled out first, both by testing rather than argument:

  - `git apply` from a subdirectory inside a git repository works normally,
    and applies to the subdirectory, not the repo root
  - 0004 applies cleanly to a fresh copy of the vendored tree

So the answer is not known yet, and guessing a fourth time is how the last
several rounds went wrong. The step now:

  - echoes each patch as it applies, naming the directory
  - COUNTS them and fails below four, because a glob that matches nothing is
    the silent case that matters most here
  - asserts the encoding IN THE STEP THAT PRODUCED IT, printing the offending
    line, the cwd and the file's stat on failure

The gate two steps later could only say "the table is wrong" and point at
nothing. An assertion belongs next to the code that just claimed to have done
the work.

TWO RED HERRINGS IN THE SAME LOG, BOTH BENIGN

    error: No valid patches in input (allow with "--allow-empty")

is patches/tcc-debug/0001-DEBUG-mark-progress-through-tcc_new.patch, a
ZERO-BYTE FILE. git apply says that on an empty input, the loop tolerates it,
and the "skipped" line follows. It has been in every log of this workflow.
Deleted.

    skipped 0004 ... -- not applicable to this revision

is m2/M2libc, a different M2libc revision, and is skipped by design -- that
tree is only an include path. Neither line had anything to do with the gate.

=============================================================================
git apply SKIPS AND EXITS 0

The instrumented step said everything and the answer was one line of git's
manual.

    m2libc-patched: applied 0001-free-null-is-a-no-op.patch
    m2libc-patched: applied 0002-malloc-report-refused-size.patch
    m2libc-patched: applied 0003-va-copy-argument-order.patch
    m2libc-patched: applied 0004-aarch64-defs-x16-in-the-rn-field.patch
    m2libc-patched: 4 patch(es) applied
    FAIL: add_x0,x16,x0 is still wrong in m2libc-patched
    848:DEFINE add_x0,x16,x0 0020008b

Four successes and an unchanged file. Reproduced locally, then asked git:

    $ git apply --check -v .../0004-...patch
    Skipped patch 'aarch64/aarch64_defs.M1'.
    $ echo $?
    0

git-apply(1): "When running from a subdirectory in a repository, patched paths
outside the directory are ignored." m2libc-patched is a plain copy --
spikes/reference/m2libc has no .git -- so it lived inside the Veron repository
as an ordinary subdirectory. git computed the prefix `m2libc-patched/`, saw
the patch asking for `aarch64/aarch64_defs.M1`, judged it outside, skipped it,
and returned success.

NONE OF THE m2libc SERIES HAS EVER APPLIED THERE. Not free(NULL), not the
malloc reporting, not va_copy. Every run since that copy was introduced has
compiled m2libc.M1 from unpatched sources while the log said otherwise.

WHY IT WAS INVISIBLE. va_copy appeared to work because it ALSO goes to
m2/M2libc, which is a real repository, and that is the copy libtcc.c includes
-- so the fix that mattered landed and the one that did not was never
observed. mc-tcc escapes the whole thing for an accidental reason: `cp -r
tcc-src mc-tcc` copies tcc's .git along with it, so it is a repository too.
m2libc-patched was the only plain directory in either workflow receiving a
git apply, which is why nothing else ever misbehaved.

THE FIX IS ONE LINE.

    git -C m2libc-patched init -q

An empty repository makes the prefix empty and the paths resolve. `patch -p1`
would also work and applies with fuzz; zero fuzz is worth keeping.

WHAT ACTUALLY FOUND IT. Not reasoning -- three theories died first: git apply
from a subdirectory (works, when the subdirectory is not inside another repo),
the patch being malformed (it applies fine to /tmp), and .gitignore (the file
is not ignored). What found it was making the step report per-patch and assert
its own result, so the log contained a contradiction that could not be
explained away. Before that, "applied" and "the loop never ran" were the same
output, and the failure appeared two steps later attached to different code.

A step that reports only failure cannot be debugged. This one now names each
patch, counts them, refuses to proceed below four, and checks the bytes it
just claimed to have written.

=============================================================================
A fatal: THAT MEANS NOTHING

    fatal: unable to access 'https://repo.or.cz/tinycc.git/':
    Recv failure: Connection reset by peer
      tcc 5ec0e6f8 + 5 patches, tccdefs_.h generated

The clone worked. `clone A || clone B` recovers and prints A's failure anyway,
so every run where repo.or.cz hiccups carries a fatal: that is not one.

That matters more here than it looks. This file has already lost time to a
benign `error: No valid patches in input` -- a zero-byte tcc-debug patch --
sitting three lines from a real failure, and to `git apply` reporting success
while skipping the patch. A log that cries wolf gets skimmed, and the next
line down is where the actual answer usually is.

clone_tcc now tries each mirror TWICE before moving on, because a reset is
typically transient and re-cloning the same host is cheaper than abandoning
it. It names the mirror and attempt that worked. Output is captured and shown
only if every attempt fails, so a good run is silent and a bad one is
complete. Tested against unreachable mirrors: four attempts, one FAIL, the
real error, exit 1.

All three workflows that clone tcc use it. sources/tcc.toml remains the
authority on the mirror list; it is duplicated in the workflows because they
cannot read toml.

=============================================================================
FOURTH SITE, SAME COPY

The m91 fix worked -- the encoding gate now reports the table clean, and 19
patches build micro-c. tcc moved from 40,761 markers to 40,782 and from L21 to
L33, past tccgen_init.

But 05 and 46 stayed red on aarch64, having passed locally under qemu with the
same compiler. difftest was being handed the wrong table:

    ARCH=aarch64 sh difftest.sh "$PWD/micro-c" \
      "$PWD/spikes/reference/m2libc" "$PWD/mescc-bin"

difftest assembles every case with $M2LIBC/aarch64/aarch64_defs.M1, so it was
using the UNPATCHED encodings -- the exact bug patch 0004 fixes -- while the
gate two steps earlier reported the patched table clean. Both statements were
true about different files.

The count so far, for one dependency in one workflow: the .c sources, the
include path, the assembler tables, difftest, and vocabulary. Five consumers,
three copies, and a fix has to reach the right one. Each time it has been
found by a symptom that looked like a compiler bug.

WHAT THE tcc RUN NOW SAYS, WHICH IS NEW

    In file included from /tmp/trivial.c:0: <command line>:1:
    error: '##' cannot appear at either end of macro

That is tcc's OWN preprocessor, running, parsing the predefs buffer that
tcc_predefs pushes, and rejecting one of its built-in macros. Not a crash --
a diagnostic, printed through the error path that va_copy fixed. It is the
first time tcc has judged anything about a program.

=============================================================================
ROUND 12: A LABEL IS A PREFIX

The '##' error was not a macro bug.

    In file included from /tmp/trivial.c:0: <command line>:1:
    error: '##' cannot appear at either end of macro

tcc raises that from

    if (t0 == TOK_PPJOIN)
    bad_twosharp:
        tcc_error("'##' cannot appear at either end of macro");   tccpp.c:1621

-- a braceless if whose body is a LABELLED STATEMENT, and the label is also a
goto target, so one error site is reached two ways. statement() emitted the
label and returned, treating it as a complete statement, so the if got the
label as its whole body and the tcc_error became the next statement,
unconditional. Every #define raised the error; the first reported was line 1
of tcc's own predefs.

Inside a block the mistake is INVISIBLE -- the block loop parses the next line
anyway and the emitted code is identical. It bites only where exactly one
statement is expected. M2-Planet's own sources label at block scope, so
nothing upstream ever exercised it.

MY FIRST FIX BROKE THE COMPILE IN ONE MINUTE

    tcc.h:1116: case is not a defined symbol

tccpp.c:952 has an ordinary goto label directly in front of a switch label:

    break;
    _default:
        default:

Recursing into statement() made it parse `default` as an expression, and the
error was reported against a #define with nothing to do with it. process_switch
already has a branch for exactly that shape, with a comment saying so -- the
guard here is the same rule from the other side. Under CI that is a round and a
misleading location; locally it was the next command.

    amd64    45 pass  0 fail  2 gaps
    aarch64  44 pass  1 fail  2 gaps      (16-switch-wide)

WHERE tcc IS NOW

    tcc_new -> tcc_set_output_type -> crt errors PRINTED -> D3
    tcc_add_file -> tcc_compile -> preprocess_start (980 keywords interned)
    -> tccgen_init -> tccgen_compile -> next()
    -> next_nomacro OK, define_find OK
    -> macro_subst_tok            <- the next fault

It preprocesses its own predefs cleanly and reaches macro substitution on the
first identifier of a real source file.

A LIMIT OF instrument.py WORTH KNOWING

It cannot instrument next_nomacro. Markers inside that function's large switch
produce

    ERROR in process_switch
    MISSING }

because micro-c's switch parser will not accept statements where the
instrumenter puts them. The biggest function on the tokenizer path is
currently un-instrumentable, and that is a tool limit, not a compiler bug.

=============================================================================
THE INSTRUMENT STOPPED REACHING THE FAULT AGAIN

The label fix landed: the '##' error is gone from every step of the run, and
difftest is 44 pass / 1 fail on aarch64, matching the local numbers exactly.
Markers went 40,782 -> 41,165.

But the report said

    LAST STATEMENT THAT COMPLETED: P20
    P20  tccpp.c:488  tok_alloc_new: ts->str[len] = '\0';

and that is not the fault. tok_alloc_new is interning a token during macro
substitution -- ordinary work. The fault is in macro_subst_tok, which was not
in the instrumented set, so the last marker INSIDE the set got reported as the
last thing that happened.

The set was chosen when the fault was in tok_alloc, three subsystems ago. This
file already records the same thing happening once:

    "Instrumenting a single function is only useful while you already know
     which one. When the failure moved out of tcc_set_output_type and into
     tcc_compile there were no markers there at all, so the report had nothing
     to say and it looked like the fault had gone invisible. It had not -- the
     instrument did not reach it."

It is the same failure with the opposite symptom. Then the trail went quiet;
this time it pointed confidently at a line that was fine. Quiet is easier to
notice.

TWO CHANGES

next and macro_subst_tok added to the default set. next_nomacro deliberately
left out, with the reason in the workflow: markers inside its switch produce
`ERROR in process_switch / MISSING }`, because micro-c's switch parser will
not accept statements where instrument.py puts them.

And the report now PRINTS WHAT IT INSTRUMENTED, with the warning that a fault
outside the set appears as the last marker inside it. A reader can then check
the frequency column -- a "last statement" that ran 980 times is a statement
in a loop, not a crash site.

=============================================================================
A MARKER INSIDE AN ARRAY INITIALISER

Following the frontier broke the instrumenter, and the error named the marker
rather than the placement:

    tccpp.c:3542: Unable to find symbol 'write' for use in constant expression.

    static char const ab_month_name[12][4] = {
    write(2, "P114\n", 4);                        <- HERE
        "Jan", "Feb", "Mar", ...
    };                                            tccpp.c:3541

instrumentable() treated any line ending in `{` as opening a block. An
aggregate initialiser ends in `{` too, and so does a type definition, and
neither contains statements.

The guard has to distinguish an ASSIGNMENT `=` from the tail of ==, !=, <=, >=
or a compound operator, because `if (a == b) {` really does open a block:

    [^=!<>+\-*/%&|^]=\s*\{$

That is the third placement bug in this tool and they share a shape: a line
that ends in a character the instrumenter reads as structure, in a context
where it means something else. The first was a braceless loop body, the second
a function's own closing brace, this one an initialiser.

Each was found the same way -- micro-c refused the instrumented file and named
a symbol that made no sense, `write`, in a place that had nothing to do with
markers. A tool whose failures point somewhere else is expensive, and this one
now has three separate reasons in its guards.

WHERE THE FAULT IS

With the tool fixed, 30,502 markers and:

    P95  macro_subst_tok: sa = sym_push2(nested_list, v, 0, 0);   completed
    P96  macro_subst_tok: ret = macro_subst(tok_str, nested_list, jstr);

macro_subst -- the recursive expansion body, one level below macro_subst_tok
-- does not return. That is the next thing to instrument.

=============================================================================
ROUND 13: THE FRONTIER REACHED THE KNOWN GAP

The trace, all local, about a minute a round:

    next -> macro_subst_tok -> macro_subst
      iteration 1  TOK_GET ok, else branch, tok_str_add2_spc x29 ok, P31
      iteration 2  TOK_GET                                    SIGSEGV

TOK_GET is tcc's token reader and runs for every token it reads:

    #define TOK_GET(t,p,c) do { \
        int _t = **(p); \
        if (TOK_HAS_VALUE(_t)) \
            tok_get(t, p, c); \
        else \
            *(t) = _t, ++*(p); \
        } while (0)                              tccpp.c:1245

    ++*(p) through a pointer-to-pointer    gcc=0  micro-c=1
    comma expr as a braceless else body    gcc=0  micro-c=0     fine
    both together, TOK_GET's shape         gcc=0  micro-c=139

`*p` is `const int *`, so ++ must advance it by sizeof(int) and advances it by
ONE. The first iteration works because the initial pointer is valid; the
second reads from a misaligned address.

THAT IS CASE 21. Pointer arithmetic does not scale -- the gap documented and
deferred several rounds ago, reached from a new direction and now load-bearing
rather than theoretical. Recorded as case 48 so the shape TOK_GET actually
uses is covered: through a parameter, through a global, and with a wider
element so a one-byte advance is unmistakable.

    45 pass  0 fail  3 known gaps

The shelved fix, scale_pointer_operand, made two cases pass and broke a third
because promote_type folds the pointee type away before the operator is
handled. That is the same information loss behind the nineteen load sites, and
it is now the blocker rather than a note.

TWO TOOL FIXES OUT OF THE SAME STRETCH

THE MARKER BYTE COUNT WAS HARDCODED AT 4. Correct for "P01\n" and one short
for "P100\n", so from the hundredth marker on the newline was dropped:

    P100Q1
    Q3

Two markers on one line, and every grep in the reporting is anchored with ^,
so the second of each pair is invisible -- indistinguishable from a statement
that did not run. I read it as a dropped statement and spent a round on it.
Any file with more than 99 markers was affected, which by now is most of them.

AND MARKERS MUST NOT LAND IN AN AGGREGATE INITIALISER, which is the previous
entry -- three placement bugs in this tool now, all the same shape: a line
ending in a character the instrumenter reads as structure, in a context where
it means something else.

instrument.py STILL CANNOT ENTER A SWITCH. tok_str_add2 and next_nomacro are
both un-instrumentable for that reason. Hand-placed markers reached past it
this time; that will not scale.

=============================================================================
REPRODUCING ANY OF THIS: local-build.sh AND local-tcc.sh

Everything above was found locally, and none of it was reproducible from the
repository until now. Doing the obvious thing -- copy the reference tree, apply
the patches, build -- produces a compiler that segfaults on case 05, and the
reasonable conclusion is that micro-c is broken. It is not.

FOUR TRAPS, ALL SILENT, THREE FOUND THE HARD WAY

  1. git apply INSIDE THIS REPOSITORY SKIPS AND EXITS 0. git-apply(1): "When
     running from a subdirectory in a repository, patched paths outside the
     directory are ignored." A plain copy of spikes/reference/m2libc in the
     working tree is exactly that. Nothing in the m2libc series applied for
     weeks. Every copy gets `git init` first.

  2. M1's max_string DEFAULTS TO 4096 and tcc's keyword table is one string
     far bigger. Without the substitution the link dies with "exceeds max
     string size" and hex2 then fails on a file that does not exist -- two
     errors, neither naming the cause.

  3. THE .M1 TABLES MUST COME FROM THE PATCHED M2libc. Three aarch64 macros in
     the vendored table encode x16 as x8. They assemble, link, run, and compute
     garbage. Both CI workflows made this mistake and it read as a codegen bug
     twice.

  4. CODE MUST PRECEDE STRINGS in the joined .M1, or a function lands off a
     four-byte boundary and every call to it is SIGBUS on aarch64.

The scripts encode all four and ASSERT THE RESULT rather than the action. "The
patch was applied" and "the fix is in the file" are different claims; every
earlier version of this checked the first one.

    sh spikes/stage3/tools/local-build.sh
    sh spikes/stage3/tools/local-tcc.sh build/local
    sh spikes/stage3/tools/local-tcc.sh build/local tccpp.c macro_subst

difftest-qemu.sh runs the same case suite on aarch64 under the committed
emulator, which is where the alignment class of bug lives and where two cases
have only ever failed.

Verified from a clean checkout: 45 pass / 0 fail / 3 gaps on amd64, 44 / 1 / 3
on aarch64, and mc-tcc built and run to the same fault this file describes.

================================================================================
ROUND: POINTER ARITHMETIC, AND THE THING THAT WAS ACTUALLY IN THE WAY
================================================================================

Two patches: EXPERIMENT-zz7 (pointer arithmetic scales) and EXPERIMENT-zz8 (a
dereference of an address is an lvalue). Cases 21 and 48 closed, 49 and 50
added. amd64 49/0, aarch64 48/1, regression 0.

THE FINDING THAT MATTERS IS NEGATIVE. MICRO-C.md named pointer scaling as THE
BLOCKER. It was a real gap and it is now closed -- and the tcc marker trail
with the fix is BYTE-IDENTICAL to the trail without it. A cause that has been
written down for several rounds is still a hypothesis until something measures
it, and the cheap measurement here was: fix it, rerun, diff the trail. That is
two minutes locally and it would have been worth doing before any of the work.

WHAT MOVED tcc was `*(t) = 7` -- an assignment through a parenthesised
dereference -- storing through the loaded value, where `*t = 7` had always been
right. Found by reducing TOK_GET to fifteen lines and bisecting it with
difftest, which separated the two spellings in about a second. Reading emitted
assembly would have shown the extra load; it would not have said which of the
three constructs in that macro carried it.

THREE THINGS TO REUSE:

1. FIX IT AND DIFF THE TRAIL. `local-tcc.sh WORK tccpp.c FUNC` twice, once per
   compiler, and `diff` the marks. It is the only way to tell "this was a real
   bug" from "this was the bug". Both patches here are real fixes; only one of
   them moved anything.

2. A FIX WITH THE WRONG LEVEL COUNT LOOKS LIKE NO FIX AT ALL. zz8's
   address-of cancellation was first keyed on the dereference loop's LAST
   iteration, which is correct only when there is one star. `++*(&x)` passed in
   isolation and tcc did not move by a single marker, because the same macro
   also writes `**(p)`. A green case suite said nothing about it. Cost: one
   round.

3. STACK THE CASES AGAINST EVERY VERSION, not just the final one. Each of the
   four cases here was run against three compilers -- baseline, zz7 only, both:

       21  BASE=FAIL  A=pass  NEW=pass
       48  BASE=FAIL  A=FAIL  NEW=pass
       49  BASE=FAIL  A=FAIL  NEW=pass
       50  BASE=FAIL  A=pass  NEW=pass

   That table is what makes the split honest: each patch is witnessed by cases
   that its predecessor does not fix. A case that passes on the baseline is
   measuring nothing, and the only way to know is to run it there.

WHAT THE SUITE STILL CANNOT SEE. Every case here is amd64-and-aarch64 C with an
exit code. It cannot see that `16-switch-wide` has been red on aarch64 and
green on amd64 for some time -- that needs someone to read the second column.


================================================================================
ROUND: A NEGATIVE case LABEL, AND WHAT THE SECOND COLUMN IS FOR
================================================================================

EXPERIMENT-zz9. Cases 16 and 51 closed; aarch64 50/0 for the first time.

`case -2:` emitted `:_SWITCH_CASE_4294967294_...` and the jump table loaded
that name back through strtoint, so the sign went out through a string. The
switch value is sign-extended in its register; the constant was not; nothing
matched.

WHAT MAKES IT WORTH A LOG ENTRY IS NOT THE BUG. It is that difftest had been
REPORTING it, on the aarch64 line, for some time -- and the docs said nothing,
because the amd64 line was green and that is the line that gets read. x86-64's
`mov_rax,%imm32` sign-extends, so on the development machine the wrong constant
landed on the right value. That is the fifth member of the
invisible-on-amd64/fatal-on-aarch64 family; the other four each cost a CI
round to find. This one cost nothing to find and months to notice.

    A GREEN amd64 DIFFTEST IS NOT A RESULT.

Two things to reuse:

1. RUN BOTH COLUMNS AND READ BOTH. difftest-qemu.sh exists and is fast. Every
   number quoted in a commit message from here should be a pair.

2. A CASE THAT CANNOT FAIL ON ONE ARCHITECTURE SHOULD SAY SO IN ITS HEADER.
   Case 51 passes on amd64 with and without the fix -- by design, since the
   bug is that the two architectures disagree. A reader seeing it green on a
   laptop needs to know that means nothing. Cases 05, 06 and 08 have the same
   property and did not say it.

And the fix's own lesson: there was no negative-immediate lowering to reach
for -- three hardcoded entries in the aarch64 table, the ones M2libc needed --
so the constant is built as ~(|v| - 1), reusing the NOT that unary `~` already
emits on all six architectures. When a per-architecture emission looks
necessary, check whether an identity gets you there with instructions that are
already proven. It usually does, and vocabulary.sh will tell you in seconds
whether it did not.


================================================================================
ROUND: I SAID I COULD NOT VERIFY AN ENCODING. I COULD.
================================================================================

patches/m2libc/0005 and tools/verify-imm64.sh.

The reasoning was: these macros need a byte-compare against real `as`, there is
no aarch64 assembler on this machine, therefore they cannot be checked here and
must not ship. Every step true, conclusion wrong. spikes/toolbox has a
qemu-aarch64-static and it has been sitting there since the toolbox landed.

    A BYTE-COMPARE IS NOT THE ONLY WAY TO CHECK AN ENCODING. RUNNING IT IS
    ANOTHER, AND IT ANSWERS A DIFFERENT AND ARGUABLY BETTER QUESTION.

Byte-identity proves the bytes are what `as` would have emitted -- that the
encoding was TYPED right. Executing it proves the CPU does the intended thing.
For `ldr_x0,8` the second is what is actually wanted, and it took four minutes.

The test that discriminates: read BOTH HALVES of the constant back. A form that
loaded only the low 32 bits -- exactly the bug being fixed -- passes a low-byte
check. Checking one half would have confirmed the broken behaviour, which is
the shape MICRO-C.md's "honest limits of the case suite" section already
records twice (case 43 passing because both sides were broken identically,
every array-of-pointers probe using `long*` where both widths are 8).

Also: Rt was exercised below and above 7, where the encoding's nibble carries.
Testing x0 and x1 alone would not have caught a wrong high-register form, and
the previous encoding disaster in this table (0004, x16 read as x8) was exactly
a register-field error.

================================================================================
ROUND: THE LABEL COLLISION, AND HOW TO STOP READING
================================================================================

EXPERIMENT-zza. Case 52. tcc is out of macro expansion.

`tccpp.c` has FIVE functions that each declare `redo:`. micro-c emitted the
bare name into one flat namespace, so every `goto redo` in the unit went to
whichever definition survived -- into an unrelated function.

WHAT THIS COST: four rounds aimed at macro expansion, because the last
completed marker was a `begin_macro` call and the natural reading of "last
statement that completed" is "crash site". It is not. It is the last statement
before control went SOMEWHERE ELSE, and a goto is somewhere else.

    A LAST MARKER IS NOT A CRASH SITE. It is a boundary. Ask what the next
    control transfer was before believing the function it names.

WHAT ENDED IT IN ONE BUILD, and this is the technique to reuse. Instead of
reading more code, `begin_macro` was made to ANSWER:

    int *zsave = str->str;
    if (zsave == 0)            write(2, "Z_NULL_ON_ENTRY\n", 16);
    str->alloc = alloc;
    if (str->str != zsave)     write(2, "Z_CLOBBER_ALLOC\n", 16);
    ... one check per store ...
    write(2, "Z_PRE_READ\n", 11);
    { int zt = *macro_ptr; }
    write(2, "Z_READ_OK\n", 10);

It printed Z_P_PLAUSIBLE, Z_PRE_READ, Z_READ_OK -- no null, no clobber, and it
successfully performed the very dereference that was believed to be faulting.
That eliminated the entire function in one minute. What is left after the last
statement of a function is the control flow out of it.

The general shape: when a marker names a function, do not read the function.
Make it assert its own preconditions and postconditions and print which one
broke. instrument.py says WHERE execution stopped; this says WHAT was untrue.
They answer different questions and the second one is usually the one wanted.

Also worth keeping: the reproducer is three lines and fails on BOTH
architectures, so it was never an aarch64 problem and could have been found on
the development machine at any point in the last four rounds. Every difftest
case that has ever mattered has been under twenty lines.

================================================================================
ROUND: THE NARROWING CAST. Twelve programs green; the frontier moves to
multiple translation units.
================================================================================

STARTING STATE. mc-tcc built and started, `-c seven.c` produced a 1022-byte
object, and four of the twelve end-to-end programs segfaulted: 05
(pointers-and-arrays), 06 (structs-by-pointer), 11 (function-pointer-member),
12 (prefix-operator-through-a-dot). difftest aarch64 was 84/1 with case 14 red.

THE WRONG START, RECORDED BECAUSE IT WAS PLAUSIBLE. Case 14 and program 11 are
the same twelve lines of C and both were red, so they read as one bug. They are
not. Case 14 is compiled by MICRO-C; program 11 is compiled by MC-TCC, so tcc
lays that struct out. One grep of the tcc tree settled it: the only inline
function-pointer member in all of tcc is `void (*error_func)(...)` at
tcc.h:856, and `void` is register-sized, so micro-c's layout bug cannot reach
tcc at all. Two real bugs, adjacent, sharing a shape and nothing else.

WHAT NARROWED IT. Not a marker trail. The pass/fail split:

    passing   constants, arithmetic, loops, recursion, globals+bss, string
              literal, char/switch/goto, a function pointer in a SCALAR local
    failing   every program that takes the address of, or indexes, a LOCAL
              AGGREGATE

Globals passing (program 07) rules out the whole symbol path. Scalars passing
rules out `loc` itself. That points at one branch of tcc's `load()`, and the
two branches differ in a way that predicts exactly this split:

    VT_LOCAL | VT_LVAL   scalar load -> arm64_ldrx -> ldur with (off & 511)
                         THE HIGH BITS ARE MASKED OFF
    VT_LOCAL             address-of, arm64-gen.c:572 -> range test, then
                         straight into an instruction word, NO MASK

THE PROBE. arm64-gen.c:494 sign-extends a 32-bit offset by hand. Six sub-steps,
one bit each, twelve lines, no tcc build, seconds:

    bit 1  (unsigned int)ci truncates   FAIL     <- the only cause
    bit 2  (v >> 31) & 1                ok       <- zze had fixed precedence
    bit 4  (unsigned long)1 << 32       ok       <- zzb had fixed the literal
    bit 8  the whole sign extension     FAIL     <- consequence
    bit 16 -svcul == 32                 FAIL     <- consequence
    bit 32 the range test               FAIL     <- consequence

Then one more probe returning WHICH shape the value had: gcc 1 (truncated),
micro-c 2 (untouched). The cast emitted nothing at all.

Splitting the sub-steps is the whole technique here. A case checking only the
final value says "the idiom is wrong" and names nothing, and four of the six
bits fail as consequences of the first.

WHY IT WAS INVISIBLE UNTIL NOW. While `int` was eight bytes every integer cast
was register-width to register-width and there was nothing to discard. zzw made
`int` four bytes. This is the fourth bug in this file whose cause is "zzw ended
an accident", after zzu, zzx and zzzb.

THE FIX. emit_narrowing_cast() in cc_core.c, called from primary_expr's cast
branch. Six aarch64 macros and five amd64 macros added to the tables --
neither had an instruction for a register-to-register truncation.

ONE SITE, NOT ALL THREE. primary_expr applies a cast type in three places.
Only the one a cast over a postfix expression reaches is wired up, because that
is where `(uint32_t)sv->c.i` goes and it is the only one cases 101/102 can
reach. An emission site no case can reach is a liability, not coverage.

RESULT.
    difftest aarch64   84/1  -> 87/0   (2 new cases)
    difftest amd64     82/1  -> 83/0
    mc-tcc programs     8/12 -> 12/12
    micro-c -c /dev/null, PREDEF_LINES=0     rc=0 (the old frontier: closed,
                                             and it had been closed before this
                                             round started -- MICRO-C.md was
                                             describing a fault that no longer
                                             reproduced)

THE CASES FAIL WITHOUT THE FIX, CHECKED. A case that passes either way tests
nothing, and this file already records two of those. Against the compiler built
WITHOUT zzzc/zzzd: case 101 rc=199, case 102 rc=249, case 14 rc=139 (SIGSEGV).
All three rc=0 with them.

STAGE-2 SUBSET, CHECKED BEFORE HANDING OVER. micro-c's own source is compiled
by `./stage2 < microc.c` in step 10 of the hermetic job, and stage 2 discards a
`#`-line entire -- `#define ANSWER 42` compiles clean and leaves ANSWER for
stage 1 to fail on. The only `#define` in micro-c is still `cc.h:20 #define
CC_H`, a bare guard; AARCH64, AMD64 and TO_FUNCTION_POINTER are enum constants
(cc.h:37, 39, 121). This round adds no constant of any kind. A `#define` here
would build under gcc, pass local-build.sh, pass difftest, and fail only in the
box, at stage 1, as an undefined label with no line pointing back.

THE NEXT FRONTIER. tcc's own tests2/00_assignment.c against the shim segfaults
during the COMPILE -- but each file compiles alone:

    mc-tcc -c tests2/00_assignment.c   rc=0, 1577 bytes
    mc-tcc -c crt.c                    rc=0, 5961 bytes
    mc-tcc -o t2.bin 00_assignment.c crt.c      SIGSEGV

Reduced to two trivial files it becomes a different message from the same
cause: `tcc: error: _start not defined`, for a `_start` plainly defined in the
file that was passed. Both routes fail -- two sources in one invocation, and
two objects linked afterwards -- so this is state carried ACROSS translation
units. Everything the twelve programs exercise is single-file, which is why it
sat behind them.

--------------------------------------------------------------------------------
FOLLOW-UP: the wider measurement, and what the twelve programs did not ask.
--------------------------------------------------------------------------------

imm-identity.sh WENT RED AND IT WAS MINE. Cases 101 and 102 carry 4294967264
and 4294967296, so they legitimately move across zzb -- they just were not
declared. `WIDE CONSTANTS` added to both headers; moved 8, declared 8,
undeclared 0. A guard that goes red for a correct reason still costs a round,
and a new case is exactly when to check it.

12/12 MEANT LESS THAN IT LOOKED. All twelve hermetic programs are small enough
that tcc never grows a section past its first allocation, so none of them
reaches realloc. Swept tcc's own tests2 -- 129 tests, each compiled and run,
against a control tcc built by gcc from the same source:

    pass 0    fail 57    not-applicable 72

    46  M2libc: realloc: pointer was never returned by malloc
     5  SIGNAL 11 during compile
     1  _Generic -- a real missing feature
     1  ran, output differs

The control decides which count: 72 tests it cannot pass either are measuring
the shim, not us. Both sides get the SAME single concatenated file, because
feeding the control two inputs and mc-tcc one would have measured the multi-TU
gap and reported it as 57 codegen failures.

FOUR HYPOTHESES, ALL KILLED BY MEASUREMENT, IN ORDER:

  1. the malloc/realloc SIGNATURE MISMATCH. M2libc defines malloc(unsigned)
     and realloc(void*, unsigned) -- four bytes since zzw -- while
     micro-c-libc/stdlib.h declares both `unsigned long`. This looked
     conclusive and was written up as the answer before it was tested.
     main-06-realloc.c crosses that exact boundary and PASSES. Wrong.
  2. the allocator's own reuse logic. main-07-realloc-sequences.c, written for
     this, exercises seven shapes main-06 does not -- free-list reuse, chained
     reallocs, a grow with another block freed between, a shrink, 64
     allocations of churn before growing the OLDEST block, 24 reallocs
     interleaved with mallocs, content survival across a move. All seven pass.
  3. use-after-free. m2libc 0011 walks _free_list before dying. Not on it.
  4. an interior pointer / tal_header_t skip -- `((tal_header_t *)p) - 1` is
     the obvious guess. 0011 checks every live block's range. Not inside one.

WHAT IS LEFT, AND THE ONE NUMBER. The address is in the heap region, is not a
block start in either list, and is not interior to any live block. 0011 reports
the distance to the nearest block start:

    realloc: not a block; bytes to the NEAREST block start is (288)

288 APPEARS EARLIER IN MICRO-C.md. The table_ident two-slot write -- the
frontier recorded as CLOSED -- reported its two overwritten values as "288
bytes apart". Not established as the same structure and it must not be assumed.
Written down because it is worth one grep, and because that frontier section
sat in the file describing a fault that had stopped reproducing long before
anyone read it again. A frontier is a claim with a date on it.

MULTI-FILE INPUT WAS DEMOTED, AND THE DEMOTION IS THE LESSON. It was called
THE open frontier on one data point, in the previous entry, by me. tcc.c and
libtcc.c both `#define ONE_SOURCE 1`, so self-compilation is a SINGLE input
file -- which is what tcc's own test1/2/3 do. Multi-file is needed to link
libtcc1.a and the crt objects, not to compile tcc. Concatenating the two files
makes the symptom CHANGE, not disappear, which is what a thing that is not in
the way looks like.

NOT LOOKED AT: the five SIGNAL 11 compiles. They may or may not share the
realloc cause; nobody has checked, and saying so is cheaper than implying they
are covered.

--------------------------------------------------------------------------------
CORRECTION: the multi-file "bug" is our own driver, and the target was wrong.
--------------------------------------------------------------------------------

mc-tcc IS NOT tcc. It is libtcc.c compiled by micro-c plus a 175-line
hand-written driver, micro-c-libc/impl/main-tcc.c, which holds

    char* input = 0;      ...      input = argv[i];

ONE POINTER, overwritten by each file. Two inputs compiles one and drops the
other, which is exactly `undefined symbol 'main'` at step 11 of the hermetic
job. I recorded that as a codegen frontier for a full round. It is scaffolding
we wrote, and its own header says why it exists: micro-c cannot parse
tcctools.c:60, a `static const ArHdr` initialised with string members, so
tcc's real main is unavailable.

PROBED, rather than assumed -- mc-tcc with -B set, under the emulator:

    --version                rc=1  no input file      -B consumed as the input
    -E                       rc=1  crt1.o not found   not implemented
    -c to object             rc=0  1022 bytes         WORKS
    link that object alone   rc=1  _start not defined
    -print-search-dirs       rc=1  no input file      not implemented
    -ar                      rc=1  crt1.o not found   not implemented
    link against system libc rc=1  crt1.o not found

Six of seven are the hand driver, not the compiler. Closing tcctools.c:60
removes all of them at once.

THE TARGET WAS WRONG TOO. tests2 was my proxy for "does mc-tcc work", and it
is a good bug-finder and a poor definition of done. Stage 3 owes stage 4 ONE
artifact: a tcc that can stand where rung1.sh puts `$TCC` -- as `CC` for
./configure of gmp, mpfr, mpc and then gcc 4.7.4. That is autoconf driving a
compiler: hundreds of conftest compile-link-RUN cycles, -E, -c, -o, -I, -D,
-L, -l, archives, and system headers. A driver requirement first.

AND "HERMETIC" IN STAGE 4 MEANS NO HOST *COMPILER*, NOT NO HOST DEPENDENCY.
box.sh:85 binds the whole of /usr read-only and masks gcc/cc/g++/cpp to
/dev/null; env0.sh's borrow list includes binutils, make, perl, bison, flex
and libc6. Removing the host compiler is stage 3's job and is nearly done.
Removing the host libc, binutils, make and perl is a much larger project that
no rung currently owns, and calling both "hermetic" hides that.

FOUR THINGS I ASSERTED ABOUT STAGE 4 IN ONE SESSION, ALL WRONG: that it has a
userland to lend; that mc-tcc would have to build musl; that multi-TU was off
the critical path; that multi-TU was a compiler fault. Every one came from
grepping a file instead of reading the stage. The requirements are written out
properly in WHAT-STAGE-4-NEEDS.md so the next round starts from evidence.

--------------------------------------------------------------------------------
MEASURED: tcc.c compiles. One initialiser stands between us and a real driver.
--------------------------------------------------------------------------------

With tcctools.c:60 stubbed FOR MEASUREMENT ONLY, the whole of tcc.c compiles:
707 functions against libtcc's 695. That is the only parse blocker in the
entire front end -- not the first of many, which is what it could have been.

IT CANNOT STAY STUBBED, and the reason came from being corrected mid-round.
The argument for stubbing was "stage 4 borrows binutils, so a real ar exists".
That is true of the CURRENT borrow list and false of the goal: gcc needs an
assembler and linker, so binutils must be built by tcc, and building binutils
means creating libbfd.a and libiberty.a before any ar exists. `tcc -ar` is the
answer to that chicken-and-egg, so tcctools.c must compile properly.

And zeroing it does not even degrade gracefully: ar_name is "/               "
and ar_fmag is ARFMAG, both format-critical magic. A zeroed initialiser writes
INVALID archives, not archives with poor metadata.

WHAT THE FEATURE ACTUALLY IS. micro-c has a string-literal path for globals,
but only `if(type_is_pointer(type_size))`. A `char[16]` MEMBER needs its bytes
laid out INLINE -- no pointer indirection -- because tcc memcpys the struct
into a file and the layout must be exact. Note also that micro-c's global
array model emits a POINTER plus separate storage (`&GLOBAL_STORAGE_name %0`),
which is not what a struct member can be.

gettimeofday. tcc.c:283 calls it, libtcc.c never did, M2libc has no time
syscall. Added to runtime.c returning constant zero.

DETERMINISM, AUDITED RATHER THAN ASSUMED. The first version of that stub's
comment said "the only consumers are the -bench counters". That was a guess
that happened to be right, and it was written as though it were a finding.
Every clock source in the tcc tree, checked:

    gettimeofday   tcc.c:283 ONLY -- -bench, printed to stderr, read by nothing
    time()         tccpp.c:3425, expanding __DATE__/__TIME__ -- this one DOES
                   reach emitted bytes, and runtime.c already stubs it to 0
    ar_date        NOT clock-derived: tcctools.c initialises it to the literal
                   "0           ". tcc's -ar is deterministic by construction.
                   I claimed the opposite before checking.
    tccpe.c:761    TimeDateStamp, commented out upstream; PE is not a target

So the clock surface is clean. A wider audit of the same shape -- getpid,
uname, environment, directory order -- has NOT been done and is worth one pass
rather than one function at a time. rung1.sh already fights one instance of it
in its DW_AT_comp_dir note.

IT LINKS AND THEN SIGBUSES. 1,564,793 bytes, faults immediately. NOT
DIAGNOSED. Recorded as open rather than guessed at.

AND A FINDING THAT AFFECTS THE BINARY SHIPPING TODAY. The joined .M1 has 80
duplicate :GLOBAL_ labels, including :GLOBAL_STR_g_0_contents twice -- micro-c
numbers generated string labels from zero PER COMPILATION UNIT, so units
collide when joined. Checked against the WORKING mc-tcc build: identical 80
collisions. So it is not new and not the SIGBUS cause, but a string reference
may bind to another unit's string. Invisible to every test we have, because
the twelve programs and all 87 difftest cases are single-unit.

--------------------------------------------------------------------------------
A DATA-CORRUPTION BUG THAT WAS ALREADY IN THE SHIPPING BINARY.
--------------------------------------------------------------------------------

Found by grepping the joined .M1 for duplicate labels while chasing an
unrelated SIGBUS. Not by any test, because no test could see it.

declare_function resets current_count to 0 on every function. Correct for the
eight call sites that build create_unique_id("", function->s, n) -- the
function name disambiguates. WRONG for the one that builds
create_unique_id("STR_", "g", n), a GLOBAL string initialiser with no function
to name. Two globals separated by any function declaration both get STR_g_0.

hex2's AddHash inserts at the HEAD and GetTarget returns the first match, so
the LAST definition wins and the earlier global reads the later one's bytes.
M1 and hex2 both accept duplicate labels silently.

    41 colliding labels in libtcc.c alone. STR_g_0_contents was defined as
    both "alm.?" and "%s/lib%s.so".

NOT A REGRESSION FROM THIS WORK. The mc-tcc that reports 12/12 has the
identical collisions.

WHY NO TEST COULD SEE IT. A collision needs two global string initialisers
with a function declaration between them. All 87 cases and all twelve
end-to-end programs are a single small unit. This is the third structural
blindness recorded in this file -- after "every array-of-pointers case used
long*" and "a case can pass because both sides are broken identically" -- and
it is the worst of them, because the suite was green over a live corruption in
the binary it was certifying.

THE CHECK THAT SEPARATED HARMFUL FROM BENIGN. 39 duplicate :GLOBAL_ labels
REMAIN after the fix -- errno, file, anon_sym, char_pointer_type, reg_classes.
Those are tentative definitions: tcc.h declares them with ST_DATA (empty under
ONE_SOURCE) and the .c defines them again. Every one emits NULL, so references
bind to one definition whose contents are IDENTICAL to the other's. Harmless.
The STR_g ones were harmful precisely because their contents DIFFERED, and
comparing contents is the test that tells the two apart. "Duplicate label" on
its own is not a verdict.

FIXED by a second counter, current_count_global, that nothing resets. NOT by
removing the reset: it is load-bearing for the other eight sites.

    difftest aarch64 87/0 -> 88/0    twelve programs 12/12 unchanged
    joined .M1 duplicates 80 -> 39   all 39 verified identical-contents

WORTH DOING ONCE, PROPERLY: a duplicate-label check on the joined .M1 as a
build-time gate, comparing CONTENTS and failing only on a difference. That
would have caught this the day it appeared instead of on a grep months later.

--------------------------------------------------------------------------------
mc-tcc IS A WHOLE tcc. tcctools.c:60 closed; the driver is tcc's own.
--------------------------------------------------------------------------------

    $ mc-tcc --version
    tcc version 0.9.28rc (AArch64 Linux)

micro-c compiles tcc.c UNMODIFIED -- 707 functions against libtcc's 695. -E,
-c, -print-search-dirs and MULTIPLE INPUT FILES all work, because they are
tcc's code and always were. Two files in one invocation compile, link and run.

THE FEATURE. `static const ArHdr arhdr_init` initialises char ARRAY members
from string literals, and the bytes belong at the member's own offset -- the
struct is memcpy'd into an archive header and written to a file. micro-c's
other string path emits a POINTER to storage elsewhere, which a member cannot
be. ar_fmag decides the rule: two bytes from a two-character string, no room
for a terminator, so the emitter writes exactly member->size bytes and never
appends a NUL by assumption. ARFMAG is a backtick and a NEWLINE -- three source
characters, two data bytes -- so escapes are decoded, reusing escape_lookup
rather than adding a ninth copy of the rule.

IT NEARLY GOT STUBBED, and the argument against is the one worth keeping: `tcc
-ar` is on the critical path because gcc needs binutils, binutils must be built
BY tcc, and building it means creating libbfd.a before any ar exists. Zeroing
the initialiser does not degrade gracefully either -- ar_name and ar_fmag are
format-critical, so a zeroed struct writes INVALID archives.

A SECOND FAULT SURFACED ONLY WHEN tcc.c WAS LINKED, and it was latent in the
shipping build. The .M1 join split TWO ways, at "# Program strings", leaving
each unit's GLOBALS glued to its code. A global holding a string is
arbitrary-length data sitting between one unit's code and the next unit's
functions. Harmless while libtcc.M1's globals happened to total a multiple of
four; fatal once tcc.c added

    :GLOBAL_STORAGE_version  "tcc version 0.9.28rc (AArch64 Linux)\n"

-- every function after it misaligned, SIGBUS before main. micro-c emits THREE
sections ("# Core program", "# Program global variables", "# Program strings")
and the join now honours all three. Fixed in local-tcc.sh AND in
stage3-hermetic-arm64.yml, which had its own copy.

STEP 11 WAS NEVER A VALID TEST. It passes a test file AND a crt; main-tcc.c
held ONE pointer and each argument overwrote the last, so it compiled the crt
alone and tcc correctly reported `undefined symbol 'main'`. A true message
about an invalid test, recorded as a stage-3 capability failure for rounds.
main-tcc.c is superseded, kept only for bisecting "compiler or driver", and it
now REFUSES a second input instead of quietly using the last. A tool that
cannot do a thing must say so.

VERIFIED FROM A PRISTINE TREE at b1361a3 plus this overlay:

    55 micro-c patches, 11 m2libc patches, all apply
    difftest amd64   87/0        difftest aarch64  89/0
    stage-2 corpus   419 (floor) twelve programs   12/12
    local-tcc.sh     707 functions, 1,564,793 bytes, --version answers

WHAT IS LEFT. realloc -- step 11 now fails on it honestly rather than on a
harness defect, and it is 46 of 57 real failures across tcc's tests2. That is
the whole of the remaining distance to a tcc that autoconf can drive.

--------------------------------------------------------------------------------
realloc IS A SYMPTOM. The allocated list is losing nodes.
--------------------------------------------------------------------------------

Four hypotheses died before the right question got asked. The right question
was "what is actually AT that address", which the earlier table_ident hunt had
already used and which nothing here tried for three rounds.

    realloc: bad ptr        = 5779744
    realloc: nearest block  = 5779456      +288
    realloc: nearest size   = 256          ptr is 32 past its end
    realloc: ptr[-4] (next?)= 6927552
    realloc: ptr[-3] (blk?) = 5779744      EQUALS THE BAD POINTER
    realloc: ptr[-2] (size?)= 256
    realloc: ptr[-1] (used?)= 1            _IN_USE

The 32 bytes below the pointer are a struct _malloc_node whose block field is
that pointer, marked in use. THE BLOCK IS ALLOCATED, ITS NODE IS INTACT, AND
THE LIST DOES NOT REACH IT. The message was true of the LIST and false of the
HEAP.

288 IS NOT A STRUCTURE SIZE. It is the allocator's stride for a minimum block:
a 32-byte node plus a 256-byte block. The earlier note that "288 bytes apart"
might name a shared structure invited exactly the wrong reading, and this entry
retracts it. A recurring number is worth a grep and is not evidence.

RULED OUT BY MEASUREMENT, in the order they were tried and killed:

  1. the malloc/realloc signature mismatch -- main-06 crosses that boundary and
     passes. Written up as the answer before it was tested. Wrong.
  2. the allocator's reuse logic -- main-07, seven shapes, all pass
  3. use-after-free -- free-list walk silent, AND disabling free() entirely
     reproduces it unchanged. That is the strongest of the four: with nothing
     ever leaving the list, a stale pointer is impossible.
  4. interior pointer / tal_header_t skip -- range walk silent
  5. duplicate symbols -- _allocated_list, _free_list, malloc, free, realloc,
     _malloc_insert_block all defined exactly once

WHAT IT IS: a next pointer in the chain has been clobbered, so the walk stops
early. Heap corruption by a store with a wrongly-computed address, upstream of
the allocator entirely -- the same shape as the table_ident report, which was
recorded as closed and probably never was.

NEXT, AND NO WATCHPOINT NEEDED: a monotonic count of nodes inserted, compared
to the reachable count at every allocator entry. The first divergence brackets
the corruption between two allocator calls; the marker trail names the
function from there. qemu-user's gdbstub answers Z0/Z1 and refuses Z2/Z3/Z4, so
watchpoints are not available and this is the route.

AND THE WORDING FIX OWED FROM LAST ROUND: "micro-c compiles tcc.c unmodified"
meant "without the measurement stub", not "pristine upstream". The tcc tree is
tcc at pin 5ec0e6f8 PLUS spikes/stage3/patches/tcc-arm64-asm/ -- five patches
supplying an ARM64 assembler upstream lacks, applied into the committed tarball
(toolbox/README.md:77) and re-applied by the workflows. Stage 3's deliverable is
tcc-at-pin-plus-five-patches, not tcc. The accurate claim is that micro-c
compiles all of tcc.c with NO change made for micro-c's benefit.

--------------------------------------------------------------------------------
THE DETECTOR FIRES: 62 nodes lost in one store, and the neighbour is .eh_frame.
--------------------------------------------------------------------------------

A node is created once and afterwards only MOVES between lists, so
reachable(allocated) + reachable(free) == created, always. m2libc 0011 checks
that at every malloc and free, with bounded walks so a chain clobbered into a
CYCLE reports instead of hanging.

    MALLOC CHECK: NODES LOST at malloc
      nodes created = 79   reachable = 17   lost = 62
      last node addr = 6877408   its block = 6877440 (512)
      its next (BAD) = 0

62 cut off in ONE store, so the break is near the head. `next` sits at offset 0
of the node, 32 bytes before its block -- exactly where the PREVIOUS block's
data ends. An overrun of the neighbour, not a stray write.

THE NEIGHBOUR, IDENTIFIED FROM ITS CONTENTS:

      OVERRUN SOURCE blk = 6877152 (256)
       word[1] = 0x011e780400527a01
               = 01 7a 52 00 04 78 1e 01
                 version 1, augmentation "zR", code align 4,
                 data align SLEB -8, return-address register 30

A DWARF CIE for aarch64, with CFA opcodes in the tail. THE OVERRUNNING BLOCK IS
tcc's .eh_frame SECTION DATA. Reading the bytes named the owner in one step;
three rounds of reasoning about distances had not.

RULED OUT SINCE, each by reducing the logic to a small program and diffing the
exit code against gcc -- no tcc build, seconds per round:

  * CString growth: the `size > cstr->size_allocated` gate, cstr_realloc's
    doubling, the 16-byte layout. Correct.
  * section_add: `(sec->data_offset + align - 1) & -align` with a 4-byte int
    align against 8-byte unsigned long offsets, the growth gate, 400 iterations
    checking allocated never falls behind offset, and that the mask
    sign-extends rather than clearing the top half of a 64-bit value. Correct.

So the bookkeeping is right and something writes past the end anyway. NEXT: who
writes .eh_frame. A pointer taken from section_ptr_add and held across a later
section_realloc writes through a STALE BASE -- the classic shape, and not
covered by either probe above.

THE DETECTOR IS A DEBUGGING PATCH, NOT A SHIPPING ONE. It walks both lists at
every malloc and free, which is O(n^2) over a run. It is in because the fault
is live; it should come out when the corruption is fixed.

--------------------------------------------------------------------------------
THE CORRUPTION, FOUND -- AND THE FIRST FIX FOR IT WITHDRAWN.
--------------------------------------------------------------------------------

    *f(8)   is   *(f(8))

primary_expr_variable eats the stars and parks the count in
num_dereference_after_postfix for the postfix walk. THE ARGUMENT LIST IS PARSED
BETWEEN THOSE TWO POINTS, and every argument is a full expression that reads
the same global:

    mov_x0,8            # primary expr number
    ldrsw_x0,[x0]       # <-- dereferencing the literal 8 as an address
    str_x0,[x18,-8]!    # function argument

tcc writes EVERY BYTE of .eh_frame through this shape -- tccdbg.c:550,
`*(uint8_t*)section_ptr_add((s), 1) = (data)`. In a twelve-line program the
bogus address is unmapped and it segfaults, which is why no case caught it. In
tcc the address is usually MAPPED, the access silently succeeds against the
wrong memory, an allocator node's `next` gets a small value, and 62 of 79 nodes
drop off the list. It surfaced as "realloc: pointer was never returned by
malloc" -- true of the LIST, false of the HEAP.

THE DIAGNOSIS IS SOLID. THE FIX WAS NOT.

EXPERIMENT-zzzg saved and restored the count around the argument list. It made
case 105's read forms pass, difftest stayed 89/0, the 426-corpus stayed at 419
-- AND IT TOOK mc-tcc FROM 12/12 TO 0/12 ON THE END-TO-END PROGRAMS. Bisected:
the num_dereference_after_postfix save/restore alone does it; the Address_of
half is innocent. Withdrawn.

WHAT THAT SAYS ABOUT THE GATES. difftest (89 cases) and the stage-2 corpus (426
programs) were BOTH GREEN over a change that breaks every one of the twelve
end-to-end programs. Neither suite compiles tcc. The twelve programs are the
only gate that exercises micro-c's output ON A REAL PROGRAM, and they take a
tcc build to run -- so the cheap suites cannot stand in for them. RUN THE TWELVE
BEFORE BELIEVING ANY CODEGEN CHANGE. I ran difftest and the corpus after zzzg,
saw green, and shipped it; the twelve were run one step later and were red.

There is a note in the file already about why this is delicate:

    /* CONSUMED HERE. This branch applies the dereference itself, so the
     * deferred count added for `*bf->buf_end` must be cleared or
     * postfix_expr applies it a SECOND time -- which is exactly what broke
     * `*pal = al` and sent tcc backwards from line 660 to 177. */

So the count is cleared deliberately on at least one path, and restoring it
unconditionally after an argument list resurrects it somewhere that had already
consumed it. A correct fix has to know WHICH pending count belongs to the call
and which belongs to an enclosing expression, and the global cannot express
that. That is the same structural problem this file counts eight
implementations of, and it is the argument for carrying the type on the
expression rather than in a global.

THE ROUTE THAT FOUND IT, since none of the reasoning did:

  1. classify the bad pointer three ways (free list / interior / neither)
  2. READ THE MEMORY AT IT -- the 32 bytes below were a _malloc_node whose
     block field WAS the pointer. The block is live; the list cannot reach it.
  3. a node-loss detector: created vs reachable, checked every malloc and free,
     bounded so a cycle reports instead of hanging. 62 lost in ONE store.
  4. READ THE NEIGHBOUR'S BYTES -- a DWARF CIE, augmentation "zR",
     return-address register 30. .eh_frame.
  5. reduce the writer's shape to twelve lines and diff against gcc.

Steps 2 and 4 are the same move and both were decisive. Three rounds of
reasoning about distances produced nothing; reading the bytes produced the
answer twice.

THE DETECTOR IS NOW OPT-IN. Left armed it walks both lists at every malloc and
free, which changes the timing and the heap of the program under test -- and I
measured a "regression" against a contaminated tree before noticing. Set
_malloc_check_armed to 1 by hand. The failure-path diagnostics cost nothing and
stay on.

ALSO: the hermetic job truncated stderr to `head -3`, so the diagnostic that
does all this work printed three lines and stopped. Widened to 30 in both
places. A diagnostic nobody can read is not a diagnostic.

--------------------------------------------------------------------------------
CI, commit 5bf4bac: all three jobs green, and stage 3 says "end to end: yes".
--------------------------------------------------------------------------------

stage3-hermetic-arm64, run 82972144199 -- GREEN.

    micro-c (ours)                   422320  083abe4a65edf263
    mc-tcc (ours, end to end)       1575057  c644e111c6c70b65
    00-does-it-start            rc=0  tcc version 0.9.28rc (AArch64 Linux)
    01..12                            all ok
    stage 3 end to end: yes

That version line is tcc's OWN driver, from a tcc built by the seed ladder.
GATE 1 passed in the same run -- ours-gen1.M1 == ref-gen1.M1, 2947903 bytes,
dc38e13e4ceaeecb -- with BUDGET_PATH EMPTY, busybox the only driver, NO
EMULATOR (native aarch64) and no network.

STEP 11'S DIAGNOSTIC NOW PRINTS, and the native heap reproduces the local
finding exactly:

    realloc: bad ptr        = 165789984
    realloc: nearest block  = 165787968      +2016
    realloc: nearest size   = 256
    realloc: ptr[-3] (blk?) = 165789984      EQUALS THE BAD POINTER
    realloc: ptr[-2] (size?)= 256
    realloc: ptr[-1] (used?)= 1

The DISTANCE differs from the local run -- 2016 rather than 288, because the
runner's heap is laid out differently -- and THE NODE SIGNATURE IS IDENTICAL.
Two different allocator layouts, same fault: a live block whose node is intact
and unreachable. That is worth more than either measurement alone, and it is
the answer to the earlier temptation to read 288 as a structure size.

tcc-two-ways, run 82971079942 -- GREEN, and much further than run 82952884599,
which died at imm-identity before reaching any subject step.

    byte-identical 170   moved 8 (declared 8, undeclared 0)
    difftest clean on aarch64
    aarch64  426 rows: pass 419
    realloc GROWS AND PRESERVES correctly      (the standalone probe)
    SIGNAL 11 -- past the link inputs, crashing in output      (step 21)

STEP 21 IS NEW GROUND, NOT A REGRESSION. It compiles a trivial program and
LINKS IT AGAINST THE SYSTEM crt AND glibc, borrowing libtcc1.a from the
control, and crashes inside tcc_output_file after the input file was added.
Everything else stage 3 measures is -nostdlib -static single-file, so this is
the FIRST measurement of the libc-facing surface -- the one WHAT-STAGE-4-NEEDS
lists as entirely unmeasured. The previous run never got there.

A PREDICTION OF MINE THAT WAS RIGHT FOR THE WRONG REASON. I said tcc-two-ways
would stay green after the hermetic job moved to tcc.c and the three-way join,
having tested only that the old-shape binary answers --version. It is green,
but --version was the wrong test: the step that matters is a full LINK, and
both shapes compile a file to an object fine locally. The old shape's alignment
safety is still luck, and that job still builds libtcc.c + main-tcc.c with the
TWO-way join.

micro-c-builds-tcc, run 82971079882 -- GREEN. Every link set runs to exit 42,
tcc_new completes. BUT IT REPORTS

    skipped 0004-... -- other revision        (and 0005 through 0011)

so it builds against an m2libc carrying only patches 0001-0003. Pre-existing
and deliberate for that job's pin, and it means its results say NOTHING about
the aarch64 encoding fixes, the narrowing-cast macros or the realloc
diagnostics. Do not read it as a second opinion on them.
