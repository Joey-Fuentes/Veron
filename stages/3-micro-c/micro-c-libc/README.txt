Minimal headers micro-c needs that M2libc does not provide.
===========================================================

WHY THESE EXIST. The gap probe stubbed ten headers EMPTY to find out how far
tcc gets. That worked -- it walked from "hangs forever" to tcc.h:858 -- and
then the empty stubs started biting, because tcc actually uses a little of
what they should declare.

WHY OURS AND NOT A FORK OF M2libc. M2libc is upstream's and GPL-3. What tcc
needs here is about sixty lines of types and constants, so writing them is
cheaper than carrying a fork, and it keeps this side of the tree MIT.

WHAT THESE ARE NOT. Not a libc. There is no implementation behind them -- no
setjmp, no mmap. They are declarations sufficient for tcc's SOURCE to parse,
and every function declared here has to be supplied by something before a
built tcc could run. That is deliberate and it is the same staging the probe
has used throughout: make the next thing measurable, do not pretend it works.

MEASURED, NOT GUESSED. Every symbol below is one the probe reported as
missing, with the count of uses in the pinned tcc tree:

    assert    85     PROT_READ etc  6     longjmp   6
    setjmp     5     mmap           5     jmp_buf   3
    munmap     2     time_t         1     sem_t     1

=============================================================================
LAYOUT AUDIT

Prompted by micro-c turning out not to align struct members at all. Anything
in this directory whose layout must match something OUTSIDE micro-c was
checked field by field against gcc, and against the kernel where that is what
the struct talks to.

    sys/ucontext.h   mcontext_t size, uc_mcontext offset 168   AGREES
    setjmp.h         jmp_buf 256 bytes, setjmp uses 32          SAFE
    semaphore.h      opaque, and sem_* are stubs                SAFE
    sys/time.h       timeval is two longs, 8 bytes each         AGREES

    signal.h         siginfo_t.si_code at 16, kernel says 8     WRONG, FIXED
    signal.h         struct sigaction in glibc's field order,
                     not the kernel's                           WRONG, FIXED
    time.h           struct tm 72 bytes, should be 36           WRONG, FIXED

THE COMMON CAUSE of all three is micro-c's EIGHT-BYTE `int`. Written with
plain int, every 4-byte field is twice its proper size and everything after it
sits at the wrong offset. The structs that were already right are right
because they were written with uint64_t and pointers throughout -- which was
done deliberately for the 8-byte int, and turns out to have protected them
from the alignment problem as well.

NONE OF THE THREE HAS EVER CAUSED A FAILURE, because all of them are only
reached through functions that are stubbed: sigaction returns 0 without
calling the kernel, localtime returns NULL. So the bugs were latent, and would
have surfaced the first time signals or time became real -- as a handler
installed on the wrong signal with the wrong flags, which is a miserable thing
to debug.

RULE FOR THIS DIRECTORY: any struct that crosses a boundary -- to the kernel,
to hand-written assembly, or to a library compiled by something else -- uses
explicitly sized types for every field. `int` is not a width here.
