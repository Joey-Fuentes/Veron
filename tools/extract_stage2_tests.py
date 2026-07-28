#!/usr/bin/env python3
"""extract_stage2_tests.py -- lift the stage-2 conformance corpus out of
the stage2-pico-c-demo workflow so another job can run it.

The demo may live in .github/workflows/ or .github/workflows-archive/ -- the
caller passes the path, because archiving a workflow stops GitHub executing it
but does not stop this reading it as data.

    usage: extract_stage2_tests.py <demo.yml> <out.tsv> [--floor N]

Output is one test per line, three fields separated by 0x1F (ASCII US):

    <expected-exit-code>  <runtime argv, may be empty>  <program source>

THE SEPARATOR IS NOT A TAB, AND THAT IS LOAD-BEARING. POSIX classifies tab as
IFS *white space*, so a shell `read -r a b c` collapses a run of tabs into one
delimiter -- an empty middle field simply vanishes and every later field shifts
left. With argv empty on 414 of 426 rows, a tab-separated corpus would hand the
program text to the argv variable on almost every line. 0x1F is not IFS white
space, so empty fields survive, and it cannot occur in C source.

WHY THIS EXISTS. stage2-pico-c-demo.yml carries ~490 example programs across
21 harness definitions. Copying them into a second workflow would fork the
corpus, and a forked corpus drifts silently -- the copy stays green while the
original grows a case it does not have. So the demo stays the single source of
truth and this script reads it. Add a test there and every job that runs the
corpus picks it up.

EVERYTHING ABOUT A HARNESS IS DERIVED FROM ITS OWN DEFINITION, NOT ASSUMED.
That rule was learned three times, each time by shipping a green harness that
manufactured red results in the component under test:

  1. PRINTF FORM. Most harnesses write the program with `printf '%s' "$1"`
     (literal). etry, pptry and c23 use `printf "$1"`, so \\047 \\134 \\042 are
     INTERPRETED first. Treating those as literal fed stage 2 the raw text
     `c=\\047\\134n\\047;` instead of `c='\\n';` -- 16 failures that looked
     exactly like codegen defects and were not. The demo's own c23 comment
     records upstream hitting the identical trap.

  2. THE FORM IS POSITIONAL. etry, ftry, ptry and btry are each defined TWICE,
     and etry's two definitions disagree -- format at ~1046, literal at ~1746.
     So "what form is etry?" has no single answer; it depends where the call
     sits. This walks the file in order and classifies each call by the
     definition then in scope, which is what the shell itself does.

  3. RUNTIME ARGV. atry runs the built binary as `./a.out $3` -- a third
     positional argument carrying the argv to test against. Dropping it ran all
     13 argc/argv tests with no arguments; 7 failed. The run line is parsed for
     that positional and it becomes the corpus's second column.

A harness is only registered if its body has all three of: a printf that writes
the program, a line that RUNS the built binary, and a `"$rc" = "$2"` comparison.
Anything else is not an exit-code test and must not be run as one.

WHAT IT STILL SKIPS, counted and reported BY REASON, never silently -- because a
shrinking corpus still passes: programs assembled from shell variables, the
wsame/tsame pairs (which compare two programs' output rather than an exit code),
and anything whose decoded text contains a real tab, newline or 0x1F.

--floor N fails if fewer than N tests come out, so a refactor of the demo that
breaks the invocation shape cannot quietly turn the gate into a no-op.
"""

import re
import shlex
import sys
from collections import Counter

DEFN = re.compile(r"^\s{10}([a-z][a-z0-9_]*)\(\)\s*\{\s*$")
CALL = re.compile(r"^\s{10}([a-z][a-z0-9_]*)\s+(\S.*)$")

LITERAL_PRINTF = re.compile(r"""printf\s+'%s'\s+"\$\{?1\}?\"""")
FORMAT_PRINTF = re.compile(r"""printf\s+"\$\{?1\}?"\s""")
# the line that runs the built binary, with any positional argv appended
RUNS_BINARY = re.compile(r"\./a\.out((?:\s+\$\{?\d\}?)*)\s*;")
RC_COMPARE = re.compile(r"""\[\s*"\$rc"\s*=\s*"\$\{?2\}?"\s*\]""")
ARGV_POS = re.compile(r"\$\{?(\d)\}?")

SIMPLE = {
    "\\": "\\", "a": "\a", "b": "\b", "f": "\f",
    "n": "\n", "r": "\r", "t": "\t", "v": "\v",
}


def printf_decode(s):
    """Decode a POSIX printf format string the way `printf "$1"` would.

    Handles \\NNN and \\0NNN octal -- which is what the char-literal and
    string-literal tests are built from (\\047 = ' , \\134 = \\ , \\042 = ")
    -- plus the standard single-character escapes. One left-to-right pass, so a
    decoded backslash is never re-read as the start of a new escape: \\134n must
    come out as the two characters \\ and n, the C escape the test is about, not
    as a newline.
    """
    out = []
    i, end = 0, len(s)
    while i < end:
        c = s[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        i += 1
        if i >= end:
            out.append("\\")
            break
        d = s[i]
        if d == "0" and i + 1 < end and s[i + 1] in "01234567":
            i += 1
            d = s[i]
        if d in "01234567":
            digits = ""
            while i < end and len(digits) < 3 and s[i] in "01234567":
                digits += s[i]
                i += 1
            out.append(chr(int(digits, 8)))
            continue
        if d in SIMPLE:
            out.append(SIMPLE[d])
            i += 1
            continue
        out.append("\\")
        out.append(d)
        i += 1
    return "".join(out)


def classify(body):
    """Return (form, argv_index) for a harness body, or None if not a test."""
    if LITERAL_PRINTF.search(body):
        form = "literal"
    elif FORMAT_PRINTF.search(body):
        form = "format"
    else:
        return None
    run = RUNS_BINARY.search(body)
    if not run or not RC_COMPARE.search(body):
        return None
    pos = ARGV_POS.findall(run.group(1))
    return form, (int(pos[0]) if pos else 0)


def extract(lines):
    active = {}          # name -> (form, argv_index), as currently in scope
    defs, tests, skipped = [], [], []

    for idx, raw in enumerate(lines):
        m = DEFN.match(raw)
        if m:
            name = m.group(1)
            info = classify("\n".join(lines[idx + 1: idx + 18]))
            if info is None:
                defs.append((idx + 1, name, "-", "not an exit-code test"))
                active.pop(name, None)
                continue
            active[name] = info
            defs.append((idx + 1, name, info[0],
                         "argv=$%d" % info[1] if info[1] else ""))
            continue

        m = CALL.match(raw)
        if not m:
            continue
        name, rest = m.group(1), m.group(2).strip()
        if name not in active:
            continue
        form, argv_idx = active[name]
        try:
            parts = shlex.split(rest, posix=True)
        except ValueError:
            skipped.append((name, "unbalanced quotes", rest))
            continue
        if len(parts) < 2:
            skipped.append((name, "too few arguments", rest))
            continue
        prog, want = parts[0], parts[1]
        if "$" in prog:
            skipped.append((name, "shell variable in program", rest))
            continue
        if not want.isdigit():
            skipped.append((name, "non-numeric expectation", rest))
            continue
        args = ""
        if argv_idx:
            # $3 is parts[2]: positionals are 1-based, parts is 0-based
            if len(parts) >= argv_idx:
                args = parts[argv_idx - 1]
            if "$" in args:
                skipped.append((name, "shell variable in argv", rest))
                continue
        if form == "format":
            prog = printf_decode(prog)
        blob = prog + args
        if "\n" in blob or "\t" in blob or "\x1f" in blob:
            skipped.append((name, "multi-line program or argv", rest))
            continue
        tests.append((name, want, args, prog))
    return tests, skipped, defs


def main():
    argv = sys.argv[1:]
    floor = 0
    if "--floor" in argv:
        i = argv.index("--floor")
        floor = int(argv[i + 1])
        del argv[i:i + 2]
    if len(argv) != 2:
        print("usage: extract_stage2_tests.py <demo.yml> <out.tsv> [--floor N]")
        return 2

    with open(argv[0], encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    tests, skipped, defs = extract(lines)
    if not defs:
        print("FAIL: found no harness definitions in %s." % argv[0])
        print("      The demo's shape changed; fix this script, not the floor.")
        return 1

    with open(argv[1], "w", encoding="utf-8") as out:
        for _, want, args, prog in tests:
            out.write("%s\x1f%s\x1f%s\n" % (want, args, prog))

    print("  harness definitions in file order (form and argv are positional):")
    for line, name, form, note in defs:
        print("    line %-5s %-8s %-8s %s" % (line, name, form, note))
    print("  extracted %d tests from %s" % (len(tests), argv[0]))
    by_harness = Counter(t[0] for t in tests)
    print("    " + "  ".join("%s=%d" % kv for kv in sorted(by_harness.items())))
    print("    %d of them pass runtime arguments"
          % sum(1 for t in tests if t[2]))

    if skipped:
        print("  skipped %d (reported, never silent):" % len(skipped))
        for reason, count in Counter(s[1] for s in skipped).most_common():
            print("    %-30s %d" % (reason, count))
        seen = set()
        for name, reason, rest in skipped:
            if reason in seen:
                continue
            seen.add(reason)
            print("      e.g. [%s] %s %s" % (reason, name, rest[:80]))

    if len(tests) < floor:
        print("FAIL: extracted %d tests, floor is %d." % (len(tests), floor))
        print("      Either the demo's harness shape changed -- fix this script")
        print("      -- or tests were removed on purpose, in which case lower the")
        print("      floor in the same commit. A shrinking corpus still passes,")
        print("      which is the whole reason the floor is here.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
