#!/usr/bin/env python3
"""Rewrite object-like integer `#define`s as `enum` constants.

    defines_to_enums.py <srcdir> <outdir> <file> [file ...]
    defines_to_enums.py --list <srcdir> <outdir> <file> ...   report only

Reads <file>s under <srcdir>, writes transformed copies at the same relative
paths under <outdir>. Runs in the AIRLOCK, like tools/drop_asm.py -- the box
receives the result through pins/ and never sees a python interpreter.

WHY. stage 2 has no preprocessor. `nt_hash` skips a `#` line to end-of-line and
that is the whole of it, so `#define AARM64 0xB7` leaves nothing behind and
`AARM64` reaches stage 1 as an unresolved label.

It has never mattered until now, and the reason is worth writing down: M2-Planet
uses `#define` exactly ONCE in its entire source, `#define CC_H`, a bare include
guard with no value. Every constant in it is an `enum` -- because it was written
to be compiled by bootstrap compilers that have no preprocessor. mescc-tools is
the same author writing for a later rung, where one is assumed, so hex2 is the
first thing in this ladder to need it.

WHY NOT TEACH stage 2 `#define`. Because stage 2 already has the table this
needs. Enum constants live in a 16-byte-record table looked up by `ceid_var`,
and an object-like integer `#define` is that record exactly. Adding a second
mechanism to a hand-written assembler to express something the first one
already expresses is more surface for no capability -- and it is surface in
aarch64 assembly, where every one of these has cost a round.

WHAT IT WILL AND WILL NOT DO. Only `#define NAME <integer literal>`, decimal or
hex, becomes `enum { NAME = <integer>; }`. A bare `#define GUARD` is dropped:
this build CONCATENATES rather than compiles, so include guards have no meaning
and stage 2 was discarding them anyway.

Anything else -- function-like macros, expression bodies, string bodies,
`#undef`, conditional compilation -- is REFUSED, loudly, naming the line. A tool
that quietly half-translated its input would put a wrong constant into a linker
and let it emit wrong bytes, which is the failure mode this whole directory
exists to make impossible. Measured on the pinned tree the hex2 unit contains
sixteen value defines and every one is a plain integer, so the refusal path
should stay cold; if it ever fires, upstream changed and someone must look.

DUPLICATES ARE REAL. `TRUE` and `FALSE` are defined in both hex2.h and
M2libc/bootstrappable.h, and the unit gets both. Identical name-and-value pairs
are emitted once; a name redefined to a DIFFERENT value is an error, because
picking one silently is how a linker ends up with the wrong architecture number.
"""
import os
import re
import sys

DEFINE = re.compile(r'^[ \t]*#[ \t]*define[ \t]+([A-Za-z_][A-Za-z0-9_]*)([ \t]*)(.*?)[ \t]*$')
INTEGER = re.compile(r'^[+-]?(0[xX][0-9a-fA-F]+|[0-9]+)$')
COMMENT = re.compile(r'/\*.*?\*/', re.S)
OTHER_PP = re.compile(r'^[ \t]*#[ \t]*(undef|if|ifdef|ifndef|elif|else|endif)\b')


def classify(line):
    """('enum', name, value) | ('guard', name, None) | ('keep', None, None) | raise."""
    m = DEFINE.match(line)
    if not m:
        return ('keep', None, None)
    name, gap, body = m.group(1), m.group(2), m.group(3)

    # A function-like macro is `NAME(` with NO space before the paren. With a
    # space it is an object-like macro whose body starts with a paren, which is
    # a different thing and also unsupported -- both are refused below, but the
    # distinction matters for the message.
    if body.startswith('(') and gap == '':
        raise ValueError("function-like macro")

    body = COMMENT.sub('', body).strip()
    if body == '':
        return ('guard', name, None)
    if not INTEGER.match(body):
        raise ValueError("body is not a plain integer literal: %r" % body)
    return ('enum', name, body)


def value_of(text):
    return int(text, 16) if text[1:2] in 'xX' else int(text, 10)


def main():
    args = sys.argv[1:]
    list_only = False
    if args and args[0] == '--list':
        list_only = True
        args = args[1:]
    if len(args) < 3:
        sys.stderr.write(__doc__)
        return 2
    root, outdir, files = args[0], args[1], args[2:]

    seen = {}       # name -> (value_text, file, lineno)
    errors = []
    report = []

    for rel in files:
        path = os.path.join(root, rel)
        try:
            with open(path, errors='replace') as f:
                lines = f.read().split('\n')
        except OSError as e:
            sys.stderr.write("defines_to_enums: %s: %s\n" % (rel, e))
            return 1

        out = []
        for i, line in enumerate(lines, 1):
            if OTHER_PP.match(line):
                # Conditional compilation would change WHICH lines exist, and
                # stage 2 discards it. Left exactly as it is, and reported, so
                # nobody assumes it was handled.
                report.append("%s:%d  left alone: %s" % (rel, i, line.strip()))
                out.append(line)
                continue
            try:
                kind, name, body = classify(line)
            except ValueError as e:
                errors.append("%s:%d  %s\n      %s" % (rel, i, e, line.strip()))
                out.append(line)
                continue

            if kind == 'keep':
                out.append(line)
            elif kind == 'guard':
                report.append("%s:%d  guard dropped: %s" % (rel, i, name))
                out.append("/* %s: include guard dropped -- this unit is "
                           "concatenated */" % name)
            else:
                prev = seen.get(name)
                if prev is None:
                    seen[name] = (body, rel, i)
                    report.append("%s:%d  %s = %s" % (rel, i, name, body))
                    out.append("enum { %s = %s };" % (name, body))
                elif value_of(prev[0]) == value_of(body):
                    report.append("%s:%d  %s = %s (duplicate of %s:%d, dropped)"
                                  % (rel, i, name, body, prev[1], prev[2]))
                    out.append("/* %s: same value already defined at %s:%d */"
                               % (name, prev[1], prev[2]))
                else:
                    errors.append("%s:%d  %s redefined as %s, was %s at %s:%d"
                                  % (rel, i, name, body, prev[0], prev[1], prev[2]))
                    out.append(line)

        if not list_only:
            dest = os.path.join(outdir, rel)
            os.makedirs(os.path.dirname(dest) or '.', exist_ok=True)
            with open(dest, 'w') as f:
                f.write('\n'.join(out))

    for r in report:
        print("  " + r)
    if errors:
        sys.stderr.write("\ndefines_to_enums: REFUSING -- %d directive(s) this "
                         "tool must not guess at:\n" % len(errors))
        for e in errors:
            sys.stderr.write("    %s\n" % e)
        return 1
    print("  %d constant(s) became enums, from %d file(s)" % (len(seen), len(files)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
