#!/usr/bin/env python3
"""links.py -- do the four boxes actually form one ladder?

Each box is deliberately independent. Every one of them says so:

    hermetic-gcc10   "This box starts from a host-built cross toolchain,
                      DELIBERATELY, so that a failure here is gcc 10's and
                      not 4.7's."
    hermetic-gcc15   "starts from a host-built cross toolchain ON PURPOSE,
                      so a failure here is the SYSTEM's and not the ladder's."
    hermetic-gcc16   same, and both add: "this box never triggers another and
                      no other box triggers it."

That independence is the design and it is worth keeping: it is what makes a
failure localise to one question instead of blinding you to three others.

But it leaves one thing unchecked, and it is the thing the word "ladder"
depends on. Each box names the compiler it starts from and the compiler it
reaches, in its own env: block, with its own variable name. Nothing compares
them. If hermetic-gcc10 is bumped to reach gcc 15.3 while hermetic-gcc15 still
builds 15.2, both boxes stay green forever and the ladder has a hole in the
middle that no run will ever report -- the rung that was proven reachable is
not the rung that was proven to boot.

This checks exactly that, in about a second, by reading the workflow files.
It is not a substitute for flowing the actual artifact from one box to the
next; it is the cheap half, and it is the half that can run before four
multi-hour jobs rather than after them.

WHY THE VARIABLE NAMES ARE LISTED RATHER THAN GUESSED. The boxes do not agree
on naming -- gcc15 uses GCCVER, gcc16 uses GCC_VER, gcc10 uses GCCVER for what
it builds and GCC15/GCC16 for what it reaches. Pattern-matching that would make
this script fail open the moment someone renames a variable, which is precisely
when it needs to fail closed.
"""
import re
import sys

WF = ".github/workflows/%s.yml"


def env_of(name):
    """Read a workflow's top-level env: block. Deliberately not a YAML parse:
    these files carry ${{ }} expressions that a strict loader chokes on, and we
    only want scalar pins."""
    try:
        txt = open(WF % name).read()
    except FileNotFoundError:
        # FAIL CLOSED AND READABLE. A traceback here reads as "the checker is
        # broken" when what it means is "a box this ladder depends on is not
        # in the tree".
        print(f"    MISSING WORKFLOW: {WF % name}")
        return None
    m = re.search(r"^env:\n(.*?)^(?=\S)", txt, re.M | re.S)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        mm = re.match(r"\s{2}([A-Z][A-Z0-9_]*):\s*'([^']*)'", line)
        if mm:
            out[mm.group(1)] = mm.group(2)
    return out


# (description, from-box, from-var, to-box, to-var)
LINKS = [
    ("tcc's gcc 10 is the gcc 10 that reaches 15 and 16",
     "tcc-builds-gcc-arm64", "GCC10", "hermetic-gcc10", "GCCVER"),
    ("the gcc 15 that gcc 10 reaches is the gcc 15 that boots",
     "hermetic-gcc10", "GCC15", "hermetic-gcc15", "GCCVER"),
    ("the gcc 16 that gcc 10 reaches is the gcc 16 that boots",
     "hermetic-gcc10", "GCC16", "hermetic-gcc16", "GCC_VER"),
]

envs = {}
fail = 0
print("  the four boxes, and the pins that must meet:\n")
for desc, fbox, fvar, tbox, tvar in LINKS:
    for b in (fbox, tbox):
        if b not in envs:
            envs[b] = env_of(b)
    if envs[fbox] is None or envs[tbox] is None:
        print(f"    BAD  {fbox} -> {tbox}: a workflow file is absent")
        fail = 1
        continue
    a = envs[fbox].get(fvar)
    b = envs[tbox].get(tvar)
    ok = a is not None and a == b
    print(f"    {'ok ' if ok else 'BAD'}  {fbox}.{fvar}={a or '<missing>'}"
          f"  ->  {tbox}.{tvar}={b or '<missing>'}")
    print(f"          {desc}")
    if not ok:
        fail = 1
        if a is None or b is None:
            print("          ^^ a pin could not be read. Either the variable was"
                  " renamed or the")
            print("             env: block moved. This fails closed on purpose:"
                  " a link that")
            print("             cannot be read is not a link that holds.")
        else:
            print("          ^^ THE LADDER HAS A GAP HERE. One box proves it can"
                  " reach a")
            print("             compiler that the next box does not build. Both"
                  " will stay")
            print("             green; the chain between them does not exist.")
print()
if fail:
    print("  THE BOXES DO NOT COMPOSE.")
    print("  Fix the pins before spending four multi-hour jobs proving rungs")
    print("  that do not meet.")
    sys.exit(1)
print("  every link meets: the four boxes describe one ladder.")
