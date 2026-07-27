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

WHAT IT DOES NOT DO. It does not evaluate shell. Programs assembled from shell
variables ("$DECLS$APPENDF'...'), printf escape forms, and anything with
unbalanced quoting are SKIPPED, counted, and reported by reason. Silently
dropping them would be the one failure mode that matters here, because a
shrinking corpus still passes.

--floor N fails if fewer than N tests come out, so a refactor of the demo that
breaks the invocation shape cannot quietly turn the gate into a no-op.
"""

import re
import shlex
import sys
from collections import Counter

HARNESSES = (
    "try vtry ftry stry gtry ptry btry etry pptry ltry dwtry wtry ttry"
).split()

# The demo's harness calls sit at exactly ten spaces of indentation, inside a
# `run: |` block. Anchoring on that avoids matching the same names in comments.
CALL = re.compile(r"^\s{10}(" + "|".join(HARNESSES) + r")\s+(\S.*)$")


def extract(lines):
    tests, skipped = [], []
    for raw in lines:
        m = CALL.match(raw)
        if not m:
            continue
        harness, rest = m.group(1), m.group(2).strip()
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
        if "\n" in prog or "\\n" in prog or "\t" in prog:
            # The corpus format is one test per line, tab-separated. A program
            # carrying either character cannot survive the round trip, and
            # mangling it into something that still compiles would be worse
            # than not running it.
            skipped.append((harness, "escape or newline form", rest))
            continue
        tests.append((harness, want, prog))
    return tests, skipped


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
    args = argv

    with open(args[0], encoding="utf-8") as fh:
        tests, skipped = extract(fh.read().splitlines())

    with open(args[1], "w", encoding="utf-8") as out:
        for _, want, prog in tests:
            out.write("%s\t%s\n" % (want, prog))

    print("  extracted %d tests from %s" % (len(tests), args[0]))
    by_harness = Counter(h for h, _, _ in tests)
    print("    " + "  ".join("%s=%d" % kv for kv in sorted(by_harness.items())))

    if skipped:
        print("  skipped %d (reported, never silent):" % len(skipped))
        for reason, count in Counter(r for _, r, _ in skipped).most_common():
            print("    %-28s %d" % (reason, count))
        # one worked example per reason, so the next reader can judge
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
