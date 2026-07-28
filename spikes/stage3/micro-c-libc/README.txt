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
