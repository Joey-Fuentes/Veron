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
    instrument.py [--prefix X] <file.c> <func>[,func2,...] > patched.c
    instrument.py --map [--prefix X] <file.c> <func>[,...]   the line map only

--prefix gives each FILE its own marker letter. Instrumenting two files with
the default produces two L07s, and the map cannot then say which one a marker
came from.

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


def prev_code_line(lines, i):
    """The nearest preceding line that is actual code, or None."""
    j = i - 1
    while j >= 0:
        t = lines[j].strip()
        if t and not t.startswith(('//', '/*', '*', '#')):
            return lines[j]
        j -= 1
    return None


# THE BYTE COUNT IS len(tag)+1, NOT 4.
#
# A marker is written with write(2, "P01\n", 4) -- three characters and a
# newline. That was hardcoded, so the hundredth marker onwards emitted
# write(2, "P100\n", 4) and dropped its newline:
#
#     P100Q1
#     Q3
#
# Two markers on one line. Every grep in the reporting is anchored with ^, so
# the second of each pair becomes invisible -- and it looks exactly like a
# statement that did not execute. I read that as a dropped statement and spent
# a round on it.
#
# Any file with more than 99 markers was affected, which by now is most of
# them: the tccpp.c set alone maps 286 statements.


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
    if re.search(r'[^=!<>+\-*/%&|^]=\s*\{$', t):
        # AN AGGREGATE INITIALISER ALSO ENDS IN `{`, and it does not open a
        # block:
        #     static char const ab_month_name[12][4] = {
        #         "Jan", "Feb", ...
        #     };                                        tccpp.c:3541
        # A marker after that line lands between the braces, where micro-c is
        # parsing a constant expression, and the error names the marker:
        #     Unable to find symbol 'write' for use in constant expression.
        #
        # The `=` has to be an ASSIGNMENT, not the tail of ==, !=, <=, >= or a
        # compound operator -- `if (a == b) {` really does open a block.
        return False
    if re.match(r'^(typedef|struct|union|enum)\b', t) and t.endswith('{'):
        # A type definition, likewise. Its body is a member list, not
        # statements.
        return False
    if t.endswith('{') and re.match(r'^(for|while|do)\b', t):
        # A marker at the top of a LOOP body repeats every iteration and
        # drowns the log.
        #
        # MATCHED AS A WORD, not a substring. `'do' in t` was true for
        #     if (s1->do_debug && filename) {
        # because "do" appears inside "do_debug" -- so the statement
        # immediately after the last one that completed was silently skipped,
        # which is the one statement the whole run existed to identify.
        return False
    if t.startswith(('return', 'break', 'continue', 'goto')):
        return False            # NOTHING RUNS AFTER THESE. A marker here is
                                # unreachable, and its absence made a function
                                # that returned normally look like it had
                                # faulted on its last statement.
    # a declaration WITH an initialiser: a marker cannot split it, but one
    # after it is fine -- so this is allowed. A bare declaration is allowed too.
    return True


# A control header with NO opening brace: the body is the single statement
# that follows it, and a marker placed after that statement is a SIBLING of
# the loop or branch, not part of it.
#
# This is not cosmetic. In tok_alloc,
#
#     for(i=0;i<len;i++)
#         h = TOK_HASH_FUNC(h, ((unsigned char *)str)[i]);
#
# the marker landed after the loop, so its frequency count read 1 no matter
# how many times the loop ran -- and 1 was read as "the loop ran once", which
# is a claim the instrument cannot make. The count was correct; the sentence
# underneath it was wrong, which is the same failure this file was written to
# stop.
#
# Worse, a braceless `if (c)\n    stmt;` followed by `else` puts the marker
# between the body and the else and does not compile at all.
BRACELESS = re.compile(r'^(if|for|while|else\s+if)\b.*\)\s*$')
BRACELESS_ELSE = re.compile(r'^else\s*$')


def opens_braceless_body(line):
    """Is this a control header whose body is the next statement, unbraced?"""
    t = line.strip()
    if t.endswith('{') or t.endswith(';'):
        return False
    return bool(BRACELESS.match(t) or BRACELESS_ELSE.match(t))


def is_single_line_branch(line):
    """`if (x) foo();` -- header and body on one line.

    A marker after it runs whether or not the branch was taken, so it cannot
    mean what every other marker means. Skipped rather than reported wrongly.
    """
    t = line.strip()
    if not t.endswith(';'):
        return False
    return bool(re.match(r'^(if|while|else)\b', t))


def main():
    args = sys.argv[1:]
    map_only = False
    prefix = 'L'
    if args and args[0] == '--map':
        map_only = True
        args = args[1:]
    if len(args) >= 2 and args[0] == '--prefix':
        # A DISTINCT LETTER PER FILE. Markers are numbered from 1 in whichever
        # file they come from, so instrumenting two files with the default
        # prefix produces two L07s and the map cannot say which is which.
        prefix = args[1]
        args = args[2:]
    if len(args) != 2:
        sys.stderr.write(__doc__)
        return 2

    path, funcnames = args
    lines = open(path).read().split('\n')

    # SEVERAL FUNCTIONS AT ONCE, comma-separated.
    #
    # Instrumenting one function is only useful while you already know which
    # one. When the failure moved from tcc_set_output_type into
    # tcc_compile_string there were NO markers there at all, so the report had
    # nothing to say and it looked like the fault had become invisible. It had
    # not; the instrument simply did not reach it.
    ranges = []
    for func in funcnames.split(','):
        func = func.strip()
        if not func:
            continue
        start, end = find_function(lines, func)
        if start is None:
            sys.stderr.write("skipping %s: no definition found in %s\n" % (func, path))
            continue
        ranges.append((start, end, func))

    if not ranges:
        sys.stderr.write("none of the named functions were found in %s\n" % path)
        return 1

    def covering(i):
        for start, end, func in ranges:
            if start <= i <= end:
                return func
        return None

    def at_func_end(i):
        """Is this line a instrumented function's OWN closing brace?

        The rejoin marker is guarded by a file-wide brace counter, and that
        counter drifts: braces inside string literals and comments are counted,
        and over six thousand lines of tccgen.c it ends up off. A drifted depth
        lets the guard pass on a function's final brace, which emits

            }
            write(2, "N34\\n", 4);      <- FILE SCOPE

        and micro-c rejects it with `Unknown type write` -- an error that names
        the marker rather than the placement, which is why it reads as
        nonsense.

        The function's own end is known exactly, from the range that was
        computed by matching braces from its definition. Use that instead of
        trusting the running counter.
        """
        for start, end, func in ranges:
            if i == end:
                return True
        return False

    out = []
    mapping = []
    skipped = []
    n = 0
    depth = 0
    for i, line in enumerate(lines):
        out.append(line)
        func = covering(i)

        # MARK WHERE CONTROL REJOINS, not only where it enters.
        #
        # A marker after `if (...) {` sits INSIDE the body, so it never prints
        # when the branch is not taken -- and "last marker" then understates
        # how far execution got. That is what happened here: the last marker
        # was memcpy, the next was inside `if (s1->do_debug && filename)`, and
        # do_debug is zero, so the branch was skipped and the fault was
        # actually several statements further on with nothing to say so.
        #
        # A closing brace that leaves the block still inside the function is a
        # rejoin point, and both paths pass through it.
        closing = line.strip() == '}' or line.strip().startswith('} else') \
                  or line.strip() == '};'
        before = depth
        for ch in line:
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1

        if func is not None and closing and depth >= 1 and before > depth \
                and not at_func_end(i):
            n += 1
            tag = "%s%02d" % (prefix, n)
            indent = line[:len(line) - len(line.lstrip())]
            out.append('%swrite(2, "%s\\n", %d);' % (indent, tag, len(tag) + 1))
            mapping.append((tag, i + 1, "%s: (rejoin) %s" % (func, line.strip())))
            continue

        if func is not None and instrumentable(line):
            # THE BODY OF A BRACELESS CONTROL HEADER GETS BRACED.
            #
            # Appending the marker on its own would put it OUTSIDE the loop or
            # branch. Wrapping both in braces keeps the marker where it reads
            # as it does everywhere else -- once per execution of that body --
            # and keeps the program meaning identical.
            prev = prev_code_line(lines, i)
            prev_t = prev.strip() if prev is not None else ''

            # A LOOP HEADER WITH THE BRACE ON THE NEXT LINE is still a loop
            # header. The existing guard only caught `while (x) {`; written
            #     while (x)
            #     {
            # the brace line was instrumented and the marker repeated every
            # iteration -- the drowning this file set out to avoid, just in
            # the other brace style.
            if line.strip() == '{' and re.match(r'^(for|while|do)\b', prev_t):
                continue

            # Only wrap when this line really IS the unbraced body. If the
            # next thing after the header is a brace, the body is braced
            # already and wrapping it would add a block that changes nothing
            # and reads as though it did.
            wrap = prev is not None and opens_braceless_body(prev) \
                   and line.strip() != '{'

            if is_single_line_branch(line):
                # header and body on one line: a marker after it is
                # unconditional and would mean something different from every
                # other marker. Recorded as skipped, not silently dropped.
                skipped.append((i + 1, line.strip()))
                continue

            n += 1
            tag = "%s%02d" % (prefix, n)
            indent = line[:len(line) - len(line.lstrip())]
            if wrap:
                out[-1] = '%s{ %s' % (indent, line.strip())
                out.append('%swrite(2, "%s\\n", %d); }' % (indent, tag, len(tag) + 1))
                mapping.append((tag, i + 1, "%s: (braced) %s" % (func, line.strip())))
            else:
                out.append('%swrite(2, "%s\\n", %d);' % (indent, tag, len(tag) + 1))
                mapping.append((tag, i + 1, "%s: %s" % (func, line.strip())))

    if map_only:
        for tag, lineno, text in mapping:
            print("%s  %s:%d  %s" % (tag, path, lineno, text[:70]))
        # A LINE WITH NO MARKER IS A BLIND SPOT, and a blind spot the reader
        # does not know about is how "the instrument went quiet" gets read as
        # "the program became mysterious". Name them.
        for lineno, text in skipped:
            print("--   %s:%d  (no marker: single-line branch) %s"
                  % (path, lineno, text[:60]))
        return 0

    sys.stdout.write('\n'.join(out))
    sys.stderr.write("instrumented %d function(s): %d markers\n"
                     % (len(ranges), n))
    return 0


if __name__ == '__main__':
    sys.exit(main())
