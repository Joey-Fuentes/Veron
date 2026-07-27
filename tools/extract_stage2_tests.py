#!/usr/bin/env python3
"""extract_stage2_tests.py -- lift the stage-2 conformance corpus out of
.github/workflows/stage2-mini-c-demo.yml so another job can run it.

    usage: extract_stage2_tests.py <demo.yml> <out.tsv> [--floor N]

WHY THIS EXISTS. stage2-mini-c-demo.yml carries ~450 example programs, each an
invocation of one of thirteen near-identical harnesses:

    <harness> '<program>' <expected-exit-code> ['<label>']

Copying them into a second workflow would fork the corpus, and a forked corpus
drifts silently -- the copy stays green while the original grows a case it does
not have. So the demo stays the single source of truth and this script reads it.
Add a test there and every job that runs the corpus picks it up.

TWO PRINTF FORMS, AND THE FIRST VERSION GOT THIS WRONG. The harnesses do not
all write their program the same way:

    try, vtry, ftry, ... :  printf '%s' "$1"   -- program written LITERALLY
    etry, pptry          :  printf "$1"        -- program is a printf FORMAT,
                                                  so \\047 \\134 \\042 \\n are
                                                  INTERPRETED before compiling

v1 treated everything as literal, so all 34 escape-form tests were handed to
stage 2 as the raw text `c=\\047\\134n\\047;` instead of `c='\\n';`. Sixteen of
them failed and looked exactly like stage-2 codegen defects. They were not.
That is the expensive kind of wrong: a green-looking harness manufacturing red
results in the component under test.

So the form is DERIVED, not assumed -- the script reads each harness's own
definition out of the demo and classifies it. If someone adds a fourteenth
harness, or changes an existing one's printf, this follows automatically.

WHAT IT STILL SKIPS. Programs assembled from shell variables, and anything whose
decoded text contains a real tab or newline (the corpus is one test per line,
tab-separated). Skips are counted and reported BY REASON, never silent, because
a shrinking corpus still passes.

--floor N fails if fewer than N tests come out, so a refactor of the demo that
breaks the invocation shape cannot quietly turn the gate into a no-op.
"""

import re
import shlex
import sys
from collections import Counter

# Harness definition:  `          name() {`  at ten spaces of indent.
DEFN = re.compile(r"^\s{10}([a-z][a-z0-9_]*)\(\)\s*\{\s*$")
# Its first printf, within a few lines of the opening brace.
LITERAL_PRINTF = re.compile(r"""printf\s+'%s'\s+"\$1\"""")
FORMAT_PRINTF = re.compile(r"""printf\s+"\$1"|printf\s+"\$\{1\}\"""")

SIMPLE = {
    "\\": "\\", "a": "\a", "b": "\b", "f": "\f",
    "n": "\n", "r": "\r", "t": "\t", "v": "\v",
}


def printf_decode(s):
    """Decode a POSIX printf format string the way `printf "$1"` would.

    Handles \\NNN and \\0NNN octal (which is what the demo's char-literal and
    string-literal tests are built from: \\047 = ' , \\134 = \\ , \\042 = ")
    plus the standard single-character escapes. A single left-to-right pass, so
    a decoded backslash is never re-interpreted as the start of a new escape --
    \\134n must come out as the two characters \\ and n, which is the C escape
    the test is actually about, not as a newline.
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


def extract(lines):
    """Single positional pass: definitions and calls in file order.

    FOUR HARNESSES ARE REDEFINED MID-FILE -- etry, ftry, ptry, btry -- and
    etry's two definitions do not agree: the first (line ~1046) is
    `printf "$1"`, the second (~1746) is `printf '%s' "$1"`. So "what form is
    etry?" has no single answer; it depends on where the call sits. Building a
    name->form map in one pass and applying it to the whole file gets 34 tests
    wrong in whichever direction the last definition happens to point.

    Walking in order and classifying each call by the definition CURRENTLY in
    scope is both correct and exactly what the shell itself does.
    """
    forms = {}
    seen_defs = []
    tests, skipped = [], []
    call = re.compile(r"^\s{10}([a-z][a-z0-9_]*)\s+(\S.*)$")

    for idx, raw in enumerate(lines):
        m = DEFN.match(raw)
        if m:
            name = m.group(1)
            body = "\n".join(lines[idx + 1: idx + 10])
            if LITERAL_PRINTF.search(body):
                forms[name] = "literal"
            elif FORMAT_PRINTF.search(body):
                forms[name] = "format"
            else:
                continue
            seen_defs.append((name, forms[name], idx + 1))
            continue

        m = call.match(raw)
        if not m:
            continue
        harness, rest = m.group(1), m.group(2).strip()
        if harness not in forms:
            continue          # not a test harness, or not yet defined
        try:
            parts = shlex.split(rest, posix=True)
        except ValueError:
            skipped.append((harness, "unbalanced quotes", rest))
            continue
        if len(parts) < 2:
            skipped.append((harness, "too few arguments", rest))
            continue
        prog, want = parts[0], parts[1]
        if "$" in prog:
            skipped.append((harness, "shell variable in program", rest))
            continue
        if not want.isdigit():
            skipped.append((harness, "non-numeric expectation", rest))
            continue
        if forms[harness] == "format":
            prog = printf_decode(prog)
        if "\n" in prog or "\t" in prog:
            skipped.append((harness, "multi-line program", rest))
            continue
        tests.append((harness, want, prog))
    return tests, skipped, seen_defs


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
        for _, want, prog in tests:
            out.write("%s\t%s\n" % (want, prog))

    print("  harness definitions, in file order (form is positional):")
    for name, form, line in defs:
        mark = "   <- escapes decoded" if form == "format" else ""
        print("    line %-5s %-8s %s%s" % (line, name, form, mark))
    print("  extracted %d tests from %s" % (len(tests), argv[0]))
    by_harness = Counter(h for h, _, _ in tests)
    print("    " + "  ".join("%s=%d" % kv for kv in sorted(by_harness.items())))

    if skipped:
        print("  skipped %d (reported, never silent):" % len(skipped))
        for reason, count in Counter(r for _, r, _ in skipped).most_common():
            print("    %-28s %d" % (reason, count))
        seen = set()
        for harness, reason, rest in skipped:
            if reason in seen:
                continue
            seen.add(reason)
            print("      e.g. [%s] %s %s" % (reason, harness, rest[:88]))

    if len(tests) < floor:
        print("FAIL: extracted %d tests, floor is %d." % (len(tests), floor))
        print("      The demo's harness shape probably changed. Fix this script")
        print("      rather than lowering the floor -- a shrinking corpus still")
        print("      passes, which is the whole reason the floor is here.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
