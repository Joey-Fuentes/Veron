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
