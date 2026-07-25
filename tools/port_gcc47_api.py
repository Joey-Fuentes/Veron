#!/usr/bin/env python3
"""Adapt gcc 4.8 middle-end API calls in a backported backend to 4.7 signatures.

WHY
---
Moving 4.8's aarch64 backend into 4.7 gets remarkably far: config.gcc accepts
the target, all six generator programs build, the generators read the machine
description (after tools/expand_int_iterators.py handles the 4.8-only
constructs), and 264 objects compile. What is left is genuine middle-end API
drift, and the measurement is small -- ONE function:

    16 error: too many arguments to function 'plus_constant'

`plus_constant` gained a leading mode parameter in 4.8:

    4.7   extern rtx plus_constant (rtx, HOST_WIDE_INT);
    4.8   extern rtx plus_constant (enum machine_mode, rtx, HOST_WIDE_INT);

In 4.7 the mode is taken from the rtx operand, so the adaptation is to drop the
explicit mode. That is only correct when the mode passed equals the operand's
own mode -- which holds for every call here: 21 pass Pmode with a pointer-valued
rtx, and one passes `mode` alongside `reg` of that same mode. The tool prints
each first argument it removes so that assumption stays visible in review
rather than buried.

This is a NAMED, REVIEWABLE DELTA in the same spirit as tools/drop_asm.py and
tools/expand_int_iterators.py -- not a fork of upstream.

DESIGN
------
The table below is meant to grow. Each entry is one upstream signature change,
with the arity check that proves the rewrite applied to the right thing. If a
later run turns up another drifted call, add a row rather than a special case.
"""

import argparse
import os
import re
import sys


# Each rule: (function name, how many args 4.8 takes, how many 4.7 takes,
#             which argument index to drop, a note for the log)
RULES = [
    ("plus_constant", 3, 2, 0,
     "4.8 added a leading mode; 4.7 infers it from the rtx operand"),
]


def split_args(text, start):
    """Given text[start] == '(', return (args, end_index_after_close).

    Splits on top-level commas only: nested calls, bracketed subscripts and
    string literals all contain commas that must not be treated as separators.
    """
    assert text[start] == '('
    depth, i, n = 0, start, len(text)
    args, cur, instr = [], [], False
    while i < n:
        c = text[i]
        if instr:
            cur.append(c)
            if c == '\\' and i + 1 < n:
                cur.append(text[i + 1]); i += 2; continue
            if c == '"':
                instr = False
        elif c == '"':
            instr = True; cur.append(c)
        elif c in '([{':
            depth += 1
            if depth > 1:
                cur.append(c)
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                args.append("".join(cur))
                return args, i + 1
            cur.append(c)
        elif c == ',' and depth == 1:
            args.append("".join(cur)); cur = []
        else:
            cur.append(c)
        i += 1
    raise SystemExit(f"unterminated argument list at offset {start}")


def apply_rule(text, name, argc_48, argc_47, drop, path, verbose):
    """Rewrite calls to `name` that carry the 4.8 argument count."""
    out, i, n, count = [], 0, len(text), 0
    pat = re.compile(r'\b' + re.escape(name) + r'\b\s*\(')
    while True:
        m = pat.search(text, i)
        if not m:
            out.append(text[i:])
            break
        open_paren = m.end() - 1
        try:
            args, after = split_args(text, open_paren)
        except SystemExit:
            out.append(text[i:m.end()]); i = m.end(); continue

        if len(args) != argc_48:
            # Already 4.7-shaped, or something this rule does not describe.
            out.append(text[i:after]); i = after; continue

        dropped = args[drop].strip().replace('\n', ' ')
        dropped = re.sub(r'\s+', ' ', dropped)
        kept = [a for k, a in enumerate(args) if k != drop]
        # The dropped argument often sat alone on the first line, leaving the
        # next one starting with a newline: `plus_constant (\n   base_rtx,...`.
        # Valid C, but ugly in a source someone has to review. Pull it up.
        if kept and kept[0][:1] in '\n\r':
            kept[0] = kept[0].lstrip()
        if verbose:
            print(f"      {os.path.basename(path)}: dropped `{dropped}`")
        out.append(text[i:m.start()])
        out.append(name + " (" + ",".join(kept) + ")")
        i = after
        count += 1
    return "".join(out), count


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dir', help='backend directory to rewrite in place')
    ap.add_argument('--check', action='store_true', help='report only')
    ap.add_argument('-q', '--quiet', action='store_true')
    args = ap.parse_args()

    total = 0
    for name, argc48, argc47, drop, note in RULES:
        print(f"  {name}: {argc48} args -> {argc47}")
        print(f"    {note}")
        n_this = 0
        for fn in sorted(os.listdir(args.dir)):
            if not fn.endswith(('.c', '.h', '.md')):
                continue
            path = os.path.join(args.dir, fn)
            text = open(path).read()
            if name not in text:
                continue
            new, cnt = apply_rule(text, name, argc48, argc47, drop, path,
                                  not args.quiet)
            if cnt:
                print(f"    {fn:<20} {cnt} call(s)")
                n_this += cnt
                if not args.check:
                    open(path, 'w').write(new)
        print(f"    total: {n_this} call(s) adapted")
        total += n_this

    if not args.check:
        # Verify nothing 4.8-shaped survives.
        bad = []
        for name, argc48, _, _, _ in RULES:
            for fn in sorted(os.listdir(args.dir)):
                if not fn.endswith(('.c', '.h', '.md')):
                    continue
                text = open(os.path.join(args.dir, fn)).read()
                for m in re.finditer(r'\b' + re.escape(name) + r'\b\s*\(', text):
                    try:
                        a, _ = split_args(text, m.end() - 1)
                    except SystemExit:
                        continue
                    if len(a) == argc48:
                        bad.append(f"{fn}: {name} still has {argc48} args")
        if bad:
            print("  VERIFY FAILED:")
            for b in bad[:10]:
                print(f"    {b}")
            sys.exit(1)
        print(f"  verified: no call retains a 4.8-only signature ({total} adapted)")


if __name__ == '__main__':
    main()
