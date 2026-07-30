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


# ---------------------------------------------------------------------------
# LEXICAL MASKING, done once; everything structural reads the masked copy.
#
# Brace depth used to be counted in the RAW text, so a brace inside a string or
# a comment voted. Measured on the pinned tree, tccpp.c ends at raw depth -2 and
# masked depth 0 -- the drift is real, it is those braces, and it is not the
# #ifdef blocks it was attributed to. That drift is one of the three reasons
# --entry mode exists.
#
# Lengths are preserved exactly, so masked[i] and lines[i] agree column for
# column.
# ---------------------------------------------------------------------------
def mask_source(lines):
    """Blank out string bodies, char bodies and comments. Same shape, no lexemes."""
    out = []
    in_block_comment = False
    for line in lines:
        buf = []
        i = 0
        n = len(line)
        while i < n:
            c = line[i]
            if in_block_comment:
                if c == '*' and i + 1 < n and line[i + 1] == '/':
                    in_block_comment = False
                    buf.append('  ')
                    i += 2
                    continue
                buf.append(' ')
                i += 1
                continue
            if c == '/' and i + 1 < n and line[i + 1] == '*':
                in_block_comment = True
                buf.append('  ')
                i += 2
                continue
            if c == '/' and i + 1 < n and line[i + 1] == '/':
                buf.append(' ' * (n - i))
                i = n
                continue
            if c == '"' or c == "'":
                quote = c
                buf.append(quote)
                i += 1
                while i < n:
                    if line[i] == '\\' and i + 1 < n:
                        buf.append('  ')
                        i += 2
                        continue
                    if line[i] == quote:
                        buf.append(quote)
                        i += 1
                        break
                    buf.append(' ')
                    i += 1
                continue
            buf.append(c)
            i += 1
        m = ''.join(buf)
        out.append(m[:len(line)] if len(m) > len(line) else m + ' ' * (len(line) - len(m)))
    return out


def brace_depths(masked):
    """depth_before[i], depth_after[i] for every line, from masked text."""
    before, after = [], []
    d = 0
    for line in masked:
        before.append(d)
        for ch in line:
            if ch == '{':
                d += 1
            elif ch == '}':
                d -= 1
        after.append(d)
    return before, after


def switch_lines(masked):
    """Lines covered by a `switch (...) { ... }` BODY, plus the spans.

    micro-c answers a statement placed in there with `ERROR in process_switch /
    MISSING }`. Skipping the marker is right; skipping the whole FUNCTION, which
    is what was done before, costs next_nomacro, tok_str_add2, unary, decl and
    block -- most of the token path and most of tccgen.
    """
    flat = '\n'.join(masked)
    starts = [0]
    for line in masked:
        starts.append(starts[-1] + len(line) + 1)

    def line_of(pos):
        lo, hi = 0, len(masked) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo

    covered, spans = set(), []
    for m in re.finditer(r'\bswitch\b', flat):
        i = flat.find('{', m.end())
        if i < 0:
            continue
        d, j = 0, i
        while j < len(flat):
            if flat[j] == '{':
                d += 1
            elif flat[j] == '}':
                d -= 1
                if d == 0:
                    break
            j += 1
        if d != 0:
            continue
        a, b = line_of(i), line_of(j)
        spans.append((a, b))
        for k in range(a, b + 1):
            covered.add(k)
    return covered, spans


def find_function(lines, name, masked=None, depth_before=None, depth_after=None):
    """Return (body_open, body_close) line indices of the DEFINITION.

    A CALL SITE IS NOT A DEFINITION. This used to take the first line
    containing `name(` that reached an opening brace within twelve lines, and
    on the pinned tree that is not the definition:

        tccgen.c:7274   if (!decl(VT_JMP)) {        <- was MATCHED
        tccgen.c:8664   static int decl(int l)      <- is the definition

        tccgen.c:4574   if (!parse_btype(&btype, &ad1, 0)) {   <- was MATCHED
        tccgen.c:4712   static int parse_btype(...)            <- is the definition

    The `{` closing that `if` header opened a block, the tool called it the
    body, and it instrumented two lines of block() while labelling every marker
    `decl:`. A wrong map and a right map look identical in a log, so nothing
    downstream could catch it.

    A definition is at FILE SCOPE. Candidates are required to sit at brace
    depth 0, measured on the masked copy, and a candidate reaching `;` before
    `{` is a prototype.
    """
    if masked is None:
        masked = mask_source(lines)
    if depth_before is None:
        depth_before, depth_after = brace_depths(masked)
    pattern = re.compile(r'\b' + re.escape(name) + r'\s*\(')
    for i, mline in enumerate(masked):
        if depth_before[i] != 0:
            continue                    # inside some other function's body
        if not pattern.search(mline):
            continue
        j, limit, opened = i, min(i + 16, len(masked)), None
        while j < limit:
            seg = masked[j]
            b, sc = seg.find('{'), seg.find(';')
            if sc >= 0 and (b < 0 or sc < b):
                break                   # prototype
            if b >= 0:
                opened = j
                break
            j += 1
        if opened is None:
            continue
        if depth_after[opened] < 1:
            continue                    # `{` closed again on the same line
        for k in range(opened, len(masked)):
            if depth_after[k] == 0:
                return opened, k
        return opened, len(masked) - 1
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
    entry_only = False
    prefix = 'L'
    if args and args[0] == '--map':
        map_only = True
        args = args[1:]
    # ONE MARKER PER FUNCTION, AT ITS FIRST STATEMENT.
    #
    # Per-statement marking cannot be used on large functions here. It has to
    # decide where a statement boundary is, and it gets that wrong in three
    # ways that all produce a BROKEN COMPILE rather than a bad trail: a marker
    # between `}` and `else`, a marker between one case body and the next
    # `case`, and -- because brace depth is counted textually while tccgen.c is
    # full of #ifndef blocks -- a marker emitted at FILE SCOPE after a function
    # it thought was still open. micro-c then says "else is not a defined
    # symbol", "ERROR in process_switch", or "Unknown type write".
    #
    # Entry marking has none of those decisions to make: the position is the
    # first line of a body the range-finder already located, which is always a
    # legal place for a statement. It answers a coarser question -- which
    # function, not which statement -- but it answers it for EVERY function in
    # a file, which is what naming a crash in a 4000-line parser actually
    # needs.
    if args and args[0] == '--entry':
        entry_only = True
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
    masked = mask_source(lines)
    depth_before, depth_after = brace_depths(masked)
    sw_lines, sw_spans = switch_lines(masked)

    ranges = []
    for func in funcnames.split(','):
        func = func.strip()
        if not func:
            continue
        start, end = find_function(lines, func, masked, depth_before, depth_after)
        if start is None:
            # "no DEFINITION found" and not "skipping": the old wording read as
            # a function that was absent, when what it usually meant was that a
            # call site had been matched instead. Say which question failed.
            sys.stderr.write("no DEFINITION found for %s in %s "
                             "(a call site is not a definition)\n" % (func, path))
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

    # SWITCH BODIES INSIDE THE INSTRUMENTED SET, named so a trail that stops
    # just before one is explained rather than mysterious.
    blind = []
    for _a, _b in sw_spans:
        _f = covering(_a)
        if _f is not None:
            blind.append((_f, _a + 1, _b + 1))

    out = []
    mapping = []
    skipped = []
    n = 0

    if entry_only:
        # ONE MARKER, AT THE FIRST LINE OF EACH BODY. No statement-boundary
        # decisions, so none of the three ways the per-statement path breaks a
        # compile can happen here.
        starts = {}
        for start, end, func in ranges:
            starts[start] = func
        for i, line in enumerate(lines):
            out.append(line)
            if i in starts:
                n += 1
                tag = "%s%02d" % (prefix, n)
                out.append('    write(2, "%s\\n", %d);' % (tag, len(tag) + 1))
                mapping.append((tag, i + 1, "%s: ENTRY" % starts[i]))
        if map_only:
            for tag, ln, what in mapping:
                sys.stdout.write("%s  %s:%d  %s\n" % (tag, path, ln, what))
        else:
            sys.stdout.write('\n'.join(out))
        return 0

    for i, line in enumerate(lines):
        out.append(line)
        func = covering(i)

        # NO MARKERS INSIDE A SWITCH BODY, rather than no markers in a function
        # that HAS one. micro-c rejects a statement placed there with `ERROR in
        # process_switch / MISSING }`; the rest of the function is still worth
        # instrumenting, and the switch is reported as a `!!` blind spot with
        # its line range.
        if func is not None and i in sw_lines:
            continue

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
        # A REJOIN LINE HAS TO BE A COMPLETE ONE.
        #
        # `startswith('} else')` was the whole test, and an else-if whose
        # CONDITION runs onto the next line is not a complete anything:
        #
        #     tccpp.c:2892  } else if ((isidnum_table['.' - CH_EOF] & IS_ID)
        #     tccpp.c:2893                  && ...) {
        #
        # The marker landed after the first half and gcc said `expected ')'
        # before 'write'`. Same shape at tccgen.c:9434. A bare `} else` with an
        # unbraced body fails the same way, between the else and its statement.
        #
        # So: the line must END the construct AND its parentheses must balance,
        # counted on the MASKED copy so a bracket in a string cannot vote.
        stripped = line.strip()
        mline = masked[i]
        balanced = mline.count('(') == mline.count(')')
        closing = balanced and (
            stripped == '}' or stripped == '};'
            or (stripped.startswith('} else') and stripped.endswith('{')))
        before = depth_before[i]
        depth = depth_after[i]

        # NOT IF THE NEXT THING IS else, case, default OR ANOTHER CLOSE.
        #
        # A marker is a statement, and a statement is not legal between a
        # closing brace and the `else` that continues it, nor between the end
        # of one case body and the `case` that follows, nor after the last
        # statement of a block whose closer comes next. Inserting there
        # produced, from micro-c,
        #
        #     tccgen.c:594:  else is not a defined symbol
        #     tccgen.c:5600: ERROR in process_switch / MISSING }
        #
        # -- and, because the compile output was not checked, a ZERO-BYTE
        # libtcc.M1 and a stale binary that was then read as evidence. That is
        # why this tool worked on three small functions and fell over on decl,
        # block and unary, which are full of both constructs.
        nxt = ''
        for _j in range(i + 1, min(i + 4, len(lines))):
            _t = lines[_j].strip()
            if _t:
                nxt = _t
                break
        unsafe_next = (nxt.startswith('else') or nxt.startswith('case ')
                       or nxt.startswith('case(') or nxt.startswith('default:')
                       or nxt.startswith('}'))

        if func is not None and closing and depth >= 1 and before > depth \
                and not unsafe_next and not at_func_end(i):
            n += 1
            tag = "%s%02d" % (prefix, n)
            indent = line[:len(line) - len(line.lstrip())]
            out.append('%swrite(2, "%s\\n", %d);' % (indent, tag, len(tag) + 1))
            mapping.append((tag, i + 1, "%s: (rejoin) %s" % (func, line.strip())))
            continue

        if func is not None and instrumentable(line) and not unsafe_next:
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
        for func, a, b in blind:
            print("!!   %s:%d-%d  (no markers: SWITCH BODY in %s, %d lines) "
                  "a fault in here shows as the last marker BEFORE it"
                  % (path, a, b, func, b - a + 1))
        return 0

    sys.stdout.write('\n'.join(out))
    sys.stderr.write("instrumented %d function(s): %d markers, "
                     "%d switch blind spot(s)\n"
                     % (len(ranges), n, len(blind)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
