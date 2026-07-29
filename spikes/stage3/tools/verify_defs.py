#!/usr/bin/env python3
"""Check that each aarch64 M1 macro ENCODES WHAT ITS NAME SAYS.

WHY THIS IS NOT vocabulary.sh. That tool asks "does every macro micro-c can
emit exist for this architecture", and it closed a whole class -- four bugs
that were all "that instruction does not exist here". It cannot ask the next
question, which is whether the macro that does exist is correct.

    DEFINE add_x0,x16,x0 0020008b        ->  ADD x0, x0, x0, LSL #8

That is in M2libc's aarch64_defs.M1. It assembles, it links, it runs, and
vocabulary.sh is perfectly happy with it, because the macro exists. It is used
315 times in one compile of libtcc.c and every one of them computed garbage.

It surfaced as "struct assignment is broken on aarch64 and only aarch64",
which is a sentence that sends you looking at alignment for a couple of hours.
The real story was one instruction: the macro is the SOURCE-POINTER ADVANCE in
the struct copy, so an 8-byte struct worked (one chunk, the advance is never
used) and a 16-byte struct read its second word from address 2056.

THE RULE THIS ENFORCES. A macro's name is a specification. `add_x0,x16,x0`
says ADD x0, x16, x0 and nothing else. For register-to-register forms the
encoding is fully determined by the name, so the two can be compared by
machine rather than by eye -- and by eye is exactly how three of them got
through.

SCOPE, STATED HONESTLY. Only the forms whose encoding is fully determined:

    mov_xD,xS          MOV (register) = ORR Xd, XZR, Xm
    add_xD,xN,xM       ADD (shifted register), shift 0
    sub_xD,xN,xM       SUB (shifted register), shift 0

Everything else -- immediates, loads, stores, branches, condition codes -- is
left alone rather than half-checked. A checker that guesses is worse than one
with a stated boundary. amd64 is not covered at all: x86-64 is variable-length
and its encoding is not a function of the mnemonic in the same way.

Exit 0 if every checked macro agrees with its name, 1 otherwise.
"""

import re
import sys

# lr and sp/xzr share encodings 30 and 31; xzr and sp differ by context and
# these forms use xzr, which is what MOV (register) needs.
NAMED = {'lr': 30, 'sp': 31, 'xzr': 31}

MOV_BASE = 0xAA0003E0     # MOV Xd, Xm   = ORR Xd, XZR, Xm
MOVSP_BASE = 0x91000000   # MOV involving SP = ADD Xd, Xn, #0
ADD_BASE = 0x8B000000     # ADD Xd, Xn, Xm, LSL #0
SUB_BASE = 0xCB000000     # SUB Xd, Xn, Xm, LSL #0

# SP IS NOT XZR EVEN THOUGH BOTH ARE REGISTER 31.
#
# MOV Xd, Xm is an alias for ORR Xd, XZR, Xm, and in ORR the encoding 31 means
# XZR -- there is no way to name SP. So anything moving to or from SP uses a
# different alias entirely: ADD Xd, Xn, #0.
#
# Checking the sp forms against the ORR rule reported eight mismatches in a
# table where all eight were right. That is worse than not checking them: a
# gate with false positives gets switched off, and then the three REAL errors
# next to them go unnoticed too. Which is the whole reason this file exists.


def reg(s):
    s = s.strip()
    if s in NAMED:
        return NAMED[s]
    m = re.fullmatch(r'x(\d+)', s)
    if not m:
        return None
    n = int(m.group(1))
    return n if 0 <= n <= 31 else None


def word_of(h):
    """M1 definitions are little-endian hex bytes."""
    if len(h) != 8:
        return None
    try:
        return int.from_bytes(bytes.fromhex(h), 'little')
    except ValueError:
        return None


def expected(name):
    """The encoding a macro's own name demands, or None if not checkable."""
    m = re.fullmatch(r'mov_(x\d+|lr|sp),(x\d+|lr|sp|xzr)', name)
    if m:
        dn, sn = m.group(1), m.group(2)
        d, s = reg(dn), reg(sn)
        if d is None or s is None:
            return None
        if dn == 'sp' or sn == 'sp':
            # ADD Xd, Xn, #0 -- the only alias that can name SP
            return MOVSP_BASE | (s << 5) | d
        return MOV_BASE | (s << 16) | d

    m = re.fullmatch(r'(add|sub)_(x\d+|sp),(x\d+|sp),(x\d+|sp)', name)
    if m:
        base = ADD_BASE if m.group(1) == 'add' else SUB_BASE
        d, n, s = reg(m.group(2)), reg(m.group(3)), reg(m.group(4))
        if None in (d, n, s):
            return None
        return base | (s << 16) | (n << 5) | d

    return None


def describe(w):
    """Decode a shifted-register ADD/SUB so a mismatch says what it IS."""
    rd, rn = w & 0x1f, (w >> 5) & 0x1f
    rm, sh = (w >> 16) & 0x1f, (w >> 10) & 0x3f
    op = 'ADD' if (w & 0xFF000000) == 0x8B000000 else \
         'SUB' if (w & 0xFF000000) == 0xCB000000 else '???'
    tail = '' if sh == 0 else ', LSL #%d' % sh
    return '%s x%d, x%d, x%d%s' % (op, rd, rn, rm, tail)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write('usage: %s <aarch64_defs.M1>\n' % argv[0])
        return 2
    path = argv[1]

    checked = 0
    bad = []
    for line in open(path):
        parts = line.split()
        if len(parts) != 3 or parts[0] != 'DEFINE':
            continue
        name, hexle = parts[1], parts[2]
        want = expected(name)
        if want is None:
            continue
        got = word_of(hexle)
        if got is None:
            continue
        checked += 1
        if got != want:
            bad.append((name, hexle, got, want))

    print('  %s' % path)
    print('  register-to-register macros checked: %d' % checked)
    if not bad:
        print('  every one encodes what its name says')
        return 0

    print('  MISMATCHES: %d' % len(bad))
    for name, hexle, got, want in bad:
        print('    %-20s is %s  ->  %s' % (name, hexle, describe(got)))
        print('    %-20s should be %s' % ('', want.to_bytes(4, 'little').hex()))
    print()
    print('  A macro name is a specification. These do not meet it, and the')
    print('  programs built from them are wrong in a way that assembles,')
    print('  links and runs.')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
