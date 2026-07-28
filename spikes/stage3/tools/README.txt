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
