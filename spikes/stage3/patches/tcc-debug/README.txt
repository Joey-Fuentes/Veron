DEBUG INSTRUMENTATION ONLY. NOT A CHANGE TO tcc.

Every line these patches add is a write(2, "...", n) call. No logic, no
semantics, nothing that could alter what tcc compiles or how. They exist
because a segfault says WHICH SIGNAL and not WHICH STATEMENT, and the probe
ladder can only test what can be called across a function boundary.

They are applied to a SCRATCH COPY of tcc, in the debug stage only. The
control -- tcc built by gcc and put through its own test suite -- is built
from an untouched tree, so the comparison between the two stays honest.

WHY THIS MATTERS ENOUGH TO WRITE DOWN. tcc works. It compiles gcc; the
resulting toolchain boots Linux. When a tcc built by micro-c misbehaves and
one built by gcc does not, the difference is in micro-c or in how we built it,
and that has been true of every single fault found so far:

    duplicate globals from concatenating translation units    ours
    string data not padded, so functions landed unaligned     ours
    array members loaded instead of decaying to an address    ours
    array members sized by the element's target type          ours
    &s->member not loading s first                            ours
    free(NULL) exiting instead of returning                   M2libc's
    every harness bug in between                              ours

Nothing in that list is a tcc bug, and the default assumption should stay
that the next one will not be either.

The separate patches in ../tcc-arm64-asm/ ARE real changes to tcc and predate
this work: they implement the ARM64 assembler, which upstream tcc does not
have. Those are in the build path for both sides.
