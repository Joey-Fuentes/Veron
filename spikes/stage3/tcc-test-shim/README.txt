Just enough libc to run tcc's own tests inside the box.

tests/tests2/00_assignment.c wants three things this box does not have:
<stdio.h>, a printf, and something to call main(). All three are here, in C
that mc-tcc compiles itself, linked with -nostdlib.

WHAT printf SUPPORTS: %d %i %u %o %x %X %c %s %%, the length modifiers
l / ll / z / h / hh, and WIDTH AND ZERO PADDING -- %08X and %-4d and %9s all
come out byte-identical to glibc. Precision is implemented for %s only.

THE ABORT IS SPLIT IN TWO, and that split is the point of this file's shape.

    [shim: ...]        exit 70   this file is missing something. Our fault.
    [needs-float: ...] exit 71   the conversion is fine and THE COMPILER is
                                 not: micro-c has no working floating point,
                                 so a %f here would format a wrong value with
                                 perfect precision.

Ten tests2 programs are in the second bucket. They were all being reported as
"[shim: %f is not implemented]", which reads as an incompleteness here and is
not one -- there is nothing to implement until micro-c can hold a double. The
two exit statuses let a harness count them apart without parsing text.

It still does NOT guess. A shim that quietly mishandled a conversion would make
a test fail as though the compiler were wrong, and telling those two apart is
the entire point of running the suite. Anything that would change CHARACTERS
rather than SPACING -- %#x, %+d, %.3d, %*d -- aborts rather than approximating.

_start IS ASSEMBLY, AND ARGV IS WHY. It used to be a C function calling main()
with no arguments, so 31_args printed whatever was in the argument registers.
The kernel does not pass argc in a register: sp POINTS AT it at process entry,
and a C prologue has already moved sp by the time you can read it. main is
called through a no-prototype function pointer, because a definition carries
its own prototype and `main(argc, argv, envp)` is rejected outright for two of
the three main shapes tests2 uses.

WHAT ELSE IS HERE: memset, memcpy, memmove, memcmp, strlen, strcpy, strcat,
strcmp, strncmp, strncpy, strchr, strrchr, sprintf, malloc/free/calloc/realloc
over a bump allocator, exit, abort, write, abs -- plus stddef.h, stdlib.h,
string.h, limits.h, stdint.h and assert.h. Not because a libc is the goal, but
because each was blocking a specific test at the CONTROL stage: seventeen
programs were sitting in "not applicable" for want of memset, memmove, strlen,
abort and write. tcc EMITS CALLS to memset and memmove itself for struct
assignment, so a test that names neither still needs both to link.

WHAT THIS IS STILL NOT: a libc. No file I/O, no setjmp, no wchar, no float
formatting, no threads. The tests that want those are not attempted.

THE CONTROL DECIDES WHICH TESTS COUNT. Every test is first run through a tcc
built by gcc from the same pinned source. If the control's output does not
match the .expect file, the test is not included -- it is measuring a gap in
this shim, not a defect in the compiler we built. The hermetic job has no
control and compares against .expect directly, which is why the needs-float
bucket exists there.
