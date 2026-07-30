#!/usr/bin/env python3
"""Self-test for instrument.py. Under a second, no network, no tcc.

WHY THIS EXISTS. A WRONG MARKER MAP CANNOT BE CAUGHT DOWNSTREAM. A right map
and a wrong one look identical in a log, and every reading built on the wrong
one is confident and false. That is the house failure this whole spike keeps
recording -- the tool answers confidently in a case it cannot distinguish, the
raw data is correct, and the sentence on top of it is wrong.

instrument.py has now done it seven times. Four are recorded in MICRO-C.md.
The three below were found by compiling its output instead of reading it, and
the first is the one that mattered:

    tccgen.c:7274   if (!decl(VT_JMP)) {        <- was MATCHED as the body
    tccgen.c:8664   static int decl(int l)      <- is the definition

find_function() took the first line containing `decl(` that reached an opening
brace, and the `{` closing that `if` header is one. Five functions in the set
the workflow entry-marks were affected -- decl, is_compatible_types,
parse_btype and pointed_type in tccgen.c, bind_exe_dynsyms in tccelf.c -- and
`--entry` does not help, because entry marking still has to know where the
body starts. is_compatible_types sits on the call path MICRO-C.md quotes as
the local win, so this was being read.

It is CLI-driven on purpose: it tests the tool as its callers invoke it, so a
refactor that changes the internals but keeps the interface still passes, and
one that quietly changes the interface does not.

    python3 spikes/stage3/tools/test_instrument.py
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, 'instrument.py')

FAILURES = []
NCHECKS = [0]


def check(name, cond, detail=''):
    NCHECKS[0] += 1
    if cond:
        print("  ok    %s" % name)
    else:
        FAILURES.append((name, detail))
        print("  FAIL  %s%s" % (name, ('  -- ' + detail) if detail else ''))


def run(src, funcs, *flags):
    """Instrument a fixture. Returns (out_lines, map_lines, stderr)."""
    fd, path = tempfile.mkstemp(suffix='.c')
    os.write(fd, src.encode())
    os.close(fd)
    try:
        def go(extra):
            p = subprocess.run([sys.executable, TOOL] + list(extra) + [path, funcs],
                               capture_output=True, text=True)
            return p.stdout.split('\n'), p.stderr
        out, err = go(list(flags))
        mp, _ = go(['--map'] + list(flags))
        return out, mp, err, path
    finally:
        os.unlink(path)


def entries(map_lines):
    """{func: line} from a --map --entry listing."""
    d = {}
    for l in map_lines:
        m = re.match(r'\S+\s+\S+:(\d+)\s+(\w+): ENTRY', l)
        if m:
            d[m.group(2)] = int(m.group(1))
    return d


def markers(out_lines):
    return [(i, l) for i, l in enumerate(out_lines)
            if re.match(r'\s*write\(2, "\w+\\n", \d+\);', l)]


# ---------------------------------------------------------------------------
CALLSITE = '''\
static int decl(int l);

static void block(int flags)
{
    if (tok == TOK_FOR) {
        if (!decl(VT_JMP)) {
            gexpr();
            vpop();
        }
    }
}

static int decl(int l)
{
    int v;
    v = 1;
    return v;
}
'''


def t_callsite():
    out, mp, err, path = run(CALLSITE, 'decl')
    check("a call site is not mistaken for a definition",
          not any('gexpr();' in l for l in mp),
          "instrumented block()'s body and labelled it decl")
    check("the real definition is the one instrumented",
          any('v = 1;' in l for l in mp),
          "never reached `v = 1;` in the real decl")
    check("a forward declaration is not mistaken for a definition",
          all(int(m.group(1)) > 2
              for m in (re.search(r':(\d+)\s', l) for l in mp) if m),
          "matched the prototype on line 1")

    out, mp, err, path = run(CALLSITE, 'decl', '--entry')
    e = entries(mp)
    check("--entry also lands on the definition, not the call site",
          e.get('decl', 0) > 12,
          "decl ENTRY at line %s; the definition body starts at 14" % e.get('decl'))


def t_missing():
    out, mp, err, path = run(CALLSITE, 'no_such_function')
    check("an absent function is named on stderr, not silently dropped",
          'no_such_function' in err,
          "stderr was %r" % err)


# ---------------------------------------------------------------------------
SWITCHY = '''\
static void next_nomacro(void)
{
    int c;
    c = 0;
    switch (c) {
    case 'a':
        c = 1;
        break;
    case 'b': {
        c = 2;
        break;
    }
    default:
        c = 3;
        break;
    }
    c = 4;
    c = 5;
}
'''


def t_switch():
    out, mp, err, path = run(SWITCHY, 'next_nomacro')
    # The switch body in the OUTPUT: between the `switch (c) {` line and its
    # closing brace. Any marker in that window is the bug.
    lo = next(i for i, l in enumerate(out) if 'switch (c)' in l)
    hi = next(i for i, l in enumerate(out) if i > lo and l.strip() == '}'
              and 'c = 4;' in ''.join(out[i:i + 3]))
    inside = [i for i, l in markers(out) if lo < i < hi]
    check("no marker is emitted inside a switch body",
          not inside, "markers at output lines %s" % inside)
    check("the function is still instrumented outside the switch",
          any('c = 4;' in l for l in mp),
          "the statement after the switch got no marker")
    check("the switch is reported as a named blind spot",
          any(l.startswith('!!') and 'next_nomacro' in l for l in mp),
          "no `!!` line in the map")


# ---------------------------------------------------------------------------
MULTILINE_ELSE = '''\
static void decl(int l)
{
    int t;
    t = 0;
    if (t == 1) {
        t = 2;
    } else if ((t & 3) == 0
               && !(t & 4)) {
        t = 5;
    } else {
        t = 6;
    }
    t = 7;
    t = 8;
}
'''


def t_multiline_else():
    out, mp, err, path = run(MULTILINE_ELSE, 'decl')
    idx = [i for i, l in enumerate(out) if '} else if ((t & 3) == 0' in l]
    check("no marker splits a multi-line else-if condition",
          idx and not out[idx[0] + 1].strip().startswith('write(2,'),
          "a marker was inserted between the halves of the condition")
    j = '\n'.join(out)
    check("the fixture still balances after instrumentation",
          j.count('{') == j.count('}'),
          "braces no longer balance")
    check("a marker still lands after the chain",
          any('t = 7;' in l for l in mp),
          "lost the statement after the if/else chain")


# ---------------------------------------------------------------------------
UNSAFE_NEXT = '''\
static void guarded(void)
{
    int a;
    a = 0;
    if (a) {
        a = 1;
    }
    else {
        a = 2;
    }
}
'''


def t_unsafe_next():
    """The existing guard: nothing between a close and what continues it.

    This also suppresses the LAST statement of any block, because its next
    line is `}`. That is deliberate and it is a real blind spot -- the final
    statement before a closing brace never gets a marker, so a trail that ends
    on the statement before it may have got one further. Pinned here so it
    stays a known cost rather than becoming a surprise.
    """
    out, mp, err, path = run(UNSAFE_NEXT, 'guarded')
    bad = [i for i, l in markers(out)
           if i + 1 < len(out) and out[i + 1].strip().startswith(('else', 'case ', 'default:'))]
    check("no marker between a close and the else/case that continues it",
          not bad, "markers at output lines %s" % bad)


# ---------------------------------------------------------------------------
OLD_FOUR = '''\
static void tok_alloc(void)
{
    int i, h, len;
    static char const names[2][4] = {
        "Jan", "Feb"
    };
    h = 0;
    len = 2;
    for (i = 0; i < len; i++)
        h = h + i;
    while (h)
    {
        h = h - 1;
    }
    if (h == 0) i = 1;
    do_debug_lookalike(h);
    return;
}
'''


def t_old_four():
    out, mp, err, path = run(OLD_FOUR, 'tok_alloc', '--prefix', 'P')
    check("no marker lands inside an aggregate initialiser",
          all(not out[i + 1].strip().startswith('write(2,')
              for i, l in enumerate(out) if l.strip().endswith('= {')),
          "a marker followed a `= {` line")
    check("a braceless loop body is braced, not orphaned",
          any('(braced)' in l and 'h = h + i;' in l for l in mp),
          "the for-body marker was placed outside the loop")
    check("a loop header with the brace on the next line gets no marker",
          all(not out[i + 1].strip().startswith('write(2,')
              for i, l in enumerate(out)
              if l.strip() == '{' and i and out[i - 1].strip().startswith('while')),
          "the `{` under `while (h)` was instrumented")
    check("`do` is matched as a word, not inside do_debug",
          any('do_debug_lookalike' in l for l in mp),
          "a call whose name contains 'do' was skipped")
    check("no marker after return/break/continue/goto",
          all(not re.search(r':\s*(return|break|continue|goto)\b', l) for l in mp
              if re.match(r'^[A-Z]\d', l)),
          "an unreachable marker was emitted")
    check("a single-line branch is recorded as skipped, not dropped",
          any(l.startswith('--') and 'if (h == 0) i = 1;' in l for l in mp),
          "no `--` line for the single-line branch")


def t_byte_count():
    body = '\n'.join('    x = %d;' % i for i in range(1, 130))
    src = 'static void big(void)\n{\n    int x;\n%s\n}\n' % body
    out, mp, err, path = run(src, 'big', '--prefix', 'P')
    wrong = []
    for l in out:
        m = re.search(r'write\(2, "(\w+)\\n", (\d+)\);', l)
        if m and int(m.group(2)) != len(m.group(1)) + 1:
            wrong.append(l.strip())
    check("every marker writes len(tag)+1 bytes, past the hundredth included",
          not wrong, "%d wrong, e.g. %s" % (len(wrong), wrong[:2]))
    check("a three-digit tag really was produced",
          any(re.search(r'"P\d{3}\\n"', l) for l in out),
          "the fixture never reached P100")


# ---------------------------------------------------------------------------
LEXICAL = '''\
static void noisy(void)
{
    char *a;
    a = "a brace { in a string";
    /* and a } in a comment */
    a = "an escaped \\" quote with }";
    a = 0;
    a = 0;
}

static void after(void)
{
    int z;
    z = 1;
    z = 2;
}
'''


def t_lexical():
    out, mp, err, path = run(LEXICAL, 'noisy')
    check("a brace in a string or comment does not move the depth",
          any('a = 0;' in l for l in mp),
          "lost the last statement of the function")
    out2, mp2, err2, _ = run(LEXICAL, 'after')
    check("the function after the noisy one is still found",
          any('z = 1;' in l for l in mp2),
          "depth drift lost the following function")
    out3, mp3, err3, _ = run(LEXICAL, 'noisy,after', '--entry')
    e = entries(mp3)
    check("--entry finds both functions across the noisy one",
          len(e) == 2, "found %s" % e)


def main():
    print("test_instrument.py")
    for fn in (t_callsite, t_missing, t_switch, t_multiline_else,
               t_unsafe_next, t_old_four, t_byte_count, t_lexical):
        print(" %s" % fn.__name__)
        fn()
    print()
    if FAILURES:
        print("FAIL: %d of %d checks" % (len(FAILURES), NCHECKS[0]))
        return 1
    print("PASS: %d checks" % NCHECKS[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
