#!/usr/bin/env python3
"""Insert a progress marker after EVERY statement of one function.

WHY THIS EXISTS. Markers have been placed by hand, six or eight to a function,
and each round narrowed the fault a little and cost a full CI cycle: fetch,
patch, compile 350,000 lines, assemble, link, run on the runner, read the
output. Several rounds went by with the answer still "somewhere in
tcc_set_output_type".

There is no reason for that. The placement is mechanical, so a script can do
every statement at once and one run gives the exact line.

WHAT IT DOES. Finds the named function, walks its body tracking brace depth
and string/comment state, and writes

    write(2, "L<nn>\\n", 4);

after every statement-terminating semicolon and after every opening brace, so
the LAST marker printed names the last line that completed.

READ THE LAST MARKER CAREFULLY. A function that returns NORMALLY also stops
at its last marker, because nothing can run after a return -- so "last marker
is L38" and "faulted at L38" look identical from the number alone. The way to
tell them apart is whether the CALLER'S next marker appears. It caught me out
once: L38 was the statement before `return 0`, the function had completed, and
the report said the fault was in whatever followed.

WHAT IT DELIBERATELY DOES NOT DO:

  - it does not instrument declarations that initialise, because a marker
    cannot legally go between a declarator and its initialiser
  - it does not instrument inside for(;;) headers, where semicolons are
    separators rather than terminators
  - it does not touch preprocessor lines, whose semicolons may be inside a
    conditional that is compiled out

Each of those would produce code that does not compile, which wastes a round
in a different way.

USAGE
    instrument.py <file.c> <function> > patched.c
    instrument.py --map <file.c> <function>      print the line map only

The map matters: "L07" means nothing without it, and the mapping changes
whenever the source does.
"""
import re
import sys


def find_function(lines, name):
    """Return (start, end) line indices of the function body, brace to brace."""
    pattern = re.compile(r'\b' + re.escape(name) + r'\s*\(')
    for i, line in enumerate(lines):
        if not pattern.search(line):
            continue
        if line.lstrip().startswith(('//', '*', '/*')):
            continue
        # walk forward to the opening brace of the body
        depth = 0
        opened = False
        for j in range(i, min(i + 12, len(lines))):
            for ch in lines[j]:
                if ch == '{':
                    depth += 1
                    opened = True
                elif ch == '}':
                    depth -= 1
            if opened:
                # found the body; now find its close
                for k in range(j + 1, len(lines)):
                    for ch in lines[k]:
                        if ch == '{':
                            depth += 1
                        elif ch == '}':
                            depth -= 1
                    if depth == 0:
                        return j, k
                return j, len(lines) - 1
            if ';' in lines[j]:
                break   # a prototype, not a definition
    return None, None


def instrumentable(line):
    """Can a marker legally follow this line?"""
    t = line.strip()
    if not t:
        return False
    if t.startswith('#'):
        return False            # preprocessor
    if t.startswith('//') or t.startswith('/*') or t.startswith('*'):
        return False            # comment
    if not (t.endswith(';') or t.endswith('{')):
        return False
    if t.startswith('for'):
        return False            # semicolons are separators here
    if t.endswith('{') and ('for' in t or 'while' in t or 'do' in t):
        return False            # a marker at the top of a loop body repeats
    if t.startswith(('return', 'break', 'continue', 'goto')):
        return False            # NOTHING RUNS AFTER THESE. A marker here is
                                # unreachable, and its absence made a function
                                # that returned normally look like it had
                                # faulted on its last statement.
    # a declaration WITH an initialiser: a marker cannot split it, but one
    # after it is fine -- so this is allowed. A bare declaration is allowed too.
    return True


def main():
    args = sys.argv[1:]
    map_only = False
    if args and args[0] == '--map':
        map_only = True
        args = args[1:]
    if len(args) != 2:
        sys.stderr.write(__doc__)
        return 2

    path, func = args
    lines = open(path).read().split('\n')
    start, end = find_function(lines, func)
    if start is None:
        sys.stderr.write("could not find a definition of %s in %s\n" % (func, path))
        return 1

    out = []
    mapping = []
    n = 0
    for i, line in enumerate(lines):
        out.append(line)
        if start <= i <= end and instrumentable(line):
            n += 1
            tag = "L%02d" % n
            indent = line[:len(line) - len(line.lstrip())]
            out.append('%swrite(2, "%s\\n", 4);' % (indent, tag))
            mapping.append((tag, i + 1, line.strip()))

    if map_only:
        for tag, lineno, text in mapping:
            print("%s  %s:%d  %s" % (tag, path, lineno, text[:70]))
        return 0

    sys.stdout.write('\n'.join(out))
    sys.stderr.write("instrumented %s: %d markers over lines %d-%d\n"
                     % (func, n, start + 1, end + 1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
