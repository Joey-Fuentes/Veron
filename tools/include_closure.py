#!/usr/bin/env python3
"""Every header a set of C files needs, transitively, in dependency order.

    include_closure.py <dir> <file.c> [file.c ...]

Prints one header path per line, relative to <dir>, ordered so that a header
always appears BEFORE anything that includes it.

WHY THIS EXISTS. The hermetic build does not compile and link -- it
CONCATENATES sources into one translation unit and feeds it to stage 2. So a
header is not a convenience there, it is the only place a type exists, and
ordering is not cosmetic: a struct must be defined before the line that uses
it.

The .c list is derived from upstream's makefile because a hand-written list
goes stale -- no-host-chain's header records three wrong ones in a row. The
same reasoning applies to headers, but the makefile does not list them: it
lists translation units, which is correct for a real compile and useless here.

THE OBVIOUS VERSION IS WRONG, AND IT SHIPPED. Scanning only the .c files finds

    hex2.c, hex2_linker.c, hex2_word.c   ->  #include "hex2_globals.h"

and stops. But `struct entry` and `struct input_files` are defined in hex2.h,
which is reached one level further down:

    hex2_globals.h                       ->  #include "hex2.h"

With hex2.h absent, hex2.c:34 asks stage 2 for `sizeof(struct entry*)` -- a
type it has never seen. That cost a CI run, and it read as "our hex2 crashes"
for far longer than that, because stage 2 segfaulted on the unknown type
instead of saying so. Both halves are fixed now: stage 2 diagnoses it, and the
closure below is transitive.

ORDER IS A TOPOLOGICAL SORT, NOT THE DISCOVERY ORDER. hex2_globals.h is found
first and must be emitted second, because it includes hex2.h. Emitting them in
the order they were found would put the use before the definition and fail in
a way that looks like a compiler bug rather than a list bug -- which is the
same trap, one layer along.

Only `#include "..."` is followed. `#include <...>` is the system set, which a
freestanding unit does not have and must not acquire by accident.
"""
import os
import re
import sys

INCLUDE = re.compile(r'^\s*#\s*include\s*"([^"]+)"', re.M)

UNRESOLVED = []


def includes_of(root, path):
    """Quoted includes of one file, resolved relative to it and to root."""
    full = os.path.join(root, path)
    try:
        with open(full, errors='replace') as f:
            text = f.read()
    except OSError:
        return []
    here = os.path.dirname(path)
    out = []
    for name in INCLUDE.findall(text):
        # Relative to the including file first, as a C compiler would, then
        # relative to the tree root. Anything else is not ours to guess at.
        for cand in (os.path.normpath(os.path.join(here, name)), name):
            if os.path.exists(os.path.join(root, cand)):
                out.append(cand)
                break
        else:
            # AN INCLUDE THAT CANNOT BE RESOLVED IS FATAL, NOT SKIPPED.
            #
            # The first version dropped it and said nothing, and that is the
            # exact failure this tool was written to stop -- one level along.
            # A quoted include names a file the unit needs; if it is missing,
            # the type it defines is missing, and stage 2 meets an unknown
            # type somewhere far away from here.
            #
            # It bites for real: spikes/reference/mescc-tools/M2libc is an
            # EMPTY submodule directory, so M1-macro.c's
            # `#include "M2libc/bootstrappable.h"` resolves in CI against the
            # fetched pin and not at all against the vendored copy. Silently,
            # that is an M1 unit missing its header and a puzzling failure
            # later. Loudly, it is one line naming the file.
            UNRESOLVED.append((path, name))
    return out


def closure(root, seeds):
    """Every header reachable from seeds, ordered dependencies-first.

    Depth-first post-order: a file is emitted only after everything it
    includes has been. A cycle -- which a header guard makes harmless in a
    real compile but which has no meaning in a concatenation -- is broken at
    the point it closes, and reported, because silently picking one of two
    orders is exactly the kind of confident guess this file exists to stop.
    """
    order, done, onstack, cycles = [], set(), set(), []

    def visit(path):
        if path in done:
            return
        if path in onstack:
            cycles.append(path)
            return
        onstack.add(path)
        for dep in includes_of(root, path):
            visit(dep)
        onstack.discard(path)
        done.add(path)
        order.append(path)

    for s in seeds:
        visit(s)
    return order, cycles


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    root, seeds = sys.argv[1], sys.argv[2:]
    for s in seeds:
        if not os.path.exists(os.path.join(root, s)):
            sys.stderr.write("include_closure: no such file: %s\n" % s)
            return 1

    order, cycles = closure(root, seeds)
    if UNRESOLVED:
        for who, what in UNRESOLVED:
            sys.stderr.write("include_closure: %s includes \"%s\" -- "
                             "not found under %s\n" % (who, what, root))
        sys.stderr.write("include_closure: refusing to emit an incomplete "
                         "list; a missing header is a missing type\n")
        return 1
    for c in sorted(set(cycles)):
        sys.stderr.write("include_closure: include cycle through %s -- "
                         "emitted at the point the cycle closes\n" % c)

    # The seeds are the caller's .c list and it owns their order; return only
    # the headers, which is what the caller cannot derive for itself.
    seedset = set(seeds)
    for p in order:
        if p not in seedset:
            print(p)
    return 0


if __name__ == '__main__':
    sys.exit(main())
