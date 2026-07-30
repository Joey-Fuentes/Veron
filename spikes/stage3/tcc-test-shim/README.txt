Just enough libc to run tcc's own tests inside the box.

tests/tests2/00_assignment.c wants three things this box does not have:
<stdio.h>, a printf, and something to call main(). All three are here, in C
that mc-tcc compiles itself, linked with -nostdlib.

WHAT printf SUPPORTS: %d %i %u %x %c %s %ld %lu %lx %%. Anything else prints

    [shim: printf %g is not implemented]

and exits 70. It does NOT guess. A shim that quietly mishandled a conversion
would make a test fail as though the compiler were wrong, and telling those two
apart is the entire point of running the suite.

WHAT THIS IS NOT: a libc. There is no malloc, no file I/O, no setjmp, no float
formatting. Of the first thirty tests in tests2, thirteen run against it; the
rest want things a real libc provides and are not attempted.

THE CONTROL DECIDES WHICH TESTS COUNT. Every test is first run through a tcc
built by gcc from the same pinned source. If the control's output does not
match the .expect file, the test is not included -- it is measuring a gap in
this shim, not a defect in the compiler we built.
